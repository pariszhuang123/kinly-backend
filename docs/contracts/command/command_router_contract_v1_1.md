---
Domain: Command
Capability: Voice and Text Command Router
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.1
Relates-To: contracts/api/kinly/command/command_entry_api_v1.md, contracts/api/kinly/command/command_grocery_module_v1.md, contracts/api/kinly/command/command_expense_module_v1.md, contracts/api/kinly/command/command_task_module_v1.md, contracts/api/kinly/command/command_navigation_module_v1.md, contracts/api/kinly/command/command_ai_quota_v1.md
See-Also: contracts/api/kinly/homes/shopping_list_api_v1.md, contracts/api/kinly/share/expenses_v2.md, contracts/api/kinly/homes/paywall_status_get_v1.md
---

# Kinly Command Router Contract v1.1

## 1. Purpose

This contract defines the **intent classification layer** used inside the command backend after a user says or types something into Kinly.

This is an internal behavior contract for router classification and routing semantics. The client-facing compatibility boundary for command submission lives in `command_entry_api_v1.md`.

The router's ONLY job:

1. **Classify intent** — what does the user want to do?
2. **Route to the correct module(s)** — hand off to module contracts that own field extraction, validation, and resolution

The router does NOT:

- Extract or parse structured fields (module's job)
- Resolve existing entities (module's job)
- Decide public UI outcomes (command runtime's job)
- Know what fields any module requires
- Know how modules parse their input

---

## 2. Architecture

```
User input (voice / text)
        │
        ▼
┌─────────────────────────────────┐
│  Phase 1: Intent Classifier     │  LLM call (lightweight, cheap)
│  "What does the user want?"     │
│  → intent classification        │
└──────────┬──────────────────────┘
           │
           ▼
┌─────────────────────────────────┐
│  Deterministic Router           │  No LLM — intent → module mapping
│  → single or multiple targets   │
└──────────┬──────────────────────┘
           │
     ┌─────┼──────┬───────────┐
     ▼     ▼      ▼           ▼
  Grocery  Task   Expense   Navigation
  Module   Module Module    Module
```

### Why two phases?

| Concern | Single-pass (wrong) | Two-phase (correct) |
|---------|---------------------|---------------------|
| Cost | Full LLM prompt with all possible fields | Call 1 is tiny; module parsing is free or scoped |
| Hallucination | LLM fills currency, participants, scope | LLM only classifies; module gets real data from DB |
| Field rules | Router must know "tasks: 1 assignee, expenses: ≥ 2 participants" | Each module owns its own rules |
| New modules | Router contract must change | Add a new module contract — router stays the same |

---

### AI quota gate

Before the router invokes the classifier LLM, the command entrypoint MUST enforce the AI request quota.

Quota rules:

- Metric name: `ai_command_requests`
- Scope: per user
- Entitlement interaction: if the caller's current home is premium, the free-tier AI quota does not apply
- Window: UTC calendar day
- Reset boundary: `00:00:00 UTC`
- Allowance: backend-configured integer `N`
- Free-tier users MAY create up to `N` AI command requests per UTC calendar day
- Paid users are not subject to the free-tier daily quota, but MAY still be subject to separate abuse-prevention or service-protection rate controls
- Grace overage is NOT allowed

Counting rules:

- Count an AI command request when it is accepted into the classifier pipeline
- The quota charge MUST be idempotent on `request_id` within the same UTC calendar day
- Do NOT count retries caused solely by internal system failure, timeout, or transport failure before classification completes
- Do NOT count `module_continue` follow-up turns that bypass the router/classifier
- Do NOT count a post-upgrade replay of the same blocked request when the replay reuses the original `request_id`
- Low-confidence `unknown` requests still count when they consumed the classifier call
- If quota is exhausted, the system MUST NOT invoke the classifier or any business module

Backend enforcement requirements:

- Quota enforcement MUST happen server-side before the classifier LLM call
- The backend MUST be source-of-truth for allowance, usage, and reset timing
- The backend MUST reject requests over quota even if the client fails to pre-check status
- The backend MUST persist or derive quota state in a way that is safe against concurrent double-charging
- The backend MUST be able to answer: `used`, `limit`, `resets_at`, and whether the current home entitlement bypasses the free quota

### Backend LLM call requirements

The router's classifier LLM call is backend-owned and MUST follow these rules:

- The backend MUST gate the LLM call behind auth, home-context validation, and quota enforcement
- The backend MUST use the router contract as the canonical output schema for classification
- The backend MUST pass a stable `request_id` through quota, logging, and downstream module invocations
- The backend MUST log classifier failures, timeouts, and low-confidence unknowns for observability and feature discovery
- The backend MUST NOT allow client-supplied classification results to bypass server classification
- The backend MUST bound model cost and latency with a lightweight prompt suitable for intent classification only
- The backend SHOULD record model/provider version metadata in audit logs for later evaluation
- The backend SHOULD apply abuse controls separately from entitlement quota, for example burst rate limits or anomaly throttles

Quota exhaustion outcome:

- Return a paywall-cap error to the client
- The client opens the same premium paywall used for other capped features
- The response SHOULD include the metric name and next reset boundary so the UI can explain that access resets tomorrow
- If the client retries after upgrade, it SHOULD replay the original request using the same `request_id`

---

## 3. Router Output Shape

This is the ONLY output the router produces.

```json
{
  "contract_version": "1.1",
  "source": { ... },
  "classification": {
    "intent": "...",
    "confidence": "...",
    "intents_detected": [ ... ]
  },
  "routing": {
    "module": "...",
    "is_multi_intent": false,
    "modules_targeted": [ ... ]
  },
  "audit": {
    "router_version": "command-router-v1",
    "schema_version": "1.1"
  }
}
```

---

## 4. `source`

| Field              | Type     | Description                              |
|--------------------|----------|------------------------------------------|
| `input_mode`       | string   | `"text"` or `"voice"`                    |
| `raw_text`         | string   | Original typed text (empty for voice)    |
| `transcript_text`  | string?  | STT output (null for text)               |
| `user_id`          | string   | Current authenticated user               |
| `home_id`          | string   | Current home context                     |
| `timezone`         | string   | IANA timezone, e.g. `"Pacific/Auckland"` |
| `locale`           | string   | Language/region hint, e.g. `"en-NZ"`     |
| `client_timestamp` | string   | ISO 8601 with offset                     |
| `request_id`       | string   | Unique ID for idempotency                |

Modules receive the full `source` object. The effective user input is `source.raw_text` (for text) or `source.transcript_text` (for voice).

### Allowed `input_mode`

```json
["text", "voice"]
```

---

## 5. `classification`

The LLM's output — intent classification only.

| Field              | Type     | Description                                          |
|--------------------|----------|------------------------------------------------------|
| `intent`           | string   | Primary detected intent                              |
| `confidence`       | string   | `"high"`, `"medium"`, `"low"`                        |
| `intents_detected` | array    | All intents detected (for multi-intent utterances)   |

### Allowed intents

```json
[
  "add_grocery_items",
  "create_task",
  "mark_task_done",
  "create_reminder",
  "create_expense",
  "open_house_norms",
  "view_due_items",
  "view_service",
  "unknown"
]
```

### Low confidence handling

When `confidence == "low"` and `intent == "unknown"`:

1. Route to `navigation` module (fallback to home)
2. Log the input to `unrecognized_intents` table with: `request_id`, `user_id`, `home_id`, `input_mode`, `raw_text`/`transcript_text`, `locale`, `timezone`, `confidence`, `router_version`, `timestamp`
3. Return structured fallback metadata so the client can render deterministic localized unsupported-command copy and a list of supported capabilities
4. Do NOT spend a second LLM call generating a custom apology or unsupported-feature explanation

The `unrecognized_intents` table enables feature discovery — patterns in unrecognized inputs reveal features users want but Kinly doesn't have yet.

When `confidence == "low"` and `intent` is a supported intent:

- The router MAY still route to that module
- The module MUST NOT auto-execute solely because the router named an intent
- The module MUST downgrade the outcome to `inline`, `confirm`, or `route` unless its own deterministic rules reach a safe non-destructive action
- Low router confidence MUST NOT bypass module validation, ambiguity checks, or confirmation rules

### Multi-intent detection

When the classifier detects multiple intents in one utterance:

- `intents_detected` contains all detected intents
- `is_multi_intent` is `true`
- Each intent maps to its module via the intent → module table

Example: "Add milk and eggs, and I paid $30 for groceries with John"

```json
{
  "intent": "add_grocery_items",
  "confidence": "high",
  "intents_detected": ["add_grocery_items", "create_expense"]
}
```

### Same-module multi-intent

When multiple intents map to the SAME module (e.g. "wash clothes and take out bins" = two `create_task`), the router sends it to the module ONCE. The module is responsible for detecting and handling multiple items from the input internally.

This keeps the router thin — it does not segment utterances.

Public runtime rule:

- the router MAY detect multiple intents internally
- command entry v1 still returns exactly one public result
- the public single-result selection is owned by the command runtime, not the router contract
- if the command runtime downgrades a multi-intent request to `confirm`, it
  MUST do so before any side-effecting module execution

---

## 6. `routing`

Deterministic mapping from intent to module. No LLM involved.

| Field              | Type     | Description                                    |
|--------------------|----------|------------------------------------------------|
| `module`           | string   | Primary target module                          |
| `is_multi_intent`  | boolean  | Whether multiple modules will be invoked       |
| `modules_targeted` | array    | All modules to invoke (matches `intents_detected`) |

### Intent → Module mapping

| Intent | Module | Module contract |
|--------|--------|-----------------|
| `add_grocery_items` | `grocery` | `command_grocery_module_v1.md` |
| `create_task` | `task` | `command_task_module_v1.md` |
| `mark_task_done` | `task` | `command_task_module_v1.md` |
| `create_reminder` | `task` | `command_task_module_v1.md` |
| `create_expense` | `expense` | `command_expense_module_v1.md` |
| `open_house_norms` | `navigation` | `command_navigation_module_v1.md` |
| `view_due_items` | `navigation` | `command_navigation_module_v1.md` |
| `view_service` | `navigation` | `command_navigation_module_v1.md` |
| `unknown` | `navigation` | `command_navigation_module_v1.md` (fallback route) |

---

## 7. Module Input

Every module receives the same input shape:

```json
{
  "source": { ... },
  "source_intent": "create_task",
  "request_id": "req_001"
}
```

| Field          | Type   | Description |
|----------------|--------|-------------|
| `source`       | object | Full `source` from router output (user_id, home_id, timezone, locale, raw_text, transcript_text, etc.) |
| `source_intent`| string | The specific intent this module invocation is for |
| `request_id`   | string | From `source.request_id` — for idempotency and linking |

The effective user input is `source.raw_text` (for text input) or `source.transcript_text` (for voice input). The module reads whichever is non-null.

---

## 8. Module Output Envelope (shared shape)

All modules produce output following this shared envelope. Field schemas, resolution logic, and decision rules are defined in each module's own contract.

```json
{
  "contract_version": "1.1",
  "request_id": "...",
  "source_intent": "...",
  "module": "...",
  "status": "...",
  "missing_fields": [],
  "risk_level": "...",
  "fields": { ... },
  "resolution": { ... },
  "ui_hint": { ... },
  "summary": "...",
  "policy": { ... }
}
```

### `status`

| Value            | Meaning                                |
|------------------|----------------------------------------|
| `complete`       | Module has enough info to act          |
| `missing_fields` | Fields are partially extracted         |
| `ambiguous`      | Cannot resolve entity / interpretation |
| `no_action`      | Module found nothing relevant          |

### `ui_hint`

| Field       | Type    | Description                                          |
|-------------|---------|------------------------------------------------------|
| `type`      | string  | `"execute"`, `"inline"`, `"confirm"`, `"route"`      |
| `component` | string? | UI component to render (module-specific)             |
| `target`    | string? | Deep link path (only when `type == "route"`)         |
| `prefill`   | object? | Draft values for the UI                              |
| `options`   | array   | Choices for inline pickers: `[{ "id": "...", "label": "..." }]` |

#### `ui_hint.type` meanings

| Type | Meaning | User experience |
|------|---------|-----------------|
| `execute` | All fields present, low risk — act immediately on behalf of the user | No user interaction needed |
| `inline` | One specific field needed — show a picker/input to complete it | Quick tap to finish |
| `confirm` | All fields present but needs user sign-off before acting | User reviews and confirms |
| `route` | Too complex for inline — navigate to the full page for the user to complete | Deep link with prefilled data |

### `policy`

| Field                  | Type    | Description                                    |
|------------------------|---------|------------------------------------------------|
| `suggested_outcome`    | string  | `"execute"`, `"inline"`, `"confirm"`, `"route"` — MUST match `ui_hint.type` |
| `requires_confirmation`| boolean | Whether user must explicitly confirm           |
| `is_executable_now`    | boolean | Whether all required fields are present        |
| `executor`             | string  | Target RPC. `"none"` when `status` is `no_action` or type is `route` |

`policy.suggested_outcome` MUST use one of: `"execute"`, `"inline"`, `"confirm"`, `"route"`. No module-specific values.

---

## 9. Multi-Intent Handling

### Routing

The router invokes ONLY the modules listed in `modules_targeted` — not all modules in the system. Each targeted module receives the full `source` and extracts only its relevant parts, ignoring the rest.

### Module no-action

If a module receives input but finds nothing relevant to extract, it returns:

```json
{
  "module": "grocery",
  "status": "no_action"
}
```

`no_action` modules are excluded from the batch response.

### Batch envelope

```json
{
  "contract_version": "1.1",
  "request_id": "req_abc",
  "is_batch": true,
  "modules": [
    { "module": "grocery", ... },
    { "module": "expense", ... }
  ]
}
```

The generic fallback shown above does NOT apply to `paywall_ai_command_daily_limit`.

### Batch execution rules

- Each module contract is evaluated independently
- If ANY module requires `confirm`, the batch shows a combined confirmation
- Grocery can `execute` while expense awaits `confirm` — partial success is allowed
- Undo applies per-module

---

## 10. Inline Continuation (Conversation Turns)

When a module returns `ui_hint.type == "inline"` and the user responds (e.g. picks an assignee from the inline picker), the client sends a `module_continue` request **directly to the module** — no re-classification through the router.

### `module_continue` input

```json
{
  "request_id": "req_001",
  "source_intent": "create_task",
  "module": "task",
  "prefilled_fields": {
    "task_title": "Wash the clothes"
  },
  "user_selection": {
    "field": "assigned_to",
    "value": "user_alex"
  }
}
```

The module merges `prefilled_fields` + `user_selection`, re-evaluates its decision rules, and produces a new module output. If all fields are now present, the module returns `status: "complete"` with `ui_hint.type` of `execute` or `confirm` depending on risk.

This avoids:
- Re-classifying intent (already known)
- Re-running the LLM (not needed)
- Losing context from the first turn

---

## 11. Error Envelope

```json
{
  "contract_version": "1.1",
  "request_id": "req_abc",
  "error": {
    "code": "...",
    "message": "...",
    "fallback": {
      "ui_hint": {
        "type": "route",
        "target": "/home"
      }
    }
  }
}
```

| Code | When |
|------|------|
| `classification_failed` | LLM could not classify intent |
| `transcription_failed` | STT returned empty or failed |
| `transcription_timeout` | STT exceeded timeout (show partial transcript + manual edit) |
| `paywall_ai_command_daily_limit` | Free-tier user has exhausted daily `ai_command_requests` quota |
| `module_error` | Module-level failure during field extraction |

For `paywall_ai_command_daily_limit`:

- the client MUST open the premium paywall rather than route to `/home`
- the backend SHOULD include quota context such as `metric` and `resets_at`
- the client SHOULD preserve the blocked command payload for deterministic replay after upgrade

---

## 12. Examples

Examples show ONLY router output. Module output examples live in each module's contract.

### A. Single intent — "milk"

```json
{
  "contract_version": "1.1",
  "source": {
    "input_mode": "text",
    "raw_text": "milk",
    "transcript_text": null,
    "user_id": "current_user",
    "home_id": "current_home",
    "timezone": "Pacific/Auckland",
    "locale": "en-NZ",
    "client_timestamp": "2026-04-11T10:15:00+12:00",
    "request_id": "req_001"
  },
  "classification": {
    "intent": "add_grocery_items",
    "confidence": "high",
    "intents_detected": ["add_grocery_items"]
  },
  "routing": {
    "module": "grocery",
    "is_multi_intent": false,
    "modules_targeted": ["grocery"]
  },
  "audit": {
    "router_version": "command-router-v1",
    "schema_version": "1.1"
  }
}
```

### B. Multi-intent — "Add milk and eggs, and I paid $30 for groceries with John"

```json
{
  "contract_version": "1.1",
  "source": {
    "input_mode": "voice",
    "raw_text": "",
    "transcript_text": "Add milk and eggs, and I paid $30 for groceries with John",
    "user_id": "current_user",
    "home_id": "current_home",
    "timezone": "Pacific/Auckland",
    "locale": "en-NZ",
    "client_timestamp": "2026-04-11T10:15:00+12:00",
    "request_id": "req_002"
  },
  "classification": {
    "intent": "add_grocery_items",
    "confidence": "high",
    "intents_detected": ["add_grocery_items", "create_expense"]
  },
  "routing": {
    "module": "grocery",
    "is_multi_intent": true,
    "modules_targeted": ["grocery", "expense"]
  },
  "audit": {
    "router_version": "command-router-v1",
    "schema_version": "1.1"
  }
}
```

### C. Low confidence unknown — logged for feature discovery

```json
{
  "contract_version": "1.1",
  "source": {
    "input_mode": "text",
    "raw_text": "what's the weather",
    "transcript_text": null,
    "user_id": "current_user",
    "home_id": "current_home",
    "timezone": "Pacific/Auckland",
    "locale": "en-NZ",
    "client_timestamp": "2026-04-11T10:15:00+12:00",
    "request_id": "req_003"
  },
  "classification": {
    "intent": "unknown",
    "confidence": "low",
    "intents_detected": ["unknown"]
  },
  "routing": {
    "module": "navigation",
    "is_multi_intent": false,
    "modules_targeted": ["navigation"]
  },
  "audit": {
    "router_version": "command-router-v1",
    "schema_version": "1.1"
  }
}
```

Side effect: logged to `unrecognized_intents` table for feature discovery.

---

## 13. Design Principles

1. **Router is thin** — classify intent + route. Nothing else.
2. **Modules own everything else** — fields, validation, resolution, scoring, UI decisions, parsing strategy.
3. **Multi-intent = same source to targeted modules** — each module extracts only what's relevant.
4. **Same-module multi-intent = module's responsibility** — the module handles splitting internally.
5. **No guessing** — the router never infers values. Modules get real data from DB lookups.
6. **Errors have a shape** — client always knows valid contract vs failure.
7. **New modules don't change the router** — add a new intent + module mapping, create a new module contract.
8. **Low confidence = feature discovery** — unrecognized inputs are logged, not discarded.
9. **Inline continuation skips the router** — second turn goes directly to the module with prefilled fields.
