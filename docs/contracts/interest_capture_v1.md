# Contract — Country + Locale + Email Capture v1.0

## Meta

- **Domain**: Growth / Access
- **Capability**: Interest Capture (Country + Locale + Email)
- **Surface**: Kinly Web (/get)
- **Status**: Active
- **Owners**: Web, DB
- **Last updated**: 2026-03-22

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

5. **RPC-only DB writes** Web calls RPC directly via supabase-js; no other write
   path.

## UX Requirements

### Country field

- UI MUST prefill a detected country when available.
- UI MUST allow user to override via:
  - full country list (alphabetical)
  - search input (type-to-filter)
- UI SHOULD show helper copy: “Prefilled from your device/network — change if
  needed.”

### Locale handling

- `ui_locale` MUST be auto-detected by the client.
- `ui_locale` MUST NOT be a visible form field in v1.
- UI MUST always send a resolved `ui_locale` value.
- If detection fails or yields an invalid value, UI MUST fallback to `"en"`.

### Email field

- UI MUST validate email format and require non-empty.

### Submit

- Button MUST remain disabled until:
  - valid email
  - country_code present (2-letter uppercase)
  - `ui_locale` resolved (auto-detected or fallback)
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

## UI Error Handling Rules

- Validation errors:
  - Show inline field error copy.
  - Keep submit enabled after correction.

- Rate limit errors (`LEADS_RATE_LIMIT_*`):
  - Show non-blocking message: “Too many attempts. Please try again later.”
  - UI MAY temporarily disable submit (cooldown optional).

- Deduped success:
  - Treated as success; show normal confirmation UI.

- Unknown errors:
  - Show generic retry message.

## API: RPC (direct from web)

- **RPC name**: `public.leads_upsert_v1`
- **Invocation**: `supabase-js` from `kinly-web`
- **Edge Function**: Not used
- **Approval**: This RPC is explicitly approved for direct Web invocation
  under `AGENTS.md`.

- **Inputs**:
  - `p_email` (text) — required
  - `p_country_code` (text) — required
  - `p_ui_locale` (text) — required
  - `p_source` (text, default `kinly_web_get`) — optional override for other
    campaigns: `kinly_dating_web_get`, `kinly_rent_web_get`

### Request example

```json
{
  "p_email": "someone@example.com",
  "p_country_code": "AU",
  "p_ui_locale": "en-AU"
}
```

### Response JSON (success)

```json
{
  "ok": true,
  "lead_id": "uuid",
  "deduped": true
}
```

### Errors (api_assert)

- `LEADS_MISSING_FIELDS` — email, country_code, ui_locale required.
- `LEADS_EMAIL_TOO_LONG` — >254 chars.
- `LEADS_EMAIL_TOO_SHORT` — <3 chars.
- `LEADS_EMAIL_INVALID` — fails basic format check (must include `@` and a dot
  after `@`, no spaces).
- `LEADS_COUNTRY_CODE_INVALID` — not `^[A-Z]{2}$`.
- `LEADS_UI_LOCALE_INVALID` — not 2–35 chars, has spaces, or fails light
  BCP-47-ish regex `^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$`.
- `LEADS_SOURCE_INVALID` — not in allowlist.
- `LEADS_RATE_LIMIT_GLOBAL` — global limiter exceeded (per minute).
- `LEADS_RATE_LIMIT_EMAIL` — per-email limiter exceeded (per day).

### Normalization inside RPC

- `p_email = trim(p_email)` (case is preserved; uniqueness is case-insensitive
  via `citext`).
- `p_country_code = upper(trim(p_country_code))`.
- `p_ui_locale = trim(p_ui_locale)`.
- `p_source = trim(...)` with default `kinly_web_get` when blank.

### Rate limits (RPC-level)

- Global: 300 requests per minute (hashed key, advisory lock serialized).
- Per-email: 5 submissions per email per day (case-insensitive via `citext`).
- No IP handling; frontend SHOULD throttle to avoid waste.

### Deduping semantics

- Key: `email` (case-insensitive via `citext`).
- `deduped = true` when an existing row was updated; `false` when inserted.
- `source`, `country_code`, and `ui_locale` are overwritten with the latest
  provided values on conflict.

## Security

- RPC MUST be `SECURITY DEFINER`.
- RPC MUST set `search_path = ''`.
- RPC MUST NOT require user authentication (public form).
- Tables `leads` and `leads_rate_limits` MUST have Row Level Security (RLS)
  enabled.
- Revoke all table privileges from `anon` and `authenticated`; allow only RPC
  execution.

## Idempotency rules (MUST)

**Deduping key**: `email` (case-insensitive via `citext`)

**Behavior**:

- If email already exists: overwrite `country_code`, `ui_locale`, `source`; set
  `deduped = true`.
- If email does not exist: insert row; `deduped = false`.

## Storage Contract

**Table**: `public.leads`

**Columns**:

- `id` uuid primary key default gen_random_uuid()
- `email` citext not null (case-insensitive uniqueness)
- `country_code` text not null
- `ui_locale` text not null
- `source` text not null default 'kinly_web_get'
- `created_at` timestamptz not null default now()
- `updated_at` timestamptz not null default now()

**Constraints (MUST)**:

- `unique (email)` via `citext`
- `check (country_code ~ '^[A-Z]{2}$')`
- `check (position(' ' in ui_locale) = 0)`
- `check (source in ('kinly_web_get', 'kinly_dating_web_get', 'kinly_rent_web_get'))`

**Indexes (SHOULD)**:

- index on `created_at desc` (for admin review)

**Rate limit store**: `public.leads_rate_limits`

- `k text primary key` (sha256 hex of key+window)
- `n integer not null`
- `updated_at timestamptz not null`
- Index on `updated_at`

## Failure Modes

- If geo detection is wrong: user can search + override.
- If locale is odd: accept basic strings, do not hard-fail on valid but uncommon
  tags.

## Non-goals (v1)

- No automatic translation behavior required.
- No double-opt-in email flows.
- No IP storage; no IP-based rate limiting.
