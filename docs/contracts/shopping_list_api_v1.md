---
Domain: Homes
Capability: shopping_list
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Audience: internal
Last updated: 2026-02-07
---

# Shopping List API Contract v1

Backend RPC shapes and invariants for the shared shopping list (one active list per home). Mirrors product contract behaviors and integrates with Share expenses.

## 1. Entities (storage expectations)
- Quota integration:
  - `public.home_usage_metric` includes `shopping_item_photos`.
  - `public.home_usage_counters.shopping_item_photos` tracks active shopping-item photos.
  - `public.home_plan_limits` includes free-plan limit for `shopping_item_photos` (default `10`).
- `shopping_lists`
  - Unique partial index: `UNIQUE(home_id) WHERE is_active = true`.
  - `updated_at` maintained by trigger.
- `shopping_list_items`
  - Invariants:
    - `is_completed = true` ⇒ `completed_by_user_id` & `completed_at` NOT NULL.
    - `is_completed = false` ⇒ both NULL.
    - `reference_photo_path` once non-null MUST remain non-null; only replacement is allowed (no delete-to-null).
    - `reference_photo_path` must match `households/%` when present.
    - Active views exclude `archived_at IS NOT NULL`.
  - `updated_at` maintained by trigger.

## 2. RPCs
All RPCs enforce membership with `public._assert_home_member(p_home_id)` (or equivalent membership join on item-scoped calls).

### 2.1 `shopping_list_get_for_home(p_home_id uuid)`
Returns the active list and all unarchived items for the home.
- Filters: `home_id = p_home_id` AND `archived_at IS NULL`.
- If no active list exists, returns an empty active-list object (with `id = null`) and `items = []`.
- `list` includes counters: `items_unarchived_count`, `items_uncompleted_count`.
- Response fields include `completed_by_user_id` and `completed_by_avatar_id` (join to `public.profiles.avatar_id`).
- Ordering: uncompleted first, then completed by `completed_at DESC` (server MAY implement; client can reorder).

### 2.2 `shopping_list_add_item(p_home_id uuid, p_name text, p_quantity text default NULL, p_details text default NULL, p_reference_photo_path text default NULL)`
- Lazily creates an active list if missing for the home.
- Inserts item with `is_completed = false`, `archived_at = NULL`.
- If `p_reference_photo_path` provided, sets `reference_added_by_user_id = auth.uid()`.
- If `p_reference_photo_path` provided, path MUST start with `households/`.
- Adding an item with a photo increments `home_usage_counters.shopping_item_photos` and enforces quota.
- Reject empty/whitespace-only `p_name` (raise `invalid_name`).

### 2.3 `shopping_list_update_item(p_item_id uuid, p_name text default NULL, p_quantity text default NULL, p_details text default NULL, p_is_completed boolean default NULL, p_reference_photo_path text default NULL, p_replace_photo boolean default false)`
Supports rename, quantity/details edit, tick/untick, and photo replace.
- `NULL` input for `p_name`, `p_quantity`, or `p_details` means "no change" in v1.
- Tick: when `p_is_completed = true` ⇒ set `is_completed = true`, `completed_by_user_id = auth.uid()`, `completed_at = now()`.
- Untick: when `p_is_completed = false` ⇒ clear completion fields and set `is_completed = false`.
- Photo rules:
  - If `p_replace_photo = true` AND `p_reference_photo_path` provided ⇒ set `reference_photo_path = p_reference_photo_path`, `reference_added_by_user_id = auth.uid()`.
  - If no prior photo exists, providing `p_reference_photo_path` sets it (same fields as above).
  - If `p_reference_photo_path` provided, path MUST start with `households/`.
  - First-ever photo add on an item enforces/increments `shopping_item_photos`; photo replacement does not increment usage.
  - Deletion is forbidden: calls MUST NOT set `reference_photo_path = NULL`; attempts should raise `photo_delete_not_allowed`.
- Rows scoped by member checks and RPC predicates.

### 2.4 `shopping_list_prepare_expense_for_user(p_home_id uuid)`
Prefills Share expense for the caller’s completed items.
- Selection:
  - `home_id = p_home_id`
  - `archived_at IS NULL`
  - `is_completed = true`
  - `completed_by_user_id = auth.uid()`
  - `linked_expense_id IS NULL`
- Returns single row or 0 rows with: `default_description text`, `default_notes text`, `item_ids uuid[]`, `item_count int`.
- No time-window gating in v1.

### 2.5 `shopping_list_link_items_to_expense_for_user(p_home_id uuid, p_expense_id uuid, p_item_ids uuid[])`
Links caller-completed items to a newly created Share expense and archives them.
- `p_expense_id` MUST belong to `p_home_id` and be created by `auth.uid()`.
- Update WHERE:
  - `home_id = p_home_id`
  - `id = ANY(p_item_ids)`
  - `archived_at IS NULL`
  - `is_completed = true`
  - `completed_by_user_id = auth.uid()`
  - `linked_expense_id IS NULL`
- Sets `linked_expense_id = p_expense_id`, `archived_at = now()`, `archived_by_user_id = auth.uid()`.
- Locks expense row (`FOR UPDATE`) before first-link check.
- Side effect: increments `home_usage_counters.active_expenses` by `+1` only when this call creates the first shopping-list link for that expense.
- No active-expenses quota check is applied in this RPC (linking is non-blocking for that metric).

### 2.6 `shopping_list_archive_items_for_user(p_home_id uuid, p_item_ids uuid[])`
Archives caller-completed items without expense linkage.
- Update WHERE: `home_id = p_home_id` AND `id = ANY(p_item_ids)` AND `archived_at IS NULL` AND `completed_by_user_id = auth.uid()`.
- Sets `archived_at = now()`, `archived_by_user_id = auth.uid()`.

## 3. RLS / access control
- Tables have RLS enabled and direct access revoked for `authenticated`; writes/reads are RPC-only.
- Membership is enforced inside RPCs with `_assert_home_member` and scoped predicates.
- Internal helpers `_home_assert_quota(uuid, jsonb)` and `_home_usage_apply_delta(uuid, jsonb)` are not executable by `authenticated`.

## 4. Error codes (canonical)
- `invalid_name` — name missing/blank.
- `invalid_reference_photo_path` — photo path is present but not under `households/`.
- `photo_delete_not_allowed` — attempt to clear existing `reference_photo_path` to NULL.
- `NOT_HOME_MEMBER` — caller not in the home.
- `item_not_found` — item missing or archived when updating.
- `invalid_expense` — provided expense is not owned by caller in the same home.
- `PAYWALL_LIMIT_SHOPPING_ITEM_PHOTOS` — adding a new shopping item photo would exceed plan quota.

## 5. Coupling / notes
- Share expense creation lives in `contracts/api/kinly/share/expenses_v2.md`; shopping list only prepares/link/archives items.
- Matches product contract `shopping_list_contract_v1` and architecture contract `architecture/contracts/shopping_list_contract.md`.
