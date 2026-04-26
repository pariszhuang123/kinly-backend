import type { ClassificationExecutor, ProviderExecution } from "./providers.ts";
import type {
  Confidence,
  Intent,
  IntentClassificationResult,
  NormalizedInput,
  ResolvedRoute,
} from "./types.ts";
import { isConfidence, isIntent, MAX_DETECTED_INTENTS } from "./types.ts";

export async function executeIntentClassifier(args: {
  route: ResolvedRoute;
  input: NormalizedInput;
  callProvider: ClassificationExecutor;
}): Promise<ProviderExecution<IntentClassificationResult>> {
  const { route, input, callProvider } = args;
  const fallback = classifyRouterDeterministically(input.text, route);

  if (route.provider === "stub" || route.adapter_kind === "stub") {
    return {
      result: fallback,
      providerRequestId: null,
      usage: undefined,
    };
  }

  try {
    const providerResult = await callProvider(route, input.text);
    const usable = providerResult.result.intents_detected.filter((intent) =>
      intent !== "unknown"
    );

    if (usable.length > 0) return providerResult;

    if (route.deterministic_fallback_allowed) {
      return {
        result: mergeClassifierResults(providerResult.result, fallback),
        providerRequestId: providerResult.providerRequestId,
        usage: providerResult.usage,
      };
    }

    return providerResult;
  } catch (e) {
    if (route.deterministic_fallback_allowed) {
      return {
        result: fallback,
        providerRequestId: null,
        usage: undefined,
      };
    }
    throw e;
  }
}

export function mergeClassifierResults(
  primary: IntentClassificationResult,
  fallback: IntentClassificationResult,
): IntentClassificationResult {
  const merged = [
    ...new Set([...primary.intents_detected, ...fallback.intents_detected]),
  ]
    .filter(isIntent)
    .slice(0, MAX_DETECTED_INTENTS);

  const usablePrimary = primary.intents_detected.filter((intent) =>
    intent !== "unknown"
  );
  const usableFallback = fallback.intents_detected.filter((intent) =>
    intent !== "unknown"
  );

  const primaryIntent = usablePrimary[0] ?? usableFallback[0] ?? "unknown";
  const confidence: Confidence = usablePrimary.length > 0
    ? primary.confidence
    : usableFallback.length > 0
    ? fallback.confidence
    : "low";

  return {
    primary_intent: primaryIntent,
    confidence,
    intents_detected: merged.length > 0 ? merged : ["unknown"],
    provider: primary.provider ?? fallback.provider,
    model: primary.model ?? fallback.model,
  };
}

export function classifyRouterDeterministically(
  input: string,
  route?: ResolvedRoute,
): IntentClassificationResult {
  const text = input.toLowerCase();
  const scores = new Map<Intent, number>();

  addIntentScore(scores, "open_house_norms", text, [
    /\b(house norms|house rules|norms|rules of the house)\b/,
  ], 3);

  addIntentScore(scores, "view_due_items", text, [
    /\b(what'?s due|what is due|due today|due this week)\b/,
  ], 3);

  addIntentScore(scores, "view_service", text, [
    /\b(service|services|plumber|cleaner|electrician|internet provider|wifi)\b/,
  ], 2);

  addIntentScore(scores, "create_expense", text, [
    /\b(expense|spent|paid|split|owe|bill)\b/,
    /\$/,
  ], 2);

  addIntentScore(scores, "mark_task_done", text, [
    /\b(done|finished|completed|complete)\b/,
  ], 2);

  addIntentScore(scores, "create_reminder", text, [
    /\b(remind|reminder|remember to)\b/,
  ], 2);

  addIntentScore(scores, "create_task", text, [
    /\b(task|todo|to-do|chore|clean|take out|vacuum|wash)\b/,
  ], 2);

  addIntentScore(scores, "add_grocery_items", text, [
    /\b(milk|eggs|bread|shopping|grocery|groceries|buy|pick up)\b/,
    /\badd\s+(milk|eggs|bread|groceries?|shopping list|apples?|bananas?|rice|cheese|butter)\b/,
  ], 2);

  const ranked = [...scores.entries()]
    .filter(([, score]) => score > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([intent]) => intent)
    .slice(0, MAX_DETECTED_INTENTS);

  if (ranked.length === 0) {
    return {
      primary_intent: "unknown",
      confidence: "low",
      intents_detected: ["unknown"],
      provider: route?.provider,
      model: route?.model,
    };
  }

  return {
    primary_intent: ranked[0],
    confidence: ranked.length > 1 ? "medium" : "high",
    intents_detected: ranked,
    provider: route?.provider,
    model: route?.model,
  };
}

export function normalizeIntentClassifier(
  input: unknown,
  route: ResolvedRoute,
): IntentClassificationResult {
  const obj = input && typeof input === "object"
    ? input as Record<string, unknown>
    : {};

  const primaryIntent = isIntent(obj.primary_intent)
    ? obj.primary_intent
    : "unknown";
  const confidence = isConfidence(obj.confidence)
    ? obj.confidence
    : primaryIntent === "unknown"
    ? "low"
    : "medium";

  const detected = Array.isArray(obj.intents_detected)
    ? obj.intents_detected.filter(isIntent)
    : [];

  const intents = [...new Set([primaryIntent, ...detected])].slice(
    0,
    MAX_DETECTED_INTENTS,
  );

  return {
    primary_intent: primaryIntent,
    confidence,
    intents_detected: intents.length > 0 ? intents : ["unknown"],
    provider: route.provider,
    model: route.model,
  };
}

function addIntentScore(
  scores: Map<Intent, number>,
  intent: Intent,
  text: string,
  patterns: RegExp[],
  weight: number,
) {
  for (const pattern of patterns) {
    if (pattern.test(text)) {
      scores.set(intent, (scores.get(intent) ?? 0) + weight);
    }
  }
}
