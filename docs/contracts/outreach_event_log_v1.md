---
Domain: Growth
Capability: outreach_tracking
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.0
Audience: internal
---

# Contract — Outreach Event Logging v1.0

## Meta
- **Domain**: Outreach
- **Capability**: Marketing page outreach event logging (page views + CTAs)
- **Surface**: kinly-web marketing pages
- **Status**: Active
- **Owners**: Web, DB
- **Last updated**: 2026-01-29

## Purpose
Track page views and call-to-action clicks emitted by `kinly-web` marketing pages in a privacy-preserving, append-only Supabase log so we can measure outreach effectiveness without creating user profiles.

## Scope
- ✅ Storage + validation for anonymous outreach events
- ✅ Source resolution against a backend registry with safe `unknown` fallback
- ✅ RPC-only ingestion path (no direct client table access)
- ✅ Rate limiting (global + per-session)
- ❌ User or device identification
- ❌ Behavioral timelines or cross-surface correlation

## Data Model (Authoritative)

### Table `outreach_event_logs`
- `id` uuid, PK, default `gen_random_uuid()`
- `event` text, required; allowed: `page_view`, `cta_click`
- `app_key` text, required (e.g., `kinly-web`), max 40 chars
- `page_key` text, required, max 80 chars
- `utm_campaign` text, required, max 128 chars (trimmed, case preserved)
- `utm_source` text, required, stored lowercased, max 128 chars
- `utm_medium` text, required, stored lowercased, max 128 chars
- `source_id_resolved` text, required, default `unknown` (registry/alias match or fallback)
- `store` text, NOT NULL, default `unknown`; allowed: `web`, `ios_app_store`, `google_play`, `unknown`
- `session_id` text, required (client session token; opaque, not auth), format `^anon_[A-Za-z0-9_-]{16,32}$`, max 40 chars
- `country` text, nullable (uppercased ISO 3166-1 alpha-2; invalid → NULL)
- `ui_locale` text, nullable (BCP-47-ish 2–35 chars; spaces invalid → NULL)
- `client_event_id` uuid, nullable (idempotency key)
- `created_at` timestamptz, default `now()`

Indexes (minimum; created in migration):
- `(event, created_at)`
- `(utm_campaign, utm_source, utm_medium, created_at)`
- `(source_id_resolved, created_at)` (recommended)
- `(session_id)`
- unique `(client_event_id)` where not null

### Table `outreach_rate_limits`
- `k` text (sha256 of key)
- `bucket_start` timestamptz (window start, minute for global, hour for session)
- `n` integer (count)
- `updated_at` timestamptz
- PK `(k, bucket_start)`

Indexes:
- `(bucket_start)`
- `(updated_at)`

### Table `outreach_sources` (registry)
- `source_id` text, PK (canonical allowed source identifiers)
- `label` text, required (human-readable)
- `active` boolean, default `true`
- `created_at` timestamptz, default `now()`

Purpose: backend lookup for canonical sources. Registry maintenance is service-role only.

### Table `outreach_source_aliases` (registry aliases)
- `alias` text, PK (normalized, lowercased)
- `source_id` text, required FK → `outreach_sources.source_id`
- `active` boolean, default `true`
- `created_at` timestamptz, default `now()`

Purpose: map variant `utm_source` values to canonical sources.

## Insert Path (Authoritative)
- RPC: **`outreach.log_event`** (`public.outreach_log_event`)
- Auth: `anon` and `authenticated` may call; table writes occur via `SECURITY DEFINER`.
- Inputs (required): `event`, `app_key`, `page_key`, `utm_campaign`, `utm_source`, `utm_medium`, `session_id`
- Inputs (optional): `store`, `country`, `ui_locale`, `client_event_id`
- Validation:
  - `event` must be `page_view` or `cta_click`; otherwise `INVALID_EVENT`.
  - `store` defaults to `unknown`; when provided, must be in `web | ios_app_store | google_play | unknown`; otherwise `INVALID_STORE`.
  - `session_id` must match `^anon_[A-Za-z0-9_-]{16,32}$`; otherwise `INVALID_SESSION`.
  - Required text inputs must be non-empty after trim; length caps: `app_key`<=40, `page_key`<=80, `utm_*`<=128, `session_id`<=40; otherwise `INVALID_INPUT`.
  - `country` uppercased; must match `^[A-Z]{2}$` or is nulled; `ui_locale` must be 2–35 chars with no spaces or is nulled.
  - Backend lowercases `utm_source` and `utm_medium`; trims everything; preserves case for `utm_campaign`.
  - Blank `utm_*` or `store` inputs are coerced to `unknown` before validation.
- Source resolution (server-side only):
  1) match `utm_source` against `outreach_sources.active`
  2) else match against `outreach_source_aliases.active`
  3) else fallback `unknown`
  Resolution failure never aborts insert.
- Idempotency: when `client_event_id` provided, duplicate ids return existing row without inserting.
- Behavior:
  - Append-only insert into `outreach_event_logs`.
  - Returns `{ ok: true, id: <uuid> }` for observability; client should ignore for UX.
  - Function uses `SET search_path = ''` to avoid search-path exploits.
- Rate limits enforced inside RPC (bucketed):
  - Global: 500 events per minute → `RATE_LIMIT_GLOBAL`.
  - Per-session: 100 events per hour → `RATE_LIMIT_SESSION`.
  - Keys are hashed; buckets are `date_trunc('minute', now())` for global and `date_trunc('hour', now())` for per-session.

## RLS & Access Control (Authoritative)
- RLS enabled on `outreach_event_logs`, `outreach_sources`, `outreach_source_aliases`, and `outreach_rate_limits`.
- No client `select/insert/update/delete` on these tables.
- Only `public.outreach_log_event` may write `outreach_event_logs`.
- Service-role may maintain `outreach_sources`, `outreach_source_aliases`, and perform cleanup on `outreach_rate_limits`.

## Privacy Guardrails
- Do **not** store IP addresses, auth identifiers, device IDs, or cookies.
- `session_id` is opaque, client-generated, and must not be reused for user identity.
- No joins to auth tables; no retroactive association of outreach events to users.

## Allowed Analytics
- Aggregate counts by `event`, `utm_campaign`, `utm_source`, `utm_medium`, `store`.
- Aggregate counts by `source_id_resolved` (canonical, preferred for dashboards).
- Distinct `session_id` counts.
- Time-series of outreach events (`created_at` buckets).
- Campaign/source/medium summaries.

## Disallowed Analytics
- Individual behavioral timelines.
- Ranking/profiling of sessions or inferred users.
- Cross-surface correlation with in-app data.

## Failure Handling
- Validation failures return structured `api_error` codes (`INVALID_EVENT`, `INVALID_STORE`, `INVALID_SESSION`, `INVALID_INPUT`).
- Rate limit failures return `RATE_LIMIT_GLOBAL` or `RATE_LIMIT_SESSION`.
- Source resolution failures fall back to `unknown` without error.
- Client UX must not block navigation on failures; logging is best-effort.

## Success Criteria
- Outreach events are ingested reliably via RPC only.
- Invalid source IDs never break ingestion.
- No personal data is collected or inferable.
- Analytics remain aggregate-only and respect the privacy guardrails above.
