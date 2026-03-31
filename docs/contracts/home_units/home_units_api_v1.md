---
Domain: Homes
Capability: Home Units
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.3
---

# Home Units API Contract v1.3

Status: Draft

Scope: Backend contract for reusable home-scoped units that support subgroup
identity for shopping-list scope, explicit unit-based expense allocation, and
Today visibility. This contract defines the home-units data model and unit RPC
surface. Expense RPC semantics remain owned by
`contracts/contracts/api/kinly/share/expenses_v2.md`.

## Purpose

This contract introduces a home-scoped grouping model around existing canonical
tables rather than replacing them.

Core intent:
- Every current membership has exactly one personal unit.
- A current membership may also belong to one active shared unit.
- Exact `unit_id` is the authority for subgroup identity.
- Shopping-list unit scope and expense unit liability both reuse the same unit
  identity model.
- Internal cost sharing inside a shared unit is out of scope for v1.

## Existing canonical tables used by this contract

This contract does NOT redefine the following canonical tables:
- `public.memberships`
- `public.profiles`
- `public.shopping_lists`
- `public.shopping_list_items`
- `public.expenses`
- `public.expense_splits`
- `public.expense_plans`
- `public.chores`

This contract adds unit-specific structures around those tables rather than
replacing them.

## Design principles

- **RPC-first architecture** - all public mutations go through SECURITY
  DEFINER functions with `search_path = ''`; all object references inside those
  functions MUST be fully schema-qualified.
- **Deny-by-default** - direct table access is revoked from `anon`,
  `authenticated`, and `PUBLIC`; only explicitly granted RPCs are executable by
  `authenticated`.
- **Membership-scoped unit identity** - unit membership attaches to
  `memberships.id`, not directly to `profiles.id`, because participation is
  tied to a home-membership episode.
- **Personal units are backend-managed** - each current membership SHOULD have
  exactly one active personal unit created automatically on join or rejoin.
- **One shared unit max per current membership** - this keeps shopping-list
  scope, Today visibility, and expense liability unambiguous.
- **DB-enforced core shape, RPC-enforced actor targeting** - table constraints
  and indexes enforce the durable unit shape; RPCs enforce which unit the
  caller may target.
- **Archived units are historical** - archived units may remain referenced by
  historical shopping items or expenses.

## Entities

### HomeUnit

| Field | Type | Notes |
|---|---|---|
| `id` | `uuid` | PK, `gen_random_uuid()` |
| `home_id` | `uuid` | FK -> `homes(id)`, CASCADE |
| `unit_type` | `text` | `'personal'` or `'shared'` |
| `name` | `text` | Required stored display name; 1-100 chars after trim |
| `personal_membership_id` | `uuid|null` | FK -> `memberships(id)`; set iff `unit_type = 'personal'` |
| `created_by_user_id` | `uuid|null` | FK -> `profiles(id)` |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | Auto-touched on UPDATE |
| `archived_at` | `timestamptz|null` | Soft-delete |

Table-level constraints:
- `unit_type IN ('personal', 'shared')`
- `unit_type = 'personal'` -> `personal_membership_id IS NOT NULL`
- `unit_type = 'shared'` -> `personal_membership_id IS NULL`
- `char_length(btrim(name)) BETWEEN 1 AND 100`

Indexes:
- Unique partial index:
  `(home_id, personal_membership_id)` where
  `unit_type = 'personal' AND archived_at IS NULL`
- `home_id, unit_type` where `archived_at IS NULL`
- unique composite key on `(id, home_id)` for same-home foreign keys

### HomeUnitMember

| Field | Type | Notes |
|---|---|---|
| `unit_id` | `uuid` | Composite FK -> `home_units(id, home_id)`, CASCADE |
| `home_id` | `uuid` | Projected from `home_units.home_id` |
| `membership_id` | `uuid` | Composite FK -> `memberships(id, home_id)`, CASCADE |
| `is_active_shared` | `boolean` | Projection flag for active shared membership rows |
| `created_at` | `timestamptz` | |

Primary key:
- `(unit_id, membership_id)`

Recommended invariants:
- each active personal unit has exactly one current member row
- a current membership may belong to zero or one active shared unit
- all `home_unit_members.membership_id` values used by an active unit belong to
  the same home as that unit
- `is_active_shared` is derived by the database and must not be treated as a
  caller-controlled flag

## Unit naming

`home_units.name` MUST be non-null for all active and archived units.

### Personal units

Personal units are auto-provisioned with a stored display name.

Default naming rule:
1. Use a short personal label derived from `profiles.full_name` when present.
2. Otherwise, use `'Personal'`.

Clients MUST NOT infer personal-unit identity from a null name. Personal-unit
identity is defined by `unit_type = 'personal'`.

### Shared units

Shared units MUST have an explicit caller-supplied name at creation time.
Shared-unit names are not required to be unique within a home.

## Enums

### UnitType
`personal | shared`

### ShoppingItemScopeType
`house | unit`

### ExpenseAllocationMode
`unit_based | debtor_based`

## Active unit invariants

For active units (`archived_at IS NULL`):

1. Every current membership SHOULD have exactly one active personal unit.
2. A personal unit MUST have exactly one `home_unit_members` row.
3. For personal units, that row's `membership_id` MUST equal
   `personal_membership_id`.
4. A current membership MAY belong to zero or one active shared unit.
5. A shared unit MUST have at least two current members while active.
Archived units are historical records and are exempt from active
membership-shape rules.

## Membership lifecycle

### Current-membership model

`public.memberships` is the source of truth for whether a person is currently in
a home.

Assumptions:
- `memberships.valid_to IS NULL` means current membership
- leaving a home is represented by setting `valid_to`
- rejoining later is represented by a new `memberships` row

### Join and rejoin

On current membership insert, backend lifecycle logic SHOULD ensure one active
personal unit exists for that membership.

Rejoin semantics are membership-based, not profile-based:
- if a user leaves and later rejoins, the new membership gets a fresh personal
  unit
- shared-unit participation does not automatically carry over from an older
  membership row

### Departure

When a membership stops being current:
- its active personal unit is archived
- its shared-unit membership rows are removed
- any affected shared unit that drops below two current members is archived

This lifecycle may be implemented via row-level triggers, statement-level
triggers, or equivalent DB-owned logic. The contract does not require a
specific trigger architecture in v1.1.

## Scope resolution

Home units are the authority for allowed scoped targeting in dependent systems.

For a current member in a home, the backend resolves:
- `house` scope is always allowed
- if the member has no active shared unit, the allowed unit scope is their
  personal unit
- if the member has an active shared unit, the allowed unit scope is that exact
  shared `unit_id`

Dependent RPCs such as shopping-list and expense mutations MUST reject attempts
to target a different unit with `invalid_unit_scope` or an equivalent canonical
error.

## Shopping-list integration

`public.shopping_lists` remains the canonical one-active-list-per-home
container.

This contract does NOT create multiple shopping-list headers per home.

Unit scope, if enabled, MUST live on `shopping_list_items`, not on
`shopping_lists`.

Expected item extension:
- `scope_type text not null default 'house'`
- `unit_id uuid null`

Constraints:
- `scope_type IN ('house', 'unit')`
- `scope_type = 'house'` -> `unit_id IS NULL`
- `scope_type = 'unit'` -> `unit_id IS NOT NULL`

Behavioral alignment:
- house items are visible to all home members
- unit items are visible only to current members of that exact unit
- multiple couples in one home remain isolated because reads and writes are
  keyed by concrete `unit_id`, not by label
- if a shared unit is archived, open unarchived incomplete unit-scoped shopping
  items for that unit are automatically reassigned to `house`
- completed or archived shopping items may continue to reference the original
  unit historically

## Expense integration boundary

Expenses MAY use home units as explicit liability targets, but the unit-expense
wire shapes and RPC versioning remain owned by
`contracts/contracts/api/kinly/share/expenses_v2.md`.

Boundary rules:
- unit-based expenses target exact `unit_id` values
- debtor-based expenses remain an explicit compatibility mode
- shopping-list item scope does not automatically determine expense liability
  mode
- unit identity is shared across domains, but each domain owns its own payload
  semantics

## Chore integration

`public.chores` remains canonical.

Chores remain assigned to `assignee_user_id` and are NOT unit-owned in v1.

## RPC direction

All public RPCs below are `SECURITY DEFINER` with `search_path = ''`.

Auth baseline:
- caller MUST be authenticated
- caller MUST be a current home member for the target home

### Internal helper: `_home_units__ensure_personal`

Ensures one active personal unit exists for a current membership.

This helper is backend-owned lifecycle infrastructure and SHOULD remain
internal.

Related internal lifecycle helpers also maintain projected membership state:
- `_home_units__sync_member_projection`
- `_home_units__sync_members_from_unit`
- `_home_units__reconcile_member_projection`
- `_home_units__ensure_personal_membership_trigger`
- `_home_units__membership_departure_trigger`

### `home_units_get_my_context`

Returns the caller's resolved unit context for a given home.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_home_id` | `uuid` | yes | Must be a home where the caller has a current membership |

Returns:
- object:
  - `personal_unit`
  - `active_shared_unit|null`
  - `allowed_shopping_scopes text[]`

Required response shape:

```json
{
  "personal_unit": {
    "unit_id": "uuid",
    "home_id": "uuid",
    "name": "Personal",
    "unit_type": "personal",
    "member_user_ids": ["uuid"]
  },
  "active_shared_unit": {
    "unit_id": "uuid",
    "home_id": "uuid",
    "name": "Alex + Sam",
    "unit_type": "shared",
    "member_user_ids": ["uuid", "uuid"]
  },
  "allowed_shopping_scopes": ["house", "unit"]
}
```

Behavior:
- `active_shared_unit` is `null` when the caller is not in a shared unit
- `allowed_shopping_scopes` is:
  - `['house', 'unit']` where `unit` means the caller's personal unit when no
    shared unit exists
  - `['house', 'unit']` where `unit` means the caller's active shared unit when
    one exists

### `home_units_list_selectable_expense_units`

Returns the exact units the caller may target in unit-based expense flows.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_home_id` | `uuid` | yes | Must be a home where the caller has a current membership |

Returns:
- `setof object`
  - `unit_id`
  - `home_id`
  - `name`
  - `unit_type`
  - `member_user_ids text[]`

Behavior:
- if the caller has no active shared unit, return only their personal unit
- if the caller has an active shared unit, return:
  - their active shared unit
  - their personal unit only if debtor selection rules in the expense contract
    still allow switching back to personal targeting

### `home_units_list_create_shared_candidates`

Returns eligible current memberships the caller may include during creation of a
new shared unit.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_home_id` | `uuid` | yes | Must be a home where the caller has a current membership |

Returns:
- `setof object`
  - `membership_id`
  - `user_id`
  - `display_name`
  - `avatar_url|null`
  - `is_owner`

Behavior:
- excludes the caller's current membership
- excludes current memberships already belonging to another active shared unit
- excludes non-current memberships

### `home_units_list_joinable_shared_units`

Returns active shared units in the home that the caller may explicitly join.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_home_id` | `uuid` | yes | Must be a home where the caller has a current membership |

Returns:
- `setof object`
  - `unit_id`
  - `home_id`
  - `name`
  - `unit_type`
  - `member_user_ids text[]`

Behavior:
- excludes archived shared units
- excludes any shared unit the caller already belongs to
- returns an empty set if the caller already belongs to another active shared
  unit

### `home_units_create_shared`

Creates a shared unit containing two or more current memberships.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_home_id` | `uuid` | yes | |
| `p_name` | `text` | yes | Non-empty after trim, max 100 chars |
| `p_membership_ids` | `uuid[]` | yes | At least 2 distinct current memberships |

Returns:
- `uuid` - new shared unit ID

Validations:
- all memberships are current and in the same home
- no listed membership already belongs to another active shared unit
- the shared unit is active immediately only when the submitted set contains at
  least 2 distinct current memberships

### `home_units_update_shared`

Updates mutable shared-unit metadata.

Supported updates in v1:
- rename shared unit

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_unit_id` | `uuid` | yes | Must be an active shared unit in the home |
| `p_name` | `text` | yes | Non-empty replacement name |

Returns:
- `uuid` - updated shared unit ID

### `home_units_join_shared`

Adds the caller's current membership to an existing shared unit.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_unit_id` | `uuid` | yes | Must be an active shared unit in the home |

Returns:
- `uuid` - joined shared unit ID

Validations:
- caller has a current membership in the target unit's home
- caller does not already belong to another active shared unit
- caller is not already a member of `p_unit_id`

### `home_units_leave_shared`

Removes the caller's current membership from their active shared unit.

| Param | Type | Required | Notes |
|---|---|---|---|
| `p_unit_id` | `uuid` | yes | Must be an active shared unit in the home |

Returns:
- `uuid` - left shared unit ID

Behavior:
- remove the caller's shared-unit membership row
- archive the shared unit if remaining current member count drops below two
- this RPC is only for leaving a shared unit while remaining a current home
  member
- when the caller leaves the home entirely, shared-unit departure remains a
  backend lifecycle side effect of membership closure and MUST NOT require the
  mobile app to call this RPC separately

## Schema impact summary

Minimum new tables for the home-units slice:
- `home_units`
- `home_unit_members`

Expected dependent extensions in this stream:
- `shopping_list_items`
  - add `scope_type`
  - add `unit_id`
- expense unit allocation tables and RPCs are defined in
  `contracts/contracts/api/kinly/share/expenses_v2.md`

No new shopping-list header table is required.
No new chore table is required.

## RPC reuse and versioning strategy

- Shopping-list scope is additive to the existing list model, but wrapped
  purchase-memory responses should use `shopping_list_add_item_v2` rather than
  silently changing the legacy add-item shape.
- Expense RPC versioning is owned by
  `contracts/contracts/api/kinly/share/expenses_v2.md`.
- Chore RPCs remain unchanged because chores are still person-scoped.

## Product rules

1. Every current membership SHOULD have exactly one active personal unit.
2. A current membership MAY belong to zero or one active shared unit.
3. Shared units MUST contain at least two current memberships while active.
4. Unit names are not required to be unique within a home.
5. Shopping-list scoping, when unit-aware, belongs on items rather than list
   headers.
6. Multiple couples in one home are isolated by exact `unit_id`.
7. Expense liability may target either units or direct debtors, but unit-based
   liability uses these same unit identities.
8. Internal cost sharing inside a shared unit is out of scope for v1.
9. Chores remain individual-scoped, not unit-owned.
10. Home-unit management may be surfaced from profile/settings UI, but remains
    implemented as home-scoped unit RPCs rather than profile mutations.

## Permissions

### Table-level access

| Table | `anon` | `authenticated` | `PUBLIC` | Notes |
|---|---|---|---|---|
| `home_units` | REVOKE ALL | REVOKE ALL | REVOKE ALL | RPC only |
| `home_unit_members` | REVOKE ALL | REVOKE ALL | REVOKE ALL | RPC only |

### Function-level access

For every public RPC:
1. `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC`
2. `GRANT EXECUTE ON FUNCTION ... TO authenticated`

For internal helpers:
1. `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC`
2. Do NOT grant to `authenticated`

## Assumptions

- `public.homes(id)` exists.
- `public.memberships(id, user_id, home_id, valid_to)` exists.
- `public.profiles(id)` exists.
- `public.shopping_lists` remains one-active-list-per-home.
- `public.shopping_list_items` is the correct place for unit-aware shopping-list
  scope.

## Out of scope (v1.1)

- Internal cost sharing within a shared unit
- Automatic inferred personal sub-splits inside a shared-unit charge
- A second active shared unit for the same current membership
- Unit-owned chores
- Nested or hierarchical units
- Exposing unit participation as a direct profile field
