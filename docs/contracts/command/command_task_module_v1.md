---
Domain: Command
Capability: Task Module
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/chores/chore_wheel_api_v1.md
---

# Command Task Module Contract v1.0

## 1. Purpose

This module handles three intents routed from the [command router](command_router_contract_v1_1.md):

| Intent | Action |
|--------|--------|
| `create_task` | Create a new task |
| `mark_task_done` | Mark an existing task as complete |
| `create_reminder` | Open the task flow with date-aware context so the user can finish reminder setup |

Parsing strategy differs by intent. The module follows the two-phase architecture: the router provides module input with `source`, and this module owns field extraction, resolution, and UI decisions.

---

## 2. Parsing Strategy

### create_task

- **Step 1 (regex):** Extract `task_title` from the effective user input in `source.raw_text` or `source.transcript_text`.
- **Step 2 (LLM escalation):** Escalate if the effective user input contains:
  - Date patterns: `today`, `tomorrow`, `next week`, `by Friday`, day names
  - Assignee patterns: `for Alex`, `assign to Sam`
- If no escalation triggers → Step 1 is sufficient.

### mark_task_done

- **Step 1 only (resolver):** Score existing tasks against the effective user input.
- MUST NEVER use LLM for Call 2. The resolver always produces a result or no-match.

### create_reminder

- Uses the same parsing family as `create_task`.
- Date-aware reminder phrases SHOULD be parsed into task-like structured fields
  such as title, assignee hint, start date, and recurrence hints.
- Current backend behavior does NOT auto-create a dated reminder directly from
  `command_submit_v1`.
- Current backend behavior routes the user into the task screen so they can
  confirm the actual reminder date there.
- Current backend route payload SHOULD preserve the parsed fields needed to
  prefill the task screen:
  - `task_title`
  - `assigned_to`
  - `due_at`
  - `notes`
  - `recurrence_every`
  - `recurrence_unit`
- Current backend behavior does NOT yet persist a dedicated reminder draft row
  separate from the generic command handoff payload. The handoff stores route
  context, but reminder setup still completes on the task screen.

---

## 3. Field Schema — create_task

| Field | Type | Source | Rule |
|-------|------|--------|------|
| `task_title` | `string` | Regex or LLM | Extracted from the effective user input |
| `assigned_to` | `string?` | User selection | Exactly 1 person. MUST show inline picker if missing. Cannot assign to multiple people. |
| `due_at` | `string?` | LLM if date pattern detected, else `null` | Optional. Date-aware task/reminder hint. Current backend commonly routes these flows to the task screen for final selection rather than auto-executing directly. |

---

## 4. Field Schema — mark_task_done

| Field | Type | Source | Rule |
|-------|------|--------|------|
| `task_id` | `string` | Resolver | Matched against user's active tasks |
| `task_title` | `string` | Resolver | From the matched task record |

---

## 5. Assignment Rules (create_task)

- `assigned_to` allows EXACTLY 1 person.
- If not specified → MUST show inline picker with home members.
- Cannot assign to "everyone" or multiple people.
- If user says "for me" → `assigned_to = current_user` (no picker needed).

---

## 6. Resolution Logic (mark_task_done)

The module owns scoring. The resolver scores each active task against the effective user input.

### Scoring factors

| Factor | Score |
|--------|-------|
| Assigned to current user | +40 |
| Due today | +30 |
| Due recently (last 3 days) | +20 |
| Strong title match (>70% fuzzy) | +30 |
| Weak title match (40–70% fuzzy) | +15 |
| Recently active (updated in last 24h) | +25 |
| Recurring task | +10 |
| Last referenced entity | +20 |

Score range is uncapped (sum of matching factors).

### Selection thresholds (system config, not per-request)

| Threshold | Value |
|-----------|-------|
| `auto_execute_min` | 80 |
| `confirm_min` | 50 |

### Resolution shape

```json
{
  "mode": "matched_existing",
  "entity_type": "task",
  "entity_id": "task_123",
  "match_confidence_band": "high",
  "top_candidate_score": 94,
  "top_candidate_reasons": ["assigned_to_current_user", "due_today", "strong_title_match"],
  "candidate_count": 3,
  "requires_user_selection": false
}
```

### Allowed `mode`

`not_applicable` · `matched_existing` · `needs_selection` · `no_match_create_new` · `route_for_resolution`

### Allowed `match_confidence_band`

`high` · `medium` · `low` · `none`

### Allowed `top_candidate_reasons`

`assigned_to_current_user` · `due_today` · `due_recently` · `strong_title_match` · `weak_title_match` · `recently_active` · `recurring_task` · `last_referenced_entity` · `multiple_weak_matches`

---

## 7. Decision Rules — create_task

| Priority | Condition | Outcome |
|----------|-----------|---------|
| 1 | `task_title` missing | `route` (not enough info) |
| 2 | `assigned_to` missing | `inline` (show member picker) |
| 3 | All fields present and `risk_level == "low"` | `execute` |
| 4 | All fields present and `risk_level == "medium"` | `confirm` |

Risk level: `"low"` for simple tasks, `"medium"` if `due_at` is set.

Current backend clarification:

- parser-owned `task_title`, `notes`, and assignee hints may directly shape the
  created task
- when parsed date-aware reminder structure is present, the backend currently
  prefers routing into the task screen instead of direct execution
- when parsed recurrence structure is present, the backend currently preserves
  `recurrence_every` and `recurrence_unit` in the route payload so the task
  screen can prefill the cadence rather than re-parse the raw text
- this means the parser helps prefill and narrow the task flow, but date-aware
  reminder completion still happens on the task screen

---

## 8. Decision Rules — mark_task_done

| Priority | Condition | Outcome |
|----------|-----------|---------|
| 1 | `resolution.mode == route_for_resolution` | `route` |
| 2 | `resolution.mode == needs_selection` AND `candidate_count <= 3` | `inline` (show task picker) |
| 3 | `resolution.mode == no_match_create_new` | `confirm` ("Create and mark done?") |
| 4 | `resolution.mode == needs_selection` AND `top_candidate_score < confirm_min` | `inline` selection |
| 5 | `resolution.mode == matched_existing` AND `top_candidate_score >= confirm_min` AND `top_candidate_score < auto_execute_min` | `confirm` |
| 6 | `resolution.mode == matched_existing` AND `top_candidate_score >= auto_execute_min` | `execute` |

Risk level: always `"low"` for `mark_task_done`.

---

## 9. Examples

All examples use the shared [module contract envelope](command_router_contract_v1_1.md#9-module-contract-envelope-shared-shape).

### A. Create task — simple ("wash the clothes")

Regex extracts title. No date or assignee patterns → no LLM. `assigned_to` missing → inline picker.

```json
{
  "contract_version": "1.1",
  "request_id": "req_002",
  "source_intent": "create_task",
  "module": "task",
  "status": "missing_fields",
  "missing_fields": ["assigned_to"],
  "risk_level": "low",
  "fields": {
    "task_title": "wash the clothes",
    "assigned_to": null,
    "due_at": null
  },
  "resolution": {
    "mode": "not_applicable"
  },
  "ui_hint": {
    "type": "inline",
    "component": "member_picker",
    "options": [
      { "id": "member_1", "label": "Alex" },
      { "id": "member_2", "label": "Sam" },
      { "id": "member_3", "label": "Jordan" }
    ]
  },
  "summary": "Create task: wash the clothes",
  "policy": {
    "suggested_outcome": "inline",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "task_create_rpc"
  }
}
```

### B. Create task — with assignee and date ("remind Alex to fix the tap by Friday")

Date pattern ("by Friday") and assignee pattern ("Alex") detected → LLM escalation. All fields present.

```json
{
  "contract_version": "1.1",
  "request_id": "req_010",
  "source_intent": "create_task",
  "module": "task",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "medium",
  "fields": {
    "task_title": "fix the tap",
    "assigned_to": "alex_user_id",
    "due_at": "2026-04-17T23:59:59+12:00"
  },
  "resolution": {
    "mode": "not_applicable"
  },
  "ui_hint": {
    "type": "confirm",
    "prefill": {
      "task_title": "fix the tap",
      "assigned_to": "Alex",
      "due_at": "Friday"
    }
  },
  "summary": "Create task: fix the tap — assigned to Alex, due Friday",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": true,
    "executor": "task_create_rpc"
  }
}
```

### C. Mark done — high confidence ("washing completed")

Resolver scores 94 (assigned_to_current_user +40, due_today +30, strong_title_match +30, minus overlap). Score ≥ `auto_execute_min` → execute.

```json
{
  "contract_version": "1.1",
  "request_id": "req_020",
  "source_intent": "mark_task_done",
  "module": "task",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "task_id": "task_123",
    "task_title": "wash the clothes"
  },
  "resolution": {
    "mode": "matched_existing",
    "entity_type": "task",
    "entity_id": "task_123",
    "match_confidence_band": "high",
    "top_candidate_score": 94,
    "top_candidate_reasons": ["assigned_to_current_user", "due_today", "strong_title_match"],
    "candidate_count": 1,
    "requires_user_selection": false
  },
  "ui_hint": {
    "type": "execute"
  },
  "summary": "Mark done: wash the clothes",
  "policy": {
    "suggested_outcome": "execute",
    "requires_confirmation": false,
    "is_executable_now": true,
    "executor": "task_completion_rpc"
  }
}
```

### D. Mark done — medium confidence (score 64)

Score ≥ `confirm_min` but < `auto_execute_min` → confirm.

```json
{
  "contract_version": "1.1",
  "request_id": "req_021",
  "source_intent": "mark_task_done",
  "module": "task",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "task_id": "task_456",
    "task_title": "take out recycling"
  },
  "resolution": {
    "mode": "matched_existing",
    "entity_type": "task",
    "entity_id": "task_456",
    "match_confidence_band": "medium",
    "top_candidate_score": 64,
    "top_candidate_reasons": ["assigned_to_current_user", "weak_title_match"],
    "candidate_count": 2,
    "requires_user_selection": false
  },
  "ui_hint": {
    "type": "confirm",
    "prefill": {
      "task_title": "take out recycling"
    }
  },
  "summary": "Mark done: take out recycling?",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": true,
    "executor": "task_completion_rpc"
  }
}
```

### E. Mark done — low confidence (score 42, 3 candidates)

Score < `confirm_min` → inline selection.

```json
{
  "contract_version": "1.1",
  "request_id": "req_022",
  "source_intent": "mark_task_done",
  "module": "task",
  "status": "ambiguous",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "task_id": null,
    "task_title": null
  },
  "resolution": {
    "mode": "needs_selection",
    "entity_type": "task",
    "entity_id": "task_789",
    "match_confidence_band": "low",
    "top_candidate_score": 42,
    "top_candidate_reasons": ["weak_title_match", "recently_active"],
    "candidate_count": 3,
    "requires_user_selection": true
  },
  "ui_hint": {
    "type": "inline",
    "component": "task_picker",
    "options": [
      { "id": "task_789", "label": "Wash clothes" },
      { "id": "task_790", "label": "Wash towels" },
      { "id": "task_791", "label": "Wash bedding" }
    ]
  },
  "summary": "Which task did you complete?",
  "policy": {
    "suggested_outcome": "inline",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "task_completion_rpc"
  }
}
```

### F. Mark done — no match (0 candidates)

No existing tasks match → confirm create-and-complete.

```json
{
  "contract_version": "1.1",
  "request_id": "req_023",
  "source_intent": "mark_task_done",
  "module": "task",
  "status": "ambiguous",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "task_id": null,
    "task_title": "mow the lawn"
  },
  "resolution": {
    "mode": "no_match_create_new",
    "entity_type": "task",
    "entity_id": null,
    "match_confidence_band": "none",
    "top_candidate_score": 0,
    "top_candidate_reasons": [],
    "candidate_count": 0,
    "requires_user_selection": false
  },
  "ui_hint": {
    "type": "confirm",
    "prefill": {
      "task_title": "mow the lawn"
    }
  },
  "summary": "No matching task found. Create and mark done: mow the lawn?",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": true,
    "executor": "task_create_and_complete_rpc"
  }
}
```
