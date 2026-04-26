---
Domain: Command
Capability: Voice Multi-Item Grocery Capture
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/command/command_grocery_module_v1.md, contracts/api/kinly/homes/shopping_list_api_v1.md
Relates-To: contracts/api/kinly/share/expenses_v2.md
See-Also: contracts/product/kinly/shared/shopping_list_contract_v1.md
---

# Grocery Capture via Command Entry v1

## 1. Purpose

This contract defines the product behavior for grocery capture as the first implemented module slice on top of Kinly's general command entry surface.

The grocery module receives routed command input from text or voice submission and handles its own field extraction, scope resolution, and UI decision (Phase 2) without a second LLM call in the normal path.

**Binding product principle:**

> "Capture first. Refine later."
>
> "Say it once. Kinly structures it."

---

## 2. Scope

### In Scope

- Text or voice command entry for groceries
- Parsing multiple grocery items from a single utterance
- Scope resolution (shared unit vs house)
- Adding items to a grocery list via `shopping_list_api_v1`
- Lightweight confirmation UI when confidence is low

### Out of Scope (Phase 1)

- Advanced categorization (e.g. dairy, produce)
- Smart suggestions (e.g. "organic milk?")
- Store-specific logic
- Inventory tracking
- Auto-removal of items after purchase (handled separately)
- Quantity extraction (see Section 3.3)

---

## 3. Functional Requirements

### 3.1 Voice Capture

User MUST be able to:

- trigger text or voice command entry from the command surface
- trigger voice input via button, widget, or chat interface (future Telegram)
- Speak a natural sentence, e.g.:
  - "Milk, eggs, bread, chicken and apples"
  - "Add milk and eggs"
  - "We need bin liners and toilet paper"

### 3.2 Transcription

System MUST:

- Convert speech → text using a transcription service

Performance target: ≤ 2 seconds. When exceeded:

- System MUST show a loading indicator
- After 5 seconds, system MUST fall back to showing the partial transcript with a manual edit option
- See `command_router_contract_v1_1.md` Section 10 for error envelope (`transcription_timeout`)

### 3.3 Grocery Item Extraction

Technical parsing rules, separator heuristics, and normalization behavior are defined in `command_grocery_module_v1.md`.

Product requirement:

- Voice grocery capture MUST feel fast and low-friction for one or many items
- Ambiguous parses MUST show a confirmation UI rather than silently guessing
- Quantity capture remains out of scope for v1

### 3.4 Scope Resolution

The product experience MUST respect the shopping-list scope chosen by the grocery module. Canonical scope rules live in `command_grocery_module_v1.md` and `shopping_list_api_v1.md`.

### 3.5 Deduplication

The product experience MUST surface duplicate outcomes clearly, for example by labeling an item as already on the list. Canonical deduplication rules live in `command_grocery_module_v1.md` and `shopping_list_api_v1.md`.

### 3.6 Persistence

Persistence is handled by calling `shopping_list_add_item_rpc` as defined in `shopping_list_api_v1.md`. This contract does NOT define storage schema — the API contract owns that.

### 3.7 Response / Feedback

System MUST return immediate feedback.

**Single-intent example:**

> Added 5 items to your grocery list:
> • Milk • Eggs • Bread • Chicken • Apples

**With duplicates:**

> Added 3 items to your grocery list:
> • Bread • Chicken • Apples
> • Milk (already on list)
> • Eggs (already on list)

**Multi-intent example** (when command entry routes grocery + expense):

> Added 2 items to grocery list
> Split $30 with John → confirm?

System MUST include:

- Undo option (soft delete via `shopping_list_api_v1`)
- Edit option (optional UI)

---

## 4. Safety and Trust Rules

### 4.1 No Destructive Actions Without Confirmation

System MUST NOT:

- Remove grocery items automatically
- Overwrite existing list items
- Merge items without user action

### 4.2 Confidence Threshold

If the NLP parser produces fewer items than expected (e.g. a long phrase yields only 1 item), or if the input contains ambiguous separators:

System MUST show confirmation:

> Did you want to add these items?
> • Milk • Eggs • Bread
>
> \[Confirm\] \[Edit\]

This maps to the module contract's deterministic rules: `status == "ambiguous"` → `ui_hint.type` is `confirm` or `inline`, never `execute`.

---

## 5. Architecture

### 5.1 Two-Phase Flow

```
Phase 1 (Command entry + router)
  User says "milk, eggs, bread"
  → command_submit_v1
  → intent: add_grocery_items
  → input text: "milk, eggs, bread"
  → module: grocery

Phase 2 (Grocery Module — NO LLM)
  → NLP splits: ["milk", "eggs", "bread"]
  → Scope lookup: house (no shared unit)
  → Dedup check: no duplicates
  → Status: complete, risk: low
  → UI hint: execute
  → Call shopping_list_add_item_rpc
```

### 5.2 Cost Profile

| Step | Method | Cost |
|------|--------|------|
| Intent classification | LLM (lightweight prompt) | ~$0.001 |
| Item extraction | Regex/NLP | Free |
| Scope resolution | DB lookup | Free |
| Dedup check | DB lookup | Free |

Total: one cheap LLM call per grocery voice command.

---

## 6. Multi-Intent Handling

When command entry detects grocery + another intent (e.g. expense):

1. The grocery module receives the full input text and extracts only grocery items
2. The expense module receives the same input text and extracts only expense fields
3. Each module produces its own module contract independently
4. The batch envelope combines them (see `command_router_contract_v1_1.md` Section 9)

The grocery module MUST ignore expense-related phrases in the input text. It only extracts items that match grocery patterns.

---

## 7. Success Metrics

### Adoption

| Metric | Target |
|--------|--------|
| % of users using voice capture | track |
| Avg items per voice input | track |
| Time to capture | < 3s total |

### Quality

| Metric | Target | Measurement |
|--------|--------|-------------|
| Parsing accuracy | > 90% | Measured against curated test set of 200+ utterances |
| Undo rate | < 5% | Low indicates trust |
| Edit rate | < 10% | Low indicates low friction |
| Duplicate add rate | 0% | Dedup should catch all |

### Engagement

| Metric | Target |
|--------|--------|
| Repeat usage within 7 days | track |
| Shared list interactions | track |

When parsing accuracy drops below 90%, the team MUST review the NLP rules and expand the test set.

---

## 8. Future Extensions (Not in Scope)

- Quantity extraction ("2 litre milk" → `{ item: "milk", qty: 2, unit: "litre" }`)
- Auto reconciliation with expenses
- Smart deduplication across users
- Category grouping
- "Repeat last grocery list"
- Household-level intelligence
