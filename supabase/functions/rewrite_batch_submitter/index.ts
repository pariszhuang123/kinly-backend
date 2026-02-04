// supabase/functions/rewrite_batch_submitter/index.ts
// Batch submitter (OpenAI-only).
// RPC-only DB access.
// Flow:
// 1) claim queued jobs (RPC)
// 2) fetch rewrite_request for each job (RPC)
// 3) build JSONL lines (custom_id = job_id)
// 4) upload JSONL file to OpenAI
// 5) create OpenAI batch
// 6) register batch + mark jobs batch_submitted + link provider_batch_id (RPC)
//
// Updated per your latest schema + worker semantics:
// - Uses job.status = 'batch_submitted' (collector expects this)
// - Sets rewrite_jobs.provider_batch_id (FK to rewrite_provider_batches)
// - Uses WORKER_SHARED_SECRET header guard (x-internal-secret)
// - Byte-safe JSONL caps (TextEncoder) to prevent upload failures
// - If batch fills up: requeues leftover claimed jobs so none stay "claimed"
// - If OpenAI fails: requeues accepted jobs with backoff
// - If DB register/link fails: requeues accepted jobs, returns error
//
// Required RPCs this submitter expects:
// - claim_rewrite_jobs_for_batch_submit_v1(p_limit) -> rows(job_id, rewrite_request_id, recipient_user_id, routing_decision)
// - complaint_rewrite_request_fetch_v1(p_rewrite_request_id) -> { rewrite_request, target_locale, policy_version }
// - rewrite_batch_register_v1(p_provider_batch_id, p_input_file_id, p_job_count, p_endpoint)
// - mark_rewrite_jobs_batch_submitted_v1(p_job_ids uuid[], p_provider_batch_id text)
// - complaint_rewrite_job_fail_or_requeue(p_job_id uuid, p_error text, p_backoff_seconds int)
// - fail_complaint_rewrite_job(p_job_id uuid, p_error text)
//
// Notes:
// - This file directly calls OpenAI HTTP APIs for files + batches.
// - It does not write DB tables directly; only via RPCs.

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.48.0";
import { buildOpenAIBatchJsonlLine } from "../rewrite_batch/providers.ts";

/* ---------------- config ---------------- */

const MAX_JOBS = 100;
const COMPLETION_WINDOW = "24h"; // batch is non-realtime
const ENDPOINT = "/v1/responses";
const MAX_CONTENT_LENGTH = 256_000;

// JSONL safety caps (bytes)
const MAX_JSONL_BYTES = 5_000_000; // ~5MB
const MAX_JSONL_LINE_BYTES = 100_000; // per request line cap
const BACKOFF_BATCH_FULL_SECONDS = 5 * 60;
const BACKOFF_OPENAI_FAIL_SECONDS = 15 * 60;
const BACKOFF_INTERNAL_SECONDS = 10 * 60;

if (import.meta.main) {
  Deno.serve(async (req) => {
    const request_id = crypto.randomUUID();
    try {
      requireInternalSecret(req);
      rejectHugeBodies(req);

      const supabase = supabaseClient();

      // 1) claim jobs
      const claimed = await claimJobs(supabase, MAX_JOBS);
      if (!claimed.ok) {
        return json({ ok: false, request_id, error: claimed.error }, 500);
      }
      if (claimed.jobs.length === 0) {
        return json({ ok: true, request_id, submitted: 0 }, 200);
      }

      // 2) build JSONL safely
      const encoder = new TextEncoder();

      type AcceptedLine = {
        job_id: string;
        rewrite_request_id: string;
        line: string;
      };
      const accepted: AcceptedLine[] = [];
      const jobsToRequeueBecauseBatchFull: string[] = [];

      let totalBytes = 0;
      let skippedMissingRequest = 0;
      let skippedUnsupportedProvider = 0;
      let skippedTooLargeLine = 0;
      let skippedBatchFull = 0;

      for (const job of claimed.jobs) {
        if (totalBytes >= MAX_JSONL_BYTES) {
          jobsToRequeueBecauseBatchFull.push(job.job_id);
          skippedBatchFull++;
          continue;
        }

        const requestRow = await fetchRewriteRequest(
          supabase,
          job.rewrite_request_id,
        );
        if (!requestRow) {
          // terminal: request missing -> fail job
          await failJob(supabase, job.job_id, "rewrite_request_not_found");
          skippedMissingRequest++;
          continue;
        }

        // Step 1 batch support: OpenAI Responses only
        const decision = (job.routing_decision ?? {}) as Record<
          string,
          unknown
        >;
        const provider = String(decision.provider ?? "openai");
        const adapter_kind = String(
          decision.adapter_kind ?? "openai_responses",
        );

        if (provider !== "openai" || adapter_kind !== "openai_responses") {
          await requeueJob(
            supabase,
            job.job_id,
            "batch_provider_not_supported",
            6 * 3600,
          );
          skippedUnsupportedProvider++;
          continue;
        }

        const model = String(decision.model ?? "gpt-5-nano");
        const promptVersion = String(decision.prompt_version ?? "v1");
        const rr = requestRow.rewrite_request;

        // Build the JSONL line object for OpenAI Batch
        const lineObj = buildOpenAIBatchJsonlLine({
          job_id: job.job_id,
          input: {
            model,
            promptVersion,
            targetLocale: requestRow.target_locale,
            intent: rr.intent,
            contextPack: rr.context_pack,
            policy: rr.policy,
            originalText: rr.original_text,
            routingDecision: decision,
          },
        });

        // Drift guard: custom_id must be job_id
        const cid = (lineObj as { custom_id?: unknown })?.custom_id;
        if (String(cid ?? "") !== job.job_id) {
          await requeueJob(
            supabase,
            job.job_id,
            "batch_custom_id_mismatch",
            BACKOFF_INTERNAL_SECONDS,
          );
          continue;
        }

        const line = JSON.stringify(lineObj);
        const lineBytes = encoder.encode(line).length;

        if (lineBytes > MAX_JSONL_LINE_BYTES) {
          await requeueJob(
            supabase,
            job.job_id,
            `batch_line_too_large_${lineBytes}`,
            6 * 3600,
          );
          skippedTooLargeLine++;
          continue;
        }

        const newlineBytes = accepted.length === 0 ? 0 : 1;
        if (totalBytes + newlineBytes + lineBytes > MAX_JSONL_BYTES) {
          jobsToRequeueBecauseBatchFull.push(job.job_id);
          skippedBatchFull++;
          continue;
        }

        accepted.push({
          job_id: job.job_id,
          rewrite_request_id: job.rewrite_request_id,
          line,
        });
        totalBytes += newlineBytes + lineBytes;
      }

      // 3) requeue jobs deferred due to batch size cap
      for (const jobId of jobsToRequeueBecauseBatchFull) {
        await requeueJob(
          supabase,
          jobId,
          "batch_full_deferred",
          BACKOFF_BATCH_FULL_SECONDS,
        );
      }

      if (accepted.length === 0) {
        return json(
          {
            ok: true,
            request_id,
            submitted: 0,
            note: "no_valid_jobs",
            skipped: {
              missing_request: skippedMissingRequest,
              unsupported_provider: skippedUnsupportedProvider,
              too_large_line: skippedTooLargeLine,
              batch_full_deferred: skippedBatchFull,
            },
          },
          200,
        );
      }

      // Build JSONL + jobIds from accepted (single source of truth)
      const jsonl = accepted.map((x) => x.line).join("\n");
      const jobIds = accepted.map((x) => x.job_id);

      // 4) upload JSONL + create batch
      // Single rewrite key for batch submit + collect
      const openaiKey = env("OPENAI_REWRITE_API_KEY");

      let inputFileId: string;
      let batchId: string;

      try {
        inputFileId = await uploadJsonlToOpenAI(openaiKey, jsonl);
        batchId = await createOpenAIBatch(
          openaiKey,
          inputFileId,
          ENDPOINT,
          COMPLETION_WINDOW,
        );
      } catch (e) {
        const msg = toErrorMessage(e);
        for (const jobId of jobIds) {
          await requeueJob(
            supabase,
            jobId,
            `openai_batch_submit_failed:${truncate(msg, 240)}`,
            BACKOFF_OPENAI_FAIL_SECONDS,
          );
        }
        throw e;
      }

      // 5) register batch in DB
      {
        const { error } = await supabase.rpc("rewrite_batch_register_v1", {
          p_provider_batch_id: batchId,
          p_input_file_id: inputFileId,
          p_job_count: accepted.length,
          p_endpoint: ENDPOINT,
        });

        if (error) {
          // Without DB row, collector won't poll => requeue jobs
          for (const jobId of jobIds) {
            await requeueJob(
              supabase,
              jobId,
              `db_register_batch_failed:${error.message}`,
              BACKOFF_INTERNAL_SECONDS,
            );
          }
          return json({
            ok: false,
            request_id,
            error: `rewrite_batch_register_v1_failed:${error.message}`,
          }, 500);
        }
      }

      // 6) mark jobs batch_submitted + link provider_batch_id
      {
        const { error } = await supabase.rpc(
          "mark_rewrite_jobs_batch_submitted_v1",
          {
            p_job_ids: jobIds,
            p_provider_batch_id: batchId,
          },
        );

        if (error) {
          // Batch exists in OpenAI + registered, but jobs didn't link.
          // Requeue jobs so they can be retried and you can reconcile later.
          for (const jobId of jobIds) {
            await requeueJob(
              supabase,
              jobId,
              `mark_jobs_submitted_failed:${error.message}`,
              BACKOFF_INTERNAL_SECONDS,
            );
          }
          return json({
            ok: false,
            request_id,
            error:
              `mark_rewrite_jobs_batch_submitted_v1_failed:${error.message}`,
          }, 500);
        }
      }

      return json(
        {
          ok: true,
          request_id,
          submitted: accepted.length,
          provider_batch_id: batchId,
          input_file_id: inputFileId,
          note: accepted.length < claimed.jobs.length
            ? "partial_batch_due_to_limits"
            : "full_batch",
          skipped: {
            missing_request: skippedMissingRequest,
            unsupported_provider: skippedUnsupportedProvider,
            too_large_line: skippedTooLargeLine,
            batch_full_deferred: skippedBatchFull,
          },
        },
        200,
      );
    } catch (e) {
      return json({ ok: false, error: toErrorMessage(e), request_id }, 500);
    }
  });
}

/* ---------------- helpers ---------------- */

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

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
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function toErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

function truncate(s: string, n: number) {
  return s.length <= n ? s : s.slice(0, n) + "…";
}

/* ---------------- RPC calls ---------------- */

type JobRow = {
  job_id: string;
  rewrite_request_id: string;
  recipient_user_id: string;
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

async function claimJobs(supabase: SupabaseClient, limit: number) {
  const { data, error } = await supabase.rpc(
    "claim_rewrite_jobs_for_batch_submit_v1",
    { p_limit: limit },
  );
  if (error) return { ok: false as const, error: error.message };
  return { ok: true as const, jobs: (data ?? []) as JobRow[] };
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

async function requeueJob(
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

async function failJob(
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

async function uploadJsonlToOpenAI(
  apiKey: string,
  jsonl: string,
): Promise<string> {
  const form = new FormData();
  form.append("purpose", "batch");
  form.append(
    "file",
    new Blob([jsonl], { type: "application/jsonl" }),
    "rewrite_jobs.jsonl",
  );

  const resp = await fetch("https://api.openai.com/v1/files", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });

  if (!resp.ok) {
    throw new Error(
      `openai_files_error:${resp.status}:${(await resp.text()).slice(0, 400)}`,
    );
  }
  const data = await resp.json();
  const id = data?.id;
  if (typeof id !== "string" || !id) throw new Error("openai_files_missing_id");
  return id;
}

async function createOpenAIBatch(
  apiKey: string,
  inputFileId: string,
  endpoint: string,
  window: string,
): Promise<string> {
  const resp = await fetch("https://api.openai.com/v1/batches", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      input_file_id: inputFileId,
      endpoint,
      completion_window: window,
      metadata: { system: "complaint_rewrite", mode: "batch" },
    }),
  });

  if (!resp.ok) {
    throw new Error(
      `openai_batch_create_error:${resp.status}:${
        (await resp.text()).slice(0, 400)
      }`,
    );
  }
  const data = await resp.json();
  const id = data?.id;
  if (typeof id !== "string" || !id) throw new Error("openai_batch_missing_id");
  return id;
}

// Test-only exports
export { env, rejectHugeBodies, requireInternalSecret, truncate };
