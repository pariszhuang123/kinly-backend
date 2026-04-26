---
Domain: Command
Capability: Expense Module
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/share/expenses_v2.md
---

# Command Expense Module Contract v1.0

## 1. Purpose

This module receives router module input with `source_intent: "create_expense"` and extracts expense/bill fields. It produces a module envelope that the executor layer uses to create an expense via the expenses RPC contract.

This module often requires a second LLM call (scoped prompt) because amount and participant extraction from natural language frequently needs structured understanding.

However, the module SHOULD still prefer deterministic continuation when the user is responding to a constrained follow-up, such as selecting from explicit options or confirming a previously extracted draft.

---

## 2. Parsing Strategy

Initial freeform expense extraction is normally **Step 2** (LLM, scoped prompt). The module does not rely on a regex-only shortcut for the first freeform parse.

For follow-up turns:

- deterministic merge/revalidation SHOULD be used when the user is selecting or confirming from structured options
- a scoped LLM MAY be used when a follow-up freeform reply is still too ambiguous or complex for deterministic parsing
- any such follow-up LLM use remains part of the same command thread and does not imply an additional user-visible AI quota charge

The LLM prompt is small and tightly scoped:

> "From this text, extract: amount, category, participants, who paid."

The LLM returns raw extracted values only. Currency, membership validation, and split resolution are handled deterministically by the module — NEVER by the LLM.

### LLM extraction schema

The LLM MUST return a JSON object in this exact shape:

```json
{
  "amount": 84,
  "category": "groceries",
  "participant_tokens": ["all_scope_members"],
  "paid_by_token": "current_user",
  "allocation_target_type": "debtor_based",
  "split_mode": "equal",
  "custom_splits": []
}
```

Schema rules:

- `amount` is a number or `null`
- `category` is a string or `null`
- `participant_tokens` is an array of raw participant references or canonical tokens
- `paid_by_token` is a raw payer reference or canonical token
- `allocation_target_type` MUST be one of `"debtor_based"` or `"unit_based"` when the user stated the target mode; otherwise `null`
- `split_mode` MUST be one of `"equal"` or `"custom"` when the user stated the split style; otherwise `null`
- `custom_splits` is an array of `{ "token": string, "amount": number|null, "percent": number|null }`

The module MUST normalize synonymous phrases before validation:

- `"everyone"`, `"everybody"`, `"all"`, `"all of us"`, `"the whole house"` -> `all_scope_members`
- `"me"`, `"I"`, `"myself"` -> `current_user`
- Percentage-based utterances MAY be converted by the module into custom exact amounts before RPC execution

---

## 3. Field Schema

| Field | Type | Source | Rule |
|-------|------|--------|------|
| `amount` | number | LLM extraction | Required — MUST be explicitly stated by user. If not stated, `status = missing_fields` |
| `currency` | string | Home settings DB lookup | NEVER from LLM. NEVER guessed. Always from home configuration |
| `category` | string? | LLM extraction | Optional, e.g. `"groceries"`, `"utilities"` |
| `allocation_target_type` | string | LLM extraction + module defaults | MUST be `"debtor_based"` or `"unit_based"` before execution |
| `split_mode` | string | LLM extraction + module defaults | MUST map to downstream `ExpenseSplitType` values `"equal"` or `"custom"` |
| `participants` | string[] | LLM extraction + membership validation | Min 2 debtors for `debtor_based`; `all_scope_members` resolves via module rules |
| `unit_ids` | string[] | Unit resolution | Used only when `allocation_target_type == "unit_based"` |
| `paid_by` | string | LLM extraction or default | Defaults to `current_user` if not stated |
| `custom_splits` | object[] | LLM extraction + module derivation | Required when `split_mode == "custom"` |

---

## 4. Split Rules

> **This section is critical for correct expense creation.**

- The module MUST align with `expenses_v2.md`:
  - `allocation_target_type = "debtor_based"` targets individual home members
  - `allocation_target_type = "unit_based"` targets one or more home units
- The backend MUST NOT infer allocation mode from shopping-list scope or active shared-unit membership
- If the user explicitly indicates unit-based splitting, the module MUST resolve concrete `unit_ids`
- If the user explicitly indicates individual splitting, the module MUST resolve concrete member IDs
- If the user uses `all_scope_members` without specifying target mode:
  - default to `debtor_based`
  - resolve to all current home members
- `paid_by` MUST be included in debtor-based participant resolution when the payer shares the expense
- Minimum 2 debtors required for debtor-based equal or custom splits
- Unit-based allocation MAY target a shared unit plus one or more personal units, for example `50%` to a couple unit and `25%` each to two individual units
- Internal cost sharing inside a shared unit remains out of scope; the unit is the debtor
- Owner is NOT excluded from splits

### Percentage to exact amount conversion

If the user expresses percentages, the module MAY parse them but MUST convert them into exact custom amounts before execution.

Conversion rules:

- Percentages MUST sum to `100`
- Conversion MUST happen in minor currency units
- Round down each share except the last
- Assign any remainder to the last share so the total matches the stated amount exactly
- The outgoing RPC payload still uses downstream `split_mode = "custom"`

---

## 5. Validation Rules

- `amount` MUST be > 0
- `amount` MUST be explicitly stated (MUST NOT be inferred)
- `currency` MUST come from home settings (MUST NOT be guessed or LLM-extracted)
- `allocation_target_type` MUST be chosen before execution
- `split_mode` MUST be chosen before execution
- For `debtor_based`, `participants.length` MUST be >= 2
- For `debtor_based`, `paid_by` MUST be in `participants` when payer shares the bill
- If `participants` includes non-members of the home -> `status = ambiguous`
- For `unit_based`, every `unit_id` MUST belong to the same home and be active
- For `split_mode == "custom"`, exact amounts MUST sum to the total amount

---

## 6. Decision Rules

Deterministic, priority-ordered. First match wins.

| Priority | Condition | Outcome |
|----------|-----------|---------|
| 1 | `amount` is missing | `missing_fields` -> `inline` (ask for amount) |
| 2 | `allocation_target_type` or `split_mode` cannot be resolved safely | `ambiguous` -> `confirm` or `route` |
| 3 | Participants or unit targets cannot be resolved | `ambiguous` -> `inline` or `route` |
| 4 | `status == complete` (all fields present and valid) | `confirm` (ALWAYS) |

`risk_level` is ALWAYS `"high"` for expenses. Expenses MUST ALWAYS require confirmation, regardless of confidence. Auto-execute is never permitted.

---

## 7. Examples

### A. Complete expense with shared unit

User says: `"groceries 84 split all"`

Home has a shared unit `unit_abc_123` with members represented as a unit debtor

```json
{
  "contract_version": "1.1",
  "request_id": "req_exp_001",
  "source_intent": "create_expense",
  "module": "expense",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "high",
  "fields": {
    "amount": 84,
    "currency": "NZD",
    "category": "groceries",
    "allocation_target_type": "unit_based",
    "split_mode": "equal",
    "participants": [],
    "unit_ids": ["unit_abc_123"],
    "paid_by": "user_A",
    "custom_splits": []
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "confirm",
    "component": "expense_confirm_card",
    "prefill": {
      "amount": 84,
      "currency": "NZD",
      "category": "groceries",
      "allocation_target_type": "unit_based",
      "split_mode": "equal",
      "participants": [],
      "unit_ids": ["unit_abc_123"],
      "paid_by": "user_A",
      "split_source": "unit_based"
    }
  },
  "summary": "Split $84 groceries to the selected shared unit",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": true,
    "executor": "expense_create_rpc"
  }
}
```

### B. Complete expense without shared unit

User says: `"internet 120 split all"`

Home has no explicit unit target. Home members: `[user_A, user_B, user_C, user_D]`

```json
{
  "contract_version": "1.1",
  "request_id": "req_exp_002",
  "source_intent": "create_expense",
  "module": "expense",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "high",
  "fields": {
    "amount": 120,
    "currency": "NZD",
    "category": "utilities",
    "allocation_target_type": "debtor_based",
    "split_mode": "equal",
    "participants": ["user_A", "user_B", "user_C", "user_D"],
    "unit_ids": [],
    "paid_by": "user_A",
    "custom_splits": []
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "confirm",
    "component": "expense_confirm_card",
    "prefill": {
      "amount": 120,
      "currency": "NZD",
      "category": "utilities",
      "allocation_target_type": "debtor_based",
      "split_mode": "equal",
      "participants": ["user_A", "user_B", "user_C", "user_D"],
      "unit_ids": [],
      "paid_by": "user_A",
      "split_source": "home_members"
    }
  },
  "summary": "Split $120 internet evenly between 4 home members",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": true,
    "executor": "expense_create_rpc"
  }
}
```

### C. Missing amount

User says: `"split groceries with John"`

```json
{
  "contract_version": "1.1",
  "request_id": "req_exp_003",
  "source_intent": "create_expense",
  "module": "expense",
  "status": "missing_fields",
  "missing_fields": ["amount"],
  "risk_level": "high",
  "fields": {
    "amount": null,
    "currency": "NZD",
    "category": "groceries",
    "allocation_target_type": "debtor_based",
    "split_mode": "equal",
    "participants": ["user_A", "user_john"],
    "unit_ids": [],
    "paid_by": "user_A",
    "custom_splits": []
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "inline",
    "component": "expense_amount_input",
    "prefill": {
      "category": "groceries",
      "allocation_target_type": "debtor_based",
      "split_mode": "equal",
      "participants": ["user_A", "user_john"],
      "unit_ids": [],
      "paid_by": "user_A"
    }
  },
  "summary": "How much was the groceries?",
  "policy": {
    "suggested_outcome": "inline",
    "requires_confirmation": true,
    "is_executable_now": false,
    "executor": "expense_create_rpc"
  }
}
```

### D. Ambiguous participants

User says: `"paid $50 split with someone"`

```json
{
  "contract_version": "1.1",
  "request_id": "req_exp_004",
  "source_intent": "create_expense",
  "module": "expense",
  "status": "ambiguous",
  "missing_fields": [],
  "risk_level": "high",
  "fields": {
    "amount": 50,
    "currency": "NZD",
    "category": null,
    "allocation_target_type": null,
    "split_mode": null,
    "participants": [],
    "unit_ids": [],
    "paid_by": "user_A",
    "custom_splits": []
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "inline",
    "component": "expense_participant_picker",
    "prefill": {
      "amount": 50,
      "currency": "NZD",
      "paid_by": "user_A"
    },
    "options": []
  },
  "summary": "Who should this be split with?",
  "policy": {
    "suggested_outcome": "inline",
    "requires_confirmation": true,
    "is_executable_now": false,
    "executor": "expense_create_rpc"
  }
}
```
