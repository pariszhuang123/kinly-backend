---
Domain: Command
Capability: AI Invocation Pipeline
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Canonical-Id: command_ai_pipeline_v1
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/command/command_ai_quota_v1.md
Relates-To: contracts/api/kinly/command/command_entry_api_v1.md, contracts/api/kinly/command/command_grocery_module_v1.md, contracts/api/kinly/command/command_task_module_v1.md, contracts/api/kinly/complaint/complaint_rewrite_ai_routing_providers_v1.md
See-Also: contracts/api/kinly/homes/paywall_status_get_v1.md
---

# Kinly Command AI Pipeline Contract v1.0

## 1. Purpose

This contract defines the bounded internal backend refactor for Kinly command AI
invocation.

The goal is to replace request-supplied provider/model routing with a
server-resolved, multi-stage pipeline that:

- supports multiple providers and models
- allows different AI jobs to use different models
- keeps orchestration deterministic and auditable
- makes local model-swap validation possible

This contract establishes the core architecture only. It does not attempt to
solve every future AI routing concern in v1.

This is an internal backend orchestration contract. The public client-facing
compatibility boundary remains `command_entry_api_v1.md`.

## 2. Non-goals

This contract does NOT implement:

- image or PDF AI processing
- full fallback chain orchestration
- a full eval runner or CI judge system
- a full prompt registry product
- every future routing dimension

## 3. Core principle

The client asks for a product feature outcome. The backend decides which AI
job runs, which route is used, and what the next deterministic step is.

Frontend and caller payloads MUST NOT choose provider, model, adapter kind,
prompt version, or retry policy.

## 4. Standardized concepts

### 4.1 `feature_key`

`feature_key` identifies the product-facing integration point.

Examples:

- `command`
- `complaint_rewrite`
- `complaint_summarize`

`feature_key` is not the AI job itself.

### 4.2 `stage`

`stage` identifies the pipeline stage.

Allowed values:

- `normalization`
- `understanding`
- `execution`

For this v1 contract, the command pipeline implements:

- `normalization`
- `understanding`
- `execution`

`normalization` remains a reserved stage name so future modalities can be
expand without redefining the model.

### 4.3 `role_key`

`role_key` identifies the AI job being performed.

Examples:

- `intent_classifier`
- `grocery_parser`
- `task_parser`
- `complaint_summarizer`
- `tone_rewriter`

A feature MAY use one or more roles.

Not every feature requires its own parser role.

For v1, a feature MAY have:

- only a classifier role
- a classifier role followed by a feature-specific parser role
- a classifier role followed by deterministic non-AI module logic

Parser roles SHOULD exist only when a feature needs a stable, reusable
structured extraction boundary that benefits from independent routing, logging,
or evaluation.

### 4.4 `route`

A route is the server-resolved provider/model/prompt configuration used for a
single role execution.

A resolved route MUST include:

- `provider`
- `adapter_kind`
- `base_url`
- `model`
- `prompt_version`
- `execution_mode`
- `deterministic_fallback_allowed`
- `max_retries`

The request payload MUST NOT supply route details directly.

### 4.5 `normalized_input`

`normalized_input` is the canonical input passed into AI stages.

For v1, text and audio-originated text input are supported.

```ts
type NormalizedInput = {
  modality: "text";
  text: string;
  language_code?: string | null;
  metadata?: Record<string, unknown>;
};
```

For audio input in v1:

- raw audio MUST be transcribed before downstream AI understanding roles run
- the transcription result MUST be converted into `NormalizedInput`
- `NormalizedInput.modality` remains `text` after transcription
- audio bytes or waveform payloads MUST NOT be passed to understanding or
  execution roles in v1

This means audio support exists in v1, but only through a normalization step
that produces canonical text input.

### 4.6 Role schema discipline

Every `role_key` MUST map to an explicit, versioned contract for:

- input shape
- output shape
- validation rules
- semantic invariants
- eval expectations

Route resolution chooses provider, model, adapter, and prompt. It MUST NOT
change the role's input or output contract.

A model swap is valid only if the role still satisfies the same schema and
invariants.

Minimal registry shape:

```ts
type RoleContract = {
  role_key: string;
  stage: Stage;
  input_schema_key: string;
  output_schema_key: string;
  invariants: string[];
};
```

Example role contracts:

- `intent_classifier`
  - input schema: `normalized_text_input_v1`
  - output schema: `intent_classification_v1`
  - invariants:
    - exactly one primary intent
    - intent must be from the allowed enum
    - confidence must be from the allowed enum
    - supported intents should be classified consistently across supported
      locales without requiring translation into a canonical storage language

- `grocery_parser`
  - input schema: `normalized_text_input_v1`
  - output schema: `grocery_parse_result_v1`
  - invariants:
    - `items` must be an array
    - item strings must be non-empty after normalization
    - parser output must not emit task or expense fields

- `task_parser`
  - input schema: `normalized_text_input_v1`
  - output schema: `task_parse_result_v1`
  - invariants:
    - title must be non-empty when parse succeeds
    - parser output must not emit grocery item arrays

The generic runtime function boundary MAY remain broad:

```ts
async function executeRole(route: ResolvedRoute, input: unknown): Promise<unknown>
```

However, implementations MUST validate `input` and `output` against the role's
declared schemas before the role result is treated as valid pipeline output.

For `intent_classifier` specifically:

- it SHOULD be language-agnostic across supported locales
- it MUST classify intent from the user-provided language/script directly
  rather than requiring pre-translation into English or another canonical
  storage language
- unsupported locales MAY degrade to lower confidence or `unknown`
- this requirement applies only to intent classification; it does NOT imply
  cross-language equivalence for downstream exact-match systems such as
  purchase memory

## 5. Critique and design clarifications

This contract adopts the draft direction with the following clarifications.

### 5.1 Static steps versus conditional branching

`ai_feature_steps` can describe ordered entry steps, but it does not fully
describe conditional follow-up work such as:

- run `intent_classifier`
- if intent is `add_grocery_items`, run `grocery_parser`
- if intent is `create_task`, run `task_parser`

For v1:

- `ai_feature_steps` MUST define the static ordered entry path for a feature
- conditional branching after a step result MUST remain deterministic
  application logic
- the command pipeline MAY seed parser-capable roles in `ai_feature_steps` so
  route resolution stays server-authoritative, but runtime execution of those
  parser roles remains conditional application logic driven by the classifier
- parser rescue MAY reuse the parser role route when deterministic extraction
  is ambiguous, provided the parser output still satisfies the same role schema
  and invariants

This keeps the schema small without lying about runtime behavior.

### 5.2 One active route per role

One active route per `role_key` is acceptable for the first bounded refactor.
It keeps route resolution simple and satisfies the immediate goal of swapping
models per AI job.

However, this is intentionally narrow. If routing later needs to vary by
surface, locale, cost lane, or tenant policy, a future version SHOULD extend
route resolution inputs rather than overloading `role_key`.

### 5.3 Validation fixture shape

The draft requirement for `expected schema` is directionally correct but too
ambiguous to be reliably automated.

For v1 fixtures, each case SHOULD include:

- `role_key`
- `input`
- `expected`
- optional `schema_key` or equivalent schema reference

The fixture format MUST stay simple enough that a local runner can later
validate both structure and semantic assertions.

### 5.4 Stage meaning

`stage` identifies the pipeline phase, not whether a provider call is
guaranteed to happen.

A `role_key` is a pipeline job. Some roles may execute through a provider
route; others may be deterministic local logic while still participating in
the same pipeline, logging, and validation model.

Only routed roles invoke external AI providers.

For v1 command voice flows, transcription MAY be implemented as either:

- a normalization-stage role, or
- a pre-pipeline input preparation step that still produces the same
  `NormalizedInput`

Both are acceptable as long as the output entering `understanding` is the same
canonical text shape.

## 6. Runtime flow

For `feature_key = command`, the edge function MUST follow this sequence:

1. Validate request body.
2. Normalize input into canonical text form.
3. Resolve feature entry steps from backend configuration.
4. Execute steps in order.
5. Apply deterministic branching based on prior step output.
6. Return the final pipeline result.
7. Log each step independently.

## 7. Request contract

### 7.1 Invocation input

The request body MAY contain:

- `request_id`
- `home_id`
- `feature_key`
- `payload`

The request body MUST NOT contain provider, model, adapter, route, retry, or
prompt configuration.

For the command text flow:

- `feature_key` MUST be a supported feature
- `payload.effective_input` MUST be present
- `payload.effective_input` MUST be a non-empty string

For the command voice flow:

- the request MAY contain audio input fields defined by the transport layer
- the request MUST NOT require callers to provide provider, model, or route
  details for transcription
- the backend MUST produce canonical text before understanding roles run

### 7.2 Minimal TypeScript shapes

```ts
type FeatureKey = "command" | "complaint_rewrite" | "complaint_summarize";
type Stage = "normalization" | "understanding" | "execution";

type NormalizedInput = {
  modality: "text";
  text: string;
  language_code?: string | null;
  metadata?: Record<string, unknown>;
};

type RoleContract = {
  role_key: string;
  stage: Stage;
  input_schema_key: string;
  output_schema_key: string;
  invariants: string[];
};

type ResolvedRoute = {
  role_key: string;
  stage: Stage;
  provider: string;
  adapter_kind: string;
  base_url: string | null;
  model: string;
  prompt_version: string;
  execution_mode: string;
  deterministic_fallback_allowed: boolean;
  max_retries: number;
};

type FeatureStep = {
  feature_key: FeatureKey;
  step_key: string;
  step_order: number;
  role_key: string;
  stage: Stage;
};

type InvocationPayload = {
  request_id: string;
  home_id: string;
  feature_key: FeatureKey;
  payload: Record<string, unknown>;
};
```

### 7.3 Required runtime function boundaries

```ts
function validateInvocation(input: unknown): InvocationPayload
function buildNormalizedInput(invocation: InvocationPayload): NormalizedInput
async function resolveFeatureSteps(featureKey: FeatureKey): Promise<FeatureStep[]>
async function resolveRoleRoute(roleKey: string): Promise<ResolvedRoute>
async function executeRole(route: ResolvedRoute, input: unknown): Promise<unknown>
async function runFeaturePipeline(invocation: InvocationPayload): Promise<unknown>
async function logAiStep(...): Promise<void>
```

These function boundaries are normative for the refactor shape. Internal
implementation details MAY vary as long as semantics are preserved.

## 8. Minimal command pipeline behavior

For `feature_key = command`:

1. If the request is voice, transcribe audio into text and build
   `normalized_input`.
2. If the request is text, build `normalized_input` from
   `payload.effective_input`.
3. Run role `intent_classifier`.
4. If intent is `add_grocery_items`, run role `grocery_parser`.
5. If intent is `create_task`, run role `task_parser`.
6. Otherwise stop after classification.

Current command runtime note:

- parser execution remains conditional backend logic after classification
- the command submit RPC still returns only one primary actionable result
- when multiple intents are detected, the backend MUST NOT execute any
  destructive side effect before returning a downgraded `confirm` result
- parser-backed grocery and task extraction may be used to prepare the primary
  result even when the final outcome is `confirm`, `inline`, or `route`

The response MUST return:

- classification result
- parser result when a parser role ran

The parser selection after classification is deterministic backend logic. It is
not caller-controlled.

## 9. Logging requirements

The system MUST log per pipeline step, not only per high-level request.

Each step log entry MUST capture:

- `request_id`
- `feature_key`
- `stage`
- `role_key`
- `provider`
- `model`
- `prompt_version`
- `status`
- `latency_ms`
- `error_code`
- `provider_request_id`

The step log MAY also capture attempt count, route resolution time, and
fallback path metadata, but those fields are optional in v1.

This step log replaces any older logging shape that recorded only one
top-level provider call for the full request.

## 10. Deterministic fallback boundary

The interface MUST preserve deterministic fallback support even though full
fallback chains are out of scope.

For v1:

- `deterministic_fallback_allowed` MUST exist on the resolved route
- the system MAY use a local deterministic fallback for bounded jobs such as
  classifier fallback
- the system MUST NOT implement silent multi-provider fallback chains

## 11. Provider support boundary

This refactor MUST preserve current OpenAI support.

The design MUST also allow future compatible adapters, including Gemini or
OpenAI-compatible providers, without redesigning invocation payloads or stage
boundaries.

Current command backend note:

- the long-term schema allows future adapters
- the currently active command runtime intentionally uses a narrower provider
  set than the long-term schema design
- the command migration currently seeds `openai`, `gemini`, and `stub`
  providers only
- `qwen` and `openai_compat_chat_completions` are not currently active command
  routes and MUST NOT be treated as supported command runtime paths until the
  edge runtime implements them

## 12. Minimal SQL schema

This is the smallest useful schema for the v1 architecture.

### 12.1 `ai_providers`

Stores provider transport configuration.

```sql
create table public.ai_providers (
  provider_id uuid primary key default gen_random_uuid(),
  provider_key text not null unique,
  adapter_kind text not null,
  base_url text null,
  secret_name text null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ck_ai_providers_adapter_kind check (
    adapter_kind = any (
      array[
        'openai_responses'::text,
        'openai_compat_responses'::text,
        'gemini'::text,
        'stub'::text
      ]
    )
  )
);
```

### 12.2 `ai_models`

Stores models and core capabilities.

```sql
create table public.ai_models (
  model_id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.ai_providers(provider_id),
  model_key text not null,
  supports_structured_output boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_ai_models unique (provider_id, model_key)
);
```

### 12.3 `ai_roles`

Stores AI job definitions.

```sql
create table public.ai_roles (
  role_key text primary key,
  stage text not null,
  input_schema_key text not null,
  output_schema_key text not null,
  description text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ck_ai_roles_stage check (
    stage = any (
      array[
        'normalization'::text,
        'understanding'::text,
        'execution'::text
      ]
    )
  )
);
```

### 12.4 `ai_feature_steps`

Maps feature plus ordered entry step to role.

For v1 this table describes only the static ordered entry path. Conditional
follow-up branching after classification remains deterministic application
logic.

```sql
create table public.ai_feature_steps (
  feature_key text not null,
  step_key text not null,
  step_order integer not null,
  role_key text not null references public.ai_roles(role_key),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (feature_key, step_key),
  constraint uq_ai_feature_steps_order unique (feature_key, step_order)
);
```

### 12.5 `ai_role_routes`

Maps role to active model route.

For v1 there is one active route per role.

```sql
create table public.ai_role_routes (
  role_key text primary key references public.ai_roles(role_key),
  model_id uuid not null references public.ai_models(model_id),
  prompt_version text not null,
  execution_mode text not null default 'sync',
  deterministic_fallback_allowed boolean not null default false,
  max_retries integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ck_ai_role_routes_max_retries check (max_retries >= 0)
);
```

## 13. Local eval fixtures

The codebase MUST support simple local fixtures for model-swap checks, even if
there is no full eval runner yet.

Initial fixture coverage SHOULD exist for:

- `intent_classifier`
- `grocery_parser`
- `task_parser`

Example fixture shape:

```json
{
  "role_key": "intent_classifier",
  "schema_key": "intent_classifier_v1",
  "input": {
    "modality": "text",
    "text": "buy milk and eggs"
  },
  "expected": {
    "intent": "add_grocery_items"
  }
}
```

```json
{
  "role_key": "grocery_parser",
  "schema_key": "grocery_parser_v1",
  "input": {
    "modality": "text",
    "text": "buy milk and eggs"
  },
  "expected": {
    "items": ["milk", "eggs"]
  }
}
```

Each fixture SHOULD support:

- structural checks against a known schema reference
- semantic assertions such as expected intent, item set, or task title

The fixture runner SHOULD support a minimal assertion vocabulary such as:

- `equals`
- `contains_all`
- `required_keys`
- `forbidden_keys`

## 14. Implementation constraints

The refactor MUST:

- remain incremental
- reuse as much of the current edge function shape as practical
- avoid introducing a large framework
- avoid implementing audio, image, or PDF processing
- keep deterministic fallback support in the interface
- preserve current OpenAI support
- allow future provider expansion without redesign

## 15. Versioning

- Adding new `feature_key` values or new `role_key` values is a MINOR change.
- Changing invocation semantics, stage meaning, or route resolution semantics
  is a MAJOR change.
- Swapping provider or model defaults in backend configuration does not require
  a contract version bump.

## 16. Summary

This contract defines the minimum useful skeleton for a command AI pipeline:
validated invocation, normalized text input, server-resolved routes,
deterministic multi-stage execution, per-step logs, and fixture-ready eval
inputs. It is intentionally narrow so the architecture can be corrected now
without prematurely building the whole future platform.
