---
Domain: Growth
Capability: outreach_tracking
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.1
Audience: internal
Last updated: 2026-02-24
---

# Contract - Outreach Event Logging v1.1

## Purpose
Provide RPC-only, privacy-safe append-only event ingestion for Kinly outreach surfaces, with staged compatibility for poll funnel events.

## Ingestion Surface
- RPC: `public.outreach_log_event`
- Caller: `anon`, `authenticated`, `service_role`
- Function MUST be `SECURITY DEFINER` with `SET search_path = ''`

## Allowed Event Enum
`event` MUST be one of:
- `page_view`
- `cta_click`
- `poll_page_view`
- `poll_vote`
- `poll_results_view`
Invalid values MUST return `INVALID_EVENT`.

## Required Input Validation
- `session_id` MUST match `^anon_[A-Za-z0-9_-]{16,32}$` or return `INVALID_SESSION`.
- `store` (if provided) MUST be one of `web | ios_app_store | google_play | unknown` or return `INVALID_STORE`.
- Required text fields MUST be non-empty after normalization and respect max lengths.
- Blank `utm_*` and `store` values MUST coerce to `unknown`.

## Data Model (authoritative columns)
`public.outreach_event_logs` includes:
- `event`
- `app_key`
- `page_key`
- `utm_campaign`
- `utm_source`
- `utm_medium`
- `source_id_resolved`
- `store`
- `session_id`
- `country`
- `ui_locale`
- `client_event_id`
- `created_at`

## Source Resolution
Backend MUST resolve `utm_source`:
1. active direct match in `outreach_sources`
2. active alias in `outreach_source_aliases`
3. fallback `unknown`

Resolution failure MUST NOT block insert.

## Idempotency
- Unique partial index on `client_event_id` where not null.
- Duplicate `client_event_id` MUST return existing row id.

## Rate Limits
- Global: 500 events/minute -> `RATE_LIMIT_GLOBAL`
- Per-session: 100 events/hour -> `RATE_LIMIT_SESSION`

## RLS and Access
- RLS MUST remain enabled on outreach tables.
- No direct client table writes.
- RPC is the public write surface.

## Poll Integration Requirements
- Poll vote RPC MAY emit `poll_vote` via `outreach_log_event`.
- Poll results render flow MAY emit `poll_results_view`.
- Poll page load flow MAY emit `poll_page_view`.
- Existing resolver logging of `page_view` remains valid and unchanged.

## Privacy Constraints
- No IPs, auth ids, or device ids in outreach logs.
- No joins to user identity tables.

## Version History
| Version | Change |
| --- | --- |
| v1.1 | Added active poll event taxonomy (`poll_page_view`, `poll_vote`, `poll_results_view`). |
| v1.0 | Initial outreach event logging contract. |
