---
Domain: withYou
Capability: Pack Download Tracking
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Contract — Pack Download Tracking v1.0

## Purpose

Track app-requested audio pack downloads by language using a durable record in Supabase. This data drives product decisions about which language packs should later be bundled in-app.

## Tracked Route (Vercel side)

Pattern: `/withyou/download/audio/{language}`

Examples:
- `/withyou/download/audio/en`
- `/withyou/download/audio/zh`
- `/withyou/download/audio/ko`

Behavior:
1. Vercel Route Handler validates the language
2. Vercel writes one durable event record to Supabase
3. Vercel responds with a redirect (302) to the real static ZIP path: `/withyou/audio/{language}/core.zip`

## What Is Counted

The durable event represents: **download requested by app**.

- NOT guaranteed install success
- NOT guaranteed completed extraction
- This is the main business metric for language-pack bundling decisions

## Storage Schema

Table: `public.withyou_pack_downloads`

| Column | Type | Constraints |
|---|---|---|
| `id` | `uuid` | primary key, default `gen_random_uuid()` |
| `language` | `text` | not null |
| `pack_version` | `text` | null |
| `platform` | `text` | null (e.g. `android`, `ios`) |
| `app_version` | `text` | null |
| `requested_at` | `timestamptz` | not null, default `now()` |
| `source` | `text` | not null, default `'withyou_app_pack_download'` |
| `request_path` | `text` | null |
| `user_agent` | `text` | null |
| `country_code` | `text` | null |

## RLS and Security

- Table MUST have RLS enabled.
- No direct table access from `anon` or `authenticated` roles.
- Writes MUST go through a SECURITY DEFINER RPC or Vercel service-role insert.

## Suggested RPC

Name: `public.withyou_log_pack_download_v1`

### Inputs

| Parameter | Type | Required |
|---|---|---|
| `p_language` | `text` | yes |
| `p_pack_version` | `text` | no |
| `p_platform` | `text` | no |
| `p_app_version` | `text` | no |
| `p_request_path` | `text` | no |
| `p_user_agent` | `text` | no |
| `p_country_code` | `text` | no |

### Response

```json
{ "ok": true }
```

### Validation

- `p_language` MUST be non-empty.
- `p_language` MUST match `^[a-z]{2,3}$` (ISO 639).

## Supported Queries

This table enables:
- Downloads by language
- Downloads by month
- Downloads by app version
- Downloads by platform

## Minimum v1 Requirement

If a new table is too much for v1, a smaller durable record MAY be logged elsewhere in Kinly backend, but a dedicated table is preferred.
