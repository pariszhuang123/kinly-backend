---
Domain: Homes
Capability: shopping_list
Scope: platform
Artifact-Type: architecture
Stability: evolving
Status: draft
Version: v1.3
Last updated: 2026-03-28
---

# Shopping List Architecture Contract v1.3

This architecture contract is aligned to
`docs/contracts/shopping_list/shopping_list_api_v1.md`,
`docs/contracts/shopping_list/shopping_list_contract_v1.md`, and
`docs/contracts/shopping_list/shopping_list_purchase_memory_v1.md`.
It exists to capture cross-layer invariants only.

## 1. Scope

- One active shopping list header per home remains canonical.
- Shopping-list scope is item-level, not list-level:
  - the home has one active list
  - each item may target either `house` or one allowed `unit`
- Purchase memory follows the same sharing boundary as the source item:
  - house-scoped items read and write house-scoped memory
  - unit-scoped items read and write memory for that unit only

## 2. Cross-Layer Invariants

### 2.1 List and item model

- `shopping_lists` keeps `UNIQUE(home_id) WHERE is_active = true`.
- `shopping_list_items` is the only place where shopping scope is stored.
- `shopping_list_items.scope_type IN ('house', 'unit')`.
- `scope_type = 'house'` implies `unit_id IS NULL`.
- `scope_type = 'unit'` implies `unit_id IS NOT NULL`.
- `unit_id` must reference a valid `home_units.id` in the same home.
- Scope selection is constrained by the caller's home-unit state:
  - no active shared unit: allowed scopes are `house` and the caller's personal
    unit
  - active shared unit: allowed scopes are `house` and that shared unit

### 2.2 Completion and archive model

- Completion is single-writer and first-completer-wins.
- A member may complete an uncompleted item or re-submit completion for an item
  they already completed.
- A different member must not take over or clear another member's completion;
  item update must reject that transition with a canonical error.
- "Done shopping" actions remain per-user:
  - bulk archive and expense-link archive operate only on the caller's
    completed items
  - single-item archive may archive another member's completed item, but memory
    attribution still uses the item's `completed_by_user_id`

### 2.3 Purchase memory model

- Purchase memory is scope-aware, not purely home-wide.
- Memory rows belong to one bucket:
  - `house` bucket: `(home_id, scope_type = 'house', canonical_name)`
  - `unit` bucket: `(home_id, scope_type = 'unit', unit_id, canonical_name)`
- The implementation must enforce uniqueness per bucket; a plain unique
  constraint including nullable `unit_id` is not sufficient for house rows.
- `canonical_name` is derived from the item name after lowercase,
  punctuation folding, whitespace collapse, and simple singularisation while
  preserving non-Latin letters and digits for exact-match reminders.
- Memory is written only from completed rows actually archived by the archive
  RPC transaction.
- The current implementation stores latest-purchase recency per bucket rather
  than a cumulative purchase counter.
- Reminder reads use the same scope bucket as the item being added.
- If a shared unit is archived, open unarchived incomplete items still scoped to
  that unit are reassigned to `house`; completed or archived items retain their
  original unit reference historically.

### 2.4 Read and filter model

- Default shopping-list reads return the active list plus caller-visible items
  across allowed scopes, with scope metadata on each item.
- Backend filtering by `house` or by a specific allowed `unit` must be
  supported by the read RPC surface.
- Scope-aware filtering changes which items are returned, not which list header
  is active.

## 3. Shared Infrastructure Rules

- Shopping-item photo quota remains home-level:
  - `public.home_usage_metric` includes `shopping_item_photos`
  - `public.home_usage_counters.shopping_item_photos` tracks active shopping
    item photos
- Shopping list tables and purchase-memory tables are RPC-only with RLS
  enabled.
- Membership and scope validation must be enforced inside security-definer RPCs;
  clients must not be trusted to self-scope.

## 4. Coupling

- Product behavior lives in
  `docs/contracts/shopping_list/shopping_list_contract_v1.md`.
- Backend wire/storage behavior lives in
  `docs/contracts/shopping_list/shopping_list_api_v1.md`.
- Purchase-memory behavior lives in
  `docs/contracts/shopping_list/shopping_list_purchase_memory_v1.md`.
- Home-unit permissions and unit lifecycle live in
  `docs/contracts/home_units/home_units_api_v1.md` and
  `docs/contracts/home_units/home_units_v1.md`.
- Share expense allocation remains defined in
  `docs/contracts/expenses/expenses_v2.md`.
