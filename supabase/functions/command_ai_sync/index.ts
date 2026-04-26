import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.48.0";

import { buildIntentWorkItems } from "./assessment.ts";
import {
  executeIntentClassifier,
  normalizeIntentClassifier,
} from "./classifier.ts";
import type { ProviderExecution, ProviderExecutionUsage } from "./providers.ts";
import { buildNormalizedInput } from "./normalization.ts";
import { normalizeGroceryParseResult } from "./parsers/grocery.ts";
import { normalizeTaskParseResult } from "./parsers/task.ts";
import { extractOutputText } from "./shared.ts";
import type {
  FeatureKey,
  FeatureStep,
  GroceryParseResult,
  IntentClassificationResult,
  InvocationPayload,
  NormalizedInput,
  PipelineResult,
  ResolvedRoute,
  TaskParseResult,
  UserContextDefaults,
} from "./types.ts";
import { INTENTS } from "./types.ts";

type RequestContext = {
  requestId: string;
  supabase: SupabaseClient;
  logWarnings: string[];
};

type ProviderResponsePayload = {
  result: unknown;
  providerRequestId: string | null;
  usage: ProviderExecutionUsage;
};

const MAX_BODY_BYTES = 64_000;
const OPENAI_TIMEOUT_MS = 12_000;
const MAX_OUTPUT_TOKENS = 500;
const PARSER_ROLE_KEYS = ["grocery_parser", "task_parser"] as const;

if (import.meta.main) {
  Deno.serve(async (req) => {
    const ctx = createRequestContext();

    try {
      requireInternalSecret(req);

      const invocation = validateInvocation(
        await safeJson(req, MAX_BODY_BYTES),
        ctx.requestId,
      );

      const pipelineResult = await runFeaturePipeline(ctx, invocation);

      return json({
        ok: true,
        request_id: invocation.request_id,
        pipeline_request_id: ctx.requestId,
        client_request_id: invocation.request_id,
        result: pipelineResult,
      }, 200);
    } catch (e) {
      const err = normalizeError(e);
      return json({
        ok: false,
        request_id: ctx.requestId,
        error_code: err.code,
        error: err.message,
        retryable: err.retryable,
        details: err.details ?? null,
      }, err.status);
    }
  });
}

function createRequestContext(): RequestContext {
  return {
    requestId: crypto.randomUUID(),
    supabase: serviceClient(),
    logWarnings: [],
  };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

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

function validateInvocation(
  input: unknown,
  requestId: string,
): InvocationPayload {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw makeError(400, "invalid_payload", "invalid payload", false, {
      request_id: requestId,
    });
  }

  const obj = input as Record<string, unknown>;
  const clientRequestId = requiredString(obj, "request_id");
  const homeId = requiredString(obj, "home_id");
  const featureKey = requiredString(obj, "feature_key") as FeatureKey;
  const payload = obj.payload;

  if (featureKey !== "command") {
    throw makeError(
      400,
      "unsupported_feature_key",
      "unsupported feature_key",
      false,
    );
  }

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw makeError(
      400,
      "invalid_payload",
      "payload object is required",
      false,
    );
  }

  const forbiddenFields = [
    "route",
    "provider",
    "model",
    "adapter_kind",
    "prompt_version",
    "max_retries",
  ];

  assertForbiddenKeys(obj, forbiddenFields, "top_level");
  assertForbiddenKeys(
    payload as Record<string, unknown>,
    forbiddenFields,
    "payload",
  );

  return {
    request_id: clientRequestId,
    home_id: homeId,
    feature_key: featureKey,
    payload: payload as Record<string, unknown>,
  };
}

function assertForbiddenKeys(
  obj: Record<string, unknown>,
  keys: string[],
  scope: string,
) {
  for (const key of keys) {
    if (obj[key] !== undefined) {
      throw makeError(
        400,
        "invalid_payload",
        `${scope}.${key} must not be supplied`,
        false,
      );
    }
  }
}

async function runFeaturePipeline(
  ctx: RequestContext,
  invocation: InvocationPayload,
): Promise<PipelineResult> {
  const normalizedInput = await buildNormalizedInput({
    invocation,
    getUserContextDefaults: (userId) => getUserContextDefaults(ctx, userId),
  }).catch((e) => {
    if (
      e instanceof Error && e.message === "payload.effective_input is required"
    ) {
      throw makeError(400, "invalid_payload", e.message, false);
    }
    throw e;
  });

  const steps = await resolveFeatureSteps(ctx, invocation.feature_key);
  if (steps.length === 0) {
    throw makeError(
      500,
      "pipeline_not_configured",
      "no active feature steps configured",
      false,
    );
  }

  const routes = await resolveRoutesForSteps(ctx, steps);
  const warnings: string[] = [];

  const classifierStep = steps.find((step) =>
    step.role_key === "intent_classifier"
  );
  if (!classifierStep) {
    throw makeError(
      500,
      "pipeline_invalid",
      "intent classification step did not run",
      false,
    );
  }

  const classifierRoute = routes.get(classifierStep.role_key);
  if (!classifierRoute) {
    throw makeError(500, "pipeline_invalid", "missing classifier route", false);
  }

  const classificationExecution = await executeLoggedRole(
    ctx,
    invocation,
    classifierRoute,
    normalizedInput,
    (route, input) =>
      executeIntentClassifier({
        route,
        input,
        callProvider: callClassificationProvider,
      }),
  );

  const classification = classificationExecution.result;

  const workItems = await buildIntentWorkItems({
    normalizedInput,
    classification,
    resolveConfiguredRoute: (roleKey) =>
      Promise.resolve(routes.get(roleKey) ?? null),
    executeParserProvider: (route, input, parserKind, rescueContext) =>
      executeLoggedRole(
        ctx,
        invocation,
        route,
        input,
        (resolvedRoute, resolvedInput) =>
          callParserProvider(
            resolvedRoute,
            resolvedInput,
            parserKind,
            rescueContext,
          ),
      ),
  });

  if (
    classification.primary_intent === "unknown" &&
    classification.intents_detected.length === 1
  ) {
    warnings.push(
      "Classifier returned unknown only. Consider improving prompt quality, training examples, or fallback rules.",
    );
  }

  const executableIntents = workItems
    .filter((item) => item.execution_readiness === "ready")
    .map((item) => item.intent);

  const reviewRequiredIntents = workItems
    .filter((item) => item.execution_readiness === "needs_review")
    .map((item) => item.intent);

  const handledIntents = new Set(workItems.map((item) => item.intent));
  const nonExecutableIntents = classification.intents_detected.filter(
    (intent) => !handledIntents.has(intent),
  );

  return {
    feature_key: invocation.feature_key,
    normalized_input: normalizedInput,
    classification,
    intent_work_items: workItems,
    execution_plan: {
      strategy: "separate_per_intent",
      executable_intents: executableIntents,
      review_required_intents: reviewRequiredIntents,
      non_executable_intents: nonExecutableIntents,
    },
    warnings,
    telemetry: {
      request_id: invocation.request_id,
      pipeline_request_id: ctx.requestId,
      logging_degraded: ctx.logWarnings.length > 0,
      logging_errors: ctx.logWarnings,
    },
  };
}

async function getUserContextDefaults(
  ctx: RequestContext,
  userId: string,
): Promise<UserContextDefaults> {
  const { data, error } = await ctx.supabase
    .from("notification_preferences")
    .select("timezone, locale")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    ctx.logWarnings.push(
      `notification_preferences_lookup_failed:${error.message}`,
    );
    return { timezone: null, locale: null };
  }

  return {
    timezone: data?.timezone ?? null,
    locale: data?.locale ?? null,
  };
}

async function executeLoggedRole<T>(
  ctx: RequestContext,
  invocation: InvocationPayload,
  route: ResolvedRoute,
  normalizedInput: NormalizedInput,
  executor: (
    route: ResolvedRoute,
    normalizedInput: NormalizedInput,
  ) => Promise<ProviderExecution<T>>,
): Promise<ProviderExecution<T>> {
  const startedAt = Date.now();

  try {
    const result = await executor(route, normalizedInput);

    await logAiStep(ctx, {
      invocation,
      route,
      status: "completed",
      latencyMs: Date.now() - startedAt,
      errorCode: null,
      providerRequestId: result.providerRequestId,
      usage: result.usage,
    });

    return result;
  } catch (e) {
    const err = normalizeError(e);

    await logAiStep(ctx, {
      invocation,
      route,
      status: err.code === "provider_timeout" ? "timeout" : "failed",
      latencyMs: Date.now() - startedAt,
      errorCode: err.code,
      providerRequestId: null,
      usage: undefined,
    });

    throw e;
  }
}

async function resolveFeatureSteps(
  ctx: RequestContext,
  featureKey: FeatureKey,
): Promise<FeatureStep[]> {
  const { data, error } = await ctx.supabase.rpc("ai_feature_steps_get", {
    p_feature_key: featureKey,
  });

  if (error) {
    throw makeError(500, "pipeline_steps_failed", error.message, false);
  }

  if (!Array.isArray(data)) {
    return [];
  }

  return data.map((row) => ({
    feature_key: String(row.feature_key) as FeatureKey,
    step_key: String(row.step_key),
    step_order: Number(row.step_order),
    role_key: String(row.role_key),
    stage: String(row.stage) as FeatureStep["stage"],
  })).sort((a, b) => a.step_order - b.step_order);
}

async function resolveRoutesForSteps(
  ctx: RequestContext,
  steps: FeatureStep[],
): Promise<Map<string, ResolvedRoute>> {
  const routes = new Map<string, ResolvedRoute>();

  for (const step of steps) {
    if (!routes.has(step.role_key)) {
      routes.set(step.role_key, await resolveRoleRoute(ctx, step.role_key));
    }
  }

  return routes;
}

async function resolveRoleRoute(
  ctx: RequestContext,
  roleKey: string,
): Promise<ResolvedRoute> {
  const { data, error } = await ctx.supabase.rpc("ai_role_route_get", {
    p_role_key: roleKey,
  });

  if (error) {
    throw makeError(500, "pipeline_route_failed", error.message, false);
  }

  if (!data || typeof data !== "object") {
    throw makeError(
      500,
      "pipeline_route_missing",
      `missing route for role ${roleKey}`,
      false,
    );
  }

  const row = data as Record<string, unknown>;

  return {
    role_key: requiredString(row, "role_key"),
    stage: requiredString(row, "stage") as ResolvedRoute["stage"],
    provider: requiredString(row, "provider"),
    adapter_kind: requiredString(row, "adapter_kind"),
    base_url: optionalString(row, "base_url"),
    secret_name: optionalString(row, "secret_name"),
    model: requiredString(row, "model"),
    prompt_version: requiredString(row, "prompt_version"),
    execution_mode: requiredString(row, "execution_mode"),
    deterministic_fallback_allowed:
      optionalBoolean(row, "deterministic_fallback_allowed") ?? false,
    max_retries: optionalNumber(row, "max_retries") ?? 0,
  };
}

async function callClassificationProvider(
  route: ResolvedRoute,
  text: string,
): Promise<ProviderExecution<IntentClassificationResult>> {
  if (route.provider === "stub" || route.adapter_kind === "stub") {
    throw makeError(
      500,
      "unsupported_provider_call",
      "stub route should not call provider",
      false,
    );
  }

  if (
    route.adapter_kind !== "openai_responses" &&
    route.adapter_kind !== "openai_compat_responses"
  ) {
    throw makeError(
      422,
      "unsupported_adapter",
      "adapter_kind is not implemented",
      false,
    );
  }

  const payload = await callOpenAIResponses(route, {
    schemaName: "intent_classifier",
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        primary_intent: { type: "string", enum: INTENTS },
        confidence: { type: "string", enum: ["high", "medium", "low"] },
        intents_detected: {
          type: "array",
          items: { type: "string", enum: INTENTS },
          minItems: 1,
          maxItems: 4,
        },
      },
      required: ["primary_intent", "confidence", "intents_detected"],
    },
    systemPrompt:
      "Classify the user's Kinly household command. Return JSON only with primary_intent, confidence, intents_detected. Detect multiple intents when present. Do not use unknown unless no allowed intent reasonably applies. Allowed intents: add_grocery_items, create_task, mark_task_done, create_reminder, create_expense, open_house_norms, view_due_items, view_service, unknown.",
    userText: text,
  });

  return {
    providerRequestId: payload.providerRequestId,
    usage: payload.usage,
    result: normalizeIntentClassifier(payload.result, route),
  };
}

async function callParserProvider(
  route: ResolvedRoute,
  input: NormalizedInput,
  parserKind: "grocery_parser" | "task_parser",
  rescueContext?: {
    intent: IntentClassificationResult["primary_intent"];
    detectedIntents: IntentClassificationResult["intents_detected"];
    extractedSpan: string | null;
    fullText: string;
  },
): Promise<ProviderExecution<GroceryParseResult | TaskParseResult>> {
  if (!PARSER_ROLE_KEYS.includes(parserKind)) {
    throw makeError(
      500,
      "unsupported_role",
      `unsupported parser role ${parserKind}`,
      false,
    );
  }

  if (route.provider === "stub" || route.adapter_kind === "stub") {
    throw makeError(
      500,
      "unsupported_provider_call",
      "stub route should not call provider",
      false,
    );
  }

  if (
    route.adapter_kind !== "openai_responses" &&
    route.adapter_kind !== "openai_compat_responses"
  ) {
    throw makeError(
      422,
      "unsupported_adapter",
      "adapter_kind is not implemented",
      false,
    );
  }

  const parserConfig = parserKind === "grocery_parser"
    ? {
      schemaName: "grocery_parser",
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          items: {
            type: "array",
            minItems: 0,
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                raw_text: { type: "string" },
                canonical_name: { type: "string" },
                quantity_text: { type: ["string", "null"] },
                notes: { type: ["string", "null"] },
              },
              required: [
                "raw_text",
                "canonical_name",
                "quantity_text",
                "notes",
              ],
            },
          },
        },
        required: ["items"],
      },
      systemPrompt: rescueContext
        ? `Extract grocery items for the target intent ${rescueContext.intent} from the household command.
Return JSON only.
Detected intents: ${rescueContext.detectedIntents.join(", ")}.
Original command: ${rescueContext.fullText}
Focused clause: ${rescueContext.extractedSpan ?? "none"}.
Only return grocery entities. Do not emit task, reminder, expense, or navigation text.`
        : "Extract grocery items from the user's household command. Return JSON only. Keep canonical_name concise. Use notes only for true modifiers or context.",
    }
    : {
      schemaName: "task_parser",
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          task_title: { type: ["string", "null"] },
          notes: { type: ["string", "null"] },
          recurrence_every: { type: ["number", "null"] },
          recurrence_unit: {
            type: ["string", "null"],
            enum: ["day", "week", "month", "year", null],
          },
          assignee_hint: { type: ["string", "null"] },
          start_date: { type: ["string", "null"] },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
        },
        required: [
          "task_title",
          "notes",
          "recurrence_every",
          "recurrence_unit",
          "assignee_hint",
          "start_date",
          "confidence",
        ],
      },
      systemPrompt: `${
        rescueContext
          ? `Extract only the ${rescueContext.intent} portion of the household command.`
          : "Extract a household task/reminder from the user's command."
      } Return JSON only.
Use timezone=${input.timezone}, locale=${input.language_code}, resolved_now_utc=${input.resolved_now_utc}.
Resolve relative dates like today/tomorrow into YYYY-MM-DD when possible.
${
        rescueContext
          ? `Detected intents: ${rescueContext.detectedIntents.join(", ")}.
Original command: ${rescueContext.fullText}
Focused clause: ${rescueContext.extractedSpan ?? "none"}.
Do not emit grocery items, expense fields, or unrelated command text.`
          : ""
      }`,
    };

  const payload = await callOpenAIResponses(route, {
    schemaName: parserConfig.schemaName,
    schema: parserConfig.schema,
    systemPrompt: parserConfig.systemPrompt,
    userText: input.text,
  });

  return {
    providerRequestId: payload.providerRequestId,
    usage: payload.usage,
    result: parserKind === "grocery_parser"
      ? normalizeGroceryParseResult(payload.result)
      : normalizeTaskParseResult(payload.result),
  };
}

async function callOpenAIResponses(
  route: ResolvedRoute,
  args: {
    schemaName: string;
    schema: Record<string, unknown>;
    systemPrompt: string;
    userText: string;
  },
): Promise<ProviderResponsePayload> {
  const apiKey = resolveProviderSecret(route);
  const url = `${route.base_url ?? "https://api.openai.com"}/v1/responses`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), OPENAI_TIMEOUT_MS);

  try {
    const res = await fetch(url, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: route.model,
        max_output_tokens: MAX_OUTPUT_TOKENS,
        input: [
          {
            role: "system",
            content: [{ type: "input_text", text: args.systemPrompt }],
          },
          {
            role: "user",
            content: [{ type: "input_text", text: args.userText }],
          },
        ],
        text: {
          format: {
            type: "json_schema",
            name: args.schemaName,
            strict: true,
            schema: args.schema,
          },
        },
      }),
    });

    const payload = await res.json().catch(() => ({}));

    if (!res.ok) {
      throw makeError(
        res.status >= 500 ? 502 : 400,
        "provider_error",
        `${args.schemaName} provider call failed`,
        res.status >= 500,
        { provider_status: res.status, body: payload },
      );
    }

    const outputText = extractOutputText(payload);
    if (!outputText) {
      throw makeError(
        502,
        "invalid_provider_response",
        "provider returned no output text",
        true,
        payload,
      );
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(outputText);
    } catch {
      throw makeError(
        502,
        "invalid_provider_response",
        "provider returned invalid JSON",
        true,
        {
          raw_output_text: outputText,
        },
      );
    }

    return {
      providerRequestId: typeof payload.id === "string" ? payload.id : null,
      result: parsed,
      usage: extractProviderUsage(payload),
    };
  } catch (e) {
    if ((e as Error).name === "AbortError") {
      throw makeError(504, "provider_timeout", "provider timed out", true);
    }
    throw e;
  } finally {
    clearTimeout(timeout);
  }
}

async function logAiStep(
  ctx: RequestContext,
  args: {
    invocation: InvocationPayload;
    route: ResolvedRoute;
    status: "completed" | "failed" | "timeout";
    latencyMs: number | null;
    errorCode: string | null;
    providerRequestId: string | null;
    usage?: ProviderExecutionUsage;
  },
) {
  const actorUserId = optionalInvocationActorUserId(args.invocation);
  const { error } = await ctx.supabase.rpc("_ai_log_step", {
    p_request_id: args.invocation.request_id,
    p_home_id: args.invocation.home_id,
    p_feature_key: args.invocation.feature_key,
    p_stage: args.route.stage,
    p_role_key: args.route.role_key,
    p_provider: args.route.provider,
    p_model: args.route.model,
    p_prompt_version: args.route.prompt_version,
    p_status: args.status,
    p_user_id: actorUserId,
    p_latency_ms: args.latencyMs,
    p_error_code: args.errorCode,
    p_provider_request_id: args.providerRequestId,
    p_input_tokens: args.usage?.inputTokens ?? null,
    p_output_tokens: args.usage?.outputTokens ?? null,
    p_total_tokens: args.usage?.totalTokens ?? null,
  });

  if (error) {
    const message =
      `ai_step_log_failed:${args.route.role_key}:${error.message}`;
    ctx.logWarnings.push(message);

    console.error(JSON.stringify({
      level: "warn",
      msg: "ai_step_log_failed",
      request_id: args.invocation.request_id,
      pipeline_request_id: ctx.requestId,
      feature_key: args.invocation.feature_key,
      role_key: args.route.role_key,
      error: error.message,
    }));
  }
}

function requiredString(obj: Record<string, unknown>, key: string): string {
  const value = obj[key];
  if (typeof value !== "string" || !value.trim()) {
    throw makeError(400, "missing_field", `${key} missing`, false);
  }
  return value.trim();
}

function optionalString(
  obj: Record<string, unknown>,
  key: string,
): string | null {
  const value = obj[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function optionalBoolean(
  obj: Record<string, unknown>,
  key: string,
): boolean | undefined {
  return typeof obj[key] === "boolean" ? obj[key] : undefined;
}

function optionalNumber(
  obj: Record<string, unknown>,
  key: string,
): number | undefined {
  return typeof obj[key] === "number" ? obj[key] : undefined;
}

function requireInternalSecret(req: Request) {
  const expected = env("WORKER_SHARED_SECRET");
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

function optionalInvocationActorUserId(
  invocation: InvocationPayload,
): string | null {
  const payload = invocation.payload;
  const actorUserId =
    typeof payload.actor_user_id === "string" && payload.actor_user_id.trim()
      ? payload.actor_user_id.trim()
      : null;
  if (actorUserId) return actorUserId;

  return typeof payload.user_id === "string" && payload.user_id.trim()
    ? payload.user_id.trim()
    : null;
}

function resolveProviderSecret(route: ResolvedRoute): string {
  if (route.secret_name) {
    const explicit = Deno.env.get(route.secret_name);
    if (explicit) return explicit;

    throw makeError(
      500,
      "missing_provider_secret",
      `Missing env ${route.secret_name} for provider ${route.provider}`,
      false,
    );
  }

  if (route.provider === "openai") {
    return env("OPENAI_API_KEY");
  }

  throw makeError(
    500,
    "missing_provider_secret",
    `Provider ${route.provider} requires an explicit secret_name`,
    false,
  );
}

function extractProviderUsage(
  payload: Record<string, unknown>,
): ProviderExecutionUsage {
  const usage = payload.usage && typeof payload.usage === "object" &&
      !Array.isArray(payload.usage)
    ? payload.usage as Record<string, unknown>
    : {};

  const inputTokens = optionalUsageNumber(
    usage.input_tokens ?? usage.prompt_tokens ?? usage.inputTokens,
  );
  const outputTokens = optionalUsageNumber(
    usage.output_tokens ?? usage.completion_tokens ?? usage.outputTokens,
  );
  const totalTokens = optionalUsageNumber(
    usage.total_tokens ?? usage.totalTokens,
  ) ?? ((inputTokens !== null || outputTokens !== null)
    ? (inputTokens ?? 0) + (outputTokens ?? 0)
    : null);

  return {
    inputTokens,
    outputTokens,
    totalTokens,
  };
}

function optionalUsageNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return Math.trunc(value);
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed >= 0) {
      return Math.trunc(parsed);
    }
  }

  return null;
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw makeError(500, "missing_env", `Missing env ${name}`, false);
  }
  return value;
}

function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function normalizeError(e: unknown) {
  if (
    e && typeof e === "object" && "status" in e && "code" in e && "message" in e
  ) {
    return e as {
      status: number;
      code: string;
      message: string;
      retryable: boolean;
      details?: unknown;
    };
  }

  return {
    status: 500,
    code: "internal_error",
    message: e instanceof Error ? e.message : "internal error",
    retryable: false,
  };
}

function makeError(
  status: number,
  code: string,
  message: string,
  retryable: boolean,
  details?: unknown,
) {
  return { status, code, message, retryable, details };
}

export {
  extractOutputText,
  extractProviderUsage,
  normalizeIntentClassifier,
  resolveProviderSecret,
  safeJson,
  validateInvocation,
};
