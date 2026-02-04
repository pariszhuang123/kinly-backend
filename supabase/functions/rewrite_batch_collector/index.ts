// supabase/functions/rewrite_batch_collector/index.ts
// Batch collector (OpenAI-only).
// RPC-only DB access.
//
// FULL adjusted version:
// - custom_id is the rewrite_jobs.job_id UUID string (no provider_job_custom_id)
// - per-batch finalize set (no cross-batch re-finalize spam)
// - batch update RPC errors are checked (supabase.rpc does NOT throw)
// - clearer handling of "completed but missing output_file_id" (batch-level failure + recovery RPC)
// - safer JSONL parsing + bounded error text
// - retry-safe: transient issues requeue w/ backoff; permanent issues fail
// - finalize rewrite_request only when all its jobs are terminal (via finalize RPC)
//
// Required RPCs this collector expects:
// - rewrite_batch_list_pending_v1(p_limit)
// - rewrite_batch_update_v1(p_provider_batch_id, p_status, p_output_file_id, p_error_file_id)
// - rewrite_job_fetch_v1(p_job_id)
// - complaint_rewrite_request_fetch_v1(p_rewrite_request_id)
// - complete_complaint_rewrite_job(...)
// - complaint_rewrite_job_fail_or_requeue(p_job_id, p_error, p_backoff_seconds)
// - fail_complaint_rewrite_job(p_job_id, p_error)
// - complaint_rewrite_request_finalize_v1(p_rewrite_request_id)
// - complaint_rewrite_jobs_requeue_by_provider_batch_v1(p_provider_batch_id, p_reason, p_backoff_seconds, p_limit)  <-- NEW (recovery)
//
// Notes:
// - Keeps OpenAI HTTP calls (Batch GET + file download).
// - Does not write tables directly; only RPCs.

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.48.0";
import { evaluateRewrite } from "../../../tool/rewrite_eval/evaluator.ts";
import { extractRewrittenTextFromOpenAIResponseBody } from "../rewrite_batch/providers.ts";

/* ---------------- config ---------------- */

const MAX_BATCHES = 10;
const MAX_CONTENT_LENGTH = 256_000; // incoming request safety (collector endpoint itself)
const MAX_JSONL_LINE_CHARS = 2_000_000; // guard against weirdly huge single lines
const LEXICON_VERSION = "complaint_rewrite_lexicon_v1";

// backoffs
const BACKOFF_PROVIDER_SECONDS = 6 * 3600; // provider not ready / provider item failure
const BACKOFF_PARSE_SECONDS = 10 * 60; // transient parse issues
const BACKOFF_COMPLETE_SECONDS = 10 * 60; // transient DB complete issues
const BACKOFF_BATCH_DOWNLOAD_SECONDS = 30 * 60; // transient batch file download/parse issues
const BACKOFF_MISSING_OUTPUT_SECONDS = 30 * 60; // completed batch but missing output file recovery

const REQUEUE_MISSING_OUTPUT_LIMIT = 1_000;

/* ---------------- entrypoint ---------------- */

if (import.meta.main) {
  Deno.serve(async (req) => {
    const request_id = crypto.randomUUID();

    try {
      requireInternalSecret(req);
      rejectHugeBodies(req);

      const supabase = supabaseClient();
      // Single rewrite key shared with submitter
      const openaiKey = env("OPENAI_REWRITE_API_KEY");

      const pending = await listPendingBatches(supabase, MAX_BATCHES);
      if (!pending.ok) {
        return json({ ok: false, request_id, error: pending.error }, 500);
      }
      if (pending.batches.length === 0) {
        return json({ ok: true, request_id, checked: 0 }, 200);
      }

      const results: unknown[] = [];

      for (const b of pending.batches) {
        // touched rewrite_request_ids are PER BATCH (avoid re-finalizing from previous batches)
        const touchedRequestIds = new Set<string>();

        // 1) Poll provider batch
        const status = await getOpenAIBatch(openaiKey, b.provider_batch_id);
        const mappedStatus = mapOpenAIStatus(status?.status);

        // Update our batch row (RPC-only) + observe errors
        await rpcMust(supabase, "rewrite_batch_update_v1", {
          p_provider_batch_id: b.provider_batch_id,
          p_status: mappedStatus,
          p_output_file_id: status?.output_file_id ?? null,
          p_error_file_id: status?.error_file_id ?? null,
        });

        if (mappedStatus !== "completed") {
          results.push({
            provider_batch_id: b.provider_batch_id,
            status: mappedStatus,
          });
          continue;
        }

        if (!status?.output_file_id) {
          // Provider says completed but no output file.
          // 1) Mark batch failed in our DB
          await rpcBestEffort(supabase, "rewrite_batch_update_v1", {
            p_provider_batch_id: b.provider_batch_id,
            p_status: "failed",
            p_output_file_id: null,
            p_error_file_id: status?.error_file_id ?? null,
          });

          // 2) Recovery: requeue stuck jobs still in batch_submitted for this provider_batch_id
          const requeueRes = await rpcMaybeJson<RequeueByBatchResultRow[]>(
            supabase,
            "complaint_rewrite_jobs_requeue_by_provider_batch_v1",
            {
              p_provider_batch_id: b.provider_batch_id,
              p_reason: "provider_batch_completed_missing_output_file",
              p_backoff_seconds: BACKOFF_MISSING_OUTPUT_SECONDS,
              p_limit: REQUEUE_MISSING_OUTPUT_LIMIT,
            },
          );

          results.push({
            provider_batch_id: b.provider_batch_id,
            status: "failed",
            reason: "missing_output_file_id",
            requeued_jobs: Array.isArray(requeueRes) ? requeueRes.length : 0,
          });

          // Nothing else we can do for this batch.
          continue;
        }

        // 2) Download output file content
        let outputText = "";
        try {
          outputText = await downloadOpenAIFile(
            openaiKey,
            status.output_file_id,
          );
        } catch (e) {
          // Batch output download failure: try to requeue jobs in this provider_batch_id with backoff.
          // This assumes jobs are still batch_submitted (often true if collector is the first to process).
          await rpcBestEffort(
            supabase,
            "complaint_rewrite_jobs_requeue_by_provider_batch_v1",
            {
              p_provider_batch_id: b.provider_batch_id,
              p_reason: "output_download_failed",
              p_backoff_seconds: BACKOFF_BATCH_DOWNLOAD_SECONDS,
              p_limit: REQUEUE_MISSING_OUTPUT_LIMIT,
            },
          );

          results.push({
            provider_batch_id: b.provider_batch_id,
            status: "completed",
            reason: "output_download_failed",
            error: toErrorMessage(e).slice(0, 300),
          });
          continue;
        }

        const lines = outputText
          .split("\n")
          .map((x) => x.trim())
          .filter((x) => x.length > 0);

        let completed = 0;
        let failed = 0;
        let skipped = 0;

        for (const line of lines) {
          try {
            if (line.length > MAX_JSONL_LINE_CHARS) {
              throw new Error("jsonl_line_too_large");
            }

            type OpenAIBatchLine = {
              custom_id?: unknown;
              response?: { body?: unknown };
              error?: unknown;
            };

            const item = JSON.parse(line) as OpenAIBatchLine;

            // OpenAI batch output line includes custom_id.
            // In our system, custom_id MUST be the rewrite_jobs.job_id uuid string.
            const jobId = String(item?.custom_id ?? "").trim();
            if (!isUuid(jobId)) throw new Error("invalid_custom_id_uuid");

            // Fetch job first so we can validate state and get rewrite_request_id/recipient_user_id
            const job = await fetchJob(supabase, jobId);
            if (!job) {
              failed++;
              continue;
            }

            // Ensure this job belongs to this batch and is in the expected state
            if (job.provider_batch_id !== b.provider_batch_id) {
              skipped++;
              continue;
            }
            if (job.status !== "batch_submitted") {
              skipped++;
              continue;
            }

            touchedRequestIds.add(job.rewrite_request_id);

            if (item?.error) {
              // Provider-side failure for this job: requeue w/ provider backoff
              await requeueByJobId(
                supabase,
                jobId,
                `provider_item_error:${safeShort(item.error)}`,
                BACKOFF_PROVIDER_SECONDS,
              );
              failed++;
              continue;
            }

            const body = item?.response?.body;
            const rewritten = extractRewrittenTextFromOpenAIResponseBody(body);
            if (!rewritten) {
              await requeueByJobId(
                supabase,
                jobId,
                "empty_rewrite",
                BACKOFF_PARSE_SECONDS,
              );
              failed++;
              continue;
            }

            // Fetch request for policy_version + target_locale + request payload (for eval)
            const reqRow = await fetchRewriteRequest(
              supabase,
              job.rewrite_request_id,
            );
            if (!reqRow) {
              await failJobById(supabase, jobId, "rewrite_request_not_found");
              failed++;
              continue;
            }

            const request = reqRow.rewrite_request;
            const targetLocale = reqRow.target_locale;

            // Eval (same semantics as realtime worker)
            const powerMode = getPowerMode(request.context_pack);

            const evalResult = evaluateRewrite(
              {
                rewrite_request_id: job.rewrite_request_id,
                target_locale: targetLocale,
                original_text: request.original_text,
                intent: request.intent,
              },
              {
                rewrite_request_id: job.rewrite_request_id,
                recipient_user_id: job.recipient_user_id,
                rewritten_text: rewritten,
                output_language: targetLocale,
              },
              {
                power: { power_mode: powerMode },
              },
              { judge_version: "v1", dataset_version: "none" },
            );

            if (!evalResult.lexicon_pass || evalResult.tone_safety === "fail") {
              await failJobById(
                supabase,
                jobId,
                "eval_failed:" +
                  safeShort((evalResult.violations ?? []).join(",")),
              );
              failed++;
              continue;
            }

            // Routing meta (optional)
            const decision = (job.routing_decision ?? {}) as Record<
              string,
              unknown
            >;
            const provider = String(decision.provider ?? "openai");
            const model = String(decision.model ?? "gpt-4.1");
            const promptVersion = String(decision.prompt_version ?? "v1");

            // Complete job (IMPORTANT: completion RPC must NOT mark the request completed unconditionally)
            const { error } = await supabase.rpc(
              "complete_complaint_rewrite_job",
              {
                p_job_id: job.job_id,
                p_rewrite_request_id: job.rewrite_request_id,
                p_recipient_user_id: job.recipient_user_id,
                p_rewritten_text: rewritten,
                p_output_language: targetLocale,
                p_target_locale: targetLocale,
                p_model: model,
                p_provider: provider,
                p_prompt_version: promptVersion,
                p_policy_version: reqRow.policy_version,
                p_lexicon_version: LEXICON_VERSION,
                p_eval_result: evalResult,
              },
            );

            if (error) {
              await requeueByJobId(
                supabase,
                jobId,
                `complete_failed:${safeShort(error.message)}`,
                BACKOFF_COMPLETE_SECONDS,
              );
              failed++;
              continue;
            }

            completed++;
          } catch (_e) {
            // line-level parsing failure
            // If we can’t identify a job_id, we can’t requeue/fail specific jobs here.
            failed++;
          }
        }

        // 3) Finalize touched rewrite_requests for this batch
        // (marks request completed ONLY when all jobs are terminal: completed/failed/canceled)
        let finalized = 0;
        for (const rid of touchedRequestIds) {
          const { error } = await supabase.rpc(
            "complaint_rewrite_request_finalize_v1",
            {
              p_rewrite_request_id: rid,
            },
          );
          if (!error) finalized++;
        }

        results.push({
          provider_batch_id: b.provider_batch_id,
          status: "completed",
          lines: lines.length,
          completed,
          failed,
          skipped,
          finalized_requests: finalized,
        });
      }

      return json({
        ok: true,
        request_id,
        checked: pending.batches.length,
        results,
      }, 200);
    } catch (e) {
      return json({ ok: false, request_id, error: toErrorMessage(e) }, 500);
    }
  });
}

/* ---------------- response helpers ---------------- */

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

/* ---------------- auth + env ---------------- */

function supabaseClient(): SupabaseClient {
  const url = env("SUPABASE_URL");
  // Internal-only edge function: OK to use service role, gated by x-internal-secret.
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function requireInternalSecret(req: Request) {
  const expected = env("WORKER_SHARED_SECRET");
  const got = req.headers.get("x-internal-secret");
  if (got !== expected) throw new Error("unauthorized");
}

function rejectHugeBodies(req: Request) {
  const cl = req.headers.get("content-length");
  if (!cl) return;
  const n = Number(cl);
  if (Number.isFinite(n) && n > MAX_CONTENT_LENGTH) {
    throw new Error("payload_too_large");
  }
}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing ${name}`);
  return v;
}

function toErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

function safeShort(x: unknown): string {
  try {
    const s = typeof x === "string" ? x : JSON.stringify(x ?? "");
    return s.slice(0, 300);
  } catch {
    return String(x ?? "").slice(0, 300);
  }
}

function isUuid(s: string): boolean {
  // strict-ish UUID v4/v1/v5 shape
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(s);
}

function getPowerMode(
  contextPack: unknown,
): "peer" | "higher_sender" | "higher_recipient" {
  if (
    contextPack &&
    typeof contextPack === "object" &&
    "power" in contextPack &&
    (contextPack as { power?: unknown }).power &&
    typeof (contextPack as { power: unknown }).power === "object" &&
    "power_mode" in
      ((contextPack as { power: { power_mode?: unknown } }).power ?? {})
  ) {
    const pm =
      (contextPack as { power: { power_mode?: unknown } }).power.power_mode;
    if (pm === "peer" || pm === "higher_sender" || pm === "higher_recipient") {
      return pm;
    }
  }
  return "peer";
}

function mapOpenAIStatus(
  status: string | undefined,
): "submitted" | "running" | "completed" | "failed" | "canceled" {
  const s = String(status ?? "").toLowerCase();
  if (s === "completed") return "completed";
  if (s === "failed") return "failed";
  if (s === "canceled" || s === "cancelled") return "canceled";
  // OpenAI uses statuses like: validating, in_progress, finalizing, etc.
  if (s) return "running";
  return "running";
}

// Test-only exports
export { env, getPowerMode, mapOpenAIStatus, rejectHugeBodies, safeShort };

/* ---------------- RPC helpers ---------------- */

// Must-succeed RPC helper (observes errors).
async function rpcMust(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
) {
  const { error } = await supabase.rpc(fn, args);
  if (error) throw new Error(`${fn}_failed:${error.message}`);
}

// Best-effort RPC helper (swallows errors).
async function rpcBestEffort(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
) {
  try {
    const { error } = await supabase.rpc(fn, args);
    if (error) {
      // swallow
    }
  } catch {
    // swallow
  }
}

// Returns data or null; does NOT throw unless RPC call itself errors unexpectedly.
async function rpcMaybeJson<T>(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T | null> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) return null;
  return (data ?? null) as T | null;
}

/* ---------------- RPC calls ---------------- */

type BatchRow = {
  provider_batch_id: string;
  status: string;
  input_file_id: string | null;
  output_file_id: string | null;
  error_file_id: string | null;
  endpoint: string;
};

type JobFetchRow = {
  job_id: string;
  rewrite_request_id: string;
  recipient_user_id: string;
  status: string;
  provider_batch_id: string | null;
  routing_decision?: unknown;
};

type RewriteRequestRPCRow = {
  rewrite_request: {
    surface: string;
    lane: string;
    rewrite_strength: string;
    intent: "request" | "boundary" | "concern" | "clarification";
    original_text: string;
    context_pack?: unknown;
    policy?: unknown;
  };
  target_locale: string;
  policy_version: string;
};

type RequeueByBatchResultRow = {
  job_id: string;
  prev_status: string;
  new_status: string;
  run_after: string;
};

async function listPendingBatches(supabase: SupabaseClient, limit: number) {
  const { data, error } = await supabase.rpc("rewrite_batch_list_pending_v1", {
    p_limit: limit,
  });
  if (error) return { ok: false as const, error: error.message };
  return { ok: true as const, batches: (data ?? []) as BatchRow[] };
}

async function fetchJob(
  supabase: SupabaseClient,
  jobId: string,
): Promise<JobFetchRow | null> {
  const { data, error } = await supabase.rpc("rewrite_job_fetch_v1", {
    p_job_id: jobId,
  });
  if (error || !data) return null;
  return data as JobFetchRow;
}

async function fetchRewriteRequest(
  supabase: SupabaseClient,
  rewriteRequestId: string,
): Promise<RewriteRequestRPCRow | null> {
  const { data, error } = await supabase.rpc(
    "complaint_rewrite_request_fetch_v1",
    {
      p_rewrite_request_id: rewriteRequestId,
    },
  );
  if (error || !data) return null;
  return data as RewriteRequestRPCRow;
}

async function requeueByJobId(
  supabase: SupabaseClient,
  jobId: string,
  reason: string,
  backoffSeconds: number,
) {
  await supabase.rpc("complaint_rewrite_job_fail_or_requeue", {
    p_job_id: jobId,
    p_error: reason,
    p_backoff_seconds: backoffSeconds,
  });
}

async function failJobById(
  supabase: SupabaseClient,
  jobId: string,
  reason: string,
) {
  await supabase.rpc("fail_complaint_rewrite_job", {
    p_job_id: jobId,
    p_error: reason,
  });
}

/* ---------------- OpenAI HTTP ---------------- */

type OpenAIBatchStatus = {
  id: string;
  status: string;
  output_file_id?: string | null;
  error_file_id?: string | null;
  input_file_id?: string | null;
};

async function getOpenAIBatch(
  apiKey: string,
  batchId: string,
): Promise<OpenAIBatchStatus> {
  const resp = await fetch(
    `https://api.openai.com/v1/batches/${encodeURIComponent(batchId)}`,
    {
      method: "GET",
      headers: { Authorization: `Bearer ${apiKey}` },
    },
  );
  if (!resp.ok) {
    throw new Error(
      `openai_batch_get_error:${resp.status}:${
        (await resp.text()).slice(0, 400)
      }`,
    );
  }
  return (await resp.json()) as OpenAIBatchStatus;
}

async function downloadOpenAIFile(
  apiKey: string,
  fileId: string,
): Promise<string> {
  const resp = await fetch(
    `https://api.openai.com/v1/files/${encodeURIComponent(fileId)}/content`,
    {
      method: "GET",
      headers: { Authorization: `Bearer ${apiKey}` },
    },
  );
  if (!resp.ok) {
    throw new Error(
      `openai_file_download_error:${resp.status}:${
        (await resp.text()).slice(0, 400)
      }`,
    );
  }
  return await resp.text();
}
