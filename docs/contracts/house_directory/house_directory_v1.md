---
Domain: Homes
Capability: House Directory
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# House Directory Contract v1

Status: Proposed

Scope: Shared home operational reference data for wifi access, home services,
home links, and due renewal reminders derived from service terms.

Audience: Product, design, engineering, AI agents.

Depends on:
- Homes v2 (membership and role model)
- Personal Directory capability (separate person-scoped information)
- House Norms capability (separate behavior/social agreements)

## 1. Purpose

House Directory provides a structured source of truth for shared household
operations.

House Directory MUST support:
- wifi access details
- home service references
- home-related external links
- due renewal reminders for time-bound services

## 2. Scope and boundaries

In scope:
- shared home operations, not person-specific records
- URL references, not file hosting
- reminder timing derived from service term windows and configured offsets
- per-member acknowledgement of due reminders

Out of scope:
- House Norms content and workflows
- standalone House Rules policy workflows
- personal bank/emergency/document records
- binary document upload and hosting
- enterprise/hidden-network wifi QR variants

## 3. Core entities

### 3.1 Wifi profile
- A home MAY have at most one wifi profile.
- Wifi profile includes `ssid` and optional `password`.
- Raw password MAY be stored server-side for owner updates and QR generation.
- Public/member RPC reads MUST NOT return the raw password.
- QR payload is derived from stored wifi values.

### 3.2 Home service
- Represents one shared home service record:
  - `rent`
  - `internet`
  - `electricity`
  - `gas`
  - `water`
  - `other`
- `service_type='internet'` is distinct from the wifi credentials profile.
- `other` requires non-empty `custom_label`.
- Each service includes `provider_name`, optional `account_reference`,
  optional `link_url`, optional term dates, optional reminder offset, and
  optional notes.
- `rent` MUST include both `term_start_date` and `term_end_date`.
- Services and links are soft-archived with `archived_at`.
- Active service uniqueness is enforced for:
  - one active `rent` per home
  - one active `internet` per home
  - one active `electricity` per home

### 3.3 Home link
- Represents a curated external home link with tags:
  - `rent`
  - `bond`
  - `utilities`
  - `other`
- Tag `other` requires `custom_tag`.
- Link rows are URL references only.
- Links are soft-archived with `archived_at`.

### 3.4 Renewal reminder
- Renewal reminders are derived, not user-authored.
- Reminder eligibility requires:
  - active service row
  - both `term_start_date` and `term_end_date`
  - valid reminder offset or default offset
- Default reminder timing is `3 months` before `term_end_date`.
- Allowed explicit units are `day`, `week`, `month`.
- `term_end_date` is inclusive in v1.
- A due reminder is actionable only when current UTC date is on or after
  `due_at`.

### 3.5 Reminder acknowledgement
- A due reminder MAY be acknowledged by each current member independently.
- Acknowledgement hides that reminder from that member’s due-reminder list.
- Material reminder changes reopen visibility by clearing acknowledgements.

## 4. Reminder lifecycle invariants

- Reminder identity is scoped to:
  - `service_id`
  - `reminder_kind`
  - `term_start_date`
  - `term_end_date`
- Dismissal is owner-driven and applies to the reminder row.
- Acknowledgement is member-specific and does not dismiss the reminder globally.
- If term dates or reminder timing change materially, the reminder is reopened
  as `active` and prior acknowledgements are cleared.
- If a service is archived or no valid due date exists, reminder rows are
  retained as `retired`.
- If current UTC date is before `due_at`, the reminder is not actionable in
  Today.

## 5. Access and privacy rules

- Read access:
  - wifi read: current home members on active homes
  - directory content read: current home members on active homes
  - due reminders read: current home members on active homes
- Write access:
  - wifi/service/link create-update-archive: current home owner only
  - reminder dismiss: current home owner only
  - reminder acknowledge: current home members
- Wifi password is sensitive operational data:
  - storage is allowed for home operations
  - UI SHOULD mask by default when displayed outside explicit reveal flow
  - value MUST NOT be emitted to telemetry payloads
  - public/member read RPCs MUST NOT return the raw password

## 6. Cross-capability relationships

- House Directory stores shared operational facts.
- House Norms stores shared behavioral expectations.
- Personal Directory stores person-specific records.
- Contracts MUST remain separated; cross-links are allowed, duplication is not.

## 7. Contract test scenarios

- Non-owner cannot mutate wifi, services, links, or dismiss reminders.
- Member can read wifi/content and acknowledge due reminders.
- Wifi read returns `ssid` and `qr_payload` but not raw password.
- Rent service creation without term dates is rejected.
- Invalid reminder offset pair or out-of-range offset is rejected.
- A due reminder appears when current UTC date is on or after `due_at`.
- Member acknowledgement hides the reminder only for that member.
- Owner dismissal removes the reminder from due-reminder results.
- Archiving a service retires its reminder and removes it from content reads.
- Archived links are excluded from content reads.

## 8. References

- [House Directory API v1](./house_directory_api_v1.md)
- [Homes v2](../homes_v2.md)

```contracts-json
{
  "domain": "house_directory",
  "version": "v1",
  "entities": {
    "WifiProfile": {},
    "HomeService": {},
    "HomeLink": {},
    "HomeServiceReminder": {},
    "HomeServiceReminderAcknowledgement": {}
  },
  "functions": {},
  "rls": []
}
```
