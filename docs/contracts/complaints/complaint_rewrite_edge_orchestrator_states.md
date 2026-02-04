---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.1
Audience: internal
Last updated: 2026-02-01
---

# Edge Orchestrator State Machine (supporting view)

This is a supporting view for `complaint_rewrite_edge_orchestrator_v1` to clarify states and transitions. It does not alter semantics; follow the main contract for authority.

## States
- `received` — RPC accepted, basic payload present.
- `queued` — original message persisted, `rewrite_request_id` assigned.
- `classified` — classifier response attached (or defaulted).
- `context_built` — RecipientContextPackV1 attached.
- `routed` — provider/model selected; prompt_version known.
- `enqueued` — job handed to async worker with routing + request payload.
- `completed` — rewrite succeeded, validations/lexicon passed, stored, `rewrite_completed_at` set; recipient delivery is allowed and should be triggered immediately after this timestamp.
- `revealed` — sender can view rewritten text after `sender_reveal_at` (default +24h from `rewrite_completed_at`); sender visibility only, recipient has already received at `completed`.
- `failed` — terminal error (classifier/context/rewriter/validation failure).
- `canceled` — terminal admin/system cancel (no delivery, no reveal).

## Transitions (deterministic)
- received → queued  
  - Preconditions: home/recipient eligibility, recipient preferences completed or fallback allowed, surface allowed.
- queued → classified  
  - Preconditions: message persisted; call classifier; on failure use safe defaults.
- classified → context_built  
  - Preconditions: classifier topics/intent available (or defaults); cadence satisfied; context pack RPC succeeds. If cadence or context pack fails → failed.
- context_built → routed  
  - Preconditions: context pack present; derive rewrite policy; call routing contract.
- routed → enqueued  
  - Preconditions: RewriteRequestV1 assembled and validated; async job created with routing info.
- enqueued → completed  
  - Preconditions: rewriter returns RewriteResponseV1; safety + lexicon checks pass; data stored.
- enqueued → failed  
  - If rewriter errors, times out, or safety/lexicon validation fails.
- any → canceled  
  - Admin/system cancel only.
- completed → revealed  
  - When current time ≥ `sender_reveal_at` (set e.g., +24h). Visibility to sender only.

## Entry/exit rules
- Entry: only via server RPCs (e.g., `weekly_harmony_rewrite_create_v1`).
- Exit: terminal states are `failed` or `revealed`.
- Exit: terminal states are `failed`, `revealed`, or `canceled`.

## Validation checklist (inputs before enqueue)
- Required: `home_id`, `sender_user_id`, `recipient_user_id`, `sender_message`, `surface`.
- Eligibility: same home, recipient preferences completed or fallback allowed, cadence satisfied, surface allowed.
- Classifier present (or defaulted) with topics non-empty and intent set.
- Context pack present and matches topic map (no extra preference IDs).
- Rewrite policy populated (tone, directness, emotional_temperature, rewrite_strength).
- RewriteRequestV1 validates against schema; no provider/model hints inside the request body.

## Safety gates
- If any required piece is missing at a stage, transition to `failed` and do NOT enqueue or deliver.
- No retries without user re-submission; retries are handled via async job policy only within the same request.

## Observability (minimum events)
- `rewrite_received`, `rewrite_queued`, `rewrite_classified`, `rewrite_context_built`, `rewrite_routed`, `rewrite_enqueued`, `rewrite_completed`, `rewrite_failed`, `rewrite_revealed`.

## Determinism note
- Given identical input payload, preferences, contract versions, and routing config, the state path and decisions MUST be identical.
