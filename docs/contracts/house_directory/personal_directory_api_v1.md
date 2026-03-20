---
Domain: Identity
Capability: Personal Directory API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Personal Directory API v1

Status: Proposed

Scope: Backend RPCs, storage invariants, and access rules for the personal
directory capability. The backend implementation uses `member_directory_*`
table and function names.

Audience: Product, design, engineering, AI agents.

Depends on:
- Personal Directory Contract v1
- Homes v2

## 1. Access model

- Caller MUST be authenticated for all RPCs.
- Own-record mutations enforce `auth.uid()` ownership.
- Reading another member's directory data requires shared active-home
  membership.
- Reading the caller's own bank account or notes requires only
  authentication.
- Direct client table DML MUST be denied; tables are RPC-only.
- Member roster discovery remains outside this API.

## 1.1 Client entry visibility

- Client surfaces MAY hide the owner-facing Personal Directory entry point when
  the owner has no bank account and no active notes.
- Owner-facing entry visibility is a product concern; it does not change the
  authenticated caller's RPC authorization to read or mutate their own
  Personal Directory data.

## 2. Canonical enums

### 2.1 `member_directory_note_type`
- `emergency_contact`
- `allergy`
- `other`

## 3. Storage model and invariants

### 3.1 `member_directory_bank_accounts`

Required fields:
- `id uuid pk`
- `user_id uuid fk profiles(id)`
- `account_holder_name text`
- `account_number text`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- one bank account per user: `unique(user_id)`
- `account_holder_name` must be non-empty after trim, max length `120`
- `account_number` must be non-empty after trim, max length `50`
- rows MUST NOT be deleted; they are updated in place

### 3.2 `member_directory_notes`

Required fields:
- `id uuid pk`
- `user_id uuid fk profiles(id)`
- `note_type text`
- `label text null`
- `custom_title text null`
- `contact_name text null`
- `phone_number text null`
- `details text null`
- `photo_path text null`
- `archived_at timestamptz null`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- `note_type` in canonical enum list
- `note_type='allergy'` requires non-empty trimmed `label` length `1..120`
- non-`allergy` rows require `label is null`
- `note_type='other'` requires non-empty trimmed `custom_title` length
  `1..80`
- non-`other` rows require `custom_title is null`
- `note_type='emergency_contact'` requires non-empty trimmed
  `contact_name` length `1..120` and `phone_number` length `1..30`
- non-`emergency_contact` rows require `contact_name is null` and
  `phone_number is null`
- `phone_number`, when present, must match `^[0-9+()\\- ]{1,30}$` and
  contain at least one digit
- `details` is optional for `emergency_contact`
- `details` is forbidden for `allergy`
- `details` is optional for `other`, but if present must be non-empty after
  trim and max length `2000`
- `photo_path` may be null; when present it must be at most `512`
  characters and must match
  `house_directory/{home_id}/member_directory/{user_id}/...`
- at most one active (non-archived) `emergency_contact` note per user
- at most `20` active (non-archived) `other` notes per user
- hard delete is forbidden; notes are archived via `archived_at`

### 3.3 `member_directory_nudge_dismissals`

Required fields:
- `user_id uuid fk profiles(id)`
- `home_id uuid fk homes(id)`
- `dismissed_at timestamptz`

Required constraints:
- primary key: `(user_id, home_id)`
- at most one dismissal per user per home

Behavioral invariants:
- a dismissed nudge MUST NOT reappear for the same `(user_id, home_id)`
- the v1 nudge only tracks missing bank account state
- the nudge MAY re-surface when the user joins a different home

## 4. RPC contract

### 4.1 `get_member_directory_bank_account() -> jsonb`

Caller: authenticated user.

Behavior:
- returns the caller's own bank account block
- works even when the caller is not in a home

Canonical response shape:

```json
{
  "ok": true,
  "has_bank_account": true,
  "bank_account": {
    "id": "uuid",
    "account_holder_name": "text",
    "account_number": "text",
    "created_at": "timestamptz",
    "updated_at": "timestamptz"
  }
}
```

### 4.2 `upsert_member_directory_bank_account(p_account_holder_name text, p_account_number text) -> jsonb`

Caller: authenticated user.

Behavior:
- creates the bank account if none exists; otherwise updates in place
- both inputs are trimmed for validation
- response includes `has_bank_account=true`

### 4.3 `get_member_directory_notes(p_target_user_id uuid|null default null) -> jsonb`

Caller: authenticated user.

Behavior:
- if `p_target_user_id` is null, returns the caller's notes
- if `p_target_user_id` is another user, caller MUST share an active home
  with that user
- archived notes are excluded
- ordering is:
  - `emergency_contact` first
  - `allergy` second, sorted by `lower(label)` then `id`
  - `other` after that, sorted by `created_at desc` then `id`

Canonical response shape:

```json
{
  "ok": true,
  "user_id": "uuid",
  "notes": [
    {
      "id": "uuid",
      "note_type": "text",
      "label": "text|null",
      "custom_title": "text|null",
      "contact_name": "text|null",
      "phone_number": "text|null",
      "details": "text|null",
      "photo_path": "text|null",
      "created_at": "timestamptz",
      "updated_at": "timestamptz"
    }
  ]
}
```

### 4.4 `get_member_bank_account(p_target_user_id uuid) -> jsonb`

Caller: authenticated user.

Behavior:
- if `p_target_user_id = auth.uid()`, returns the caller's own bank account
  without a home-membership check
- otherwise, caller MUST share an active home with the target user
- returns `bank_account` object or `null`

Canonical response shape:

```json
{
  "ok": true,
  "user_id": "uuid",
  "has_bank_account": true,
  "bank_account": {
    "id": "uuid",
    "account_holder_name": "text",
    "account_number": "text"
  }
}
```

### 4.5 `create_member_directory_note(p_note_type text, p_label text|null default null, p_custom_title text|null default null, p_contact_name text|null default null, p_phone_number text|null default null, p_details text|null default null, p_photo_path text|null default null) -> jsonb`

Caller: authenticated user.

Behavior:
- creates a new active note owned by the caller
- `p_note_type` must be one of `emergency_contact`, `allergy`, `other`
- `allergy` requires `p_label` and forbids `p_details`
- `other` requires `p_custom_title`
- `emergency_contact` requires `p_contact_name` and `p_phone_number`
- non-`emergency_contact` note types forbid contact fields
- if `p_photo_path` is present, the caller must have an active home because
  the path is validated against the current home id
- creating a second active `emergency_contact` fails with
  `MEMBER_DIRECTORY_NOTE_TYPE_CONFLICT`
- creating a 21st active `other` note fails with
  `MEMBER_DIRECTORY_OTHER_NOTE_LIMIT_REACHED`

### 4.6 `update_member_directory_note(p_note_id uuid, p_label text|null default null, p_custom_title text|null default null, p_contact_name text|null default null, p_phone_number text|null default null, p_details text|null default null, p_photo_path text|null default null) -> jsonb`

Caller: authenticated user.

Behavior:
- updates an existing active note owned by the caller
- the note type is inferred from stored data and cannot be changed through
  this RPC
- validation rules are re-applied based on the stored note type
- if the note is not found or is archived, returns
  `MEMBER_DIRECTORY_NOTE_NOT_FOUND`

### 4.7 `archive_member_directory_note(p_note_id uuid) -> jsonb`

Caller: authenticated user.

Behavior:
- soft-archives the note by setting `archived_at`
- idempotent shape via `already_archived`
- only the owning user can archive their own notes

### 4.8 `get_member_directory_nudge() -> jsonb`

Caller: authenticated user with an active home.

Behavior:
- resolves the caller's current active home implicitly
- the nudge is eligible only when the caller does not have a bank account
- if the nudge was already dismissed for `(auth.uid(), current_home_id)`,
  returns `show=false`

Canonical response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "show": true,
  "missing": ["bank_account"]
}
```

### 4.9 `dismiss_member_directory_nudge() -> jsonb`

Caller: authenticated user with an active home.

Behavior:
- resolves the caller's current active home implicitly
- records a dismissal for `(auth.uid(), current_home_id)`
- idempotent via `already_dismissed=true`

## 5. Error envelope and codes

Error envelope:

```json
{ "code": "STRING_CODE", "message": "Human readable", "details": {} }
```

Required codes:
- `UNAUTHORIZED`
- `NOT_HOME_MEMBER`
- `MEMBER_DIRECTORY_INVALID_ENUM`
- `MEMBER_DIRECTORY_INVALID_INPUT`
- `MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS`
- `MEMBER_DIRECTORY_ALLERGY_LABEL_REQUIRED`
- `MEMBER_DIRECTORY_ALLERGY_LABEL_FORBIDDEN`
- `MEMBER_DIRECTORY_EMERGENCY_CONTACT_REQUIRED_FIELDS`
- `MEMBER_DIRECTORY_OTHER_TITLE_REQUIRED`
- `MEMBER_DIRECTORY_OTHER_TITLE_FORBIDDEN`
- `MEMBER_DIRECTORY_CONTACT_FIELDS_FORBIDDEN`
- `MEMBER_DIRECTORY_DETAILS_FORBIDDEN`
- `MEMBER_DIRECTORY_INVALID_PHONE_NUMBER`
- `MEMBER_DIRECTORY_NOTE_TYPE_CONFLICT`
- `MEMBER_DIRECTORY_OTHER_NOTE_LIMIT_REACHED`
- `MEMBER_DIRECTORY_NOTE_NOT_FOUND`
- `MEMBER_DIRECTORY_NOTE_INVALID_PHOTO_PATH`

## 6. Privacy and security requirements

- Bank account `account_number` is sensitive operational data.
- Logging and telemetry MUST NOT include `account_number`.
- `get_member_bank_account` MUST enforce shared active-home membership for
  non-self reads.
- Own-record RPCs MUST enforce `auth.uid()` ownership.

## 7. Contract test scenarios

- Authenticated user reads own bank account and receives
  `has_bank_account`.
- Bank account upsert creates on first call and updates on later calls.
- Bank account upsert without `account_holder_name` fails with
  `MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS`.
- Bank account upsert without `account_number` fails with
  `MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS`.
- User with no home can read and mutate own bank account.
- User with no home can read own notes and create a note without a photo.
- Shared-home member can read another member's notes.
- Non-home-member cannot read another user's notes.
- Shared-home member can read another member's bank account through
  `get_member_bank_account`.
- Non-home-member cannot read another user's bank account.
- `get_member_bank_account` with own user id succeeds without a home.
- Creating `emergency_contact` without `contact_name` or `phone_number`
  fails with `MEMBER_DIRECTORY_EMERGENCY_CONTACT_REQUIRED_FIELDS`.
- Creating `allergy` without `label` fails with
  `MEMBER_DIRECTORY_ALLERGY_LABEL_REQUIRED`.
- Creating `allergy` with `details` fails with
  `MEMBER_DIRECTORY_DETAILS_FORBIDDEN`.
- Creating `other` without `custom_title` fails with
  `MEMBER_DIRECTORY_OTHER_TITLE_REQUIRED`.
- Non-`other` note with `custom_title` fails with
  `MEMBER_DIRECTORY_OTHER_TITLE_FORBIDDEN`.
- Non-`emergency_contact` note with contact fields fails with
  `MEMBER_DIRECTORY_CONTACT_FIELDS_FORBIDDEN`.
- Creating a second active `emergency_contact` fails with
  `MEMBER_DIRECTORY_NOTE_TYPE_CONFLICT`.
- Creating a 21st active `other` note fails with
  `MEMBER_DIRECTORY_OTHER_NOTE_LIMIT_REACHED`.
- Note with invalid `photo_path` fails with
  `MEMBER_DIRECTORY_NOTE_INVALID_PHOTO_PATH`.
- Updating an `allergy` note with `details` fails with
  `MEMBER_DIRECTORY_DETAILS_FORBIDDEN`.
- Archiving sets `archived_at`, archived notes are excluded from reads, and
  archive is idempotent.
- User cannot archive another user's note.
- Notes response is ordered as implemented: `emergency_contact`, then
  `allergy`, then `other`.
- `get_member_directory_nudge` returns `show=true` with
  `missing=["bank_account"]` when bank account is absent and the nudge has
  not been dismissed for the current home.
- `get_member_directory_nudge` returns `show=false` when bank account
  exists or the nudge is already dismissed.
- `dismiss_member_directory_nudge` persists dismissal for the current home.

## 8. References

- [Personal Directory Contract v1](../../../product/kinly/shared/personal_directory_v1.md)
- [Homes v2](../homes/homes_v2.md)

```contracts-json
{
  "domain": "personal_directory_api",
  "version": "v1",
  "entities": {
    "MemberDirectoryBankAccount": {},
    "MemberDirectoryNote": {},
    "MemberDirectoryNudgeDismissal": {}
  },
  "functions": {
    "personalDirectory.getBankAccount": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.get_member_directory_bank_account",
      "args": {},
      "returns": "jsonb"
    },
    "personalDirectory.upsertBankAccount": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.upsert_member_directory_bank_account",
      "args": {
        "p_account_holder_name": "text",
        "p_account_number": "text"
      },
      "returns": "jsonb"
    },
    "personalDirectory.getNotes": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.get_member_directory_notes",
      "args": {
        "p_target_user_id": "uuid|null"
      },
      "returns": "jsonb"
    },
    "personalDirectory.getMemberBankAccount": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.get_member_bank_account",
      "args": {
        "p_target_user_id": "uuid"
      },
      "returns": "jsonb"
    },
    "personalDirectory.createNote": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.create_member_directory_note",
      "args": {
        "p_note_type": "text",
        "p_label": "text|null",
        "p_custom_title": "text|null",
        "p_contact_name": "text|null",
        "p_phone_number": "text|null",
        "p_details": "text|null",
        "p_photo_path": "text|null"
      },
      "returns": "jsonb"
    },
    "personalDirectory.updateNote": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.update_member_directory_note",
      "args": {
        "p_note_id": "uuid",
        "p_label": "text|null",
        "p_custom_title": "text|null",
        "p_contact_name": "text|null",
        "p_phone_number": "text|null",
        "p_details": "text|null",
        "p_photo_path": "text|null"
      },
      "returns": "jsonb"
    },
    "personalDirectory.archiveNote": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.archive_member_directory_note",
      "args": {
        "p_note_id": "uuid"
      },
      "returns": "jsonb"
    },
    "personalDirectory.getNudge": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.get_member_directory_nudge",
      "args": {},
      "returns": "jsonb"
    },
    "personalDirectory.dismissNudge": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.dismiss_member_directory_nudge",
      "args": {},
      "returns": "jsonb"
    }
  },
  "rls": []
}
```
