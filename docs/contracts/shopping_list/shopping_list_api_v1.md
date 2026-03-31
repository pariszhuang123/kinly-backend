---
Domain: Homes
Capability: shopping_list
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.6
Audience: internal
Last updated: 2026-03-31
---

# Shopping List API Contract v1.6

Backend RPC shapes and invariants for the shared shopping list. This version
adds item-level scope semantics, scope-aware purchase memory, backend read
filtering, and a versioned add-item response while keeping the legacy
shopping-list RPC family compatibility-stable.

## 1. Entities

### 1.1 `shopping_lists`

- `UNIQUE(home_id) WHERE is_active = true`
- `updated_at` maintained by trigger
- one active list per home remains canonical

### 1.2 `shopping_list_items`

Invariants:
- `is_completed = true` -> `completed_by_user_id` and `completed_at` are not
  null
- `is_completed = false` -> both are null
- `reference_photo_path` once non-null must remain non-null
- `reference_photo_path` must match `households/%` when present
- active views exclude `archived_at IS NOT NULL`
- scope is item-level, not list-level
- `scope_type IN ('house', 'unit')`
- `scope_type = 'house'` -> `unit_id IS NULL`
- `scope_type = 'unit'` -> `unit_id IS NOT NULL`
- completion is item-local; completing a unit-scoped item does not complete any
  house-scoped item
- if a shared unit is archived, open unarchived incomplete items still scoped to
  that unit are automatically reassigned to `house`

Required extension:
- `scope_type text not null default 'house'`
- `unit_id uuid null` FK -> `home_units(id)`

Scope rules:
- shopping-list default scope is `house`
- if caller has no active shared unit, allowed alternate scope is the caller's
  personal unit
- if caller has an active shared unit, allowed alternate scope is that shared
  unit

### 1.3 `shopping_list_purchase_memory`

One row per canonical name per memory bucket.

Required columns:
- `home_id`
- `scope_type`
- `unit_id`
- `canonical_name`
- `display_name`
- `last_purchased_at`
- `last_purchased_by_user_id`
- `warning_window_days`

Invariants:
- `scope_type IN ('house', 'unit')`
- `scope_type = 'house'` -> `unit_id IS NULL`
- `scope_type = 'unit'` -> `unit_id IS NOT NULL`
- `canonical_name` is derived from the item name after trim, lowercase,
  punctuation folding, whitespace collapse, and simple singularisation
- `last_purchased_by_user_id` is the archived item's `completed_by_user_id`
- `warning_window_days` is derived from the canonical name in the current
  implementation
- uniqueness must be enforced per bucket:
  - house bucket on `(home_id, canonical_name)`
  - unit bucket on `(home_id, unit_id, canonical_name)`

Canonicalisation examples:
- `Eggs` and `egg` resolve to the same canonical key
- `paper-towels` and `paper towels` resolve to the same canonical key
- `farmer's eggs` resolves to the canonical key `farmer egg`

## 2. RPCs

All RPCs enforce membership with `public._assert_home_member(p_home_id)` or an
equivalent item-scoped membership join.

### 2.1 `shopping_list_get_for_home_v2(p_home_id uuid, p_scope_type text default NULL, p_unit_id uuid default NULL)`

Returns the active list and caller-visible unarchived items for the home.

Default read behavior:
- no filter params means return caller-visible items across all allowed scopes
- payload includes `scope_type`, `unit_id`, and optional `unit_name`

Filter behavior:
- `p_scope_type IS NULL` and `p_unit_id IS NULL` -> no scope filter
- `p_scope_type = 'house'` -> return only house-scoped items; `p_unit_id` must
  be null
- `p_scope_type = 'unit'` -> return only items for `p_unit_id`; caller must be
  allowed to target that unit

Completion visibility:
- caller sees `is_completed = true` only for items they completed
- items completed by other members are masked as not completed in the read
  response
- `items_uncompleted_count` uses the same masked visibility rule

Ordering:
- uncompleted first, then completed by `completed_at DESC`

Shared-unit collapse:
- if a unit-scoped open item is automatically reassigned to `house` because its
  shared unit was archived, subsequent reads expose it as a normal house-scoped
  item

### 2.2 `shopping_list_add_item(p_home_id uuid, p_name text, p_quantity text default NULL, p_details text default NULL, p_reference_photo_path text default NULL)`

Legacy compatibility RPC.

Behavior:
- lazily creates an active list if missing
- inserts an uncompleted, unarchived item
- validates requested scope against the caller's allowed home-unit scope
- validates photo path and applies photo quota rules as before
- rejects blank names with `invalid_name`

Response shape:
- returns a bare `shopping_list_items` row
- does not return purchase-memory payload

Compatibility note:
- existing callers may continue to use this row-returning RPC unchanged

### 2.3 `shopping_list_add_item_v2(p_home_id uuid, p_name text, p_quantity text default NULL, p_details text default NULL, p_reference_photo_path text default NULL, p_scope_type text default 'house', p_unit_id uuid default NULL)`

Versioned add-item RPC for reminder-aware clients.

Behavior:
- matches `shopping_list_add_item` for validation and insertion
- performs the same purchase-memory lookup after insert
- returns a wrapped payload rather than a bare row:

```json
{
  "item": {
    "id": "uuid",
    "shopping_list_id": "uuid",
    "home_id": "uuid",
    "created_by_user_id": "uuid",
    "name": "Eggs",
    "quantity": "12",
    "details": null,
    "scope_type": "unit",
    "unit_id": "uuid",
    "reference_photo_path": null,
    "reference_added_by_user_id": null,
    "is_completed": false,
    "completed_by_user_id": null,
    "completed_by_avatar_id": null,
    "completed_at": null,
    "linked_expense_id": null,
    "archived_at": null,
    "archived_by_user_id": null,
    "created_at": "2026-03-28T00:00:00.000Z",
    "updated_at": "2026-03-28T00:00:00.000Z"
  },
  "purchase_memory": {
    "last_purchased_at": "2026-03-10T14:22:00.000Z",
    "last_purchased_by_display_name": "Paris",
    "days_since_last_purchase": 13,
    "warning_window_days": 14
  }
}
```

Compatibility note:
- use this RPC only for callers that are ready for the wrapped response shape
- do not silently change legacy callers over in place

Purchase-memory lookup:
- performed after insert
- uses the same bucket as the new item:
  - `house` add -> house memory only
  - `unit` add -> that unit's memory only
- if no matching in-window memory exists, `purchase_memory` is `null`
- lookup is non-blocking; item creation still succeeds if lookup fails

### 2.4 `shopping_list_update_item_v2(p_item_id uuid, p_name text default NULL, p_quantity text default NULL, p_details text default NULL, p_is_completed boolean default NULL, p_reference_photo_path text default NULL, p_replace_photo boolean default false, p_scope_type text default NULL, p_unit_id uuid default NULL)`

Supports rename, quantity/details edit, completion, photo replacement, and
optional re-scoping.

Scope behavior:
- `NULL` `p_scope_type` and `p_unit_id` means no scope change
- `p_scope_type = 'house'` -> effective `unit_id` must resolve to null
- `p_scope_type = 'unit'` -> `p_unit_id` must be a caller-allowed unit

Completion behavior:
- first-completer-wins
- tick on an uncompleted item sets completion to `auth.uid()`
- tick again by the same completer is idempotent
- untick by the same completer clears completion
- tick or untick by a different member when already completed raises
  `item_already_completed_by_other`

Photo behavior:
- same path validation and photo quota rules as current v1
- deletion to null remains forbidden

### 2.5 `shopping_list_prepare_expense_for_user(p_home_id uuid)`

- returns caller-completed, unarchived, unlinked items only
- returns `default_description`, `default_notes`, `item_ids`, and `item_count`
- item scope does not force expense liability mode; shopping-list scope and
  expense liability target remain separate concepts
- expense creation must make an explicit choice between `person_based` and
  `unit_based` allocation where both are supported

### 2.6 `shopping_list_link_items_to_expense_for_user(p_home_id uuid, p_expense_id uuid, p_item_ids uuid[])`

- archives caller-completed items linked to the given expense
- keeps the existing expense ownership and `FOR UPDATE` locking rules
- writes purchase memory for completed archived rows using the item's scope
  bucket

### 2.7 `shopping_list_archive_items_for_user(p_home_id uuid, p_item_ids uuid[])`

- archives caller-completed items without expense linkage
- writes purchase memory for completed archived rows using the item's scope
  bucket

### 2.8 `shopping_list_archive_item(p_item_id uuid)`

- archives a single item after membership validation
- does not require `completed_by_user_id = auth.uid()`
- if the item is completed, writes purchase memory using the item's scope
  bucket
- if the item is uncompleted, writes no memory

### 2.9 Purchase memory UPSERT

Shared side-effect for 2.5, 2.6, and 2.7. Runs in the same transaction as the
archive update.

Rules:
- use only rows actually modified by `UPDATE ... RETURNING`
- ignore rows where `is_completed = false`
- group by bucket plus canonical name:
  - house bucket: `(home_id, scope_type = 'house', canonical_name)`
  - unit bucket: `(home_id, scope_type = 'unit', unit_id, canonical_name)`
- within one bucket, duplicate-named archived rows collapse to one latest
  reminder record update
- for duplicate rows in the same bucket, the latest `created_at` wins for
  `display_name` and `last_purchased_by_user_id`, with `id` ascending as
  tie-break
- UPSERT failure rolls back the archive transaction

## 3. RLS / access control

- `shopping_lists`, `shopping_list_items`, and `shopping_list_purchase_memory`
  are RPC-only with RLS enabled
- direct access for `authenticated` is revoked
- internal quota helpers remain non-executable by `authenticated`

## 4. Error codes

- `invalid_name`
- `invalid_scope_type`
- `invalid_unit_scope`
- `invalid_reference_photo_path`
- `photo_delete_not_allowed`
- `NOT_HOME_MEMBER`
- `item_not_found`
- `item_already_completed_by_other`
- `invalid_expense`
- `PAYWALL_LIMIT_SHOPPING_ITEM_PHOTOS`

## 5. Backend Acceptance Tests

- Add item:
  - house-scoped add succeeds with no `unit_id`
  - unit-scoped add succeeds only for allowed personal/shared unit
  - invalid scope/unit combinations fail with canonical errors
- Read/list:
  - default read returns visible items with scope metadata
  - house filter returns only house-scoped items
  - unit filter returns only items for that allowed unit
- Completion/archive:
  - first-completer-wins is enforced
  - different-member takeover or untick fails with
    `item_already_completed_by_other`
  - archive/link flows write memory only for completed archived rows
- Purchase memory:
  - house-scoped `egg` memory does not affect unit-scoped `egg` memory
  - one shared unit's `farmer's eggs` memory does not warn the wider family
  - duplicate names in one archive batch collapse to one latest reminder record
    update per bucket
  - when a shared unit collapses, open incomplete unit-scoped items are
    reassigned to `house`
- Compatibility:
  - callers and tests are updated for the wrapped `shopping_list_add_item`
    response shape

## 6. Coupling

- Product behavior is defined in
  `docs/contracts/shopping_list/shopping_list_contract_v1.md`
- Architecture invariants are defined in
  `docs/contracts/shopping_list/shopping_list_contract.md`
- Purchase-memory rules are defined in
  `docs/contracts/shopping_list/shopping_list_purchase_memory_v1.md`
- Unit lifecycle and scope permission rules come from
  `docs/contracts/home_units/home_units_api_v1.md` and
  `docs/contracts/home_units/home_units_v1.md`
- Expense allocation remains defined in `docs/contracts/expenses/expenses_v2.md`
