# Contract — Country + Locale + Email Capture v1.0

## Meta

- **Domain**: Growth / Access
- **Capability**: Interest Capture (Country + Locale + Email)
- **Surface**: Kinly Web (/get)
- **Status**: Active
- **Owners**: Web, Edge, DB
- **Last updated**: 2026-01-20

## Purpose

Capture a user’s:

- `email`
- `country_code` (ISO 3166-1 alpha-2)
- `ui_locale` (BCP-47, e.g. en, en-NZ, zh-Hans)

This is used for:

- access requests / rollout tracking
- future localization prioritization
- lead/contact list segmentation

## Principles

1. **Best-effort detection, never treated as truth** Country and locale may be
   prefilled, but user can override.

2. **Client is not trusted** All values MUST be validated server-side (Edge +
   RPC).

3. **Idempotent submission** Same email + country + locale should not create
   duplicates.

4. **Minimal sensitive retention** Store only what we need; no IP storage
   required for v1.

5. **RPC-only DB writes** Edge Function MUST call RPC; no direct table insert
   from Edge.

## UX Requirements

### Country field

- UI MUST prefill a detected country when available.
- UI MUST allow user to override via:
  - full country list (alphabetical)
  - search input (type-to-filter)
- UI SHOULD show helper copy: “Prefilled from your device/network — change if
  needed.”

### Email field

- UI MUST validate email format and require non-empty.

### Submit

- Button MUST remain disabled until:
  - valid email
  - country_code present (2-letter uppercase)
- On submit, UI sends only:
  - `email`
  - `country_code`
  - `ui_locale`

## Data Definitions

### `country_code`

- **Type**: text
- **Format**: ISO 3166-1 alpha-2
- **Rules**: MUST match `^[A-Z]{2}$`

### `ui_locale`

- **Type**: text
- **Format**: BCP-47 (examples: en, en-NZ, zh-Hans, ms-SG)
- **Rules**:
  - MUST be 2–35 chars
  - MUST NOT contain spaces
  - SHOULD be normalized to canonical-ish casing: language lowercase (en),
    region uppercase (NZ), script TitleCase (Hans).

### `email`

- **Type**: text
- **Rules**:
  - trim whitespace
  - lowercase before storage
  - MUST pass server-side email validation

## System Detection Rules (Web)

### `ui_locale` detection (client)

Priority order:

1. `navigator.languages[0]`
2. `navigator.language`
3. server-provided fallback (if injected)

### `country_code` detection

Priority order:

1. stored previous selection (optional cookie/localStorage)
2. server-provided geo best-effort (if available)
3. empty (user chooses)

**Important**: Detection is used only to prefill; user override wins.

## API: Edge Function

**Endpoint**: `POST /functions/v1/interest_capture_v1`

### Request JSON

```json
{
    "email": "someone@example.com",
    "country_code": "AU",
    "ui_locale": "en-AU"
}
```

### Response JSON (success)

**Status**: 200 OK

```json
{
    "ok": true,
    "lead_id": "uuid",
    "deduped": true
}
```

### Response JSON (validation error)

**Status**: 400 Bad Request

```json
{
    "ok": false,
    "error": "validation_failed",
    "fields": {
        "email": "invalid",
        "country_code": "invalid"
    }
}
```

### Edge Validation (MUST)

- Reject if missing any required field.
- **Normalize**:
  - `email = lower(trim(email))`
  - `country_code = upper(trim(country_code))`
  - `ui_locale = trim(ui_locale)` (then apply casing normalization if
    implemented)
- **Validate**:
  - email format
  - country_code regex `^[A-Z]{2}$`
  - ui_locale basic constraints (length, no spaces)

### Abuse controls (SHOULD)

- Rate limit per IP (Edge-level) with a low threshold (e.g. 10/min). Return 429
  Too Many Requests.
- Add invisible honeypot field on web (optional).
- Reject obviously automated payloads (optional).

### Observability (SHOULD)

- Log: `request_id`, result ok/failed, validation failure fields.
- MUST NOT log raw email in plaintext logs (hash allowed).

## DB Write: RPC

**RPC name**: `public.leads_upsert_v1`

### Signature

```sql
leads_upsert_v1(
  p_email text,
  p_country_code text,
  p_ui_locale text,
  p_source text default 'kinly_web_get'
) returns jsonb
```

### Return JSONB

```json
{
    "lead_id": "uuid",
    "deduped": true
}
```

## Security

- RPC MUST be `SECURITY DEFINER`.
- RPC MUST set `search_path = ''`.
- RPC MUST NOT require user authentication (public form).
- Table `leads` MUST have Row Level Security (RLS) enabled to prevent direct
  access.

## Idempotency rules (MUST)

**Deduping key**: `email` (normalized lowercase)

**Behavior**:

- If email already exists:
  - update `country_code`, `ui_locale` only if new values are non-null
  - update `updated_at`
  - return `deduped = true`
- If email does not exist:
  - insert new row
  - return `deduped = false`

## Storage Contract

**Table**: `public.leads`

**Columns**:

- `id` uuid primary key default gen_random_uuid()
- `email` text not null (stored lowercased)
- `country_code` text not null
- `ui_locale` text not null
- `source` text not null default 'kinly_web_get'
- `created_at` timestamptz not null default now()
- `updated_at` timestamptz not null default now()

**Constraints (MUST)**:

- `unique (email)`
- `check (country_code ~ '^[A-Z]{2}$')`
- `check (position(' ' in ui_locale) = 0)`

**Indexes (SHOULD)**:

- index on `created_at desc` (for admin review)

## Failure Modes

- If geo detection is wrong: user can search + override.
- If locale is odd: accept basic strings, do not hard-fail on valid but uncommon
  tags.

## Non-goals (v1)

- No automatic translation behavior required.
- No double-opt-in email flows.
- No IP storage.
