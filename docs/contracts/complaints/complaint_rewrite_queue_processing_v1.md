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

# Complaint Rewrite Queue Processing & Backpressure (complaint_rewrite_queue_processing_v1)

## 1) Purpose
Define how Kinly processes queued complaint rewrite jobs safely and predictably under load.

Goals:
- Prevent cost spikes and retry storms.
- Ensure deterministic throughput (jobs either process or wait).
- Make “waiting for next cron run” an explicit, documented behavior.
- Keep frontend unaware of provider mechanics and queue limits.

Scope: queue semantics, per-run limits, deferral, claiming/locking, retry/failure, audit signals. This complements `complaint_rewrite_async_jobs_v1` (execution rules) by specifying how jobs are picked up.

## 2) Key definitions
- Job: one rewrite task stored in DB.
- Worker run: one Edge Function invocation (cron or admin trigger).
- Backpressure: when queued jobs exceed per-run capacity; excess remain queued.

## 3) Job lifecycle states (canonical vocabulary)
- `queued`          : eligible to be picked up (subject to `not_before_at`).
- `processing`      : claimed; in progress (pre-batch or async execution).
- `batch_submitted` : handed to provider batch; awaiting batch completion (submitter sets this).
- `completed`       : rewrite completed and stored.
- `failed`          : permanently failed; no more retries.
- `canceled`        : system/admin cancel only.

Alias note: if existing systems use `running/succeeded`, map `running -> processing`, `succeeded -> completed` for consistency across contracts.

Jobs MUST NOT skip directly from `queued` to `completed` without `processing` unless explicitly documented as an optimization.

## 4) Job record (minimum schema)
```json
{
  "job_id": "uuid",
  "rewrite_request_id": "uuid",
  "task": "complaint_rewrite",
  "surface": "weekly_harmony | direct_message | other",
  "rewrite_strength": "light_touch | full_reframe",
  "language_pair": { "from": "bcp47", "to": "bcp47" },
  "recipient_user_id": "uuid",
  "recipient_snapshot_id": "uuid",
  "recipient_preference_snapshot_id": "uuid",

  "status": "queued | processing | batch_submitted | completed | failed | canceled",

  "created_at": "timestamptz",
  "updated_at": "timestamptz",

  "not_before_at": "timestamptz | null",
  "claimed_at": "timestamptz | null",
  "claimed_by": "string | null",

  "attempt_count": 0,
  "max_attempts": 2,

  "last_error": "string | null",
  "last_error_at": "timestamptz | null",

  "routing_decision": {
    "provider": "openai | google | other",
    "adapter_kind": "openai_responses | openai_chat | gemini_generate | ...",
    "base_url": "https://api.openai.com/v1 | null",
    "model": "string",
    "prompt_version": "v1",
    "policy_version": "string",
    "execution_mode": "async | batch",
    "cache_eligible": true,
    "max_retries": 2
  }
}
```
Notes: `(rewrite_request_id, recipient_user_id)` MUST be unique (idempotent execution unit). Raw message text MUST NOT be stored in `routing_decision`. `not_before_at` enables deliberate deferral/batching windows. Timestamps are UTC.

## 5) Worker trigger
- Recommended: DB scheduler (e.g., pg_cron) on fixed cadence for cost control.
- Batch lane uses two schedulers: `complaint_rewrite_batch_submitter_15m` and `complaint_rewrite_batch_collector_30m`.
- Optional: admin-only manual trigger for recovery.
- Frontend MUST NOT trigger workers.

## 6) Worker run configuration (backpressure)
Example config:
```json
{
  "max_jobs_per_run": 25,
  "max_runtime_seconds": 240,
  "claim_timeout_seconds": 600,
  "order": "created_at_asc",
  "eligible_statuses": ["queued"],
  "respect_not_before_at": true,
  "retry_backoff_seconds": [900, 7200]
}
```
### 6.1 Backpressure rule (normative)
If eligible queued jobs exceed `max_jobs_per_run`, process up to the limit and leave the rest queued. Waiting for the next run is normal, not a failure. Batch submitter MUST requeue overflow jobs with short backoff instead of keeping them claimed.

## 7) Job claiming and concurrency safety
### 7.1 Claiming algorithm (normative)
Eligible if `status = queued` and (`not_before_at` is null or <= now). To claim: atomically set `status = processing`, `claimed_at = now`, `claimed_by = <worker_id>` only if still eligible; return claimed rows up to `max_jobs_per_run`. Workers MUST NOT process unclaimed jobs.

### 7.2 Stale running recovery (normative)
If `status = processing` and `claimed_at` older than `claim_timeout_seconds`, MAY re-queue: set `status = queued`, increment `attempt_count`, set `last_error = "stale_claim_requeued"`.

## 8) Retry and failure rules
### 8.1 Retry (normative)
On provider/transient failure: increment `attempt_count`, set `status = queued`, set `not_before_at = now + backoff(attempt_count)` using deterministic `retry_backoff_seconds`.

### 8.2 Permanent failure (normative)
If `attempt_count >= max_attempts`: set `status = failed`, populate `last_error` and `last_error_at`. No silent fallback to other providers (aligns with routing contract).

## 9) Processing modes
- `execution_mode = async`: per-job provider calls (not used in the current OpenAI Responses batch path).
- `execution_mode = batch`: submitter groups jobs (provider/model/prompt_version/policy_version/lane/locales) and sets `status = batch_submitted`; collector later completes or fails each job individually. Each job STILL needs individual audit trail and final status.

## 10) Observability and audit (minimum)
Each worker run logs: `run_id`, started_at, finished_at, `max_jobs_per_run`, claimed_count, succeeded_count, failed_count, requeued_count, per-provider/model counts, rate-limit/capacity errors.  
Each job records: final status, attempt_count, routing_decision, timestamps.
Logging MUST NOT include raw sender text or rewritten text; use opaque IDs only.

## 11) Frontend contract (behavioral guarantee)
Frontend assumes rewrites complete asynchronously; timing not guaranteed. Job states come from DB (or Realtime), not edge “check status” endpoints.

## 12) MUST NOT
- Worker MUST NOT process unlimited jobs in one run.
- Worker MUST NOT rely on provider rate limits as flow control.
- Frontend MUST NOT poll an edge function to check completion.
- Router MUST NOT receive raw message content (per routing contract).

## 13) Versioning rules
Changing defaults (e.g., `max_jobs_per_run`, cron cadence) → config change only.  
Changing state machine semantics or claiming rules → MAJOR bump.

## 14) Suggested environment defaults (config, not contract)
- **Dev**: cron every 2h; `max_jobs_per_run = 5`; `max_runtime_seconds = 120`; backoff `[120, 600]`; `claim_timeout_seconds = 300`.
- **Stage**: cron every 30m; `max_jobs_per_run = 30`; `max_runtime_seconds = 180`; backoff `[300, 1800]`; `claim_timeout_seconds = 900`.
- **Prod**: cron every 60–120m; `max_jobs_per_run = 200` (scale to hourly arrival rate); `max_runtime_seconds = 240`; backoff `[3600, 21600]`; `claim_timeout_seconds = 3600`.

Rationale: longer cadence reduces scheduler cost; per-run cap sized to drain hourly arrivals; long backoff prevents retry storms between long cron intervals.
