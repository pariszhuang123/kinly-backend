// supabase/functions/notification_daily/index.ts
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.48.0";

type Candidate = {
  user_id: string;
  locale: string;
  timezone: string;
  token_id: string;
  token: string;
  local_date: string;
};

type SendResult =
  | { ok: true }
  | { ok: false; permanent: boolean; reason: string };

type ServiceAccount = {
  client_email: string;
  private_key: string;
  token_uri?: string;
  project_id?: string;
};

const TEMPLATES: Record<string, string> = {
  en: "Your day is ready ✨ Tap to see what's waiting.",
  es: "Tu dia esta listo ✨ Toca para ver lo que te espera.",
  ar: "يومك جاهز ✨ اضغط لمعرفة ما بانتظارك.",
};

const DEFAULT_LOCALE = "en";
const PAGE_SIZE = 200;
const BATCH_CONCURRENCY = 20;
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const ERROR_REASON_MAX_LENGTH = 512;

// ---------------------------------------------------------------------------
// Logging helpers (safe / non-sensitive)
// ---------------------------------------------------------------------------

function logFcmContext(
  context: string,
  details: {
    projectId?: string;
    clientEmail?: string;
    token?: string;
    tokenId?: string;
    userId?: string;
  },
) {
  console.log("[FCM CONTEXT]", {
    context,
    projectId: details.projectId,
    clientEmail: details.clientEmail,
    token_prefix: details.token ? details.token.slice(0, 12) + "…" : undefined,
    token_id: details.tokenId,
    user_id: details.userId,
    at: new Date().toISOString(),
  });
}

// ---------------------------------------------------------------------------
// Main entry
// ---------------------------------------------------------------------------

if (import.meta.main) {
  Deno.serve(async (_req: Request) => {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({
          error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY",
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    const supabase: SupabaseClient = createClient(supabaseUrl, supabaseKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const jobRunId = crypto.randomUUID();
    let offset = 0;
    let totalSent = 0;
    let totalFailed = 0;
    let totalExpired = 0;
    const startedAt = Date.now();

    console.log("[notifications-daily] start", {
      jobRunId,
      pageSize: PAGE_SIZE,
      batchConcurrency: BATCH_CONCURRENCY,
      at: new Date().toISOString(),
    });

    try {
      while (true) {
        const batch = await fetchCandidates(supabase, PAGE_SIZE, offset);
        if (batch.length === 0) break;

        console.log("[notifications-daily] fetched batch", {
          jobRunId,
          offset,
          batchSize: batch.length,
        });

        const { sent, failed, expired } = await processBatch(
          supabase,
          batch,
          jobRunId,
        );

        totalSent += sent;
        totalFailed += failed;
        totalExpired += expired;

        offset += batch.length;
      }

      const durationMs = Date.now() - startedAt;
      console.log("[notifications-daily] done", {
        jobRunId,
        sent: totalSent,
        failed: totalFailed,
        tokensExpired: totalExpired,
        durationMs,
      });

      return new Response(
        JSON.stringify({
          jobRunId,
          sent: totalSent,
          failed: totalFailed,
          tokensExpired: totalExpired,
          durationMs,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    } catch (error) {
      console.error("notifications-daily job error", { jobRunId, error });
      const durationMs = Date.now() - startedAt;
      return new Response(
        JSON.stringify({
          jobRunId,
          sent: totalSent,
          failed: totalFailed,
          tokensExpired: totalExpired,
          durationMs,
          error: (error as Error).message ?? "unknown_error",
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
  });
}

// ---------------------------------------------------------------------------
// Helpers: candidates + messages
// ---------------------------------------------------------------------------

export function buildMessage(locale: string | null | undefined): string {
  const normalized = (locale ?? "").toLowerCase();
  if (TEMPLATES[normalized]) return TEMPLATES[normalized];
  const language = normalized.split("-")[0];
  if (language && TEMPLATES[language]) return TEMPLATES[language];
  return TEMPLATES[DEFAULT_LOCALE];
}

async function fetchCandidates(
  supabase: SupabaseClient,
  limit: number,
  offset: number,
): Promise<Candidate[]> {
  const { data, error } = await supabase.rpc(
    "notifications_daily_candidates",
    {
      p_limit: limit,
      p_offset: offset,
    },
  );

  if (error) {
    console.error("notifications_daily_candidates error", error);
    // Fail the job so it's visible (retriable by scheduler)
    throw error;
  }

  // Cast because we know what the RPC returns
  return (data as Candidate[] | null) ?? [];
}

// ---------------------------------------------------------------------------
// Batch processing with limited concurrency
// ---------------------------------------------------------------------------

type BatchCounts = {
  sent: number;
  failed: number;
  expired: number;
};

async function processBatch(
  supabase: SupabaseClient,
  batch: Candidate[],
  jobRunId: string,
): Promise<BatchCounts> {
  let sent = 0;
  let failed = 0;
  let expired = 0;

  for (let i = 0; i < batch.length; i += BATCH_CONCURRENCY) {
    const slice = batch.slice(i, i + BATCH_CONCURRENCY);

    const results = await Promise.all(
      slice.map((candidate) => handleCandidate(supabase, candidate, jobRunId)),
    );

    for (const r of results) {
      sent += r.sent;
      failed += r.failed;
      expired += r.expired;
    }
  }

  return { sent, failed, expired };
}

async function handleCandidate(
  supabase: SupabaseClient,
  candidate: Candidate,
  jobRunId: string,
): Promise<BatchCounts> {
  const message = buildMessage(candidate.locale);
  const localDate = candidate.local_date;

  // 1️⃣ Reserve the send (idempotency guard via RPC)
  const sendId = await reserveSend(
    supabase,
    candidate.user_id,
    candidate.token_id,
    localDate,
    jobRunId,
  );

  if (!sendId) {
    // Already reserved by another worker or another run
    return { sent: 0, failed: 0, expired: 0 };
  }

  // 2️⃣ Attempt to send push
  const result = await sendPush(candidate.token, message, {
    userId: candidate.user_id,
    tokenId: candidate.token_id,
  });

  if (result.ok) {
    await markSendSuccess(supabase, sendId, candidate.user_id, localDate);
    return { sent: 1, failed: 0, expired: 0 };
  }

  const truncatedReason = truncateReason(result.reason, ERROR_REASON_MAX_LENGTH);
  await updateSendStatus(supabase, sendId, "failed", truncatedReason);

  if (result.permanent) {
    await markTokenStatus(supabase, candidate.token_id, "expired");
    return { sent: 0, failed: 1, expired: 1 };
  }

  return { sent: 0, failed: 1, expired: 0 };
}

// ---------------------------------------------------------------------------
// Helpers: notification_sends + preferences + tokens (all via RPCs)
// ---------------------------------------------------------------------------

async function reserveSend(
  supabase: SupabaseClient,
  userId: string,
  tokenId: string,
  localDate: string,
  jobRunId: string,
): Promise<string | null> {
  const { data, error } = await supabase.rpc("notifications_reserve_send", {
    p_user_id: userId,
    p_token_id: tokenId,
    p_local_date: localDate,
    p_job_run_id: jobRunId,
  });

  if (error) {
    console.error("notifications_reserve_send error", error);
    return null;
  }

  // data is the uuid or null if conflict
  return (data as string | null) ?? null;
}

async function markSendSuccess(
  supabase: SupabaseClient,
  sendId: string,
  userId: string,
  localDate: string,
) {
  const { error } = await supabase.rpc("notifications_mark_send_success", {
    p_send_id: sendId,
    p_user_id: userId,
    p_local_date: localDate,
  });

  if (error) {
    console.error("notifications_mark_send_success error", error);
  }
}

async function updateSendStatus(
  supabase: SupabaseClient,
  sendId: string,
  status: "sent" | "failed",
  errorText?: string,
) {
  const { error } = await supabase.rpc("notifications_update_send_status", {
    p_send_id: sendId,
    p_status: status,
    p_error: errorText ?? null,
  });

  if (error) {
    console.error("notifications_update_send_status error", error);
  }
}

async function markTokenStatus(
  supabase: SupabaseClient,
  tokenId: string,
  status: "expired" | "revoked",
) {
  const { error } = await supabase.rpc("notifications_mark_token_status", {
    p_token_id: tokenId,
    p_status: status,
  });

  if (error) {
    console.error("notifications_mark_token_status error", error);
  }
}

// ---------------------------------------------------------------------------
// FCM send
// ---------------------------------------------------------------------------

async function sendPush(
  token: string,
  body: string,
  meta?: { userId?: string; tokenId?: string },
): Promise<SendResult> {
  const auth = await getAccessToken();
  if (!auth) {
    return { ok: false, permanent: false, reason: "missing_service_account" };
  }

  logFcmContext("sending_push", {
    projectId: auth.projectId,
    token,
    userId: meta?.userId,
    tokenId: meta?.tokenId,
  });

  const payload = {
    message: {
      token,
      notification: {
        title: "Kinly",
        body,
      },
      data: {
        deepLink: "/today",
      },
    },
  };

  const url = `https://fcm.googleapis.com/v1/projects/${auth.projectId}/messages:send`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${auth.accessToken}`,
    },
    body: JSON.stringify(payload),
  });

  const status = response.status;

  if (!response.ok) {
    const text = await response.text();

    console.error("[FCM ERROR]", {
      projectId: auth.projectId,
      status,
      body: text.slice(0, 500),
      at: new Date().toISOString(),
    });

    // Only treat as permanent if the body clearly indicates a dead token.
    const permanent = isPermanentTokenError(text);
    return {
      ok: false,
      permanent,
      reason: `http_${status}:${text}`,
    };
  }

  const json = (await response.json().catch(() => ({}))) as {
    name?: string;
    error?: { message?: string };
  };

  if (json.error) {
    const message = json.error.message ?? "unknown_fcm_error";
    const permanent = isPermanentTokenError(message);

    console.error("[FCM JSON ERROR]", {
      projectId: auth.projectId,
      message: message.slice(0, 500),
      at: new Date().toISOString(),
    });

    return { ok: false, permanent, reason: message };
  }

  return { ok: true };
}

export function isPermanentTokenError(text: string): boolean {
  if (!text) return false;

  const upper = text.toUpperCase();
  if (upper.includes("UNREGISTERED") || upper.includes("NOT_FOUND")) {
    return true;
  }

  try {
    const parsed = JSON.parse(text) as {
      error?: {
        status?: string;
        details?: Array<{ errorCode?: string; error_code?: string }>;
      };
    };
    const status = parsed.error?.status?.toUpperCase();
    if (
      status && (status.includes("UNREGISTERED") || status.includes("NOT_FOUND"))
    ) {
      return true;
    }
    const details = parsed.error?.details ?? [];
    return details.some((d) => {
      const code = (d.errorCode ?? d.error_code ?? "").toString().toUpperCase();
      return code.includes("UNREGISTERED") || code.includes("NOT_FOUND");
    });
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// OAuth helper for FCM HTTP v1
// ---------------------------------------------------------------------------

let cachedAuth:
  | {
    accessToken: string;
    expiresAt: number;
    projectId: string;
  }
  | null = null;

function parseServiceAccount(): ServiceAccount | null {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) {
    console.error("FCM_SERVICE_ACCOUNT env missing");
    return null;
  }
  try {
    return JSON.parse(raw) as ServiceAccount;
  } catch (error) {
    console.error("Failed to parse FCM_SERVICE_ACCOUNT", error);
    return null;
  }
}

async function getAccessToken(): Promise<
  { accessToken: string; projectId: string } | null
> {
  const now = Date.now();

  if (cachedAuth && cachedAuth.expiresAt > now + 60_000) {
    logFcmContext("cached_auth", {
      projectId: cachedAuth.projectId,
    });

    return {
      accessToken: cachedAuth.accessToken,
      projectId: cachedAuth.projectId,
    };
  }

  const sa = parseServiceAccount();
  if (!sa?.client_email || !sa?.private_key) {
    console.error("FCM service account missing email or private key");
    return null;
  }

  const tokenUri = sa.token_uri ?? "https://oauth2.googleapis.com/token";

  const projectIdFromJson = sa.project_id;
  const projectIdFromEnv = Deno.env.get("FCM_PROJECT_ID") ?? undefined;
  const projectId = projectIdFromJson ?? projectIdFromEnv;

  if (!projectId) {
    console.error(
      "project_id missing (use service account project_id or FCM_PROJECT_ID env)",
    );
    return null;
  }

  logFcmContext("service_account_loaded", {
    projectId,
    clientEmail: sa.client_email,
  });

  const jwt = await createJwt(sa.client_email, sa.private_key, tokenUri, SCOPE);
  if (!jwt) return null;

  const params = new URLSearchParams();
  params.set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer");
  params.set("assertion", jwt);

  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString(),
  });

  if (!response.ok) {
    console.error("Failed to fetch access token", await response.text());
    return null;
  }

  const json = (await response.json()) as {
    access_token?: string;
    expires_in?: number;
  };

  const accessToken = json.access_token;
  const expiresIn = json.expires_in;
  if (!accessToken || !expiresIn) {
    console.error("Malformed token response", json);
    return null;
  }

  cachedAuth = {
    accessToken,
    projectId,
    expiresAt: now + (expiresIn - 60) * 1000,
  };

  return { accessToken, projectId };
}

async function createJwt(
  clientEmail: string,
  privateKeyPem: string,
  tokenUri: string,
  scope: string,
): Promise<string | null> {
  try {
    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + 3600;

    const header = base64UrlEncode(
      new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })),
    );
    const claim = base64UrlEncode(
      new TextEncoder().encode(
        JSON.stringify({
          iss: clientEmail,
          sub: clientEmail,
          scope,
          aud: tokenUri,
          iat,
          exp,
        }),
      ),
    );

    const unsigned = `${header}.${claim}`;
    const key = await importPrivateKey(privateKeyPem);
    const signatureBuf = await crypto.subtle.sign(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      new TextEncoder().encode(unsigned),
    );
    const signature = base64UrlEncode(new Uint8Array(signatureBuf));
    return `${unsigned}.${signature}`;
  } catch (error) {
    console.error("createJwt error", error);
    return null;
  }
}

function importPrivateKey(pem: string): Promise<CryptoKey> {
  const cleaned = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const binaryDer = Uint8Array.from(atob(cleaned), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    binaryDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function base64UrlEncode(data: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...data));
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------------------------------------------------------------------------
// Small util (UTF-8 / grapheme-safe truncation)
// ---------------------------------------------------------------------------

const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

export function truncateReason(reason: string, maxLength: number): string {
  const segments = [...segmenter.segment(reason)];
  if (segments.length <= maxLength) return reason;
  return segments.slice(0, maxLength).map((s) => s.segment).join("") + "…";
}
