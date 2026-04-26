import {
  assessParsedIntent,
  executeHybridExtraction,
  extractIntentSpecificInput,
} from "./assessment.ts";
import { classifyRouterDeterministically } from "./classifier.ts";
import {
  extractProviderUsage,
  resolveProviderSecret,
  safeJson,
  validateInvocation,
} from "./index.ts";
import { buildNormalizedInput } from "./normalization.ts";
import { parseGrocery } from "./parsers/grocery.ts";
import { parseTask } from "./parsers/task.ts";
import { extractOutputText } from "./shared.ts";
import type {
  IntentClassificationResult,
  NormalizedInput,
  ResolvedRoute,
} from "./types.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

const baseNormalizedInput: NormalizedInput = {
  modality: "text",
  text: "buy bread",
  language_code: "en-NZ",
  timezone: "Pacific/Auckland",
  client_timestamp: "2026-04-14T00:00:00.000Z",
  resolved_now_utc: "2026-04-14T00:00:00.000Z",
  metadata: {},
};

Deno.test("safeJson rejects oversized and invalid payloads", async () => {
  const tooBig = new Request("http://localhost", {
    method: "POST",
    body: "a".repeat(65_000),
  });
  await safeJson(tooBig, 64_000).then(
    () => {
      throw new Error("expected payload_too_large");
    },
    (e) =>
      expect(
        e.code === "payload_too_large",
        "should reject oversized payloads",
      ),
  );

  const badJson = new Request("http://localhost", {
    method: "POST",
    body: "{ bad json",
  });
  await safeJson(badJson, 10_000).then(
    () => {
      throw new Error("expected invalid_json_payload");
    },
    (e) =>
      expect(e.code === "invalid_json_payload", "should reject invalid json"),
  );
});

Deno.test("validateInvocation accepts feature-level payload and rejects route injection", () => {
  const invocation = validateInvocation({
    request_id: "00000000-0000-4000-8000-000000000001",
    home_id: "00000000-0000-4000-8000-000000000002",
    feature_key: "command",
    payload: {
      effective_input: "add milk and eggs",
    },
  }, "request-1");

  expect(invocation.feature_key === "command", "feature key preserved");

  try {
    validateInvocation({
      request_id: "00000000-0000-4000-8000-000000000001",
      home_id: "00000000-0000-4000-8000-000000000002",
      feature_key: "command",
      route: { provider: "openai" },
      payload: {
        effective_input: "add milk and eggs",
      },
    }, "request-2");
    throw new Error("expected invalid_payload");
  } catch (e) {
    expect(
      (e as { code?: string }).code === "invalid_payload",
      "route injection rejected",
    );
  }
});

Deno.test("buildNormalizedInput builds canonical text input", async () => {
  const normalized = await buildNormalizedInput({
    invocation: {
      request_id: "00000000-0000-4000-8000-000000000001",
      home_id: "00000000-0000-4000-8000-000000000002",
      feature_key: "command",
      payload: {
        effective_input: "buy bread",
        locale: "en-NZ",
        input_mode: "voice",
      },
    },
    getUserContextDefaults: () =>
      Promise.resolve({
        timezone: null,
        locale: null,
      }),
  });

  expect(normalized.modality === "text", "normalized modality is text");
  expect(normalized.text === "buy bread", "normalized text preserved");
  expect(normalized.language_code === "en-NZ", "locale preserved");
});

Deno.test("buildNormalizedInput accepts SQL-supplied user_id for defaults lookup", async () => {
  let lookedUpUserId: string | null = null;

  const normalized = await buildNormalizedInput({
    invocation: {
      request_id: "00000000-0000-4000-8000-000000000001",
      home_id: "00000000-0000-4000-8000-000000000002",
      feature_key: "command",
      payload: {
        effective_input: "buy bread",
        user_id: "00000000-0000-4000-8000-000000000003",
      },
    },
    getUserContextDefaults: (userId) => {
      lookedUpUserId = userId;
      return Promise.resolve({
        timezone: "Pacific/Auckland",
        locale: "en-NZ",
      });
    },
  });

  expect(
    lookedUpUserId === "00000000-0000-4000-8000-000000000003",
    "user_id is used for defaults lookup",
  );
  expect(
    normalized.timezone === "Pacific/Auckland",
    "timezone default loaded from user defaults",
  );
  expect(
    normalized.language_code === "en-NZ",
    "locale default loaded from user defaults",
  );
});

Deno.test("classifyRouterDeterministically handles single and multi-intent input", () => {
  const grocery = classifyRouterDeterministically("add milk and eggs");
  expect(
    grocery.primary_intent === "add_grocery_items",
    "grocery intent detected",
  );
  expect(grocery.confidence === "high", "single intent has high confidence");

  const batch = classifyRouterDeterministically(
    "add milk and I paid $20 for groceries",
  );
  expect(
    batch.intents_detected.includes("add_grocery_items"),
    "batch contains grocery intent",
  );
  expect(
    batch.intents_detected.includes("create_expense"),
    "batch contains expense intent",
  );
  expect(batch.confidence === "medium", "multi-intent is medium confidence");

  const taskOnly = classifyRouterDeterministically("add task wash dishes");
  expect(
    !taskOnly.intents_detected.includes("add_grocery_items"),
    "generic add does not force grocery",
  );

  const mixed = classifyRouterDeterministically(
    "add milk and remind me to wash clothings",
  );
  expect(
    mixed.intents_detected.includes("add_grocery_items"),
    "mixed command keeps grocery intent",
  );
  expect(
    mixed.intents_detected.includes("create_reminder"),
    "mixed command keeps reminder intent",
  );
});

Deno.test("parseGrocery and parseTask return bounded parser results", () => {
  const grocery = parseGrocery("buy milk, eggs, bread");
  expect(grocery.items.length === 3, "grocery parser returns item list");

  const task = parseTask("remind me to wash the clothes", baseNormalizedInput);
  expect(
    task.task_title === "wash the clothes",
    "task parser returns task title",
  );
});

Deno.test("extractIntentSpecificInput isolates mixed grocery and reminder clauses", () => {
  const detected: IntentClassificationResult["intents_detected"] = [
    "add_grocery_items",
    "create_reminder",
  ];

  const grocery = extractIntentSpecificInput(
    "add_grocery_items",
    "add milk and remind me to wash clothings",
    detected,
  );
  expect(grocery.raw_input === "milk", "grocery extraction isolates milk");
  expect(grocery.ambiguous === false, "grocery extraction is not ambiguous");

  const reminder = extractIntentSpecificInput(
    "create_reminder",
    "add milk and remind me to wash clothings",
    detected,
  );
  expect(
    reminder.raw_input === "wash clothings",
    "reminder extraction isolates task title",
  );
  expect(reminder.ambiguous === false, "reminder extraction is not ambiguous");
});

Deno.test("assessParsedIntent marks valid grocery parse ready", () => {
  const grocery = parseGrocery("buy milk, eggs and bread");
  const assessment = assessParsedIntent(
    "add_grocery_items",
    grocery,
    baseNormalizedInput,
  );

  expect(assessment.parse_status === "parsed", "grocery parse marked parsed");
  expect(
    assessment.execution_readiness === "ready",
    "grocery parse marked ready",
  );
});

Deno.test("assessParsedIntent rejects contaminated and semantically invalid parsed output", () => {
  const contaminatedGrocery = assessParsedIntent("add_grocery_items", {
    items: [
      {
        raw_text: "milk and remind me to wash clothings",
        canonical_name: "milk and remind me to wash clothings",
        quantity_text: null,
        notes: null,
      },
    ],
  }, baseNormalizedInput);
  expect(
    contaminatedGrocery.execution_readiness === "needs_review",
    "contaminated grocery output requires review",
  );

  const invalidTask = assessParsedIntent("create_reminder", {
    task_title: "wash clothings",
    notes: null,
    recurrence_every: 0,
    recurrence_unit: "week",
    assignee_hint: null,
    start_date: null,
    confidence: "high",
  }, baseNormalizedInput);
  expect(
    invalidTask.execution_readiness === "needs_review",
    "invalid recurrence blocks ready",
  );
});

Deno.test("parseTask resolves today and tomorrow using request timezone calendar date", () => {
  const nearMidnightNz: NormalizedInput = {
    ...baseNormalizedInput,
    timezone: "Pacific/Auckland",
    resolved_now_utc: "2026-04-14T12:30:00.000Z",
  };

  const today = parseTask("remind me to wash clothings today", nearMidnightNz);
  const tomorrow = parseTask(
    "remind me to wash clothings tomorrow",
    nearMidnightNz,
  );

  expect(
    today.start_date === "2026-04-15",
    "today uses local NZ calendar date",
  );
  expect(
    tomorrow.start_date === "2026-04-16",
    "tomorrow increments local NZ calendar date",
  );
});

Deno.test("executeHybridExtraction uses provider rescue for ambiguous mixed intent input", async () => {
  const route: ResolvedRoute = {
    role_key: "grocery_parser",
    stage: "understanding",
    provider: "openai",
    adapter_kind: "openai_responses",
    base_url: null,
    secret_name: null,
    model: "gpt-5-nano",
    prompt_version: "v1",
    execution_mode: "sync",
    deterministic_fallback_allowed: true,
    max_retries: 0,
  };

  let rescueCalled = false;
  const result = await executeHybridExtraction({
    route,
    normalizedInput: {
      ...baseNormalizedInput,
      text: "add milk and remind me to wash clothings",
    },
    classification: {
      primary_intent: "add_grocery_items",
      confidence: "medium",
      intents_detected: ["add_grocery_items", "create_reminder"],
    },
    intent: "add_grocery_items",
    rawInput: "add milk and remind me to wash clothings",
    extractedSpan: null,
    extractionAmbiguous: true,
    executeParserProvider: () => {
      rescueCalled = true;
      return Promise.resolve({
        providerRequestId: "resp_123",
        result: {
          items: [
            {
              raw_text: "milk",
              canonical_name: "milk",
              quantity_text: null,
              notes: null,
            },
          ],
        },
      });
    },
  });

  expect(rescueCalled, "provider rescue is attempted");
  expect(
    result.execution_readiness === "ready",
    "rescued parse can become ready",
  );
  expect(
    result.warnings.some((warning) => warning.includes("Provider rescue used")),
    "rescue warning added",
  );
});

Deno.test("extractOutputText reads output text from responses payload", () => {
  const direct = extractOutputText({ output_text: " hello " });
  expect(direct === "hello", "direct output text extracted");

  const nested = extractOutputText({
    output: [
      { content: [{ type: "output_text", text: " nested " }] },
    ],
  });
  expect(nested === "nested", "nested output text extracted");
});

Deno.test("resolveProviderSecret uses OpenAI default only for openai routes", () => {
  Deno.env.set("OPENAI_API_KEY", "openai-default-key");

  const openaiRoute: ResolvedRoute = {
    role_key: "intent_classifier",
    stage: "understanding",
    provider: "openai",
    adapter_kind: "openai_responses",
    base_url: null,
    secret_name: null,
    model: "gpt-5-nano",
    prompt_version: "v1",
    execution_mode: "sync",
    deterministic_fallback_allowed: false,
    max_retries: 0,
  };

  expect(
    resolveProviderSecret(openaiRoute) === "openai-default-key",
    "openai route uses default key",
  );

  const qwenRoute = {
    ...openaiRoute,
    provider: "qwen",
    adapter_kind: "openai_compat_responses",
  };
  try {
    resolveProviderSecret(qwenRoute);
    throw new Error("expected missing_provider_secret");
  } catch (e) {
    expect(
      (e as { code?: string }).code === "missing_provider_secret",
      "non-openai route requires explicit secret",
    );
  }

  Deno.env.set("QWEN_API_KEY", "qwen-key");
  expect(
    resolveProviderSecret({ ...qwenRoute, secret_name: "QWEN_API_KEY" }) ===
      "qwen-key",
    "explicit provider secret resolves",
  );

  Deno.env.delete("QWEN_API_KEY");
  try {
    resolveProviderSecret({ ...qwenRoute, secret_name: "QWEN_API_KEY" });
    throw new Error("expected missing_provider_secret");
  } catch (e) {
    expect(
      (e as { code?: string }).code === "missing_provider_secret",
      "missing explicit provider env fails",
    );
  }
});

Deno.test("extractProviderUsage normalizes response usage payloads", () => {
  const full = extractProviderUsage({
    usage: {
      input_tokens: 11,
      output_tokens: 7,
      total_tokens: 18,
    },
  });
  expect(full.inputTokens === 11, "input tokens normalized");
  expect(full.outputTokens === 7, "output tokens normalized");
  expect(full.totalTokens === 18, "total tokens normalized");

  const inferred = extractProviderUsage({
    usage: {
      prompt_tokens: 5,
      completion_tokens: 3,
    },
  });
  expect(inferred.inputTokens === 5, "prompt tokens map to input");
  expect(inferred.outputTokens === 3, "completion tokens map to output");
  expect(inferred.totalTokens === 8, "total tokens inferred when absent");

  const empty = extractProviderUsage({});
  expect(empty.inputTokens === null, "missing usage keeps null input tokens");
  expect(empty.outputTokens === null, "missing usage keeps null output tokens");
  expect(empty.totalTokens === null, "missing usage keeps null total tokens");
});
