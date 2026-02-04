// supabase/functions/complaint_orchestrator/index.ts
// Orchestrator edge (RPC-first writes only)
//
// FULL adjusted version (calls complaint_classifier as a service)
//
// Key changes vs your last orchestrator draft:
// - Uses classifier as a service (no OpenAI code inside orchestrator)
// - Fixes body-size cap to be real BYTES (TextEncoder), not string length
// - Fixes rpcSafe to actually observe Supabase RPC errors (supabase.rpc doesn't throw)
// - Preserves meaningful HTTP statuses (e.g., 504 stays 504); still returns retryable flag
// - Ensures terminal-state marking is best-effort + safer final net
//
// Required secrets/env:
// - SUPABASE_URL
// - SUPABASE_SERVICE_ROLE_KEY
// - ORCHESTRATOR_SHARED_SECRET           (for callers -> orchestrator)
// - CLASSIFIER_FUNCTION_URL              (e.g. https://<project>.functions.supabase.co/complaint_classifier)
// - CLASSIFIER_SHARED_SECRET             (must match complaint_classifier's CLASSIFIER_SHARED_SECRET)
//
// Optional:
// - CLASSIFIER_TIMEOUT_MS (default 8000)

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.48.0";

/* ---------------- Types ---------------- */

type ClassifierResult = {
  classifier_version: string;
  detected_language: string;
  topics: string[];
  intent: "request" | "boundary" | "concern" | "clarification";
  rewrite_strength: "light_touch" | "full_reframe";
  safety_flags: string[];
};

type RoutingDecision = {
  provider?: string;
  model?: string;
  prompt_version?: string;
  policy_version?: string;
  execution_mode?: string;
  cache_eligible?: boolean;
  max_retries?: number;
  adapter_kind?: string;
  base_url?: string | null;
};

type EntryLocalesRow = {
  original_text: string | null;
  recipient_locale: string | null;
  home_id: string | null;
  author_user_id: string | null;
  recipient_user_id?: string | null;
};

type SnapshotRow = {
  recipient_snapshot_id: string | null;
  recipient_preference_snapshot_id: string | null;
};

const SURFACES = ["weekly_harmony", "direct_message", "other"] as const;
type Surface = (typeof SURFACES)[number];

type Input = {
  entry_id: string; // uuid
  home_id: string; // uuid (validated against entryData)
  sender_user_id: string; // uuid (validated against entryData)
  recipient_user_id: string; // uuid (validated against entryData if returned)
  surface: Surface;
};

/* ---------------- Allow-lists + caps ---------------- */

const ALLOWED_SURFACES = new Set<Surface>(SURFACES);

const MAX_BODY_BYTES = 64_000; // protect edge + avoid abuse
const MAX_ORIGINAL_TEXT_CHARS = 4_000; // protect cost + prompt bombing

const DEFAULT_CLASSIFIER_TIMEOUT_MS = 8_000;

/* ---------------- Errors ---------------- */

class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public retryable = false,
    public code?: string,
  ) {
    super(message);
  }
}

/* ---------------- Entrypoint ---------------- */

if (import.meta.main) {
  Deno.serve(async (req) => {
    const request_id = crypto.randomUUID();
    const { supabase, errResp } = supabaseClient();
    if (!supabase) return errResp;

    let entry_id: string | null = null;
    let terminalMarked = false;

    try {
      // 1) Internal guard FIRST
      requireInternalSecret(req);

      // 2) Parse body safely (real byte cap)
      const body = await safeJson(req, MAX_BODY_BYTES);

      // 3) Validate input
      const input = validate(body);
      entry_id = input.entry_id;

      // Mark trigger processing early (best-effort)
      await rpcSafe(supabase, "complaint_trigger_mark_processing", {
        p_entry_id: input.entry_id,
        p_request_id: request_id,
      });

      const rewrite_request_id = input.entry_id; // Option 1: request_id == entry_id

      // 0) Optional fast short-circuit
      const exists = await rpcBool(
        supabase,
        "complaint_rewrite_request_exists",
        {
          p_rewrite_request_id: rewrite_request_id,
        },
      );
      if (exists === true) {
        await rpcSafe(supabase, "complaint_trigger_mark_completed", {
          p_entry_id: input.entry_id,
          p_processed_at: new Date().toISOString(),
          p_note: "already_enqueued",
          p_request_id: request_id,
        });
        terminalMarked = true;
        return json({
          ok: true,
          already_enqueued: true,
          rewrite_request_id,
          request_id,
        }, 200);
      }

      // 1) Fetch authoritative entry data (text + locale + home + author + recipient)
      const entryData: EntryLocalesRow | null = await rpcJson<EntryLocalesRow>(
        supabase,
        "complaint_fetch_entry_locales",
        {
          p_entry_id: input.entry_id,
          p_recipient_user_id: input.recipient_user_id,
        },
      );
      if (!entryData) {
        throw new ApiError(
          404,
          "mood_entry_not_found",
          false,
          "mood_entry_not_found",
        );
      }

      // Authoritative checks
      const entry_home_id = String(entryData.home_id ?? "").trim();
      const entry_author_user_id = String(entryData.author_user_id ?? "")
        .trim();
      const entry_recipient_user_id = String(
        entryData.recipient_user_id ?? input.recipient_user_id,
      ).trim();

      if (
        !isUuid(entry_home_id) || !isUuid(entry_author_user_id) ||
        !isUuid(entry_recipient_user_id)
      ) {
        throw new ApiError(
          500,
          "entry_locale_rpc_invalid_shape",
          false,
          "entry_locale_rpc_invalid_shape",
        );
      }
      if (entry_home_id !== input.home_id) {
        throw new ApiError(403, "home_id_mismatch", false, "home_id_mismatch");
      }
      if (entry_author_user_id !== input.sender_user_id) {
        throw new ApiError(
          403,
          "sender_user_id_mismatch",
          false,
          "sender_user_id_mismatch",
        );
      }
      if (entry_recipient_user_id !== input.recipient_user_id) {
        throw new ApiError(
          403,
          "recipient_user_id_mismatch",
          false,
          "recipient_user_id_mismatch",
        );
      }

      // Original text
      const original_text = String(entryData.original_text ?? "").trim();
      if (!original_text) {
        await rpcSafe(supabase, "complaint_trigger_mark_canceled", {
          p_entry_id: input.entry_id,
          p_reason: "no_text_to_rewrite",
          p_request_id: request_id,
        });
        terminalMarked = true;
        return json({
          ok: true,
          skipped: "no_text_to_rewrite",
          rewrite_request_id,
          request_id,
        }, 200);
      }
      if (original_text.length > MAX_ORIGINAL_TEXT_CHARS) {
        await rpcSafe(supabase, "complaint_trigger_mark_canceled", {
          p_entry_id: input.entry_id,
          p_reason: `text_too_long_${MAX_ORIGINAL_TEXT_CHARS}`,
          p_request_id: request_id,
        });
        terminalMarked = true;
        return json({
          ok: true,
          skipped: "text_too_long",
          rewrite_request_id,
          request_id,
        }, 413);
      }

      // Locales
      const recipient_locale = normalizeLocale(entryData.recipient_locale) ??
        "en";

      // 2) Preference payload (RPC)
      const prefPayload: Record<string, unknown> | null = await rpcJson<
        Record<string, unknown>
      >(
        supabase,
        "complaint_preference_payload",
        { p_recipient_user_id: input.recipient_user_id },
      );

      const normalizedPrefMap = normalizePreferencePayload(prefPayload);
      const snapshotPreferences = buildSnapshotPreferences(normalizedPrefMap);

      const snapshotPayload = {
        preferences: snapshotPreferences,
      };

      const snapData: SnapshotRow | null = await rpcJson<SnapshotRow>(
        supabase,
        "complaint_build_recipient_snapshots",
        {
          p_rewrite_request_id: rewrite_request_id,
          p_home_id: input.home_id,
          p_recipient_user_id: input.recipient_user_id,
          p_preference_payload: snapshotPayload,
        },
      );

      const recipient_snapshot_id = String(
        snapData?.recipient_snapshot_id ?? "",
      ).trim();
      const recipient_preference_snapshot_id = String(
        snapData?.recipient_preference_snapshot_id ?? "",
      ).trim();
      if (
        !isUuid(recipient_snapshot_id) ||
        !isUuid(recipient_preference_snapshot_id)
      ) {
        throw new ApiError(
          500,
          "snapshot_ids_invalid_uuid",
          false,
          "snapshot_ids_invalid_uuid",
        );
      }

      // 4) Classifier (CALL AS A SERVICE)
      const classifier_result = await callClassifierService({
        classifierUrl: env("CLASSIFIER_FUNCTION_URL"),
        classifierSecret: env("CLASSIFIER_SHARED_SECRET"),
        original_text,
        surface: input.surface,
        sender_user_id: input.sender_user_id,
        timeoutMs: clampInt(
          Deno.env.get("CLASSIFIER_TIMEOUT_MS"),
          2000,
          30000,
          DEFAULT_CLASSIFIER_TIMEOUT_MS,
        ),
      });

      // 5) Lane
      const source_locale =
        normalizeLocale(classifier_result.detected_language) ?? "en";
      const target_locale = recipient_locale;
      const lane = source_locale === target_locale
        ? "same_language"
        : "cross_language";

      // 6) Context pack (RPC)
      const context_pack = await rpcJson<Record<string, unknown>>(
        supabase,
        "complaint_context_build",
        {
          p_recipient_user_id: input.recipient_user_id,
          p_recipient_preference_snapshot_id: recipient_preference_snapshot_id,
          p_topics: classifier_result.topics,
          p_target_language: target_locale,
          p_power_mode: "peer",
        },
      );

      // 7) Routing (RPC)
      const routing_decision: RoutingDecision | null = await rpcJson<
        RoutingDecision
      >(supabase, "complaint_rewrite_route", {
        p_surface: input.surface,
        p_lane: lane,
        p_rewrite_strength: classifier_result.rewrite_strength,
      });
      if (!routing_decision) {
        throw new ApiError(
          500,
          "routing_not_found",
          false,
          "routing_not_found",
        );
      }

      // 8) Policy pack (simple)
      const policy = {
        tone: classifier_result.rewrite_strength === "full_reframe"
          ? "gentle"
          : "neutral",
        directness: "soft",
        emotional_temperature: "cool_down",
        rewrite_strength: classifier_result.rewrite_strength,
      };

      // 9) Rewrite request blob (for enqueue storage/logging)
      const rewrite_request = {
        rewrite_request_id,
        entry_id: input.entry_id,
        home_id: input.home_id,
        sender_user_id: input.sender_user_id,
        recipient_user_id: input.recipient_user_id,
        recipient_snapshot_id,
        recipient_preference_snapshot_id,
        surface: input.surface,
        original_text,
        topics: classifier_result.topics,
        intent: classifier_result.intent,
        rewrite_strength: classifier_result.rewrite_strength,
        source_locale,
        target_locale,
        lane,
        classifier_result,
        context_pack,
        policy,
        classifier_version: classifier_result.classifier_version ?? "v1",
        context_pack_version: "v1.1",
        policy_version: "v1",
        request_id,
        created_at: new Date().toISOString(),
      };

      const maxAttempts = clampInt(routing_decision?.max_retries, 0, 10, 2);

      // 10) Enqueue (RPC; idempotent)
      const enqueueData = await rpcJson(supabase, "complaint_rewrite_enqueue", {
        p_rewrite_request_id: rewrite_request_id,
        p_home_id: input.home_id,
        p_sender_user_id: input.sender_user_id,
        p_recipient_user_id: input.recipient_user_id,
        p_recipient_snapshot_id: recipient_snapshot_id,
        p_recipient_preference_snapshot_id: recipient_preference_snapshot_id,
        p_surface: input.surface,
        p_original_text: original_text,
        p_rewrite_request: rewrite_request,
        p_classifier_result: classifier_result,
        p_context_pack: context_pack,
        p_source_locale: source_locale,
        p_target_locale: target_locale,
        p_lane: lane,
        p_topics: classifier_result.topics,
        p_intent: classifier_result.intent,
        p_rewrite_strength: classifier_result.rewrite_strength,
        p_classifier_version: classifier_result.classifier_version ?? "v1",
        p_context_pack_version: "v1.1",
        p_policy_version: "v1",
        p_routing_decision: routing_decision,
        p_language_pair: { from: source_locale, to: target_locale },
        p_max_attempts: maxAttempts,
        p_request_id: request_id,
      });

      // Mark completed (= queued)
      await rpcSafe(supabase, "complaint_trigger_mark_completed", {
        p_entry_id: input.entry_id,
        p_processed_at: new Date().toISOString(),
        p_note: "enqueued",
        p_request_id: request_id,
      });
      terminalMarked = true;

      return json(
        {
          ok: true,
          request_id,
          rewrite_request_id,
          recipient_snapshot_id,
          recipient_preference_snapshot_id,
          routing_decision,
          enqueue: enqueueData ?? null,
        },
        200,
      );
    } catch (e) {
      const { msg, status, retryable, code } = normalizeCatch(e);

      // Best-effort terminal marking
      if (entry_id && !terminalMarked) {
        if (retryable) {
          await rpcSafe(supabase, "complaint_trigger_mark_failed", {
            p_entry_id: entry_id,
            p_error: msg.slice(0, 512),
            p_backoff_seconds: 600,
            p_request_id: request_id,
          });
        } else {
          await rpcSafe(supabase, "complaint_trigger_mark_canceled", {
            p_entry_id: entry_id,
            p_reason: msg.slice(0, 256),
            p_request_id: request_id,
          });
        }
      }

      // Preserve meaningful status where possible; still provide retryable flag.
      // For retryable upstream-ish issues, prefer 502 unless we already have 504/429 etc.
      const respStatus = retryable ? preferRetryableStatus(status) : status;

      return json(
        { ok: false, request_id, error: msg, code: code ?? null, retryable },
        respStatus,
      );
    } finally {
      // Final safety net: if we got entry_id and still didn't terminal mark,
      // mark failed with a generic backoff so the system doesn't hang.
      if (entry_id && !terminalMarked) {
        await rpcSafe(supabase, "complaint_trigger_mark_failed", {
          p_entry_id: entry_id,
          p_error: "orchestrator_exit_without_terminal_state",
          p_backoff_seconds: 600,
          p_request_id: request_id,
        });
      }
    }
  });
}

/* ---------------- Supabase + auth ---------------- */

function supabaseClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseKey) {
    return {
      supabase: null,
      errResp: json({
        ok: false,
        error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY",
      }, 500),
    } as const;
  }
  const supabase: SupabaseClient = createClient(supabaseUrl, supabaseKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  return { supabase, errResp: null } as const;
}

function requireInternalSecret(req: Request) {
  const expected = Deno.env.get("ORCHESTRATOR_SHARED_SECRET");
  if (!expected) {
    throw new ApiError(
      500,
      "missing_ORCHESTRATOR_SHARED_SECRET",
      false,
      "missing_env",
    );
  }
  const got = req.headers.get("x-internal-secret");
  if (got !== expected) {
    throw new ApiError(401, "unauthorized", false, "unauthorized");
  }
}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new ApiError(500, `Missing env ${name}`, false, "missing_env");
  return v;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

/* ---------------- Safe JSON (BYTE cap) ---------------- */

async function safeJson(req: Request, maxBytes: number): Promise<unknown> {
  const text = await req.text().catch(() => "");
  if (!text) return {};
  const bytes = new TextEncoder().encode(text).length;
  if (bytes > maxBytes) {
    throw new ApiError(413, "payload_too_large", false, "payload_too_large");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError(
      400,
      "invalid_json_payload",
      false,
      "invalid_json_payload",
    );
  }
}

/* ---------------- Validation ---------------- */

function validate(input: unknown): Input {
  if (!input || typeof input !== "object") {
    throw new ApiError(400, "invalid_payload", false, "invalid_payload");
  }
  const obj = input as Record<string, unknown>;

  const reqStr = (k: string) => {
    const v = obj[k];
    if (typeof v !== "string" || !v.trim()) {
      throw new ApiError(400, `${k}_missing`, false, "missing_field");
    }
    return v.trim();
  };

  const out = {
    entry_id: reqStr("entry_id"),
    home_id: reqStr("home_id"),
    sender_user_id: reqStr("sender_user_id"),
    recipient_user_id: reqStr("recipient_user_id"),
    surface: reqStr("surface"),
  };

  if (!isUuid(out.entry_id)) {
    throw new ApiError(400, "entry_id_invalid_uuid", false, "invalid_uuid");
  }
  if (!isUuid(out.home_id)) {
    throw new ApiError(400, "home_id_invalid_uuid", false, "invalid_uuid");
  }
  if (!isUuid(out.sender_user_id)) {
    throw new ApiError(
      400,
      "sender_user_id_invalid_uuid",
      false,
      "invalid_uuid",
    );
  }
  if (!isUuid(out.recipient_user_id)) {
    throw new ApiError(
      400,
      "recipient_user_id_invalid_uuid",
      false,
      "invalid_uuid",
    );
  }
  if (!isSurface(out.surface)) {
    throw new ApiError(400, "surface_invalid", false, "surface_invalid");
  }

  return { ...out, surface: out.surface as Surface };
}

function isUuid(s: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(s);
}

function isSurface(v: string): v is Surface {
  return ALLOWED_SURFACES.has(v as Surface);
}

function clampInt(v: unknown, min: number, max: number, fallback: number) {
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) return fallback;
  const i = Math.trunc(n);
  return Math.max(min, Math.min(max, i));
}

/* ---------------- RPC helpers ---------------- */

async function rpcJson<T>(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T | null> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    const msg = `${fn}_failed:${error.message}`;
    throw new ApiError(500, msg, isRetryableText(error.message), "rpc_failed");
  }
  return (data ?? null) as T | null;
}

async function rpcBool(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    throw new ApiError(
      500,
      `${fn}_failed:${error.message}`,
      isRetryableText(error.message),
      "rpc_failed",
    );
  }
  return Boolean(data);
}

// IMPORTANT: supabase.rpc does NOT throw; it returns { data, error }.
// So we must check error here. We intentionally swallow errors (best-effort).
async function rpcSafe(
  supabase: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
) {
  try {
    const { error } = await supabase.rpc(fn, args);
    if (error) {
      // swallow; best-effort only
      // optionally: console.warn(`${fn} best-effort failed:`, error.message);
    }
  } catch {
    // swallow
  }
}

/* ---------------- Preference normalization ---------------- */

function normalizePreferencePayload(
  published: unknown,
): Record<string, string> {
  if (!published || typeof published !== "object") return {};
  const obj = published as Record<string, unknown>;

  const values = Object.values(obj);
  const looksFlat = values.length > 0 &&
    values.every((v) => typeof v === "string");
  if (looksFlat) return obj as Record<string, string>;

  const resolved = obj["resolved"];
  if (!resolved || typeof resolved !== "object") return {};

  const out: Record<string, string> = {};
  for (
    const [prefId, v] of Object.entries(resolved as Record<string, unknown>)
  ) {
    if (v && typeof v === "object") {
      const valueKey = (v as Record<string, unknown>)["value_key"];
      if (typeof valueKey === "string" && valueKey) out[prefId] = valueKey;
    }
  }
  return out;
}

function buildSnapshotPreferences(
  normalizedPrefMap: Record<string, string>,
): Record<string, string> {
  // Always forward communication prefs when present, even if others are absent.
  const communication_core = [
    "communication_directness",
    "communication_channel",
    "conflict_resolution_style",
  ]
    .reduce<Record<string, string>>((acc, key) => {
      if (key in normalizedPrefMap) acc[key] = normalizedPrefMap[key];
      return acc;
    }, {});

  return { ...normalizedPrefMap, ...communication_core };
}

/* ---------------- Locale normalization ---------------- */

function normalizeLocale(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!s) return null;
  // allow "en", "en-nz", "zh-hant" etc (loose)
  if (!/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/.test(s)) return null;
  return s.toLowerCase();
}

/* ---------------- Classifier service call ---------------- */

async function callClassifierService(params: {
  classifierUrl: string;
  classifierSecret: string;
  original_text: string;
  surface: string;
  sender_user_id: string;
  timeoutMs: number;
}): Promise<ClassifierResult> {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), params.timeoutMs);

  try {
    const resp = await fetch(params.classifierUrl, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        "x-internal-secret": params.classifierSecret,
      },
      body: JSON.stringify({
        original_text: params.original_text,
        surface: params.surface,
        sender_user_id: params.sender_user_id,
      }),
    });

    const rawText = await resp.text().catch(() => "");
    type ClassifierResponse =
      | { ok: true; classifier_result: ClassifierResult }
      | { ok?: false; retryable?: boolean; code?: string; error?: string };

    const body = rawText ? safeParseJson<ClassifierResponse>(rawText) : null;

    // Expected success shape
    if (resp.ok && body?.ok === true && body?.classifier_result) {
      return body.classifier_result as ClassifierResult;
    }

    const hasRetryable = body && "retryable" in body &&
      typeof body.retryable === "boolean";
    const retryable = (hasRetryable
      ? Boolean(
        (body as Extract<ClassifierResponse, { retryable?: boolean }>)
          .retryable,
      )
      : false) ||
      resp.status === 429 ||
      resp.status >= 500 ||
      resp.status === 408;

    const code = body && "code" in body && typeof body.code === "string"
      ? body.code
      : "classifier_service_failed";

    const msg = body && "error" in body && typeof body.error === "string"
      ? body.error
      : rawText
      ? truncate(rawText, 240)
      : `classifier_service_status_${resp.status}`;

    // Preserve real status where possible (e.g., 401 from classifier means your internal secret mismatch)
    throw new ApiError(resp.status || 502, `${code}:${msg}`, retryable, code);
  } catch (e) {
    if (String(e).includes("AbortError")) {
      throw new ApiError(
        504,
        "classifier_service_timeout",
        true,
        "classifier_timeout",
      );
    }
    throw e;
  } finally {
    clearTimeout(t);
  }
}

function safeParseJson<T>(s: string): T | null {
  try {
    return JSON.parse(s) as T;
  } catch {
    return null;
  }
}

/* ---------------- Retry helpers ---------------- */

function isRetryableText(msg: string) {
  const m = String(msg || "").toLowerCase();
  return (
    m.includes("timeout") ||
    m.includes("timed out") ||
    m.includes("network") ||
    m.includes("connection") ||
    m.includes("rate limit") ||
    m.includes("429") ||
    m.includes("502") ||
    m.includes("503") ||
    m.includes("504") ||
    m.includes("deadlock") ||
    m.includes("could not serialize") ||
    m.includes("available") ||
    m.includes("temporarily")
  );
}

function preferRetryableStatus(status: number) {
  // Keep high-signal statuses if we already have them; otherwise default to 502.
  if (status === 504) return 504;
  if (status === 429) return 502; // internal pipeline: treat as upstream error but retryable
  if (status >= 500) return 502;
  return 502;
}

function normalizeCatch(
  e: unknown,
): { msg: string; status: number; retryable: boolean; code?: string } {
  if (e instanceof ApiError) {
    return {
      msg: e.message,
      status: e.status,
      retryable: e.retryable,
      code: e.code,
    };
  }
  const msg = toErrorMessage(e);
  const status = 500;
  const retryable = isRetryableText(msg) || status >= 500;
  return { msg, status, retryable };
}

function toErrorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  if (
    e && typeof e === "object" && "message" in e &&
    typeof (e as { message?: unknown }).message === "string"
  ) {
    return (e as { message: string }).message;
  }
  return String(e);
}

function truncate(s: string, n: number) {
  return s.length <= n ? s : s.slice(0, n) + "…";
}

// Test-only exports
export {
  ApiError,
  buildSnapshotPreferences,
  callClassifierService,
  clampInt,
  isRetryableText,
  normalizeCatch,
  normalizeLocale,
  normalizePreferencePayload,
  preferRetryableStatus,
  safeJson,
  validate,
};
