---
Domain: Command
Capability: Natural-Language Command Entry API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Relates-To: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/command/command_ai_quota_v1.md, contracts/api/kinly/command/command_ai_pipeline_v1.md
See-Also: contracts/api/kinly/homes/paywall_status_get_v1.md
---

# Command Entry API v1.0

## 1. Purpose

This contract defines the client-facing backend API for Kinly's command surface.

It covers:

- `command_submit_v1`
- `command_continue_v1`
- `command_resume_v1`
- `command_cancel_v1`
- the canonical single-result response envelope returned to clients
- handoff persistence for unfinished actionable flows

The backend MUST return exactly one actionable result per request. V1 does not expose public batch execution.

---

## 2. RPC Surface

### `command_submit_v1`

```sql
command_submit_v1(
  p_home_id uuid,
  p_input_mode text,
  p_raw_text text,
  p_transcript_text text,
  p_timezone text,
  p_locale text,
  p_client_timestamp timestamptz,
  p_request_id uuid
) -> jsonb
```

Purpose:

- accept an initial text or voice command
- enforce auth, home access, and AI quota before classifier execution
- run the command AI pipeline
- choose one primary actionable result
- create a handoff only for unfinished actionable flows

### `command_continue_v1`

```sql
command_continue_v1(
  p_handoff_id uuid,
  p_request_id uuid,
  p_user_input jsonb
) -> jsonb
```

Purpose:

- continue a previously persisted `inline` or `confirm` handoff
- load authoritative state from `command_handoffs`
- merge user follow-up input with stored fields
- execute or route without re-running quota charging

### `command_resume_v1`

```sql
command_resume_v1(
  p_home_id uuid
) -> jsonb
```

Purpose:

- return the most recent pending unexpired handoff for the authenticated user in the current home
- return `null` when no resumable handoff exists

### `command_cancel_v1`

```sql
command_cancel_v1(
  p_handoff_id uuid
) -> jsonb
```

Purpose:

- cancel a pending handoff owned by the authenticated user

---

## 3. Canonical Success Response

All command RPCs that return a command result MUST use this top-level shape.

```json
{
  "contract_version": "1.0",
  "request_id": "uuid",
  "entrypoint": "command_submit_v1",
  "result": {
    "kind": "execute | inline | route | confirm | unknown",
    "intent": "create_task",
    "module": "task",
    "confidence": 0.93,
    "message": {
      "title_key": "command.task.need_assignee.title",
      "body_key": "command.task.need_assignee.body",
      "params": {
        "task_title": "Wash clothes"
      }
    },
    "fields": {
      "task_title": "Wash clothes",
      "assigned_to": null,
      "due_at": null
    },
    "missing_fields": ["assigned_to"],
    "ui": {
      "component": "member_picker",
      "target": null,
      "options": [
        {
          "id": "user-1",
          "label": "Sam"
        }
      ],
      "prefill": {
        "task_title": "Wash clothes"
      }
    },
    "draft": {
      "handoff_id": "uuid",
      "resume_token": "opaque-token",
      "expires_at": "2026-04-16T00:00:00Z"
    },
    "execution": null,
    "meta": {
      "requires_confirmation": false,
      "is_multi_intent_detected": false,
      "raw_input_retained": true
    }
  }
}
```

Rules:

- exactly one `result` object MUST be returned
- `result.kind` is the primary UI branch
- internal executor or RPC names MUST NOT be exposed
- `draft` MUST be present only for `inline`, `route`, and `confirm`
- `draft` MUST be `null` for `execute` and `unknown`
- `execution` MUST be populated only when `kind = "execute"`
- when multi-intent is detected and the backend downgrades to `confirm`, the
  backend MUST NOT execute side effects before returning that `confirm` result
- when `result.kind = "route"` for a date-aware task or reminder flow, the
  backend SHOULD preserve parser-owned fields such as `task_title`,
  `assigned_to`, `due_at`, `notes`, `recurrence_every`, and
  `recurrence_unit` in `result.fields` and `result.ui.prefill`

---

## 4. Result Kinds

### `execute`

Use when:

- intent is recognized
- required fields are complete
- confidence is high enough
- policy allows immediate execution

### `inline`

Use when:

- intent is recognized
- required fields are missing
- the AI surface can safely collect them

### `route`

Use when:

- intent is recognized
- completion should happen on a dedicated screen

### `confirm`

Use when:

- intent is recognized
- execution is possible
- confirmation is required because the action is sensitive, ambiguous, or multi-intent downgraded

### `unknown`

Use when:

- no trustworthy intent exists
- confidence is below threshold
- the backend should not create a handoff

---

## 5. Confidence Policy

Initial backend policy:

- `execute`: confidence `>= 0.90`, no missing fields, non-sensitive action
- `confirm`: confidence `>= 0.60` and `< 0.90`, or multi-intent detected, or action requires confirmation
- `inline`: confidence `>= 0.60`, recognized intent, missing fields, completable inline
- `route`: confidence `>= 0.60`, recognized intent, dedicated screen preferred
- `unknown`: confidence `< 0.60` or no trustworthy intent

The UI MUST NOT infer these thresholds. The backend is authoritative.

---

## 6. Multi-Intent Rule

The classifier MAY detect multiple intents internally.

V1 public behavior:

- the backend MUST still return exactly one result
- `meta.is_multi_intent_detected` MUST be `true` when multiple intents were detected
- the backend MAY downgrade an otherwise executable action to `confirm`
- the backend MUST NOT execute destructive side effects before returning that
  downgraded `confirm` result
- the backend MUST NOT return `modules[]` or any public batch envelope

---

## 7. Handoff Persistence

The backend MUST persist unfinished actionable flows in `public.command_handoffs`.

Rows are created only for:

- `inline`
- `route`
- `confirm`

Rows are not created for:

- `execute`
- `unknown`

Required persisted fields:

- `request_id`
- `user_id`
- `home_id`
- `intent`
- `module`
- `kind`
- `status`
- `source_text`
- `confidence`
- `context`
- `resume_token`
- `expires_at`

Persistence rules:

- `context` MUST be the authoritative persisted handoff payload
- `context` MUST retain the canonical pending `result` object and the original
  `source_text`
- `command_continue_v1` MUST consume preserved handoff state from authoritative
  persistence rather than reconstructing missing task/module details from raw
  source text

Allowed statuses:

- `pending`
- `completed`
- `cancelled`
- `expired`

---

## 8. Resume Rules

On AI surface reopen:

- fetch the most recent pending unexpired handoff for the user and home
- return `null` when none exists
- only pending handoffs may resume
- completed, cancelled, and expired handoffs MUST NOT reopen as active state

Dismissal behavior:

- a dismissed resume card SHOULD call `command_cancel_v1`

---

## 9. Error Model

Entry-layer errors include:

- `invalid_command_input`
- `classification_failed`
- `paywall_ai_command_daily_limit`

Rules:

- quota MUST be enforced before classifier execution
- `command_continue_v1`, `command_resume_v1`, and `command_cancel_v1` MUST NOT charge AI quota
- low-confidence unsupported requests SHOULD prefer `kind = "unknown"` rather than a hard error

---

## 10. Compatibility Rules

- this contract is the client-facing compatibility boundary
- V1 MUST NOT expose public batch execution
- clients MUST branch on `result.kind` only
- backend-only helper functions and internal pipeline payloads are not part of the compatibility surface
