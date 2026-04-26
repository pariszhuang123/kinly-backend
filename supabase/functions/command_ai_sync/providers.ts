import type {
  GroceryParseResult,
  Intent,
  IntentClassificationResult,
  NormalizedInput,
  ResolvedRoute,
  TaskParseResult,
} from "./types.ts";

export type ProviderExecutionUsage = {
  inputTokens: number | null;
  outputTokens: number | null;
  totalTokens: number | null;
};

export type ProviderExecution<T> = {
  result: T;
  providerRequestId: string | null;
  usage?: ProviderExecutionUsage;
};

export type ClassificationExecutor = (
  route: ResolvedRoute,
  text: string,
) => Promise<ProviderExecution<IntentClassificationResult>>;

export type ParserExecutor = (
  route: ResolvedRoute,
  input: NormalizedInput,
  parserKind: "grocery_parser" | "task_parser",
  rescueContext?: {
    intent: Intent;
    detectedIntents: Intent[];
    extractedSpan: string | null;
    fullText: string;
  },
) => Promise<ProviderExecution<GroceryParseResult | TaskParseResult>>;
