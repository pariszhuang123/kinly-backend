---
Domain: Homes
Capability: House Directory API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.1
---

# House Directory API v1

Status: Proposed

Scope: Backend RPCs, storage invariants, reminder semantics, and access rules
for House Directory.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Directory Contract v1
- Homes v2

## 1. Access model

- Caller MUST be authenticated for all RPCs.
- Read RPCs require current home membership and active home.
- Owner mutations require active home and owner role for the target home.
- Reminder acknowledgement requires current member access.
- Direct client table DML MUST be denied; tables are RPC-only.

## 2. Canonical enums

### 2.1 `home_directory_service_type`
- `rent`
- `internet`
- `electricity`
- `gas`
- `water`
- `other`

### 2.2 `home_directory_reminder_kind`
- `renewal`

### 2.3 `home_directory_reminder_status`
- `active`
- `dismissed`
- `retired`

### 2.4 `home_directory_reminder_offset_unit`
- `day`
- `week`
- `month`

## 3. Storage model and invariants

### 3.1 `home_directory_wifi`

Required fields:
- `id uuid pk`
- `home_id uuid fk homes(id)`
- `ssid text`
- `password text null`
- `created_by_user_id uuid`
- `updated_by_user_id uuid`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- one wifi row per home: `unique(home_id)`
- ssid length: `1..64`
- password may be null but MUST NOT be whitespace-only
- password max length `128`

Read invariants:
- read RPCs MUST NOT return plaintext `password`
- QR payload is returned instead

QR payload rules:
- no password: `WIFI:T:nopass;S:<ssid>;;`
- with password: `WIFI:T:WPA;S:<ssid>;P:<password>;;`
- escape in `ssid/password`: `\`, `;`, `,`, `:`

### 3.2 `home_directory_services`

Required fields:
- `id uuid pk`
- `home_id uuid fk homes(id)`
- `service_type text`
- `custom_label text null`
- `provider_name text`
- `account_reference text null`
- `link_url text null`
- `term_start_date date null`
- `term_end_date date null`
- `renewal_reminder_offset_value integer null`
- `renewal_reminder_offset_unit text null`
- `notes text null`
- `archived_at timestamptz null`
- `created_by_user_id uuid`
- `updated_by_user_id uuid`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- `service_type` in canonical enum list
- `service_type='other'` requires non-empty trimmed `custom_label` length `1..40`
- non-`other` services require `custom_label is null`
- `link_url` may be null; if present it must be `http/https`
- `term_end_date` requires `term_start_date`
- if both term dates exist: `term_start_date <= term_end_date`
- `service_type='rent'` requires both term dates
- reminder offset fields appear as a pair
- if reminder offset exists:
  - `renewal_reminder_offset_value >= 1`
  - unit in `day|week|month`
  - term dates must exist
  - computed due date must fall within the inclusive term window
- only one active `rent`, `internet`, and `electricity` service per home

### 3.3 `home_directory_service_reminders`

Required fields:
- `id uuid pk`
- `service_id uuid fk home_directory_services(id)`
- `reminder_kind text`
- `status text`
- `term_start_date date`
- `term_end_date date`
- `due_at date`
- `dismissed_at timestamptz null`
- `dismissed_by_user_id uuid null`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- `reminder_kind='renewal'`
- `status in ('active','dismissed','retired')`
- unique identity:
  - `service_id`
  - `reminder_kind`
  - `term_start_date`
  - `term_end_date`
- `term_start_date <= term_end_date`
- `term_start_date <= due_at <= term_end_date`
- dismissal fields align with status

Behavioral invariants:
- archived or invalid services do not delete reminder history; rows become `retired`
- reminder materialization occurs on service writes/archives
- materially changed reminders are reopened as `active`

### 3.4 `home_directory_service_reminder_acknowledgements`

Required fields:
- `reminder_id uuid fk home_directory_service_reminders(id)`
- `user_id uuid fk profiles(id)`
- `acknowledged_at timestamptz`

Required constraints:
- primary key: `(reminder_id, user_id)`
- at most one acknowledgement per member per reminder row

### 3.5 `home_directory_notes`

Required fields:
- `id uuid pk`
- `home_id uuid fk homes(id)`
- `title text`
- `details text null`
- `note_type text not null default 'general'`
- `reference_url text null`
- `photo_path text null`
- `archived_at timestamptz null`
- `created_by_user_id uuid`
- `updated_by_user_id uuid`
- `created_at timestamptz`
- `updated_at timestamptz`

Required constraints:
- `title` must be non-empty after trim
- `details` may be null
- `note_type` must be `general` or `tutorial` (check constraint, not enum)
- `reference_url` may be null; if present it must be `http/https`
- `photo_path` may be null; if present it must be a storage reference under `households/%`
- at most one photo path may be attached per active note row in v1

## 4. Reminder semantics

- Eligible when the service is active and both term dates exist.
- `due_at` is computed from the configured offset:
  - default: `3 months` before `term_end_date`
  - explicit units allowed: `day`, `week`, `month`
- Due date must satisfy `term_start_date <= due_at <= term_end_date`.
- Current-date comparisons use UTC calendar date in v1.

Actionability:
- listed in Today when:
  - reminder row status is `active`
  - service is not archived
  - service term still matches the reminder identity
  - current UTC date is on/after `due_at`
  - current caller has not acknowledged the reminder
- owner may dismiss actionable reminders
- members may acknowledge actionable reminders

## 5. RPC contract

### 5.1 `get_home_directory_wifi(p_home_id uuid) -> jsonb`

Caller: member.

Returns:
- `wifi` object or `null`
- never returns raw `password`

Canonical response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "wifi": {
    "id": "uuid",
    "home_id": "uuid",
    "ssid": "text",
    "qr_payload": "text",
    "created_at": "timestamptz",
    "updated_at": "timestamptz"
  }
}
```

### 5.2 `upsert_home_directory_wifi(p_home_id uuid, p_ssid text, p_password text|null default null) -> jsonb`

Caller: owner-only.

Behavior:
- upserts the single wifi row by `home_id`
- password may be null, but not whitespace-only
- response omits raw password and returns QR payload only

### 5.3 `get_home_directory_content(p_home_id uuid) -> jsonb`

Caller: member.

Returns:
- `services` array ordered by `provider_name` asc, then `created_at` desc, then `id`
- `notes` array (note_type=`general`) ordered by `title` asc, then `created_at` desc, then `id`
- `tutorials` array (note_type=`tutorial`) ordered by `title` asc, then `created_at` desc, then `id`
- both `notes` and `tutorials` come from the `home_directory_notes` table, split by `note_type`
- archived services and notes are excluded

### 5.4 `upsert_home_directory_service(p_home_id uuid, p_service_id uuid|null default null, p_service_type text, p_custom_label text|null default null, p_provider_name text, p_account_reference text|null default null, p_link_url text|null default null, p_term_start_date date|null default null, p_term_end_date date|null default null, p_renewal_reminder_offset_value integer|null default null, p_renewal_reminder_offset_unit text|null default null, p_notes text|null default null) -> jsonb`

Caller: owner-only.

Behavior:
- create/update service using replace semantics
- recompute reminder state on every write
- returns current service plus current non-retired reminder for the matching term, or `null`

### 5.5 `archive_home_directory_service(p_home_id uuid, p_service_id uuid) -> jsonb`

Caller: owner-only.

Behavior:
- soft-archives the service
- retires associated reminder rows
- idempotent shape via `already_archived`

### 5.6 `upsert_home_directory_note(p_home_id uuid, p_note_id uuid|null default null, p_title text, p_details text|null default null, p_note_type text default 'general', p_reference_url text|null default null, p_photo_path text|null default null) -> jsonb`

Caller: owner-only.

Behavior:
- create/update note using replace semantics
- `note_type` defaults to `general`; owner may change type on update
- `title` is required and trimmed for validation; `details` is optional
- `reference_url` may be null, but if present it must be `http/https`
- `photo_path` may be null; when present it stores a storage reference only
- `photo_path` must match `households/%` when present
- the first add for a note enforces the note-photo usage limit when the home is not premium
- clearing or archiving a note photo does not refund prior usage
- replacing an existing `photo_path` MUST NOT count as a second paid usage event

### 5.7 `archive_home_directory_note(p_home_id uuid, p_note_id uuid) -> jsonb`

Caller: owner-only.

Behavior:
- soft-archives the note
- idempotent shape via `already_archived`

### 5.8 `list_due_home_directory_reminders(p_home_id uuid) -> jsonb`

Caller: member.

Returns due reminders ordered by `due_at`, `provider_name`, `service_id`.

Canonical response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "today_utc_date": "date",
  "due_reminders": []
}
```

### 5.9 `acknowledge_home_directory_reminder(p_home_id uuid, p_reminder_id uuid) -> jsonb`

Caller: member.

Behavior:
- acknowledges an actionable due reminder for the caller only
- idempotent on repeated acknowledgement of the same reminder by the same user

### 5.10 `dismiss_home_directory_reminder(p_home_id uuid, p_reminder_id uuid) -> jsonb`

Caller: owner-only.

Behavior:
- dismisses an actionable due reminder globally
- returns `already_dismissed=true` if the target row is already dismissed
- returns `HOUSE_DIRECTORY_REMINDER_NOT_ACTIONABLE` if the row exists but is not currently actionable

## 6. Error envelope and codes

Error envelope:

```json
{ "code": "STRING_CODE", "message": "Human readable", "details": {} }
```

Required codes:
- `UNAUTHORIZED`
- `NOT_HOME_MEMBER`
- `FORBIDDEN_OWNER_ONLY`
- `INVALID_HOME`
- `HOME_NOT_FOUND`
- `HOME_INACTIVE`
- `HOUSE_DIRECTORY_INVALID_ENUM`
- `HOUSE_DIRECTORY_INVALID_INPUT`
- `HOUSE_DIRECTORY_INVALID_TERM_RANGE`
- `HOUSE_DIRECTORY_RENT_TERM_REQUIRED`
- `HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET`
- `HOUSE_DIRECTORY_OTHER_LABEL_REQUIRED`
- `HOUSE_DIRECTORY_OTHER_LABEL_FORBIDDEN`
- `HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT`
- `HOUSE_DIRECTORY_SERVICE_NOT_FOUND`
- `HOUSE_DIRECTORY_NOTE_INVALID_TYPE`
- `HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS`
- `HOUSE_DIRECTORY_NOTE_INVALID_URL`
- `HOUSE_DIRECTORY_NOTE_NOT_FOUND`
- `HOUSE_DIRECTORY_REMINDER_NOT_FOUND`
- `HOUSE_DIRECTORY_REMINDER_NOT_ACTIONABLE`

## 7. Privacy and security requirements

- Wifi password is sensitive operational data.
- Wifi read and write responses MUST NOT include plaintext password.
- Logging and telemetry MUST NOT include plaintext wifi password.
- Returned data MUST exclude unrelated personal directory records.

## 8. Contract test scenarios

- Member reads wifi/content/due reminders successfully.
- Non-owner cannot mutate wifi, services, notes, or dismiss reminders.
- Wifi upsert rejects whitespace-only password and read omits password.
- Rent service without term dates fails with `HOUSE_DIRECTORY_RENT_TERM_REQUIRED`.
- Note create/update without `title` fails with `HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS`.
- Note with invalid `note_type` fails with `HOUSE_DIRECTORY_NOTE_INVALID_TYPE`.
- `get_home_directory_content` returns `notes` and `tutorials` as separate arrays split by `note_type`.
- Note with invalid `reference_url` fails with `HOUSE_DIRECTORY_NOTE_INVALID_URL`.
- Invalid reminder offset pair or invalid offset range fails with `HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET`.
- Due reminders appear only when current UTC date is on/after `due_at`.
- Member acknowledgement hides reminder for that member only.
- Owner dismissal removes the reminder from due-reminder results.
- Archived services and notes disappear from content reads.
- Active rent/internet/electricity uniqueness conflicts surface `HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT`.

## 9. References

- [House Directory Contract v1](../../../product/kinly/shared/house_directory_v1.md)
- [Homes v2](./homes_v2.md)

```contracts-json
{
  "domain": "house_directory_api",
  "version": "v1",
  "entities": {
    "HomeDirectoryWifi": {},
    "HomeDirectoryService": {},
    "HomeDirectoryServiceReminder": {},
    "HomeDirectoryServiceReminderAcknowledgement": {},
    "HouseNote": {}
  },
  "functions": {
    "houseDirectory.getWifi": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.get_home_directory_wifi",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.upsertWifi": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.upsert_home_directory_wifi",
      "args": {
        "p_home_id": "uuid",
        "p_ssid": "text",
        "p_password": "text|null"
      },
      "returns": "jsonb"
    },
    "houseDirectory.getContent": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.get_home_directory_content",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.upsertService": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.upsert_home_directory_service",
      "args": {
        "p_home_id": "uuid",
        "p_service_id": "uuid|null",
        "p_service_type": "text",
        "p_custom_label": "text|null",
        "p_provider_name": "text",
        "p_account_reference": "text|null",
        "p_link_url": "text|null",
        "p_term_start_date": "date|null",
        "p_term_end_date": "date|null",
        "p_renewal_reminder_offset_value": "int4|null",
        "p_renewal_reminder_offset_unit": "text|null",
        "p_notes": "text|null"
      },
      "returns": "jsonb"
    },
    "houseDirectory.archiveService": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.archive_home_directory_service",
      "args": {
        "p_home_id": "uuid",
        "p_service_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.upsertNote": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.upsert_home_directory_note",
      "args": {
        "p_home_id": "uuid",
        "p_note_id": "uuid|null",
        "p_title": "text",
        "p_details": "text|null",
        "p_note_type": "text",
        "p_reference_url": "text|null",
        "p_photo_path": "text|null"
      },
      "returns": "jsonb"
    },
    "houseDirectory.archiveNote": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.archive_home_directory_note",
      "args": {
        "p_home_id": "uuid",
        "p_note_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.listDueReminders": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.list_due_home_directory_reminders",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.acknowledgeReminder": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.acknowledge_home_directory_reminder",
      "args": {
        "p_home_id": "uuid",
        "p_reminder_id": "uuid"
      },
      "returns": "jsonb"
    },
    "houseDirectory.dismissReminder": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.dismiss_home_directory_reminder",
      "args": {
        "p_home_id": "uuid",
        "p_reminder_id": "uuid"
      },
      "returns": "jsonb"
    }
  },
  "rls": []
}
```
