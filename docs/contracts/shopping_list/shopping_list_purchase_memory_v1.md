---
Domain: Homes
Capability: shopping_list
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.5
Audience: internal
Last updated: 2026-04-11
---

# Shopping List Purchase Memory Contract v1.5

## 1. Purpose & scope

- Build a lightweight purchase-memory layer on top of the existing shopping
  list so the home accumulates knowledge about what has been bought before,
  when, and how often.
- Use this memory to surface gentle reminders when a member adds an item that
  was recently purchased within the same sharing boundary.
- This contract covers the memory data model, warning-window logic, reminder
  rules, and integration points with shopping-list RPCs.
- It does NOT cover budgeting, price tracking, receipt OCR, or full grocery
  taxonomy.

## 2. Goals

- Reduce accidental overbuying at the scope where stock is actually shared.
- Keep memory passive: latest-purchase recency is derived from archive flows
  with no extra user input.
- Keep reminders non-blocking and soft.
- Allow the same item name to have different memory buckets for `House` and
  unit-scoped shopping.

## 3. Non-goals

- Cross-home memory.
- Cross-scope memory merging in v1.
- Fuzzy matching, synonym expansion, or AI classification in v1.
- Auto-reorder, quantity prediction, or replenishment automation.

## 4. Data model

### 4.1 `shopping_list_purchase_memory`

One row per unique canonical item name per memory bucket, storing the latest
known purchase in that bucket.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK, auto-generated |
| `home_id` | uuid | NOT NULL | FK -> homes, ON DELETE CASCADE |
| `scope_type` | text | NOT NULL | `house` or `unit` |
| `unit_id` | uuid | NULL | FK -> `home_units(id)` when `scope_type = 'unit'`; null for `house` |
| `canonical_name` | text | NOT NULL | Normalised item name at archive time after trim, lowercase, punctuation folding, whitespace collapse, and simple singularisation |
| `display_name` | text | NOT NULL | Most recent casing/spelling used in this bucket |
| `last_purchased_at` | timestamptz | NOT NULL | Timestamp of most recent archive event in this bucket |
| `last_purchased_by_user_id` | uuid | NOT NULL | Item completer, not archiver |
| `warning_window_days` | integer | NOT NULL | Derived from the canonical name at upsert time |
| `created_at` | timestamptz | NOT NULL | Row creation time |
| `updated_at` | timestamptz | NOT NULL | Trigger-maintained |

Constraints:
- `scope_type IN ('house', 'unit')`
- `scope_type = 'house'` implies `unit_id IS NULL`
- `scope_type = 'unit'` implies `unit_id IS NOT NULL`
- `CHECK (canonical_name <> '')`
- `CHECK (warning_window_days >= 1)`
- `home_id` FK -> `homes(id)` with `ON DELETE CASCADE`
- `unit_id` FK -> `home_units(id)` with `ON DELETE CASCADE`
- `last_purchased_by_user_id` has no FK constraint; display-name resolution is a
  nullable `LEFT JOIN` to `profiles`

Uniqueness:
- House bucket uniqueness MUST be enforced for
  `(home_id, canonical_name)` where `scope_type = 'house'`
- Unit bucket uniqueness MUST be enforced for
  `(home_id, unit_id, canonical_name)` where `scope_type = 'unit'`
- A single nullable unique key across `(home_id, scope_type, unit_id,
  canonical_name)` is not sufficient by itself for house rows

Access model:
- RLS enabled, direct access revoked for `authenticated`
- All reads and writes are RPC-only
- Reminder lookup is scoped to the target bucket of the item being added

### 4.2 Canonicalisation rules

- Start from `lower(btrim(shopping_list_items.name))`
- Replace punctuation and separators, including characters such as `-` and `'`,
  with spaces
- Collapse repeated whitespace to a single space and trim again
- Apply simple token-level singularisation so common plural variants map to the
  same key, for example:
  - `eggs` -> `egg`
  - `tomatoes` -> `tomato`
  - `paper-towels` -> `paper towel`
  - `farmer's eggs` -> `farmer egg`
- Reminder matching is still deterministic exact match on the resulting
  canonical key
- No synonym mapping or fuzzy similarity in v1

### 4.3 Warning window defaults

`warning_window_days` is derived from the canonical name. If no explicit match
exists, fallback is `14` days.

#### 7 days

`milk`, `bread`, `banana`, `lettuce`, `tomato`, `chicken`, `egg`

#### 30 days

`toilet paper`, `paper towel`

#### 60 days

`pasta`, `rice`, `flour`, `sugar`

#### Fallback

Any unmatched canonical name defaults to `14` days.

The current implementation rewrites `warning_window_days` from the canonical
name on upsert, which is behaviorally stable for unchanged canonical names.

## 5. When memory is written

Memory writes are a side-effect of shopping-list archive flows:

- `shopping_list_archive_items_for_user`
- `shopping_list_link_items_to_expense_for_user`
- `shopping_list_archive_item`

### 5.1 Write rules

For each archived row where `is_completed = true`:

1. Derive bucket from the archived item:
   - `house` item -> `scope_type = 'house'`, `unit_id = null`
   - `unit` item -> `scope_type = 'unit'`, `unit_id = item.unit_id`
2. Derive `canonical_name` from the archived item name.
3. Group rows within the same archive call by bucket plus `canonical_name`.
4. UPSERT one memory row per distinct group:
   - insert: initialize latest-purchase timestamp, display name, completer, and
     warning window
   - update: refresh latest-purchase fields for that bucket

### 5.2 Attribution

`last_purchased_by_user_id` MUST come from `completed_by_user_id` on the
archived item, not `auth.uid()`.

### 5.3 Transactional integrity

- Memory UPSERTs MUST run in the same transaction as the archive update.
- UPSERTs MUST be driven from rows actually modified by `UPDATE ... RETURNING`.
- UPSERT failure rolls back the archive transaction.

### 5.4 Exclusions

- Uncompleted archived rows do not write memory.
- Historical backfill is out of scope for v1.

## 6. When memory is read

### 6.1 Trigger: adding an item

When a member adds an item via the add-item RPC family, the backend MUST look
up purchase memory in the same target bucket as the new item:

- `house` add -> house memory only
- `unit` add -> that `unit_id` memory only

The backend MUST NOT fall back from unit memory to house memory in v1.

Wire-shape note:
- legacy `shopping_list_add_item` may remain row-returning for compatibility
- existing `shopping_list_add_item_v2` may remain the wrapped-response RPC
  without confirmation semantics
- `shopping_list_add_item_v3` is the reminder-aware RPC for the confirmation
  flow
- `shopping_list_add_item_v3` SHOULD support a confirmation parameter so the
  same RPC can be called twice:
  - first call: check + maybe block creation
  - second call: explicit confirmed create

Recommended RPC shape:
- `shopping_list_add_item_v3(..., p_confirm_recent_purchase boolean default false)`

If a bucket match exists and `days_since_last_purchase < warning_window_days`
and `p_confirm_recent_purchase = false`, the RPC MUST NOT create the item.
Instead it returns a reminder payload plus a confirmation requirement:

```json
{
  "item": null,
  "needs_confirmation": true,
  "purchase_memory": {
    "last_purchased_at": "2026-03-10T14:22:00.000Z",
    "last_purchased_by_display_name": "Paris",
    "days_since_last_purchase": 13,
    "warning_window_days": 14
  }
}
```

If there is no in-window match, or if `p_confirm_recent_purchase = true`, the
RPC creates the item and returns:

```json
{
  "item": {
    "id": "uuid"
  },
  "needs_confirmation": false,
  "purchase_memory": null
}
```

If the caller confirms after a warning, the second call SHOULD still include
the same `purchase_memory` payload in the response for informational use, but
`needs_confirmation` MUST be `false` and the item MUST be created.

Field notes:
- `days_since_last_purchase` is computed server-side
- `last_purchased_by_display_name` is nullable
- `needs_confirmation = true` means no row was created
- dialog dismissal on the client should simply abandon the flow; no cleanup RPC
  is needed because no row was created
- Memory lookup is non-blocking; if lookup fails, item creation still succeeds
  and returns `purchase_memory = null`

### 6.2 API contract alignment

The wire shape is defined in
`docs/contracts/shopping_list/shopping_list_api_v1.md`.
Architecture invariants are defined in
`docs/contracts/shopping_list/shopping_list_contract.md`.

### 6.3 Reminder UX rules

- Reminders are soft-confirmation prompts, not hard errors
- First call returns a prompt state when the item appears recently purchased
- Client should show a single dialog with:
  - primary action: continue / add anyway
  - dismissal: close dialog and return to the editor with no item created
- Client copy should stay soft, for example:
  - `Bought once before - 2 days ago`
  - `Last bought 13 days ago by Paris`
  - `You may already have this in this household group`
- Unit-scoped reminders should be understood as unit-local, not whole-home
  stock assertions

## 7. Permissions & privacy

- Purchase memory is never globally public inside a home by default
- House-scoped memory may inform any home member acting at house scope
- Unit-scoped memory should only inform actions targeting that same unit scope
- No item free-text, quantities, or details are emitted beyond the canonical
  reminder payload

## 8. Edge cases

- Couple buys `eggs` in their shared unit: family-level `House` egg memory is
  unchanged
- Family buys `egg` at `House` scope: shared-unit egg memory is unchanged
- Multiple archived rows with the same canonical name in the same bucket resolve
  to one latest-purchase record update for that bucket
- The same canonical name may exist once in house memory and once in one or
  more unit-memory buckets
- Home delete cascades all memory rows

## 9. Invariants

- Purchase memory is additive; it never mutates the source shopping item
- Users can always add an item even when a reminder appears
- Memory is derived only from completed-then-archived rows
- Purchase memory respects the same sharing boundary as the source item
- Purchase memory is recency-oriented per bucket in the current
  implementation

## 10. Dependencies & links

- Extends `docs/contracts/shopping_list/shopping_list_contract_v1.md`
- Couples to archive RPCs defined in
  `docs/contracts/shopping_list/shopping_list_api_v1.md`
- Shares scope semantics with
  `docs/contracts/home_units/home_units_api_v1.md`

## 11. Future considerations

- Alias-based matching and canonical item keys
- Household-tunable warning windows
- Fuzzy/plural-aware matching
- Optional hybrid reminders that combine unit and house history
