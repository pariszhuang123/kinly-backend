// supabase/functions/complaint_classifier/index.ts
// Standalone classifier edge function for complaint_rewrite.
//
// FULL adjusted version (service-ready):
// - Internal shared-secret header guard (prevents public abuse/cost blowups)
// - Safe JSON parsing with BYTE cap (not just string length)
// - Input validation + size limits
// - OpenAI Responses API + Structured Outputs (strict JSON Schema)
// - Timeout/abort for upstream call
// - Clear error codes + appropriate HTTP statuses
// - Adds `retryable` to error responses (so orchestrator can decide failed vs canceled)
// - Fixes OpenAI error mapping bug (was always 502)
// - Adds schema maxItems to keep output bounded
//
// Secrets/env required:
// - OPENAI_CLASSIFIER_API_KEY
// - CLASSIFIER_SHARED_SECRET       (callers send: x-internal-secret)
// Optional:
// - CLASSIFIER_MODEL               (default gpt-4o-mini)
//
// Notes:
// - This function is intended to be called only by internal services (your orchestrator).

type Topic =
  | "noise"
  | "cleanliness"
  | "privacy"
  | "guests"
  | "schedule"
  | "communication"
  | "other";

type Intent = "request" | "boundary" | "concern" | "clarification";
type RewriteStrength = "light_touch" | "full_reframe";

type ClassifierOutput = {
  classifier_version: string;
  detected_language: string; // bcp47-ish
  topics: Topic[];
  intent: Intent;
  rewrite_strength: RewriteStrength;
  safety_flags: string[];
};

const ALLOWED_TOPICS = new Set<Topic>([
  "noise",
  "cleanliness",
  "privacy",
  "guests",
  "schedule",
  "communication",
  "other",
]);

const ALLOWED_INTENTS = new Set<Intent>([
  "request",
  "boundary",
  "concern",
  "clarification",
]);

const ALLOWED_REWRITE_STRENGTH = new Set<RewriteStrength>([
  "light_touch",
  "full_reframe",
]);

// Keep classifier cheap + resilient
const MAX_BODY_BYTES = 64_000; // protect edge + avoid abuse (bytes, not chars)
const MAX_ORIGINAL_TEXT_CHARS = 4_000; // cap cost + prompt bombing
const OPENAI_TIMEOUT_MS = 12_000;
const MAX_OUTPUT_TOKENS = 250;

if (import.meta.main) {
  Deno.serve(async (req) => {
    const request_id = crypto.randomUUID();

    try {
      // 1) Guard: internal-only shared secret
      requireSharedSecret(req);

      // 2) Parse body safely (BYTE cap)
      const body = await safeJson(req, MAX_BODY_BYTES);

      // 3) Validate required fields
      const { original_text, surface, sender_user_id } = validate(body);

      // 4) Call OpenAI classifier (strict schema)
      const result = await classify({
        model: Deno.env.get("CLASSIFIER_MODEL") ?? "gpt-4o-mini",
        apiKey: env("OPENAI_CLASSIFIER_API_KEY"),
        original_text,
        surface,
        sender_user_id,
        request_id,
      });

      return json({ ok: true, classifier_result: result, request_id }, 200);
    } catch (e) {
      const err = normalizeError(e);
      return json(
        {
          ok: false,
          error: err.message,
          code: err.code,
          retryable: err.retryable,
          request_id,
        },
        err.status,
      );
    }
  });
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
    throw makeError(413, "payload_too_large", "request body too large", false);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw makeError(400, "invalid_json_payload", "invalid JSON payload", false);
  }
}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw makeError(500, "missing_env", `Missing env ${name}`, false);
  return v;
}

/* ---------------- Auth guard ---------------- */

function requireSharedSecret(req: Request) {
  // You set this in Supabase secrets as: CLASSIFIER_SHARED_SECRET="..."
  // Callers must send header: x-internal-secret: <value>
  const expected = env("CLASSIFIER_SHARED_SECRET");
  const got = req.headers.get("x-internal-secret");
  if (!got || got !== expected) {
    throw makeError(
      401,
      "unauthorized",
      "missing/invalid internal secret",
      false,
    );
  }
}

/* ---------------- Validation ---------------- */

function validate(input: unknown) {
  if (!input || typeof input !== "object") {
    throw makeError(400, "invalid_payload", "invalid payload", false);
  }
  const obj = input as Record<string, unknown>;

  const required = (k: string) => {
    const v = obj[k];
    if (typeof v !== "string" || !v.trim()) {
      throw makeError(400, "missing_field", `${k} missing`, false);
    }
    return v.trim();
  };

  const original_text = required("original_text");
  const surface = required("surface");
  const sender_user_id = required("sender_user_id");

  if (original_text.length > MAX_ORIGINAL_TEXT_CHARS) {
    throw makeError(
      413,
      "payload_too_large",
      `original_text too long (max ${MAX_ORIGINAL_TEXT_CHARS} chars)`,
      false,
    );
  }

  // Basic UUID sanity check (not perfect, but avoids obvious junk)
  if (!isUuid(sender_user_id)) {
    throw makeError(
      400,
      "invalid_sender_user_id",
      "sender_user_id must be a UUID",
      false,
    );
  }

  // surface: allow flexible, but keep it sane
  if (surface.length > 64) {
    throw makeError(400, "invalid_surface", "surface too long", false);
  }

  return { original_text, surface, sender_user_id } as const;
}

function isUuid(v: string): boolean {
  // RFC 4122-ish
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(
      v,
    );
}

/* ---------------- OpenAI call ---------------- */

async function classify(params: {
  model: string;
  apiKey: string;
  original_text: string;
  surface: string;
  sender_user_id: string;
  request_id: string;
}): Promise<ClassifierOutput> {
  const instructions = "You are a fast, cheap classifier. " +
    "Return ONLY a JSON object that matches the provided schema. " +
    "Do not include extra keys. Do not include explanations.";

  const input = [
    {
      role: "user",
      content: [
        {
          type: "text",
          text: JSON.stringify({
            sender_message: params.original_text,
            surface: params.surface,
            sender_user_id: params.sender_user_id,
          }),
        },
      ],
    },
  ];

  // Strict JSON Schema (Structured Outputs)
  const schema = {
    name: "complaint_classifier_v1",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        detected_language: { type: "string", minLength: 2, maxLength: 16 },
        topics: {
          type: "array",
          items: {
            type: "string",
            enum: [
              "noise",
              "cleanliness",
              "privacy",
              "guests",
              "schedule",
              "communication",
              "other",
            ],
          },
          minItems: 1,
          maxItems: 3,
        },
        intent: {
          type: "string",
          enum: ["request", "boundary", "concern", "clarification"],
        },
        rewrite_strength: {
          type: "string",
          enum: ["light_touch", "full_reframe"],
        },
        safety_flags: {
          type: "array",
          items: { type: "string", maxLength: 48 },
          minItems: 0,
          maxItems: 12,
        },
      },
      required: [
        "detected_language",
        "topics",
        "intent",
        "rewrite_strength",
        "safety_flags",
      ],
    },
  } as const;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), OPENAI_TIMEOUT_MS);

  let resp: Response;
  try {
    resp = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${params.apiKey}`,
      },
      body: JSON.stringify({
        model: params.model,
        instructions,
        input,
        max_output_tokens: MAX_OUTPUT_TOKENS,
        text: { format: { type: "json_schema", ...schema } },
        metadata: {
          request_id: params.request_id,
          surface: params.surface,
        },
      }),
    });
  } catch (e) {
    if (String(e).includes("AbortError")) {
      throw makeError(504, "openai_timeout", "classifier timed out", true);
    }
    throw makeError(
      502,
      "openai_fetch_failed",
      "classifier upstream fetch failed",
      true,
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!resp.ok) {
    const errText = await resp.text().catch(() => "");
    const msg = errText
      ? `classifier_error ${resp.status}: ${truncate(errText, 300)}`
      : `classifier_error ${resp.status}`;

    // Retryability + status mapping:
    // - 429 / 5xx from provider are retryable
    // - 4xx (other than 429) typically means a request/config issue; not retryable
    const retryable = resp.status === 429 || resp.status >= 500;

    // Keep outward status stable for internal callers:
    // - 401/403 from provider -> treat as 502 (your config is wrong), not retryable
    // - 429 -> 502 retryable
    // - 5xx -> 502 retryable
    // - other 4xx -> 502 not retryable
    throw makeError(502, "openai_error", msg, retryable);
  }

  // Responses API returns a structured object; extract final text output
  const data: unknown = await resp.json().catch(() => null);
  const outputText = extractOutputText(data);

  // Even with strict schema, keep a final guard (defense in depth)
  let parsed: ParsedClassifier;
  try {
    parsed = JSON.parse(outputText) as ParsedClassifier;
  } catch {
    throw makeError(
      502,
      "openai_bad_json",
      "classifier returned non-JSON output",
      true,
    );
  }

  const normalized = normalizeClassifier(parsed);

  return {
    classifier_version: "v1",
    detected_language: normalized.detected_language,
    topics: normalized.topics,
    intent: normalized.intent,
    rewrite_strength: normalized.rewrite_strength,
    safety_flags: normalized.safety_flags,
  };
}

/* ---------------- Responses extraction ---------------- */

function extractOutputText(data: unknown): string {
  // In Responses API, output text is typically in data.output_text.
  if (
    isRecord(data) && typeof data.output_text === "string" &&
    data.output_text.trim()
  ) {
    return data.output_text.trim();
  }

  // Fallback: attempt to find the first "output_text" chunk
  const items = isRecord(data) && Array.isArray(data.output) ? data.output : [];
  for (const it of items) {
    const content = isRecord(it) ? it.content : undefined;
    if (Array.isArray(content)) {
      for (const c of content) {
        if (
          isRecord(c) &&
          c.type === "output_text" &&
          typeof c.text === "string" &&
          c.text.trim()
        ) {
          return c.text.trim();
        }
      }
    }
  }

  throw makeError(
    502,
    "openai_empty",
    "classifier returned empty output",
    true,
  );
}

/* ---------------- Normalization ---------------- */

type ParsedClassifier = {
  detected_language?: unknown;
  topics?: unknown;
  intent?: unknown;
  rewrite_strength?: unknown;
  safety_flags?: unknown;
};

function normalizeClassifier(parsed: ParsedClassifier): {
  detected_language: string;
  topics: Topic[];
  intent: Intent;
  rewrite_strength: RewriteStrength;
  safety_flags: string[];
} {
  // detected_language
  const detected_language = normalizeLocale(parsed?.detected_language) ?? "en";

  // topics
  const rawTopics = Array.isArray(parsed?.topics)
    ? parsed.topics.filter((t): t is string => typeof t === "string")
    : [];
  const topics = rawTopics
    .map((t) => t.trim())
    .filter((t): t is Topic => ALLOWED_TOPICS.has(t as Topic))
    .slice(0, 3);
  const finalTopics = topics.length ? topics : (["other"] as Topic[]);

  // intent
  const intent = typeof parsed?.intent === "string" &&
      ALLOWED_INTENTS.has(parsed.intent as Intent)
    ? (parsed.intent as Intent)
    : ("concern" as Intent);

  // rewrite_strength
  const rewrite_strength = typeof parsed?.rewrite_strength === "string" &&
      ALLOWED_REWRITE_STRENGTH.has(parsed.rewrite_strength as RewriteStrength)
    ? (parsed.rewrite_strength as RewriteStrength)
    : ("full_reframe" as RewriteStrength);

  // safety_flags
  const safety_flags =
    Array.isArray(parsed?.safety_flags) && parsed.safety_flags.length > 0
      ? parsed.safety_flags
        .filter((x): x is string => typeof x === "string")
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 12)
      : ["none"];

  return {
    detected_language,
    topics: finalTopics,
    intent,
    rewrite_strength,
    safety_flags,
  };
}

function normalizeLocale(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!s) return null;
  // allow "en", "en-nz", "zh-hant" etc (loose)
  if (!/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/.test(s)) return null;
  return s.toLowerCase();
}

/* ---------------- Error plumbing ---------------- */

type AppError = {
  status: number;
  code: string;
  message: string;
  retryable: boolean;
};

function makeError(
  status: number,
  code: string,
  message: string,
  retryable: boolean,
): AppError {
  return { status, code, message, retryable };
}

function normalizeError(e: unknown): AppError {
  if (
    isRecord(e) &&
    typeof e.status === "number" &&
    typeof e.code === "string" &&
    typeof e.message === "string" &&
    typeof e.retryable === "boolean"
  ) {
    return {
      status: e.status,
      code: e.code,
      message: e.message,
      retryable: e.retryable,
    };
  }

  // Backstop: treat unknown errors as retryable only if they look transient
  const msg = (e instanceof Error && e.message) ||
    (isRecord(e) && typeof e.message === "string" ? e.message : null) ||
    String(e ?? "unknown error");
  const retryable = isRetryableText(msg);
  return makeError(500, "internal_error", msg, retryable);
}

function isRetryableText(msg: string) {
  const m = msg.toLowerCase();
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
    m.includes("temporarily") ||
    m.includes("unavailable")
  );
}

/* ---------------- Utils ---------------- */

function truncate(s: string, n: number) {
  return s.length <= n ? s : s.slice(0, n) + "…";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

// Test-only exports
export {
  extractOutputText,
  isUuid,
  makeError,
  normalizeClassifier,
  normalizeError,
  safeJson,
  validate,
};
