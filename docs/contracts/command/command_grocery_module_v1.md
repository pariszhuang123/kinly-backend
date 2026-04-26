---
Domain: Command
Capability: Grocery Module
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/homes/shopping_list_api_v1.md
---

# Command Grocery Module Contract v1.0

## 1. Purpose

This module receives the router module input after the router has classified the intent as `add_grocery_items`. The module is responsible for:

- Extracting grocery items from the effective user input in `source.raw_text` or `source.transcript_text`
- Resolving scope (house vs unit)
- Producing a deterministic UI decision

No second LLM call is needed in the typical case (~95%). The router's Phase 1 LLM call has already classified intent; this module performs field extraction using regex/NLP only.

---

## 2. Parsing Strategy

This module uses **Step 1 only** (regex/NLP). No LLM escalation in the normal path.

### Parsing rules

1. Split on commas and pause markers first
2. Trim whitespace from each token
3. Normalize each token to lowercase
4. Split on the word `"and"` only when both sides appear to be standalone grocery noun phrases
5. Preserve protected compound phrases as a single item when they match the module lexicon, for example: `"fish and chips"`, `"peanut butter and jelly"`, `"mac and cheese"`
6. If both one-item and multi-item interpretations remain plausible, mark the parse as ambiguous and require confirmation
7. Discard empty tokens

### LLM escalation (rare, ~5% of cases)

If the parser returns **0 items** from non-empty effective input text, the module MUST escalate to a scoped LLM call (small prompt) to attempt extraction. This is the only condition that triggers escalation.

---

## 3. Field Schema

| Field | Type | Source | Rule |
|-------|------|--------|------|
| `items` | `string[]` | NLP parse of effective input text | Split on commas, pauses, and safe `"and"` boundaries; normalize to lowercase |
| `scope_type` | `string` | Home context DB lookup | `"unit"` if user has active shared unit, else `"house"` |
| `unit_id` | `string?` | Home context DB lookup | Non-null only when `scope_type == "unit"` |

All fields are extracted deterministically. The module MUST NOT guess or hallucinate field values.

---

## 4. Scope Resolution Rules

Scope is determined by a DB lookup against the caller's home context. The module MUST apply these rules:

| Condition | `scope_type` | `unit_id` |
|-----------|-------------|-----------|
| User has an active shared unit | `"unit"` | Shared unit ID |
| User has no shared unit | `"house"` | `null` |

- `scope_type` MUST be one of `"house"` or `"unit"`
- When `scope_type == "house"`, `unit_id` MUST be `null`
- When `scope_type == "unit"`, `unit_id` MUST NOT be `null`

Aligns with `shopping_list_api_v1.md` Section 1.2 scope invariants.

---

## 5. Normalization

The module MUST normalize parsed items before producing output:

- Lowercase all item names
- Discard quantity expressions in v1:
  - `"a dozen eggs"` → `"eggs"`
  - `"2 litre milk"` → `"milk"`
- The effective input text MUST always be preserved verbatim in the module output as `raw_input` for future re-parsing

The module SHOULD NOT attempt to singularize or canonicalize item names beyond lowercase normalization. Canonical name matching is the responsibility of the shopping list backend (see `shopping_list_api_v1.md` Section 1.3).

---

## 6. Deduplication

Before adding items, the module MUST check the active shopping list for existing items with the same canonical name in the resolved scope:

- If an item with the same canonical name already exists on the active list → do NOT add a duplicate
- Include the item in the user-facing feedback as `"(already on list)"`

Aligns with `shopping_list_purchase_memory` deduplication semantics in `shopping_list_api_v1.md` Section 1.3.

---

## 7. Decision Rules

The module produces a deterministic outcome using the following priority-ordered rules. **First match wins.**

| Priority | Condition | `status` | `ui_hint.type` | `policy.suggested_outcome` |
|----------|-----------|----------|----------------|----------------------------|
| 1 | `items` is empty | `no_action` | `"route"` | `"route"` |
| 2 | Parse confidence is low (ambiguous separators or unexpected item count) | `ambiguous` | `"confirm"` | `"confirm"` |
| 3 | `items` parsed successfully | `complete` | `"execute"` | `"execute"` |

- `risk_level` is always `"low"` for grocery items
- The module MUST NOT skip priority levels; evaluation stops at the first match

---

## 8. Examples

All examples show **module output only** (not router output). Output follows the shared envelope defined in `command_router_contract_v1_1.md` Section 9.

### A. Single item — "milk" (house scope, no shared unit)

```json
{
  "contract_version": "1.1",
  "request_id": "req_001",
  "source_intent": "add_grocery_items",
  "module": "grocery",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "items": ["milk"],
    "scope_type": "house",
    "unit_id": null,
    "raw_input": "milk"
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "execute",
    "component": null,
    "target": null,
    "prefill": null,
    "options": []
  },
  "summary": "Added milk to shopping list",
  "policy": {
    "suggested_outcome": "execute",
    "requires_confirmation": false,
    "is_executable_now": true,
    "executor": "shopping_list_add_item_rpc"
  }
}
```

### B. Multi-item — "milk, eggs, bread" (unit scope, user has shared unit)

```json
{
  "contract_version": "1.1",
  "request_id": "req_002",
  "source_intent": "add_grocery_items",
  "module": "grocery",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "items": ["milk", "eggs", "bread"],
    "scope_type": "unit",
    "unit_id": "unit_abc_123",
    "raw_input": "milk, eggs, bread"
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "execute",
    "component": null,
    "target": null,
    "prefill": null,
    "options": []
  },
  "summary": "Added milk, eggs, bread to shopping list",
  "policy": {
    "suggested_outcome": "execute",
    "requires_confirmation": false,
    "is_executable_now": true,
    "executor": "shopping_list_add_item_rpc"
  }
}
```

### C. Low confidence parse — ambiguous separators

```json
{
  "contract_version": "1.1",
  "request_id": "req_003",
  "source_intent": "add_grocery_items",
  "module": "grocery",
  "status": "ambiguous",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "items": ["peanut butter and jelly"],
    "scope_type": "house",
    "unit_id": null,
    "raw_input": "peanut butter and jelly"
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "confirm",
    "component": "grocery_confirm_items",
    "target": null,
    "prefill": {
      "suggested_items": ["peanut butter and jelly"]
    },
    "options": []
  },
  "summary": "Did you mean: peanut butter and jelly?",
  "policy": {
    "suggested_outcome": "confirm",
    "requires_confirmation": true,
    "is_executable_now": false,
    "executor": "none"
  }
}
```

### D. No items detected — empty parse

```json
{
  "contract_version": "1.1",
  "request_id": "req_004",
  "source_intent": "add_grocery_items",
  "module": "grocery",
  "status": "no_action",
  "missing_fields": [],
  "risk_level": "low",
  "fields": {
    "items": [],
    "scope_type": "house",
    "unit_id": null,
    "raw_input": "add some stuff"
  },
  "resolution": {
    "mode": "not_applicable",
    "entity_type": "none"
  },
  "ui_hint": {
    "type": "route",
    "component": null,
    "target": "/shopping-list",
    "prefill": null,
    "options": []
  },
  "summary": "No grocery items detected",
  "policy": {
    "suggested_outcome": "route",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "none"
  }
}
```
