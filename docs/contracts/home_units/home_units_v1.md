---
Domain: Homes
Capability: Home Units
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.2
---

# Home Units Mobile Contract v1.2

Status: Draft

Scope: Mobile-only product behavior for home units. Defines where unit
management appears in the app, how personal and shared units are presented, how
shared-unit creation/join works, and how Today surfaces unit-based liabilities.
Backend and schema details live in
`contracts/contracts/api/kinly/homes/home_units_api_v1.md`.

## 1. Purpose

Home units give the app a user-facing way to group liability and list scope.

The mobile experience MUST support:
- automatic personal units for every current member
- optional shared units for members who want to be treated as one liability
  bucket
- Today visibility for both personal and shared liabilities
- exact-unit privacy for unit-scoped shopping items
- unit management from profile/settings surfaces

This contract does NOT define internal cost sharing inside a shared unit.

## 2. Core Product Rules

1. Every current member has exactly one personal unit.
2. A member may belong to zero or one active shared unit.
3. A shared unit is active only when it has at least two joined current members.
4. The creator MAY choose the initial members of a shared unit during creation.
5. After a shared unit exists, the app MUST NOT silently place another member
   into that existing shared unit.
6. A member may initiate creation of a shared unit, but a one-person shared unit
   MUST NOT become active.
7. Unit management may live on profile/settings UI, but it is home-scoped
   behavior, not global profile identity.
8. Today MUST show open liabilities according to their explicit debtor target:
   personal unit or shared unit.
9. Unit-scoped shopping items are private to the exact unit that owns them.

## 3. Entry Points

### 3.1 Profile / settings

The member profile/settings surface MAY include:
- personal unit display name
- current shared unit status
- CTA to create a shared unit
- CTA to browse/join an existing shared unit
- CTA to leave current shared unit
- CTA to rename current shared unit if permitted

This surface edits home-unit participation. It does not mutate global profile
identity except for normal profile fields such as username or avatar.

Context resolution:
- profile/settings entry points MUST resolve active home context from the
  caller's current membership
- the preferred source of truth is `membership.meCurrent`
- clients MUST NOT assume profile/edit routes always carry fresh membership
  context from a previous screen
- if `membership.meCurrent.current == null`, the app MUST block shared-unit
  actions and explain that the member must join or create a home first

### 3.2 Expense flows

Expense create/edit flows MUST allow liability target selection:
- personal unit
- shared unit, if the member belongs to one
- debtor-based mode only where explicitly supported by the expense version in
  use

Recommended selector behavior:
- show a visible toggle or mode control for grouped-by-unit behavior
- if the member belongs to a shared unit, grouped-by-unit SHOULD be preselected
- when grouped-by-unit is selected, the picker SHOULD show unit targets such as
  shared units and personal units
- when unit-based bills support household-wide personal-unit targeting, the
  picker SHOULD show all current members' personal units as separate rows
- when grouped-by-unit is not selected, the picker MAY show individual debtors
  only where debtor-based expense mode is supported

### 3.3 Shopping list item flows

If shopping list items are unit-aware, item create/edit surfaces MAY let the
member choose:
- whole house
- my personal unit, only if I do not belong to a shared unit
- my shared unit, only if I belong to one

Shopping-list default scope MUST be `House`.

The current scope MUST be visibly tappable or otherwise clearly changeable from
the add/edit item UI.

Allowed scope combinations:
- no shared unit: `House` or `Personal`
- has shared unit: `House` or `Shared`

Visibility rules:
- `House` items are visible to all current home members
- unit-scoped items are visible only to current members of that exact unit
- multiple couples in one home stay isolated because unit-scoped items are
  keyed by concrete `unit_id`, not by the generic label `Shared`

### 3.4 Today

Today MUST present open liabilities using one list of rows tagged by liability
kind rather than separate mandatory sections.

## 4. Shared Unit Creation and Join Model

### 4.1 No active one-person shared unit

The app MUST NOT create an active shared unit with only one joined member.

If a member starts the shared-unit flow alone, the mobile UX should behave as an
invite/setup flow rather than activating a shared unit immediately.

### 4.2 Creation flow

In v1, the preferred path is:

1. creator enters a shared-unit name
2. creator selects the full initial member set
3. the app submits one create action
4. the shared unit is created immediately only if the initial set contains at
   least 2 distinct current members

This means the creator MAY select another member at create time and that member
becomes part of the new shared unit immediately if creation succeeds.

The app SHOULD NOT introduce a pending one-person shared-unit lifecycle in v1
unless product later decides it is necessary.

### 4.3 Joining an existing shared unit

A member may join an already active shared unit if:
- they are a current member of the home
- they do not already belong to another active shared unit

The UI MUST make the action explicit.

### 4.4 Assigning others

The app MAY allow one member to choose the initial membership set while creating
a brand-new shared unit.

Allowed behavior:
- creator creates `Alice + Bob` in one action and selects both Alice and Bob as
  the initial members
- a member later explicitly joins an already-existing shared unit

Disallowed behavior:
- creator creates a one-person shared unit and expects it to behave as active
- creator edits an existing shared unit and inserts Bob without Bob doing
  anything

Rationale:
- shared-unit membership changes expense visibility and liability grouping
- initial creation is one explicit setup action
- once a shared unit already exists, post-create membership changes should not
  be silent

## 5. Unit States

### 5.1 Personal unit

- Always exists for a current member
- Never shown as "joinable"
- Cannot be deleted manually
- May be renamed only if product decides to expose personal-label editing

### 5.2 Shared unit

Recommended mobile states:
- `none` - member is not in a shared unit
- `active` - member belongs to an active shared unit
- `invited` - optional future state if invite flow is adopted
- `pending_creation` - optional future state if one-person setup is adopted

For v1, only `none` and `active` are required.

## 6. Profile / Settings UX Rules

### 6.1 When member has no shared unit

Show:
- personal unit label
- `Create shared unit`
- `Join existing shared unit`

Guardrails:
- hide `Create shared unit` when there are no eligible create candidates
- hide `Join existing shared unit` when there are no joinable shared units

### 6.2 When member already has a shared unit

Show:
- shared unit name
- member list
- `Leave shared unit`
- `Rename shared unit` if permitted

Hide or disable:
- joining another shared unit
- creating another shared unit

### 6.3 Leave shared unit behavior

When the member leaves:
- remove them from the shared unit
- if the remaining member count drops below two, the shared unit is archived
- the member falls back to personal-unit-only behavior
- if the archived shared unit still had open uncompleted shopping items, those
  items move to `House` rather than disappearing with the archived unit

The UI SHOULD confirm this clearly before submission.

If the member leaves the home entirely:
- the app SHOULD only perform the normal home-leave action
- backend lifecycle logic handles any shared-unit departure or archival side
  effects
- the app MUST NOT require an extra explicit `Leave shared unit` action first

## 7. Today Behavior

### 7.1 Presentation model

Today SHOULD show a single list of open liabilities.

Each row MUST include a liability tag:
- `Personal`
- `Shared`

Shared rows SHOULD also show the shared unit name.

### 7.2 Personal liability rows

If an expense targets the member's personal unit:
- the row appears only for that member
- the row is tagged `Personal`
- no shared-unit chrome is shown

### 7.3 Shared liability rows

If an expense targets a shared unit:
- the row appears for all current members of that shared unit
- the row is tagged `Shared`
- the row shows the shared unit name
- the row reflects the unit-level remaining amount

### 7.4 Settlement behavior

If a shared liability is fully settled by any member:
- it MUST disappear from Today for all members of that shared unit

If personal liabilities remain open:
- they continue to appear independently

### 7.5 No inferred internal split

The UI MUST NOT infer per-member debt inside a shared unit.

Examples of forbidden copy:
- "Alice owes 30, Bob owes 30" when no such internal split exists
- equal-share assumptions for a shared unit

Allowed copy:
- "Shared"
- shared unit name
- amount due
- paid so far
- remaining
- payment activity such as "Alice paid 20"

## 8. Expense Create/Edit UX Rules

### 8.1 Target selection

When unit-based allocation is supported, the payer/creator MUST be able to pick
explicit debtor targets such as:
- Alice personal unit
- Alice + Bob shared unit
- Carol personal unit

If the current member belongs to a shared unit, expense create/edit SHOULD
default to the shared unit first while still allowing the member to switch to
their personal unit before submitting.

Shopping-list scope MUST NOT automatically force expense liability mode. The
member still makes an explicit expense choice between unit-based and
person-based allocation where both are supported.

### 8.2 Shared-unit meaning

If the creator selects a shared unit, the app MUST communicate that:
- the shared unit is one liability bucket
- all joined members of that shared unit will see the charge
- the app does not split that amount internally

## 9. Copy and Empty States

### 9.1 No shared unit

Suggested empty-state framing:
- "You are currently managing expenses on your own."
- "Create or join a shared unit if you want some costs to appear together."

### 9.2 Shared-unit join explanation

The UI SHOULD explain that joining a shared unit means:
- some expenses may appear as shared liabilities
- both members can see the same shared expense rows
- paying a shared liability removes it once settled

## 10. Non-goals

- Internal cost sharing within a shared unit
- Automatic assignment of other members into a shared unit
- Multiple concurrent active shared units per member
- Mandatory separate Today sections for shared vs personal
- Turning unit participation into a global profile field

## 11. Dependencies

- Backend/API contract:
  `contracts/contracts/api/kinly/homes/home_units_api_v1.md`
- Existing mobile expense experience
- Existing profile/settings surface
