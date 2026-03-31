---
Domain: Homes
Capability: shopping_list
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.3
Audience: internal
Last updated: 2026-03-28
---

# Shopping List Product Contract v1.3

## 1. Purpose & scope

- Define the shared shopping list experience for homes: one active list per
  home; everyone can contribute and mark progress.
- Align behaviors with existing Share expenses module without duplicating its
  logic; this contract covers list behaviors and item-level scope semantics,
  then hands off to Share when needed.

## 2. Goals

- Quick, low-friction list for daily household shopping.
- Preserve authorship of ticks (avatar shows who marked complete).
- Let any member clear *their* completed items, optionally by creating a Share
  expense.
- Support simple item scope beyond the whole house without introducing multiple
  concurrent shopping-list headers per home.

## 3. Non-goals

- Budgeting, receipt OCR, price tracking, or splitting logic (handled by Share
  after handoff).
- Multiple concurrent lists per home.
- Real-time collaborative editing guarantees beyond last-write-wins.
- Generic multi-unit shopping-list targeting for arbitrary units beyond the
  scoped rules below.

## 4. Entities & invariants

- **shopping_list** (one active per home)
  - name defaults to "Groceries"; MUST remain editable.
  - Invariant: `home_id` has exactly one row where `is_active = true`; new homes
    auto-seed one active list. Archive instead of delete.

- **shopping_list_item**
  - Required: `name`.
  - Optional: `quantity`, `details`, `reference_photo_path`.
  - Optional scope:
    - `House`
    - `Personal`, only when the acting member does not belong to an active
      shared unit
    - `Shared`, only when the acting member belongs to an active shared unit
  - Completion state is single-writer:
    - `is_completed`
    - `completed_by_user_id`
    - `completed_at`
  - Invariants:
    - If `is_completed = true`, both `completed_by_user_id` and `completed_at`
      MUST be present.
    - If `is_completed = false`, both MUST be null.
    - If `reference_photo_path` is ever set, it MUST remain non-null thereafter;
      only replacement with a new photo is allowed.
    - Active views exclude `archived_at IS NOT NULL`.
    - Scope is item-level, not list-level.
    - Completing a `Personal` or `Shared` item affects that exact item only; it
      does not also complete any `House` item.

## 5. Scope model

### 5.1 Default

Shopping-list item scope MUST default to `House`.

### 5.2 Available alternate scope

The alternate scope depends on the acting member's home-unit state:

- If the member has **no active shared unit**:
  - available scopes are `House` and `Personal`

- If the member **does have an active shared unit**:
  - available scopes are `House` and `Shared`

This keeps the scope model simple:
- `Personal` is a fallback when the member is not in a shared unit
- `Shared` replaces `Personal` as the scoped option once the member belongs to a
  shared unit

### 5.3 UI requirement

The current item scope MUST be visibly changeable in the add/edit item flow.

Examples:
- a scope chip
- a segmented control
- a tappable "House" label that opens a picker

The app MUST NOT hide scope behind a secondary advanced menu if item scoping is
enabled.

## 6. Core behaviors

- **Viewing**
  - Show unarchived items for the active list; order newest first by default.
  - Row chrome: checkbox, name, and small indicators when `quantity`, `details`,
    or `reference_photo_path` exist.
  - If scope is not `House`, the row SHOULD show a small visible scope label
    such as `Shared` or `Personal`.
  - The UI SHOULD be able to show all visible scopes together in one list.
  - The UI SHOULD support scope filtering, for example:
    - `All`
    - `House`
    - the caller's allowed unit scope
  - Tapping row opens a detail sheet.

- **Adding items**
  - Any member MAY add items.
  - Empty or whitespace-only names MUST be rejected client-side.
  - If the active list is missing, creation MUST lazily create it before
    inserting the item.
  - New items default to `House`.
  - Add-item success MAY include a soft purchase-memory reminder for the same
    sharing boundary as the new item:
    - `House` item -> check `House` memory
    - `Personal` item -> check that personal unit's memory only
    - `Shared` item -> check that shared unit's memory only
  - Current purchase memory is recency-oriented: reminders are based on the
    latest known purchase in the matching bucket

- **Reference photo**
  - Adding or replacing a photo sets `reference_photo_path` and
    `reference_added_by_user_id` to the actor.
  - Deletion is not supported: once a photo exists, the only permitted change is
    replacement with a new photo.

- **Tick / untick**
  - Completion is first-completer-wins.
  - Tick on an uncompleted item sets `is_completed = true`,
    `completed_by_user_id = actor`, and `completed_at = now()`.
  - Re-submitting completion by the same completer is idempotent.
  - Untick by the same completer clears completion fields and sets
    `is_completed = false`.
  - A different member MUST NOT take over or clear another member's completion;
    the backend should reject that transition and the UI should keep the
    original completion avatar.
  - Completion is scope-local: a completed `Shared` or `Personal` item remains
    separate from `House` items.

- **Shared-unit collapse**
  - Open uncompleted unit-scoped items stay attached to their unit while that
    shared unit remains active.
  - If a shared unit is archived because membership drops below two, open
    unarchived incomplete items for that unit MUST be automatically reassigned
    to `House`.
  - Completed or already archived items keep their original `unit_id` as
    historical records.

## 7. "Done shopping" actions (per-user)

- CTA is enabled only when `my_completed_count > 0`:
  - items where `is_completed = true`
  - `completed_by_user_id = me`
  - `archived_at IS NULL`
- Two mutually exclusive flows, both scoped to **my** completed items only:
  1. **Create Share expense**
     - Prefill description/notes from my completed items
     - backend returns `item_ids` and suggested text
     - on confirmation, items are linked (`linked_expense_id`) and archived
  2. **Clear without expense**
     - archives only my completed items
- Safeguards:
  - server-side updates MUST filter by `completed_by_user_id = auth.uid()` and
    `archived_at IS NULL`

## 8. Error and edge handling

- If `Done shopping` is tapped with zero eligible items (race condition),
  surface a non-blocking toast: "No completed items to clear".
- Upload failures for photos MUST leave the existing photo unchanged and show a
  retry affordance.
- List creation failure should show a generic retryable error and MUST NOT
  create duplicate lists client-side.
- If a shared unit collapses while it still has open uncompleted scoped items,
  those items should remain visible by being automatically moved to `House`
  rather than becoming stranded on an archived unit.

## 9. Permissions & privacy

- Home membership required for all reads/writes on list and items.
- Avatars for `completed_by_user_id` MAY be shown.
- No other unnecessary PII is stored on items.
- Purchase memory must respect the same sharing boundary as the source item:
  - house-scoped memory is visible to home members
  - unit-scoped memory should only inform members acting within that unit scope

## 10. Telemetry (privacy-safe)

- SHOULD log:
  - `shopping_list_item_added`
  - `shopping_list_item_completed`
  - `shopping_list_done_prepare`
  - `shopping_list_done_archive`
  - `shopping_list_done_linked_to_expense`
- MUST NOT log free-form text fields (`name`, `details`, `quantity`) or photo
  paths.

## 11. Dependencies & links

- Couples to Share expenses module for optional settlement; this contract stops
  at prefill + linkage.
- Unit-scope behavior aligns with:
  - `docs/contracts/home_units/home_units_api_v1.md`
  - `docs/contracts/home_units/home_units_v1.md`
- Purchase-memory reminder behavior aligns with
  `docs/contracts/shopping_list/shopping_list_purchase_memory_v1.md`.
- No required coupling to chores/house tasks modules.
