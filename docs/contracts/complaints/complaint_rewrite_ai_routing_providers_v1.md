---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.2
Audience: internal
Last updated: 2026-02-03
---

# AI Routing and Providers (complaint_rewrite_ai_routing_providers_v1)

## 1) Purpose
Define how Kinly selects AI providers, models, prompts, and execution modes for complaint rewriting without exposing this complexity to frontend or orchestration logic.

Goals:
- Enable safe model/provider swaps.
- Centralize cost, reliability, and batching decisions.
- Keep routing deterministic and auditable.
- Allow backend-only changes (no app update required).

The router answers: **Given this rewrite task, which AI configuration should be used?**

## 2) Core Principles
1. Provider-agnostic: OpenAI, Google, or future providers are interchangeable.
2. Backend-controlled: frontend and orchestrator never select models.
3. Deterministic: same inputs → same routing output.
4. Cost-aware: prefer batching, caching, and cheaper models when safe.
5. Fail-closed: if routing cannot be determined, abort rewrite safely.

## 3) Inputs
Called only by the edge orchestrator.

### 3.1 Routing request
```json
{
  "task": "complaint_rewrite",
  "surface": "weekly_harmony | direct_message | other",
  "rewrite_strength": "light_touch | full_reframe",
  "language_pair": {
    "from": "bcp47",
    "to": "bcp47"
  },
  "lane": "same_language | cross_language",
  "policy_version": "string"
}
```
Router MUST NOT receive raw message text, recipient preferences, power mode, or emotion labels. Routing decisions are policy-based, not content-based.

## 4) Outputs
### 4.1 RoutingDecisionV1
```json
{
  "provider": "openai | google | other",
  "adapter_kind": "openai_responses | openai_chat | gemini_generate | ...",
  "base_url": "https://api.openai.com/v1 | null",
  "model": "string",
  "prompt_version": "v1",
  "policy_version": "string",
  "execution_mode": "async | batch",
  "supports_translation": true,
  "cache_eligible": true,
  "max_retries": 2
}
```
Output is opaque to frontend.

## 5) Routing dimensions (decision axes)
Routing MUST consider only:

### 5.1 Rewrite strength
- light_touch: simpler transformation; may use smaller/faster model.
- full_reframe: emotionally sensitive; must use higher-quality model.

### 5.2 Execution surface
- weekly_harmony: non-urgent; async or batch preferred; latency tolerant.
- direct_message (future): may need faster turnaround; still non-real-time by default.

### 5.3 Language pair
- Same-language rewrite.
- Cross-language rewrite + translation. Some models support translation natively; others require higher-quality multilingual models.

## 6) Example routing table (non-normative)
Illustrative only; actual values live in config.

| Rewrite strength | Language pair | Surface          | Provider | Model        | Mode  |
|------------------|---------------|------------------|----------|--------------|-------|
| light_touch      | same          | weekly_harmony   | openai   | gpt-5.2-nano | batch |
| full_reframe     | same          | weekly_harmony   | openai   | gpt-5.2      | async |
| full_reframe     | cross-lang    | weekly_harmony   | openai   | gpt-5.2      | async |
| light_touch      | same          | direct_message   | google   | gemini-lite  | async |

## 7) Prompt versioning
### 7.1 Prompt identity
- Each routing decision MUST specify `prompt_version`.
- Prompt changes do not require schema changes.
- Prompt version is recorded for audit and eval.

### 7.2 Prompt responsibilities
- Prompts MUST consume RewriteRequestV1.
- Obey lexicon and safety constraints.
- Produce RewriteResponseV1 only.

## 8) Execution modes
- async: per-job provider calls; allows retries and safety checks.
- batch: preferred when supported; cost-optimized; higher latency acceptable; results processed asynchronously. Step 1 uses `adapter_kind = openai_responses` only, with batch submitter/collector edge functions.

## 9) Caching and cost controls
### 9.1 Cache eligibility
- `cache_eligible = true` means identical RewriteRequestV1 hashes MAY reuse output.
- Cache TTL is provider-dependent.
- Caching MUST NOT bypass lexicon checks, bypass evaluation, or expose outputs across users.

### 9.2 Batching rules
- Only batch requests with same provider, model, prompt_version, policy_version, lane, source locale, target locale, and execution_mode.
- Batching MUST preserve per-request audit trails.

## 10) Provider adapters (non-normative)
Each provider adapter MUST:
- accept normalized routing decision.
- translate RewriteRequestV1 → provider API.
- normalize provider output → RewriteResponseV1.
- surface provider errors cleanly.

Adapters MUST NOT inject policy, modify rewrite intent, or leak provider metadata downstream.

## 11) Failure handling
- Routing failure: if no valid route exists, abort rewrite, mark failed, do NOT fallback silently to another provider.
- Provider failure: retry up to `max_retries`; if still failing, mark rewrite as failed; user may retry only with a new message.

## 12) Routing sanity checklist (hard validation)
- `task` MUST equal `complaint_rewrite`; reject otherwise.
- `surface` MUST be one of `weekly_harmony | direct_message | other`; reject unknown.
- `rewrite_strength` MUST be `light_touch` or `full_reframe`; reject unknown.
- `language_pair.from` and `.to` MUST be valid BCP-47 strings; reject missing/empty.
- `lane` MUST be present and ∈ {same_language, cross_language}.
- `policy_version` MUST be present.
- `adapter_kind` MUST be present and supported for the chosen provider/model; `base_url` optional override (null uses provider default).
- Routing table lookup MUST succeed; if no row matches, fail-closed (no implicit fallback).
- `execution_mode` and `prompt_version` MUST be provided; reject if missing.

## 13) Audit requirements
Log every routing decision with provider, model, prompt_version, execution_mode, cache usage, timestamps. Used for cost analysis, incident review, eval regression, provider swaps.

## 14) MUST NOT
- Router MUST NOT inspect message content, infer sentiment or tone, select recipients, override orchestrator decisions, or leak routing info to frontend.

## 15) Versioning rules
- Adding providers or models → no version bump.
- Changing routing logic semantics → MAJOR bump.
- Changing default routes → config change only.

## 16) Summary
The AI routing layer isolates risk, contains cost, enables experimentation, and protects user-facing behavior. If the orchestrator is the brain, the router is the switchboard: it connects calls, it does not listen to them.
