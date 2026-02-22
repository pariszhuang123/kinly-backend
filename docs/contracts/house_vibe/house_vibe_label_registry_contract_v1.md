---
Domain: Design System
Capability: House Vibe Label Registry
Scope: frontend
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# House Vibe Label Registry Contract v1 (Presentation Metadata)
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Design, Agents  
Scope: Presentation-only metadata for vibe labels, stored in Supabase.

## Purpose

Provide a server-managed, app-consumed registry mapping `label_id` to title/summary/image/ui tokens. Copy and images may update without changing label meaning; mapping logic is untouched.

## Table: public.house_vibe_labels

Columns:
- `mapping_version text not null` (e.g., 'v1')
- `label_id text not null`
- `title_key text not null`
- `summary_key text not null`
- `image_key text not null`
- `ui jsonb not null default '{}'::jsonb`
- `is_active boolean not null default true`
- `updated_at timestamptz not null default now()`

Constraints:
- PK is `(mapping_version, label_id)`; v1 labels require mapping_version = 'v1'.

RLS / Access:
- Table is service-role only (RLS enabled + REVOKE); clients read via RPC joins, not by selecting the table directly.
- Write: service role only (migrations/seed scripts). No client writes.

Updated_at trigger:
- Uses shared `_touch_updated_at` trigger on UPDATE to keep audit fresh.

## Copy Tone Rules

- Descriptive, not prescriptive; avoid “should/must”.
- No moral judgement; safe when shared externally.
- Registry entries must not imply enforcement or house rules.

## Seed Labels (minimum v1)

- `insufficient_data`
- `mixed_home`
- `default_home`
- Recommended initial set:
  - `quiet_care_home`
  - `social_home`
  - `structured_home`
  - `easygoing_home`
  - `independent_home`

## Output Join Shape

When returned to mobile or share endpoint, the server returns:

```json
{
  "label_id": "quiet_care_home",
  "title_key": "vibe.quietCare.title",
  "summary_key": "vibe.quietCare.summary",
  "image_key": "vibe_quiet_care_animals_v1",
  "ui": { "accent_token": "tealBrand", "badge_token": "calm" }
}
```

- `title_key` and `summary_key` must exist in `intl_*.arb`; UI performs i18n lookup.
- `image_key` refers to server-managed asset identifiers; clients do not hardcode URLs.

## Change Management

- Copy/image tweaks that do not change meaning may update rows in-place.
- Any change that alters meaning requires a new mapping_version and corresponding label rows.
- Deprecating a label sets `is_active=false`; mapping logic must be updated in tandem.
