---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: guide
Stability: stable
Status: active
Version: v1.2
Audience: internal
Last updated: 2026-02-03
---

# Complaint Rewrite System Maps (Mermaid)
v1.2 splits the flow into three focused maps: (1) trigger → orchestrator, (2) batch submission, (3) batch collection/finalization.

## 1) Trigger → Orchestrator (RPC-first)
```mermaid
flowchart TD
  MOOD["mood_submit_v2"] --> TRIG["complaint_rewrite_triggers"]
  TRIG --> DRN["trigger_drain (pg_cron)"]
  DRN --> ORCH["Edge Orchestrator<br/>complaint_orchestrator"]

  ORCH -->|internal call| CLF["complaint_classifier (edge)"]
  ORCH -->|prefs RPC| PREF["complaint_preference_payload"]
  ORCH -->|context RPC| CTX["complaint_context_build"]
  ORCH -->|route RPC| ROUTE["complaint_rewrite_route<br/>(config: complaint_rewrite_routes)"]
  ORCH -->|enqueue RPC| ENQ["complaint_rewrite_enqueue"]

  ENQ --> RSNAP["recipient_snapshots"]
  ENQ --> RPSNAP["recipient_preference_snapshots"]
  ENQ --> REQ["rewrite_requests"]
  ENQ --> JOBS["rewrite_jobs (status: queued)"]
```

## 2) Batch Submission (OpenAI Responses only — Step 1)
```mermaid
flowchart TD
  CRON["pg_cron 15m<br/>complaint_rewrite_batch_submitter_15m"] --> SUB["rewrite_batch_submitter (edge)"]
  SUB --> CLAIM["claim_rewrite_jobs_for_batch_submit_v1<br/>(status = queued)"]
  SUB --> FETCH["complaint_rewrite_request_fetch_v1<br/>(per job)"]
  SUB --> JSONL["build JSONL lines<br/>providers.ts (custom_id = job_id)"]
  JSONL --> OAI["OpenAI /v1/responses Batch<br/>(file upload + create batch)"]
  SUB --> REG["rewrite_batch_register_v1<br/>rewrite_provider_batches"]
  SUB --> MARK["mark_rewrite_jobs_batch_submitted_v1<br/>(status: batch_submitted)"]

  subgraph Batch Tables
    PB["rewrite_provider_batches"]
    JOBS["rewrite_jobs"]
  end
  REG --> PB
  MARK --> JOBS
```

## 3) Batch Collection & Finalization
```mermaid
flowchart TD
  CRONC["pg_cron 30m<br/>complaint_rewrite_batch_collector_30m"] --> COL["rewrite_batch_collector (edge)"]
  COL --> LIST["rewrite_batch_list_pending_v1"]
  COL -->|poll| OAI["OpenAI Batch status + output file"]
  COL --> PARSE["parse JSONL lines<br/>extractRewrittenText..."]
  PARSE --> EVAL["evaluateRewrite<br/>complaint_rewrite_eval_and_lexicon_v1"]
  PARSE --> COMPLETE["complete_complaint_rewrite_job<br/>(status: completed/failed)"]
  COL --> UPDATE["rewrite_batch_update_v1<br/>(status, output_file_id, error_file_id)"]
  COMPLETE --> OUTS["rewrite_outputs"]
  COMPLETE --> JOBS["rewrite_jobs"]
  COMPLETE --> FINAL["complaint_rewrite_request_finalize_v1<br/>(marks rewrite_requests completed + sender_reveal_at gating)"]

  subgraph Storage
    PB["rewrite_provider_batches"]
    JOBS
    OUTS
    REQ["rewrite_requests"]
  end
```

Notes
- Storage tables reference: `complaint_rewrite_storage_schema_v1`; routing config in `complaint_rewrite_routes`.
- Core types: `complaint_rewrite_types_v1`; batch JSONL builder: `supabase/functions/rewrite_batch/providers.ts`.
- Status vocabulary across queue/async/storage: `queued → processing → batch_submitted → completed|failed|canceled`; `sender_reveal_at` still controls exposure post-output.
- All DB writes are via RPCs; edge functions are `complaint_classifier`, `complaint_orchestrator`, `rewrite_batch_submitter`, `rewrite_batch_collector`.
