export type FeatureKey = "command";
export type Stage = "normalization" | "understanding" | "execution";

export type Intent =
  | "add_grocery_items"
  | "create_task"
  | "mark_task_done"
  | "create_reminder"
  | "create_expense"
  | "open_house_norms"
  | "view_due_items"
  | "view_service"
  | "unknown";

export type Confidence = "high" | "medium" | "low";
export type ParseStatus = "not_needed" | "parsed" | "partial" | "failed";
export type ExecutionReadiness = "ready" | "needs_review" | "not_ready";

export type InvocationPayload = {
  request_id: string;
  home_id: string;
  feature_key: FeatureKey;
  payload: Record<string, unknown>;
};

export type UserContextDefaults = {
  timezone: string | null;
  locale: string | null;
};

export type ResolvedUserContext = {
  actor_user_id: string | null;
  timezone: string;
  locale: string;
  client_timestamp: string | null;
  resolved_now_utc: string;
  context_source: {
    timezone: "request" | "notification_preferences" | "fallback";
    locale: "request" | "notification_preferences" | "fallback";
  };
};

export type NormalizedInput = {
  modality: "text";
  text: string;
  language_code: string;
  timezone: string;
  client_timestamp: string | null;
  resolved_now_utc: string;
  metadata?: Record<string, unknown>;
};

export type FeatureStep = {
  feature_key: FeatureKey;
  step_key: string;
  step_order: number;
  role_key: string;
  stage: Stage;
};

export type ResolvedRoute = {
  role_key: string;
  stage: Stage;
  provider: string;
  adapter_kind: string;
  base_url: string | null;
  secret_name?: string | null;
  model: string;
  prompt_version: string;
  execution_mode: string;
  deterministic_fallback_allowed: boolean;
  max_retries: number;
};

export type IntentClassificationResult = {
  primary_intent: Intent;
  confidence: Confidence;
  intents_detected: Intent[];
  provider?: string;
  model?: string;
};

export type GroceryItem = {
  raw_text: string;
  canonical_name: string;
  quantity_text: string | null;
  notes: string | null;
};

export type GroceryParseResult = {
  items: GroceryItem[];
};

export type TaskParseResult = {
  task_title: string | null;
  notes: string | null;
  recurrence_every: number | null;
  recurrence_unit: "day" | "week" | "month" | "year" | null;
  assignee_hint: string | null;
  start_date: string | null;
  confidence: Confidence;
};

export type ParsedIntentWorkItem = {
  intent: Intent;
  parser_role_key: "grocery_parser" | "task_parser" | null;
  raw_input: string;
  extracted_span: string | null;
  parse_status: ParseStatus;
  parse_confidence: Confidence | null;
  parsed: GroceryParseResult | TaskParseResult | null;
  validation_errors: string[];
  warnings: string[];
  execution_readiness: ExecutionReadiness;
};

export type PipelineResult = {
  feature_key: FeatureKey;
  normalized_input: NormalizedInput;
  classification: IntentClassificationResult;
  intent_work_items: ParsedIntentWorkItem[];
  execution_plan: {
    strategy: "separate_per_intent";
    executable_intents: Intent[];
    review_required_intents: Intent[];
    non_executable_intents: Intent[];
  };
  warnings: string[];
  telemetry: {
    request_id: string;
    pipeline_request_id: string;
    logging_degraded: boolean;
    logging_errors: string[];
  };
};

export const FALLBACK_TIMEZONE = "UTC";
export const FALLBACK_LOCALE = "en";
export const MAX_DETECTED_INTENTS = 4;

export const INTENTS: Intent[] = [
  "add_grocery_items",
  "create_task",
  "mark_task_done",
  "create_reminder",
  "create_expense",
  "open_house_norms",
  "view_due_items",
  "view_service",
  "unknown",
];

export const EXECUTABLE_INTENT_TO_PARSER: Record<
  Intent,
  ParsedIntentWorkItem["parser_role_key"]
> = {
  add_grocery_items: "grocery_parser",
  create_task: "task_parser",
  mark_task_done: null,
  create_reminder: "task_parser",
  create_expense: null,
  open_house_norms: null,
  view_due_items: null,
  view_service: null,
  unknown: null,
};

export function isIntent(value: unknown): value is Intent {
  return typeof value === "string" && INTENTS.includes(value as Intent);
}

export function isConfidence(value: unknown): value is Confidence {
  return value === "high" || value === "medium" || value === "low";
}

export function isRecurrenceUnit(
  value: unknown,
): value is "day" | "week" | "month" | "year" {
  return value === "day" || value === "week" || value === "month" ||
    value === "year";
}
