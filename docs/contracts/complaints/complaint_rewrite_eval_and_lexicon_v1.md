---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.1
Audience: internal
Last updated: 2026-02-01
---

# Complaint Rewrite Eval and Lexicon Storage (draft linkage)

Purpose: define how evaluation results and lexicon versions are stored and referenced across the rewrite system. This document links to storage tables defined in `complaint_rewrite_storage_schema_v1` and processing steps in `complaint_rewrite_async_jobs_v1`.

## Scope
- Applies to validation of `RewriteResponseV1` outputs produced by async workers.
- Covers where eval results and lexicon versions are recorded.
- Does NOT define eval prompts or judge logic (tracked separately in `rewrite_eval_v1`, `complaint_rewrite_eval_dataset_v1`, `complaint_rewrite_eval_judge_v1`, `complaint_rewrite_lexicon_v1`).

## Storage fields (authoritative locations)
- `rewrite_outputs.lexicon_version` (TEXT, NOT NULL): the lexicon version applied during validation for this output. If no lexicon is configured, use `\"none\"`.
- `rewrite_outputs.eval_result` (JSONB, NOT NULL): structured result of eval checks for this output.
  - Suggested shape:
    ```json
    {
      "schema_valid": true,
      "lexicon_pass": true,
      "safety_pass": true,
      "intent_preserved": "pass|warn|fail",
      "tone_safety": "pass|warn|fail",
      "flags": ["optional string codes"],
      "judge_version": "v1",
      "dataset_version": "v1"
    }
    ```
  - Minimum required keys (even if eval/lexicon is not configured): `schema_valid`, `lexicon_pass`.
- `rewrite_outputs.prompt_version` and `policy_version` already present for traceability.

## Processing responsibilities (async worker)
- MUST run schema validation, lexicon checks, and any judge/eval configured for the task before persisting output.
- MUST populate `lexicon_version` and `eval_result` atomically with `rewritten_text` in `rewrite_outputs`.
- MUST fail the job (no output persisted) if lexicon or schema validation fails.
- If lexicon/eval is not configured, still validate schema, set `lexicon_version = \"none\"`, and set `eval_result.schema_valid = true` and `eval_result.lexicon_pass = null`.
- MUST include `judge_version` and `dataset_version` inside `eval_result` when applicable.

## References in other contracts
- Orchestrator: TODO link now resolved here; orchestrator remains unaware of eval details but records lexicon_version/prompt_version in metadata passed downstream.
- Async jobs: section 6 requires validation before completion; use this doc as storage guidance.
- Routing: no change; routing is not impacted by eval, but provider/model choices are logged for audit next to eval results.

## Logging and privacy
- Do NOT log rewritten text in eval logs.
- Eval outputs stored only in `rewrite_outputs.eval_result`; avoid duplicating in job logs.

## Versioning
- Adding new fields inside `eval_result` JSON: MINOR (compatible) if existing fields remain; MAJOR if semantics change or required keys change.
- Changing lexicon version format: MAJOR.
- Moving storage location: MAJOR.

## Open items
- Finalize the eval result schema (pass/warn/fail codes, flag taxonomy).
- Align judge/dataset version keys with `rewrite_eval_judge_v1` and `complaint_rewrite_eval_dataset_v1` once finalized.
