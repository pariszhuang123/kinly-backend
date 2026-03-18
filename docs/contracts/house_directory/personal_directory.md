---
Domain: Identity
Capability: Personal Directory
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Personal Directory Contract v1

Status: Proposed

Scope: User-owned reference data that the user manages independently of any
home and that becomes visible to active members of the user's current home.
The current backend implementation uses `member_directory_*` table and
function names.

Audience: Product, design, engineering, AI agents.

Depends on:
- Homes v2
- House Directory capability

## 1. Purpose

Personal Directory gives each user a place to manage personal reference
data used by housemates, especially bank details for payments and personal
notes such as emergency contacts, allergies, and other household-relevant
context.

A user's directory is user-scoped, not home-scoped. The user can manage it
without belonging to a home. When the user is in an active home, the data
is visible to current members of that home. If the user leaves one home and
joins another, the same directory carries forward.

Personal Directory MUST support:
- one bank account per user
- repeatable personal notes per user
- read visibility to active members of the user's current home

## 2. Scope and boundaries

In scope:
- user-owned records independent of a specific home
- owner read/write access even without an active home
- automatic visibility to active members of the user's current home
- owner-only mutation rights
- soft archive lifecycle for notes
- dismissible completeness nudge

Out of scope:
- home-member roster discovery
- shared home operational data
- multiple bank accounts per user
- cross-country payment validation rules
- file-upload orchestration

## 3. Core entities

### 3.1 Bank account

Each user MAY have at most one active bank account record.

Purpose: give housemates the information needed to pay that user.

Fields:
- `account_holder_name` required
- `account_number` required

Validation rules:
- both fields MUST be non-empty after trim
- `account_holder_name` max length is `120`
- `account_number` max length is `50`
- `account_number` remains free-form beyond non-empty and length checks

Lifecycle:
- bank accounts are updated in place
- bank accounts cannot be deleted
- the owner can manage their own bank account without a home
- other members do not read bank account details via the directory notes
  API; payment-specific access is via `get_member_bank_account`

Privacy:
- `account_number` is sensitive operational data
- values MUST NOT appear in telemetry or logs

### 3.2 Personal note

A personal note is a user-owned record visible to housemates in the same
active home.

Supported `note_type` values:
- `emergency_contact`
- `allergy`
- `other`

Type rules:
- at most one active `emergency_contact` note per user
- `allergy` is repeatable
- at most `20` active `other` notes per user

Emergency contact fields:
- `contact_name` required
- `phone_number` required
- `details` optional

Allergy fields:
- `label` required
- `details` forbidden in v1
- intended for chip-style display and filtering

Other fields:
- `custom_title` required
- `details` optional

Common fields:
- `photo_path` optional
- `archived_at` supports soft delete

Display and ordering:
- `emergency_contact` appears first
- `allergy` appears next, ordered by label
- `other` appears after default note types, newest first

Photo rules:
- `photo_path` is a storage object key, not a CDN URL
- if present it must match
  `house_directory/{home_id}/member_directory/{user_id}/...`
- photo-backed notes implicitly require the owner to have an active home
- photos are free in v1

Validation rules:
- `note_type` MUST be one of the allowed values
- non-emergency notes MUST NOT contain contact fields
- non-allergy notes MUST NOT contain `label`
- non-other notes MUST NOT contain `custom_title`
- phone numbers allow digits, spaces, `+`, parentheses, and hyphen, and
  must contain at least one digit

## 4. Navigation and entry point

- With an active home: users access personal directory from the house
  directory member-card surface.
- Without an active home: the owner can still access their own directory.
- Member identity and roster ordering come from the House Directory
  member-card RPC or adjacent home-membership surfaces, not from personal
  directory storage.

## 5. Completeness nudge

The v1 completeness nudge is intentionally narrow.

Rules:
- the nudge is only about a missing bank account
- it is evaluated against the user's current active home
- it is dismissible per `(user_id, home_id)`
- once dismissed, it does not reappear in the same home
- it may reappear after the user joins a different home

## 6. Access and privacy rules

- Owner access: the authenticated user can always read and mutate their own
  directory records.
- Shared-home read access: active members of the same home can read the
  owner's notes and payment bank account via the dedicated read RPC.
- Write access: only the owning user can create, update, or archive their
  own records.
- RPCs MUST enforce ownership and active-home checks; tables remain
  RPC-only.

## 7. Data lifecycle

- Records are scoped to `user_id`, not `home_id`.
- Leaving a home does not remove personal directory data.
- Joining a new home makes existing data visible to that home's members.
- Archived notes are excluded from active reads.
- Account deletion scope must include personal directory data.

## 8. Cross-capability relationships

- House Directory stores shared operational home facts.
- Personal Directory stores person-specific records shared with housemates.
- Homes v2 provides active membership context and home visibility rules.

## 9. Contract test scenarios

- User can create, read, and update their own bank account.
- User with no active home can still manage their own bank account.
- User with no active home can read their own notes and create a note that
  does not require a photo path.
- Shared-home members can read another member's notes.
- Shared-home members can read another member's bank account through the
  payment-oriented bank-account RPC.
- Non-home-members cannot read another member's notes or bank account.
- Only one active `emergency_contact` note per user is allowed.
- `allergy` requires `label`.
- `allergy` forbids `details`.
- `other` requires `custom_title`.
- Non-emergency notes forbid contact fields.
- Invalid photo paths are rejected.
- Only the owner can update or archive a note.
- Archived notes are excluded from list reads.
- Nudge appears only when bank account is missing.
- Nudge dismissal is per home and idempotent.
- Dismissed nudge does not reappear in the same home.
- Nudge may reappear after the user joins a different home.

## 10. References

- [Personal Directory API v1](personal_directory_api_v1.md)
- [House Directory Contract v1](house_directory_v1.md)
- [Homes v2](../homes_v2.md)

```contracts-json
{
  "domain": "personal_directory",
  "version": "v1",
  "entities": {
    "MemberDirectoryBankAccount": {},
    "MemberDirectoryNote": {}
  },
  "functions": {},
  "rls": []
}
```
