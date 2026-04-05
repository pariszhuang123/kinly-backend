---
Domain: withYou
Capability: Backend handoff checklist
Scope: platform
Artifact-Type: guide
Stability: evolving
Status: draft
Version: v1.0
---

# withYou Backend Handoff Checklist v1.0

## Purpose

Provide the minimum backend implementation checklist for withYou v1 so the
backend repo can execute only the required Supabase and Vercel-integrated work.

This checklist is intentionally narrow. withYou v1 does **not** require a full
backend service.

## Canonical reference contracts

Backend work MUST align to:

- [interest_capture_v1.md](../interest_capture_v1.md)
- [pack_download_tracking_v1.md](./pack_download_tracking_v1.md)
- [withyou_system_overview_v1.md](./withyou_system_overview_v1.md)

## Required backend work

### 1. Update lead uniqueness semantics

Implement the `public.leads` changes from
`docs/contracts/interest_capture_v1.md` with the withYou-specific source
addition.

Checklist:

- drop or replace the current `unique(email)` constraint/index
- add unique constraint or unique index on `(email, source)`
- update the `source` allowlist to include `withyou_web_get`
- keep the default source as `kinly_web_get`
- preserve compatibility for existing Kinly lead flows

## 2. Update lead upsert RPC

Update `public.leads_upsert_v1`.

Checklist:

- change `ON CONFLICT (email)` to `ON CONFLICT (email, source)`
- accept `p_source = 'withyou_web_get'`
- keep existing validation and rate-limiting behavior
- keep the public invocation model unchanged

## 3. Implement pack download tracking

Implement the durable download log from
`pack_download_tracking_v1.md`.

Checklist:

- create table `public.withyou_pack_downloads`
- enable RLS on the table
- deny direct table access from `anon` and `authenticated`
- implement either:
  - SECURITY DEFINER RPC `public.withyou_log_pack_download_v1`, or
  - service-role insert path from Vercel

Required fields:

- `language`
- `pack_version` optional
- `platform` optional
- `app_version` optional
- `request_path` optional
- `user_agent` optional
- `country_code` optional

## 4. Wire the tracked Vercel download route

The tracked route is:

- `/withyou/download/audio/{language}`

Checklist:

- validate `language`
- optionally resolve `pack_version` from the current manifest
- write one durable download event
- redirect to `/withyou/audio/{language}/core.zip`

Note:
- This route is owned by the Vercel/web layer, not this backend repo.
- Backend responsibility in this repo is limited to the durable table + RPC
  surface the route calls.

## 5. Confirm backend non-ownership

The backend repo MUST NOT take ownership of:

- preview audio hosting
- public preview asset URLs
- ZIP hosting
- audio manifest hosting
- route-slug to scenario-family mapping
- QR code generation for v1

Those remain in the web/Vercel/static-content layer.

## Optional enhancements

Only add these if analytics explicitly requires them.

- optional `entry_route_slug` on pack download events
- optional `primary_scenario_family` on pack download events
- future QR metadata utilities

These are optional and are not required for withYou v1 launch.

## Definition of done

Backend handoff is complete when:

- `public.leads` supports uniqueness on `(email, source)`
- `public.leads_upsert_v1` accepts `withyou_web_get`
- `public.withyou_pack_downloads` exists and writes succeed
- `/withyou/download/audio/{language}` produces durable records and redirects
- no backend code is introduced for static asset hosting or preview playback
