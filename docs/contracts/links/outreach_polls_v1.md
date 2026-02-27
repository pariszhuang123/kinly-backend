---
Domain: Growth
Capability: outreach_polls
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: active
Version: v1.0
Audience: internal
Last updated: 2026-02-24
---

# Contract - Outreach Polls API v1.0

## Purpose
Define target backend schema and RPC contracts for public outreach polls with short-code-backed attribution.

## Publication and Enforceability State
- This contract is enforceable by DB objects in `20260322090022_outreach_polls_v1.sql`.
- Contract publication remains gated by passing local/CI guardrails.

## Design Constraints
- Web clients MUST use RPCs; no direct table writes.
- Vote attribution trust boundary is `short_code` resolved from `public.outreach_short_links_effective`.
- One net vote per `(poll_id, session_id)`.

## Authoritative Tables (Target v1)

### `public.outreach_polls`
- `id` uuid PK default `gen_random_uuid()`
- `app_key` text not null
- `page_key` text not null
- `title` text not null
- `question` text not null
- `description` text null
- `active` boolean not null default true
- `created_at`, `updated_at` timestamptz not null default `now()`
- unique `(app_key, page_key)`

Validation invariants:
- `app_key` trimmed length 1..40
- `page_key` trimmed length 1..80
- `title` trimmed length 1..160
- `question` trimmed length 1..400

### `public.outreach_poll_options`
- `id` uuid PK default `gen_random_uuid()`
- `poll_id` uuid not null FK -> `public.outreach_polls.id` on delete cascade
- `option_key` text not null
- `label` text not null
- `position` int not null
- `active` boolean not null default true
- `created_at`, `updated_at` timestamptz not null default `now()`
- unique `(poll_id, option_key)`
- unique `(poll_id, position)`

Validation invariants:
- `option_key` is lowercase slug `^[a-z0-9_]{1,40}$`
- `label` trimmed length 1..120

### `public.outreach_poll_votes`
- `id` uuid PK default `gen_random_uuid()`
- `poll_id` uuid not null
- `option_id` uuid not null
- `session_id` text not null
- `client_vote_id` uuid null
- `short_link_id` uuid not null FK -> `public.outreach_short_links.id`
- attribution snapshot (all not null):
  - `page_key`
  - `source_id_resolved`
  - `utm_campaign`
  - `utm_source`
  - `utm_medium`
  - `store`
- `country` text null
- `ui_locale` text null
- `created_at`, `updated_at` timestamptz not null default `now()`

Constraints:
- unique `(poll_id, session_id)` (one net vote per session)
- unique `(client_vote_id)` where not null
- FK `(poll_id, option_id)` references option membership (composite FK or equivalent enforced invariant)
- `session_id` MUST match `^anon_[A-Za-z0-9_-]{16,32}$`
- `store` MUST be in `('web','ios_app_store','google_play','unknown')`

## Read Views (Target v1)

### `public.outreach_poll_results_uc_v1`
Per-option UC counts for a poll:
- `page_key`
- `option_key`
- `vote_count`
- `total_votes`

Requirement:
- filtered to `source_id_resolved = 'uc'`.

### `public.outreach_poll_totals_uc_v1`
UC totals per poll:
- `page_key`
- `total_votes`
- `last_vote_at`

### `public.outreach_polls_overview_v1`
Poll metadata and activity:
- poll metadata fields
- `active`
- all-source total votes
- UC total votes
- `last_activity_at`

## RPC Surface (Target v1)

### `public.outreach_poll_get_v1(p_app_key text, p_page_key text) returns jsonb`
Normalization:
- trim `p_app_key`, trim `p_page_key`.

Success response shape:
```json
{
  "ok": true,
  "poll": {
    "id": "uuid",
    "app_key": "kinly-web",
    "page_key": "kinly_market_flat_agreements",
    "title": "string",
    "question": "string",
    "description": "string or null"
  },
  "options": [
    {
      "id": "uuid",
      "option_key": "string",
      "label": "string",
      "position": 1
    }
  ]
}
```

Not found response shape:
```json
{ "ok": false, "error": "POLL_NOT_FOUND" }
```

Ordering guarantees:
- options are strictly ordered by `position asc`, tie-breaker `id asc`.

### `public.outreach_poll_vote_submit_v1(
  p_short_code text,
  p_option_key text,
  p_session_id text,
  p_store text default 'unknown',
  p_client_vote_id uuid default null,
  p_country text default null,
  p_ui_locale text default null
) returns jsonb`

Behavior:
1. validate and normalize `short_code`, `option_key`, `session_id`, `store`, locale/country.
2. resolve active short link in `public.outreach_short_links_effective` where `effective_active = true`.
3. resolve poll via short-link `(app_key, page_key)`.
4. resolve active option by `option_key` under resolved poll.
5. upsert vote by `(poll_id, session_id)`; preserve one net vote per session.
6. persist attribution snapshot from short-link row.
7. emit `poll_vote` through `public.outreach_log_event` when tracking rollout gate is active.
8. return deterministic aggregate result payload.

Success response shape:
```json
{
  "ok": true,
  "poll_id": "uuid",
  "selected_option_key": "string",
  "results": {
    "total_votes": 0,
    "option_counts": [
      { "option_key": "string", "vote_count": 0 }
    ]
  }
}
```

Error codes:
- `INVALID_SHORT_CODE`
- `SHORT_CODE_NOT_FOUND`
- `SHORT_CODE_INACTIVE`
- `POLL_NOT_FOUND`
- `INVALID_OPTION`
- `INVALID_SESSION`
- `INVALID_STORE`
- `RATE_LIMIT_GLOBAL`
- `RATE_LIMIT_SESSION`

Idempotency:
- Duplicate `p_client_vote_id` for an existing vote MUST return success for the existing logical vote without creating a second vote row.

## Security
- Poll RPCs MUST be `SECURITY DEFINER` with `SET search_path = ''`.
- RLS MUST be enabled on all poll tables.
- `anon`/`authenticated` can only `EXECUTE` approved poll RPCs.
- `anon`/`authenticated` MUST NOT receive direct table DML grants.

## Event Integration
- Vote RPC MUST emit `poll_vote` through `public.outreach_log_event` for successful writes.
- Event taxonomy aligns with active `outreach_tracking_v1_1`.

## Acceptance Criteria
1. Tracking RPC rejects `poll_vote` with `INVALID_EVENT` before event-rollout migration.
2. After rollout, tracking RPC accepts all five events and persists successfully.
3. Poll fetch returns active poll/options by `app_key + page_key`, options ordered by `position`.
4. Vote submit requires valid active short code and valid option membership.
5. One session has one net vote per poll.
6. Duplicate `client_vote_id` returns idempotent success and no extra vote row.
7. Vote row snapshot matches resolved short-link attribution at write time.
8. Poll vote event emission follows staged compatibility rules with no silent behavior breaks.
