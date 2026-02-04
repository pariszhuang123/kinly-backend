---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.5
Audience: internal
Last updated: 2026-02-03
---

# Two-Lane Async Complaint Rewrite (complaint_rewrite_two_lanes_async_v1)

## 1) Purpose
Define the async execution layer with a two-lane model:
- **Lane A (same_language):** rewrite-only when sender language equals recipient language.
- **Lane B (cross_language):** rewrite in the recipient language when languages differ (translation implicit).

Ensures per-recipient personalization, deterministic locale resolution (never "unknown"), safe batching, strong isolation, idempotent execution, and auditability. Out of scope: eligibility, UI timing, delivery mechanics, pricing.

## 2) Core Principles
1. Async-first; never real-time by default.  
2. Recipient-personalized; exactly one mentioned recipient per request.  
3. Two-lane routing based on language equality.  
4. No output reuse across recipients.  
5. Deterministic locales; `source_locale` and `target_locale` are immutable and non-"unknown".  
6. Cost-aware; batching allowed only when safe.  
7. Fail-safe; failures store no output.  
8. Auditable; log metadata only.  
9. Strict isolation; batching is compute-only, not storage/delivery.

## 3) Entities and Keys
- Rewrite request: business unit (one sender message).
- Execution unit: `(rewrite_request_id, recipient_user_id)` unique and stable.
- Snapshots captured at request creation: `recipient_snapshot_id` (targets) and `recipient_preference_snapshot_id` (preferences). Async layer MUST NOT fetch mutable preferences later.

## 4) Boundary with orchestrator and classifier
- Only `complaint_rewrite_edge_orchestrator_v1` persists raw message, calls classifier, resolves locales, creates snapshots, and enqueues jobs.
- Orchestrator MUST call `complaint_rewrite_ai_classifier_v1` to get `detected_language`, `topics`, `intent`, `rewrite_strength`, `safety_flags`. Classifier is advisory; orchestrator makes final locale decisions.

## 5) Locale resolution (deterministic, orchestrator rule)
- Normalize languages for processing (e.g., en-US→en, es-MX→es). Raw locale may be kept for analytics/UI.
- `source_locale`:  
  1) If classifier language confidence is medium/high → normalized detected language.  
  2) Else if sender profile locale exists → normalized profile locale.  
  3) Else → `en`.  
- `target_locale`: recipient locale normalized; if missing → `en`.  
- Neither locale may be "unknown"; both immutable per request.

## 6) Lane computation
- `lane = same_language` if `source_locale == target_locale`; else `lane = cross_language`. Immutable per request.
- Semantics:  
  - same_language: rewrite-only; output in target_locale (same as source).  
  - cross_language: rewrite+translate; output in target_locale only; no separate translation artifact.

## 7) Job lifecycle
States: `queued → processing → batch_submitted → completed`, with failure path to `failed` and optional admin/system cancel to `canceled`. Monotonic transitions.

## 8) Job payload (sole unit of execution)
```json
{
  "job_type": "complaint_rewrite",
  "job_id": "uuid",
  "rewrite_request_id": "uuid",
  "home_id": "uuid",
  "sender_user_id": "uuid",
  "recipient_user_id": "uuid",
  "recipient_snapshot_id": "uuid",
  "recipient_preference_snapshot_id": "uuid",
  "source_locale": "en",
  "target_locale": "es",
  "lane": "cross_language",
  "provider_batch_id": "string | null",
  "classifier_result": { "ClassifierResultV1": true },
  "routing_decision": { "RoutingDecisionV1": true }, // includes adapter_kind + base_url when present
  "rewrite_request": { "RewriteRequestV1": true },
  "execution_mode": "async | batch",
  "attempt": 1,
  "max_attempts": 2
}
```
Invariants: `(rewrite_request_id, recipient_user_id)` maps to one output slot; snapshot IDs stable; locales and lane match persisted request; output MUST be in target_locale; if `provider_batch_id` is set it MUST remain stable across retries.
Note: jobs SHOULD store only identifiers and routing metadata; the serialized `rewrite_request` is sourced from `rewrite_requests.rewrite_request` at execution time.

## 9) Processing rules
- Lock per execution unit (advisory lock on rewrite_request_id + recipient_user_id). MUST NOT lock by home_id.
- Steps: acquire lock → mark processing → (batch mode: submitter sets `provider_batch_id` + `batch_submitted`; collector polls provider and resumes) → call provider adapter per routing_decision → ensure output language = target_locale → validate RewriteResponseV1 + lexicon in target_locale → persist per execution unit → mark completed with timestamps.
- Idempotency: if already completed for the execution unit, skip provider call and no-op.

## 10) Batching rules
- Provider batch API: may mix homes/users/locales; must map (batch_id, batch_item_index) → execution unit; per-item validation/idempotency/persistence required.
- Micro-batching (shared prompt call) allowed only if all equal: provider, model, prompt_version, policy_version, execution_mode, lane, source_locale, target_locale. Batch group key = provider + model + prompt_version + policy_version + execution_mode + lane + source_locale + target_locale.
- Prohibited: output reuse across recipients, cross-target-locale micro-batching, combined prompts with shared user context, partial outputs.

## 11) Retry logic
- Allowed: transient provider/network errors, batch partial failures.  
- Not allowed: schema or lexicon failures, deterministic prompt errors.  
- Retries reuse provider, model, prompt_version, policy_version, source_locale, target_locale, lane. No routing changes mid-retry. Exponential backoff recommended. If all attempts fail → failed, no output stored.

## 12) Completion and timestamps
- On success: persist output, set `rewrite_completed_at`; sender reveal timing handled upstream; async layer does not deliver or reveal.

## 13) Observability and audit (metadata only)
- Record: rewrite_request_id, job_id, home_id, sender_user_id, recipient_user_id, recipient_snapshot_id, recipient_preference_snapshot_id, source_locale, target_locale, lane, classifier_version, detected_language, language_confidence, provider, model, prompt_version, policy_version, execution_mode, provider_batch_id, batch_group_key, batch_id, batch_item_index, attempts, timestamps, status. Never log raw or rewritten text.

## 14) Security and privacy
- No raw or rewritten text in logs. In-memory text only during processing. Enforce per-item mapping; no cross-home/user leakage.

## 15) MUST NOT
- Decide eligibility/policy, compute recipients at processing time, fetch mutable preferences, reuse outputs across recipients, output in non-target locale, mix target locales in micro-batching, change routing/locales/lane during retries, perform delivery/reveal.

## 16) Versioning rules
- New required fields or lane semantics changes → MINOR (or MAJOR if breaking).  
- Retry semantic changes → MAJOR.  
- Provider/model swaps → no version bump.

## 17) Summary
Two-lane async rewrite keeps locale decisions deterministic, preserves per-recipient personalization, enables safe batching without reuse, and remains idempotent and auditable while keeping AI constrained to rendering only.
