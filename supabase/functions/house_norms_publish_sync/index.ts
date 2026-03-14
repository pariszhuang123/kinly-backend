import { createClient } from "npm:@supabase/supabase-js@2.48.0";

const REVALIDATE_TIMEOUT_MS = 3000;

type PublishPayload = {
  home_public_id: string;
  published_at: string; // must be exact ISO (toISOString)
  published_version: string;
  template_key: string;
  locale_base: string;
  published_content: Record<string, unknown>;
  public_url_path?: string | null;
  publish_job_id?: string | null;
};

type AppErrorCode =
  | "unauthorized"
  | "invalid_method"
  | "invalid_payload"
  | "invalid_home_public_id"
  | "invalid_published_version"
  | "invalid_published_at"
  | "invalid_template_key"
  | "invalid_locale_base"
  | "invalid_published_content"
  | "invalid_public_url_path"
  | "payload_too_large"
  | "content_too_large"
  | `missing_env:${string}`
  | "artifact_failed"
  | "revalidate_failed"
  | "unexpected_error";

class AppError extends Error {
  code: AppErrorCode;
  status: number;
  details?: string;

  constructor(code: AppErrorCode, status: number, details?: string) {
    super(code);
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    const requestId = req.headers.get("x-request-id")?.trim() ||
      crypto.randomUUID();
    let stage = "start";
    let payload: PublishPayload | null = null;
    let supabase: ReturnType<typeof serviceClient> | null = null;
    let snapshotUploadMs: number | null = null;
    let manifestUploadMs: number | null = null;
    let revalidateMs: number | null = null;
    let artifactOk = false;
    let revalidateOk = false;

    try {
      requireInternalSecret(req);
      stage = "auth_checked";

      if (req.method !== "POST") {
        throw new AppError("invalid_method", 405);
      }

      payload = await parsePayload(req);
      stage = "payload_parsed";

      supabase = serviceClient();
      await markJobProcessing(
        supabase,
        payload.publish_job_id,
        requestId,
        "processing",
      );

      // Normalize consistently (and validate normalized)
      const homePublicId = payload.home_public_id.toLowerCase();
      if (!/^[a-z0-9]{8,32}$/.test(homePublicId)) {
        throw new AppError("invalid_home_public_id", 400);
      }

      const publishedVersion = payload.published_version;

      const snapshotPath =
        `public_norms/home/${homePublicId}/published_${publishedVersion}.json`;
      const manifestPath = `public_norms/home/${homePublicId}/manifest.json`;

      const snapshotBody = {
        home_public_id: homePublicId,
        published_at: payload.published_at,
        published_version: publishedVersion,
        template_key: payload.template_key,
        locale_base: payload.locale_base,
        published_content: payload.published_content,
      };

      // Guardrail: cap snapshot JSON size (approximate but effective)
      const snapshotJson = JSON.stringify(snapshotBody);
      const maxSnapshotBytes = 250_000; // ~250KB (tune)
      if (byteLength(snapshotJson) > maxSnapshotBytes) {
        throw new AppError(
          "content_too_large",
          413,
          `snapshot_bytes>${maxSnapshotBytes}`,
        );
      }

      const snapshotBlob = new Blob([snapshotJson], {
        type: "application/json; charset=utf-8",
      });

      stage = "snapshot_upload";
      const snapshotStart = Date.now();
      const { error: snapshotErr } = await supabase.storage
        .from("households")
        .upload(snapshotPath, snapshotBlob, {
          upsert: true,
          contentType: "application/json; charset=utf-8",
          // Versioned snapshots can be long-cached IF you never mutate old versions.
          cacheControl: "public, max-age=31536000, immutable",
        });
      snapshotUploadMs = Date.now() - snapshotStart;

      if (snapshotErr) {
        throw new AppError("artifact_failed", 502, snapshotErr.message);
      }

      const manifestBody = {
        home_public_id: homePublicId,
        published_at: payload.published_at,
        published_version: publishedVersion,
        latest_snapshot_path: snapshotPath,
      };

      const manifestBlob = new Blob([JSON.stringify(manifestBody)], {
        type: "application/json; charset=utf-8",
      });

      stage = "manifest_upload";
      const manifestStart = Date.now();
      const { error: manifestErr } = await supabase.storage
        .from("households")
        .upload(manifestPath, manifestBlob, {
          upsert: true,
          contentType: "application/json; charset=utf-8",
          // Manifest should never be cached.
          cacheControl: "no-store",
        });
      manifestUploadMs = Date.now() - manifestStart;

      if (manifestErr) {
        throw new AppError("artifact_failed", 502, manifestErr.message);
      }
      artifactOk = true;

      const revalidatePath = payload.public_url_path ||
        `/kinly/norms/${homePublicId}`;
      stage = "revalidate";
      const revalidateStart = Date.now();
      const revalidated = await callRevalidate(revalidatePath);
      revalidateMs = Date.now() - revalidateStart;

      if (!revalidated.ok) {
        throw new AppError("revalidate_failed", 502, revalidated.error);
      }
      revalidateOk = true;

      stage = "done";
      await markJobSucceeded(
        supabase,
        payload.publish_job_id,
        requestId,
        snapshotUploadMs,
        manifestUploadMs,
        revalidateMs,
      );
      console.log(JSON.stringify({
        level: "info",
        msg: "house_norms_publish_sync_ok",
        request_id: requestId,
        publish_job_id: payload.publish_job_id ?? null,
        home_public_id: homePublicId,
        published_version: publishedVersion,
        snapshot_path: snapshotPath,
        manifest_path: manifestPath,
        revalidate_path: revalidatePath,
        snapshot_upload_ms: snapshotUploadMs,
        manifest_upload_ms: manifestUploadMs,
        revalidate_ms: revalidateMs,
      }));

      return json(
        {
          ok: true,
          request_id: requestId,
          artifact_ok: artifactOk,
          revalidate_ok: revalidateOk,
          error_code: null,
        },
        200,
      );
    } catch (err) {
      const appErr = normalizeError(err);
      await markJobFailed(
        supabase,
        payload?.publish_job_id,
        requestId,
        appErr.code,
        appErr.details ?? appErr.code,
        stage,
        snapshotUploadMs,
        manifestUploadMs,
        revalidateMs,
      );

      console.log(JSON.stringify({
        level: appErr.status >= 500 ? "error" : "warn",
        msg: "house_norms_publish_sync_failed",
        request_id: requestId,
        publish_job_id: payload?.publish_job_id ?? null,
        stage,
        error_code: appErr.code,
        details: appErr.details,
        snapshot_upload_ms: snapshotUploadMs,
        manifest_upload_ms: manifestUploadMs,
        revalidate_ms: revalidateMs,
      }));

      return json(
        {
          ok: false,
          request_id: requestId,
          artifact_ok: artifactOk,
          revalidate_ok: revalidateOk,
          error_code: appErr.code,
          details: appErr.details ?? null,
        },
        appErr.status,
      );
    }
  });
}

function serviceClient() {
  const supabaseUrl = env("SUPABASE_URL");
  const serviceRoleKey = env("SUPABASE_SERVICE_ROLE_KEY");

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function parsePayload(req: Request): Promise<PublishPayload> {
  // Guardrail: cap request body bytes (simple approach)
  const raw = await req.text().catch(() => "");
  const maxBodyBytes = 300_000; // ~300KB (tune)
  if (!raw || byteLength(raw) > maxBodyBytes) {
    throw new AppError("payload_too_large", 413, `body_bytes>${maxBodyBytes}`);
  }

  let body: unknown = null;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new AppError("invalid_payload", 400);
  }

  if (!body || typeof body !== "object") {
    throw new AppError("invalid_payload", 400);
  }

  const payload = body as Record<string, unknown>;

  const homePublicId = String(payload.home_public_id ?? "").trim();
  const publishedAt = String(payload.published_at ?? "").trim();
  const publishedVersion = String(payload.published_version ?? "").trim();
  const templateKey = String(payload.template_key ?? "").trim();
  const localeBase = String(payload.locale_base ?? "").trim();
  const publishedContent = payload.published_content;
  const publishJobId = payload.publish_job_id == null
    ? null
    : String(payload.publish_job_id).trim();

  // Validate (note: home_public_id final validation after lowercase normalization in handler)
  if (!homePublicId) throw new AppError("invalid_home_public_id", 400);

  if (!/^v[0-9]{6}$/.test(publishedVersion)) {
    throw new AppError("invalid_published_version", 400);
  }

  // Exact ISO check (canonical UTC ISO)
  const d = new Date(publishedAt);
  if (Number.isNaN(d.getTime()) || publishedAt !== d.toISOString()) {
    throw new AppError(
      "invalid_published_at",
      400,
      "published_at must equal Date(...).toISOString()",
    );
  }

  if (!/^[a-z0-9_]{1,64}$/.test(templateKey)) {
    throw new AppError("invalid_template_key", 400);
  }

  if (!/^[a-z]{2}$/.test(localeBase)) {
    throw new AppError("invalid_locale_base", 400);
  }

  if (
    !publishedContent || typeof publishedContent !== "object" ||
    Array.isArray(publishedContent)
  ) {
    throw new AppError("invalid_published_content", 400);
  }

  const publicUrlPath = payload.public_url_path
    ? String(payload.public_url_path)
    : null;
  if (publicUrlPath !== null) {
    validateRelativePath(publicUrlPath);
  }

  if (
    publishJobId !== null &&
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(publishJobId)
  ) {
    throw new AppError("invalid_payload", 400, "publish_job_id must be a UUID");
  }

  return {
    home_public_id: homePublicId,
    published_at: publishedAt,
    published_version: publishedVersion,
    template_key: templateKey,
    locale_base: localeBase,
    published_content: publishedContent as Record<string, unknown>,
    public_url_path: publicUrlPath,
    publish_job_id: publishJobId,
  };
}

function validateRelativePath(path: string) {
  const p = path.trim();
  if (p.length === 0 || p.length > 256) {
    throw new AppError("invalid_public_url_path", 400, "path length invalid");
  }
  if (!p.startsWith("/")) {
    throw new AppError(
      "invalid_public_url_path",
      400,
      "path must start with '/'",
    );
  }
  if (p.includes("..")) {
    throw new AppError(
      "invalid_public_url_path",
      400,
      "path must not contain '..'",
    );
  }
  // Optional: lock to your route shape only
  // if (!/^\/kinly\/norms\/[a-z0-9]{8,32}$/.test(p)) throw new AppError("invalid_public_url_path", 400);
}

async function callRevalidate(
  path: string,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const url = env("VERCEL_REVALIDATE_URL");
  const secret = env("VERCEL_REVALIDATE_SECRET");

  const response = await fetch(url, {
    method: "POST",
    signal: AbortSignal.timeout(REVALIDATE_TIMEOUT_MS),
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "x-revalidate-secret": secret, // single header only
    },
    body: JSON.stringify({ path }),
  }).catch((error) => {
    return new Response(JSON.stringify({ error: toErrorMessage(error) }), {
      status: 599,
      headers: { "Content-Type": "application/json" },
    });
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    return {
      ok: false,
      error: `status=${response.status} body=${text.slice(0, 300)}`,
    };
  }

  return { ok: true };
}

function requireInternalSecret(req: Request) {
  const expected = env("WORKER_SHARED_SECRET");
  const got = req.headers.get("x-internal-secret");
  if (!got || got !== expected) {
    throw new AppError("unauthorized", 401);
  }
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new AppError(`missing_env:${name}`, 500);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

function byteLength(s: string): number {
  return new TextEncoder().encode(s).length;
}

function normalizeError(err: unknown): AppError {
  if (err instanceof AppError) return err;

  const msg = toErrorMessage(err);

  // If something else threw "missing_env:FOO" as a plain Error string
  if (msg.startsWith("missing_env:")) {
    return new AppError(`missing_env:${msg.split(":")[1]}`, 500);
  }

  // Fallback
  return new AppError("unexpected_error", 500, msg);
}

type JobRpcClient = {
  rpc(
    fn: string,
    args?: Record<string, unknown>,
  ): PromiseLike<{ error: { message: string } | null }>;
};

async function markJobProcessing(
  supabase: JobRpcClient | null,
  jobId: string | null | undefined,
  requestId: string,
  stage: string,
) {
  if (!supabase || !jobId) return;

  const { error } = await supabase.rpc(
    "house_norms_publish_job_mark_processing",
    {
      p_job_id: jobId,
      p_request_id: requestId,
      p_stage: stage,
    },
  );

  if (error) {
    console.log(JSON.stringify({
      level: "warn",
      msg: "house_norms_publish_sync_job_mark_processing_failed",
      request_id: requestId,
      publish_job_id: jobId,
      details: error.message,
    }));
  }
}

async function markJobSucceeded(
  supabase: JobRpcClient | null,
  jobId: string | null | undefined,
  requestId: string,
  snapshotUploadMs: number | null,
  manifestUploadMs: number | null,
  revalidateMs: number | null,
) {
  if (!supabase || !jobId) return;

  const { error } = await supabase.rpc(
    "house_norms_publish_job_mark_succeeded",
    {
      p_job_id: jobId,
      p_request_id: requestId,
      p_snapshot_upload_ms: snapshotUploadMs,
      p_manifest_upload_ms: manifestUploadMs,
      p_revalidate_ms: revalidateMs,
    },
  );

  if (error) {
    console.log(JSON.stringify({
      level: "warn",
      msg: "house_norms_publish_sync_job_mark_succeeded_failed",
      request_id: requestId,
      publish_job_id: jobId,
      details: error.message,
    }));
  }
}

async function markJobFailed(
  supabase: JobRpcClient | null,
  jobId: string | null | undefined,
  requestId: string,
  errorCode: string,
  errorText: string,
  stage: string,
  snapshotUploadMs: number | null,
  manifestUploadMs: number | null,
  revalidateMs: number | null,
) {
  if (!supabase || !jobId) return;

  const { error } = await supabase.rpc("house_norms_publish_job_mark_failed", {
    p_job_id: jobId,
    p_request_id: requestId,
    p_error_code: errorCode,
    p_error: errorText,
    p_stage: stage,
    p_snapshot_upload_ms: snapshotUploadMs,
    p_manifest_upload_ms: manifestUploadMs,
    p_revalidate_ms: revalidateMs,
  });

  if (error) {
    console.log(JSON.stringify({
      level: "warn",
      msg: "house_norms_publish_sync_job_mark_failed_failed",
      request_id: requestId,
      publish_job_id: jobId,
      details: error.message,
    }));
  }
}

// Test-only exports
export {
  AppError,
  byteLength,
  callRevalidate,
  env,
  markJobFailed,
  markJobProcessing,
  markJobSucceeded,
  normalizeError,
  parsePayload,
  requireInternalSecret,
  toErrorMessage,
  validateRelativePath,
};
