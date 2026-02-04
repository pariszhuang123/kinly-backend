---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.4
Audience: internal
Last updated: 2026-02-03
---

# Async Jobs and Processing (complaint_rewrite_async_jobs_v1)

## 1) Purpose
Define the asynchronous execution layer for complaint rewriting: enqueueing, batching, retries, completion semantics, failure handling, multi-home/user isolation, language-pair correctness, and recipient snapshot safety. Executes rewrites reliably, cost-controlled, non-blocking, privacy-safe, auditable, and deterministic. Scope: executes a rewrite request; does not decide eligibility, recipients, policies, or product timing.

## 2) Core Principles
1. Async-first — rewrites are never real-time by default.  
2. At-least-once — retries allowed; idempotency required.  
3. Cost-aware — supports delay and batching.  
4. Fail-safe — failed jobs never leak partial output.  
5. Auditable — every stage recorded.  
6. Strict isolation — no cross-home/user leakage; batching is compute-only, not storage/delivery.  
7. Recipient snapshot safety — delivery targets fixed at request creation.  
8. Language-pair clarity — declare `source_locale` and `target_locale`; output MUST be in `target_locale`.

## 3) Job Lifecycle
States: queued → processing → batch_submitted → completed; failure path to failed; optional admin/system cancel to canceled. Transitions are monotonic. (Alias note: if existing rows use `running/succeeded`, map to `processing/completed`.)

## 4) Job Types
### 4.1 Rewrite Job (primary)
#### 4.1.1 Job payload (sole unit of execution)
```json
{
  "job_type": "complaint_rewrite",
  "job_id": "uuid",
  "rewrite_request_id": "uuid",
  "home_id": "uuid",
  "sender_user_id": "uuid",
  "recipient_user_id": "uuid",
  "recipient_snapshot_id": "uuid",
  "source_locale": "de-DE",
  "target_locale": "en-NZ",
  "provider_batch_id": "string | null",
  "routing_decision": { "RoutingDecisionV1": true },  // includes adapter_kind + base_url when provided
  "rewrite_request": { "RewriteRequestV1": true },
  "attempt": 1,
  "max_attempts": 2,
  "status": "queued | processing | batch_submitted | completed | failed | canceled"
}
```
#### 4.1.2 Required invariants
- `rewrite_request_id` globally unique.  
- Execution unit is `(rewrite_request_id, recipient_user_id)` and MUST be unique.  
- `home_id`, `sender_user_id`, and `recipient_user_id` match persisted rewrite record.  
- `recipient_snapshot_id` references stable recipient set captured at request creation.  
- `source_locale` and `target_locale` are immutable per request and MUST NOT be \"unknown\".  
- Output MUST be in `target_locale`.
- `provider_batch_id` remains null until a job is included in a provider batch; once set, it MUST NOT change across retries.
Note: jobs SHOULD store only identifiers and routing metadata; the serialized `rewrite_request` is sourced from `rewrite_requests.rewrite_request` at execution time.

#### 4.1.3 Locale semantics
`source_locale` = sender language; `target_locale` = recipient language; translation happens if they differ.

## 5) Enqueueing Rules
- Only `complaint_rewrite_edge_orchestrator_v1` may enqueue.  
- Enqueue after raw message persistence.  
- Idempotent per execution unit; retries of enqueue must no-op if job exists.  
- On enqueue failure: mark rewrite failed; return generic failure; no provider calls.

## 6) Processing Rules
### 6.1 Execution
- Lock per execution unit (advisory lock on rewrite_request_id + recipient_user_id); mark processing.  
- Step 1 path: `rewrite_batch_submitter` claims queued jobs, builds OpenAI Responses batch JSONL, uploads, and sets `status = batch_submitted` with `provider_batch_id`; `rewrite_batch_collector` polls provider, parses JSONL, runs `evaluateRewrite`, writes outputs, and advances to completed/failed.  
- Execute via provider adapter using `routing_decision`; produce output in `target_locale`.  
- Validate against `RewriteResponseV1` and lexicon/eval rules per `complaint_rewrite_eval_and_lexicon_v1` (target locale).  
- Persist rewritten output; set status completed.  
- MUST NOT skip validation, return partial output, expose provider errors, store output on failure, alter routing, or output in another locale.

### 6.2 Batching
Two concepts: provider micro-batching and provider batch API. Items remain per-request.

#### 6.2.1 Micro-batching eligibility
Allowed only if provider supports it AND provider/model/prompt_version/policy_version/execution_mode/lane identical AND source_locale identical AND target_locale identical.  
Batch group key = provider + model + prompt_version + policy_version + execution_mode + lane + source_locale + target_locale.

#### 6.2.2 Isolation guarantees
- Create `batch_id`; assign `batch_item_index` per item.  
- Maintain mapping (batch_id, batch_item_index) -> rewrite_request_id.  
- Persist results per request; one item failure must not corrupt another; no cross-ID writes.

#### 6.2.3 Prohibited
- Combined prompts with multiple users, shared context, or reordering without mapping; no partial outputs.

#### 6.2.4 Offline batch tier
- Mixed homes/users/locales allowed in provider batch artifact, but per-request validation, idempotency, and persistence still required.

### 6.3 Locking
- Lock per execution unit (rewrite_request_id + recipient_user_id); MUST NOT lock on home_id.

### 6.4 Idempotent processing
- If re-run after completion: detect completion, do not re-run AI, return success.

## 7) Retry Logic
- Allowed for transient provider or network errors and batch partial failures.  
- Not allowed for schema or lexicon failures or deterministic prompt errors.  
- `max_attempts` from routing/policy; exponential backoff recommended.  
- Retries MUST reuse provider, model, prompt_version, policy_version, source_locale, target_locale. No routing changes mid-retry.

## 8) Completion Semantics
- On success: persist RewriteResponseV1 (target_locale), set `rewrite_completed_at`, mark completed.  
- No completion without stored output + validation + timestamps.  
- Provider errors normalized; never exposed to frontend.
 - `sender_reveal_at` is set by the orchestrator; async workers MUST NOT compute it.

### 8.4 Recipient snapshot delivery safety
- Orchestrator creates `recipient_snapshot_id` at request creation; delivery targets that snapshot only.  
- New home members after snapshot must not receive prior rewrites.  
- Async layer MUST NOT compute recipients at reveal time.

## 9) Failure Handling
- If all attempts fail: mark job and rewrite request failed; do not store output; generic failure; user may retry only with a new message (new rewrite_request_id).

## 10) Idempotency and Safety
- Duplicate execution safe; duplicate completion no-op.  
- No output stored for failed jobs; no cross-request output writes; logs avoid raw/rewritten text.

## 11) Observability and Audit
Record: rewrite_request_id, job_id, home_id, sender_user_id, recipient_user_id, recipient_snapshot_id, source_locale, target_locale, provider, model, prompt_version, policy_version, execution_mode, batch_group_key, batch_id, batch_item_index, attempt count, timestamps per state, final status. Supports cost by language pair, reliability, eval regressions, incidents.

## 12) Security and Privacy
- Do not log message or rewritten text; only opaque IDs.  
- In-memory access to text only for processing.

## 13) MUST NOT
- Decide eligibility, infer topics/intent, alter policy, change routing, apply norms, reveal messages, compute recipients dynamically, or perform delivery. Executes instructions; does not interpret them.

## 14) Versioning Rules
- New job types or required fields → MINOR.  
- Retry semantic changes → MAJOR.  
- Provider changes → none.  
- Strengthened isolation/safety → MINOR unless breaking implementations.

## 15) Summary
Async layer absorbs latency, controls cost (safe batching), ensures reliability, protects user trust, and prevents leakage via per-request locking, persistence, recipient snapshots, and explicit language-pair semantics. Router chooses the road; async drives the car safely.

## 16) Micro-batch grouping examples (informative)
- Example A (batchable): all jobs have provider=openai, model=gpt-5.2, prompt_version=v3, policy_version=v1, execution_mode=batch, source_locale=en-US, target_locale=en-US. → Same batch_group_key; may micro-batch.
- Example B (not batchable): same as A but one job has target_locale=es-ES. → Different batch_group_key; must not micro-batch together.
- Example C (not batchable): same as A but one job has prompt_version=v4. → Different batch_group_key; must not micro-batch together.

## 17) Batch result ingester checklist (provider batch APIs)
- Validate (batch_id, batch_item_index) exists and maps to a known rewrite_request_id; drop + alert on unknown items.
- Per-item: validate RewriteResponseV1 schema and run lexicon checks in target_locale before persisting.
- Enforce idempotency on rewrite_request_id: if already completed, skip write; do not re-run AI.
- Do not propagate a provider-level batch error to all items; treat missing/failed items individually.
- If item count differs from submitted batch, alert and mark affected requests failed; do not guess mapping.
- Preserve per-item timestamps and status; do not apply a single batch timestamp to all items.
