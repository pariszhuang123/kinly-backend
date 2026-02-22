---
Domain: Growth
Capability: outreach_short_links
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0.1
Audience: internal
Last updated: 2026-02-22
---

# Contract - Outreach Short Links v1.0.1

## Purpose
Provide scan-friendly short URLs on `go.makinglifeeasie.com/<code>` that redirect to canonical Kinly marketing URLs while preserving campaign tracking and producing aggregate attribution events.

This contract defines:
- Short code identity (`CITEXT`) and uniqueness rules.
- Redirect resolution behavior.
- Storage model for link definitions.
- Safety and privacy constraints.
- Effective-active semantics for expiry.

This contract complements:
- `docs/contracts/outreach_event_log_v1.md`

## Design Critique (Normative)
The proposed direction is sound. The following issues MUST be handled explicitly:

1. Collision risk:
- Short codes MUST be unique case-insensitively.
- Code generation MUST retry on collision and return deterministic error `SHORT_CODE_COLLISION_EXHAUSTED` after bounded attempts.

2. Open redirect risk:
- Destination URLs MUST be restricted to an allowlist (`go.makinglifeeasie.com` and approved Kinly web hosts).
- Arbitrary external redirects MUST NOT be allowed.

3. Tracking drift:
- Canonical tracking metadata MUST be stored in the short-link row, not derived from mutable client input at redirect time.
- Redirect appends/overrides query params from the canonical snapshot.
- Redirect analytics MUST reuse `outreach_event_logs` rather than duplicating a second click table.

4. Link lifecycle:
- Soft disable MUST be supported (`active=false`) so historical attribution remains intact.
- Hard delete SHOULD be service-role only and discouraged after production use.

5. QR scan ergonomics:
- Public codes SHOULD be 6 to 10 characters, lowercase, URL-safe.
- Ambiguous characters (`0`, `O`, `I`, `l`) SHOULD be excluded for manually typed codes.

## Canonical Short URL Shape
- Base: `https://go.makinglifeeasie.com`
- Public shape: `/<short_code>`
- Example: `https://go.makinglifeeasie.com/k8m4qz`

Rules:
- `short_code` MUST be stored as `citext`.
- Resolver MUST normalize and resolve case-insensitively.
- Producer MUST emit lowercase codes.

## Environment Host Mapping (Normative)
Short-link records are host-agnostic. They MUST store only:
- `target_path`
- `target_query`
- canonical tracking metadata (`utm_*`, `app_key`, `page_key`)

Resolver MUST choose redirect host by runtime environment:
- `production` -> `https://go.makinglifeeasie.com`
- `staging` -> `https://staging.makinglifeeasie.com`

Rules:
- Host selection MUST be configuration-driven, not hardcoded per row.
- `destination_fingerprint` MUST NOT include host, so staging/prod reuse the same canonical mapping.
- Production resolver MUST NOT redirect to staging host.
- Staging resolver MUST NOT redirect to production host unless explicitly enabled by config.
- Before staging host exists, staging MAY use current production host as a temporary fallback; once `staging.makinglifeeasie.com` is live, fallback SHOULD be removed.

## Data Model (Authoritative)

### Table `outreach_short_links`
- `id` uuid PK default `gen_random_uuid()`
- `short_code` citext unique not null
- `target_path` text not null
- `target_query` jsonb not null default `'{}'::jsonb`
- `utm_campaign` text not null
- `utm_source` text not null
- `utm_medium` text not null
- `source_id_resolved` text not null default `unknown`
- `app_key` text not null default `kinly-web`
- `page_key` text not null
- `destination_fingerprint` text not null unique
- `active` boolean not null default true
- `expires_at` timestamptz null
- `created_by` uuid null
- `created_at` timestamptz not null default now()
- `updated_at` timestamptz not null default now()

Constraints:
- `short_code` MUST match `^[a-z0-9_-]{4,24}$` after lowercase normalization.
- `target_path` MUST start with `/kinly/`.
- `utm_campaign`, `utm_source`, `utm_medium` MUST be non-empty after trim.
- `source_id_resolved` follows canonical source resolution fallback (`unknown` allowed).
- `destination_fingerprint` MUST be computed from canonicalized destination tuple:
  `target_path + normalized(target_query) + utm_campaign + utm_source + utm_medium + app_key + page_key`.
- `target_query` MUST be a JSON object (not array/scalar/null).

Indexes:
- unique index on `(short_code)`
- unique index on `(destination_fingerprint)`
- index on `(active, created_at desc)`
- index on `(utm_campaign, utm_source, utm_medium)`
- partial index on `(expires_at)` where `expires_at is not null`

Derived read model:
- View `public.outreach_short_links_effective` with:
  - all table columns
  - computed `effective_active = active and (expires_at is null or expires_at > now())`

## Redirect Resolution Contract
Resolver input:
- Path segment `short_code`.

Resolution steps (MUST):
1. Normalize incoming code to lowercase.
2. Lookup active row by `short_code` (case-insensitive via `citext`).
3. If not found, inactive, or expired -> HTTP `404` (not 302 to fallback).
4. Build destination:
- Base host from environment host mapping + `target_path`.
- Merge query params in this precedence order:
  1) existing params on target (lowest),
  2) `target_query`,
  3) canonical `utm_campaign`, `utm_source`, `utm_medium` (highest).
5. Emit event into existing `outreach_event_logs` (best effort). Logging failure MUST NOT block redirect.
6. Return HTTP `302` (or `307`) to resolved URL.

Logging linkage (authoritative):
- The resolver MUST reuse existing outreach ingestion contract.
- Preferred path: call `public.outreach_log_event` with:
  - `event = "page_view"`
  - `app_key`, `page_key`, `utm_campaign`, `utm_source`, `utm_medium` from `outreach_short_links`
  - `store = "web"`
  - `session_id` from request context when available, otherwise synthesized opaque token.
- `source_id_resolved` in `outreach_event_logs` remains resolved by `public.outreach_log_event` per `outreach_event_log_v1.md`.
- Resolver MUST NOT write a separate `outreach_short_link_clicks` table.

## API/RPC Surface (Authoritative)

### `outreach.short_links_get_or_create`
Canonical DB function: `public.outreach_short_links_get_or_create`
Caller: service-role (or trusted admin backend only)

Input:
```json
{
  "short_code": "k8m4qz",
  "target_path": "/kinly/market/flat-agreements",
  "target_query": {},
  "utm_campaign": "early_interest_2026",
  "utm_source": "offline_event",
  "utm_medium": "qr",
  "app_key": "kinly-web",
  "page_key": "kinly_market_flat_agreements",
  "expires_at": null
}
```

Output:
```json
{
  "ok": true,
  "created": false,
  "id": "uuid",
  "short_code": "k8m4qz",
  "short_url": "https://go.makinglifeeasie.com/k8m4qz",
  "destination_fingerprint": "sha256_hex"
}
```

Behavior:
- Compute `destination_fingerprint` from canonical destination tuple.
- If a row already exists with same fingerprint:
  - return existing `short_code` and `created=false`.
  - if caller passed a different `short_code`, ignore requested code and return canonical existing mapping.
  - if caller passed a different `expires_at`, ignore requested expiry and return canonical existing mapping.
- If no row exists:
  - insert new row with provided/generated `short_code`.
  - return `created=true`.

Default uniqueness policy:
- One canonical short code per canonical destination fingerprint.
- Multiple codes for identical destination are not allowed in v1.

Errors:
- `INVALID_SHORT_CODE`
- `INVALID_TARGET_PATH`
- `INVALID_TARGET_QUERY`
- `INVALID_UTM`
- `INVALID_INPUT`
- `SHORT_CODE_ALREADY_EXISTS` (only when requested code is already bound to different fingerprint)
- `SHORT_CODE_COLLISION_EXHAUSTED`

Short code generation:
- `public._outreach_short_links_generate_code` MUST use cryptographically strong randomness via `extensions.gen_random_bytes`.
- Generated alphabet MUST exclude ambiguous characters (`0`, `1`, `i`, `l`, `o`).

### `outreach.short_links_disable`
Canonical DB function: `public.outreach_short_links_disable`
Caller: service-role (or trusted admin backend only)

Input:
```json
{ "short_code": "k8m4qz" }
```

Behavior:
- Sets `active=false`.
- MUST NOT mutate historical rows in `outreach_event_logs`.

Errors:
- `INVALID_SHORT_CODE`
- `SHORT_CODE_NOT_FOUND`

## Security and Access Control
- RLS enabled on `outreach_short_links`.
- No direct `insert/update/delete/select` for anon/auth clients.
- Resolver route/function may write outreach events via existing secure path (`public.outreach_log_event`).
- Only service-role may create/disable links.
- Helper functions (`_outreach_short_links_fingerprint`, `_outreach_short_links_generate_code`, `_outreach_short_links_resolve_source`, `_outreach_short_links_before_write`) MUST NOT be executable by `PUBLIC`.

## Cross-Table Dependency
- Migration MUST ensure canonical source row `outreach_sources.source_id = 'unknown'` exists so FK writes remain safe.

## Privacy Guardrails
- Redirect analytics are aggregate attribution only.
- `session_id` MAY be logged if already generated per outreach contract rules; it MUST remain opaque and non-identifying.
- Personal data collection and cross-surface identity joins are prohibited.

## Operational Rules
- Existing short codes SHOULD be immutable for destination + UTM after first publication; create a new code for materially different campaigns.
- Expired or disabled links SHOULD return stable 404 content with no redirect.
- Retry-safe creation SHOULD be supported by optional idempotency key at the caller layer.

## Success Criteria
- QR codes resolve through short links reliably.
- Campaign metadata remains complete and stable in downstream analytics.
- No open-redirect behavior and no personal-data capture.
