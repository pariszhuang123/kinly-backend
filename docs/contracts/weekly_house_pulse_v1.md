# Kinly Weekly House Pulse Contract v1

Status: Draft (implementation-ready)  
Scope: Today → Weekly House Pulse card (home-level)  
Audience: Product, Design, Engineering, Agents  
Contract version: v1 (implemented by `20260321093000_house_pulse_weekly.sql`)

## Purpose

Surface a stable, share-safe weekly pulse for a home based on lightweight member reflections (weather + optional note) sourced from `home_mood_entries`. The card hides per-user after they view it and reappears only when a recompute changes the `pulse_state`.

## Inputs & Week Semantics

- Source: `home_mood_entries` rows (one per user per ISO week across all homes; enforced by existing unique constraint). Fields used: `home_id`, `user_id`, `mood` (enum), `comment`, `iso_week_year`, `iso_week`.
- Week anchor: ISO week + ISO year derived in UTC from the entry timestamp (`extract(isoweek/isoyear FROM (now() AT TIME ZONE 'UTC'))`). No client-supplied overrides in v1.
- Home scope: home must be `homes.is_active = true`; caller must be a current member (`memberships.is_current = true`) to compute or mark seen.
- Notes: `comment` max 500 chars (inherited from source table); no NLP/sentiment in v1.
- Gratitude Wall: out of scope for pulse; personal mentions are consumed passively as a “care amplifier” signal (see derived signals).

## Enums

- WeatherState reuses `public.mood_scale` (`sunny`, `partially_sunny`, `cloudy`, `rainy`, `thunderstorm`).
- PulseState (`public.house_pulse_state`): `forming`, `sunny_calm`, `sunny_bumpy`, `partly_supported`, `cloudy_steady`, `cloudy_tense`, `rainy_supported`, `rainy_unsupported`, `thunderstorm`.

## Participation Gate (Safety)

Let `P =` current member count (from `memberships.is_current = true`), `R =` weekly mood entries for those current members. Forming when any are true:
- `P <= 0`
- `R < required_reflections`, where `required_reflections = 1` if `P <= 1`, else `min(4, max(2, ceil(P * 0.35)))`
- Participation ratio (`R / P`) < 0.30

When forming: show the neutral placeholder copy, no weather icon/image.

## Derived Signals

Computed from weekly mood entries (post-gate):
- Counts: `light` (sunny, partially_sunny), `neutral` (cloudy), `heavy` (rainy, thunderstorm); `total = light + neutral + heavy`.
- Ratios: `light_ratio`, `neutral_ratio`, `heavy_ratio` (0 when total = 0).
- Distinct participants: count of distinct user_ids contributing that week.
- Care present: `R > 0` AND (`light_ratio >= 0.25` OR weekly personal mention exists OR any non-empty comment exists OR (P >= 2 AND distinct_participants >= min(3, ceil(P * 0.5)))).
- Friction present: thunderstorm exists OR (`R > 0` AND `heavy_ratio >= 0.30`).
- Complexity present: any rainy/thunderstorm entry has a non-empty comment.
- Weather mode: most frequent mood with tie-break weights `thunderstorm > rainy > cloudy > partially_sunny > sunny`.

## Pulse Resolution (Deterministic)

1) Gate → `forming`  
2) If any `thunderstorm` → `thunderstorm`  
3) If `heavy_ratio >= 0.30`: `care_present` ? `rainy_supported` : `rainy_unsupported`  
4) Light path:  
   - If `light_ratio >= 0.60` AND `care_present` AND NOT `friction_present` → `sunny_calm`  
   - Else if `light_ratio >= 0.40` AND `care_present` AND `friction_present` → `sunny_bumpy`  
   - Else if `weather_mode = partially_sunny` AND `care_present` → `partly_supported`  
5) Neutral/mixed:  
   - If `weather_mode = cloudy`: `friction_present` ? `cloudy_tense` : `cloudy_steady`  
   - Fallback: `friction_present` ? `cloudy_tense` : `cloudy_steady`

## Output Schema (snapshot per home/week)

`house_pulse_weekly` (snapshot; one row per `home_id`, `iso_week_year`, `iso_week`, `contract_version`):
- `member_count` (= P), `reflection_count` (= R)
- `weather_display` (`mood_scale` nullable; null when forming)
- `care_present`, `friction_present`, `complexity_present`
- `pulse_state` (`house_pulse_state`)
- `computed_at` (UTC), `contract_version` (v1)

## Label Registry, Image & Copy

- Registry table: `house_pulse_labels(contract_version, pulse_state, title_key, summary_key, image_key, ui, is_active)`.
- UI resolves copy and image via `house_pulse_label_get_v1(pulse_state, contract_version)`; no hardcoded client mapping.
- Weather shown on Today: `null` when forming; else `thunderstorm → thunderstorm`, `rainy_* → rainy`, `partly_supported → partially_sunny`, `sunny_* → sunny`, else `cloudy` (from `weather_display`).

## Privacy, Safety, Access

- Data access is RPC-only. `house_pulse_labels`, `house_pulse_weekly`, and `house_pulse_reads` have RLS enabled with no permissive policies; all table access is via SECURITY DEFINER RPCs. Direct table grants are revoked.
- Weekly pulse snapshots are visible via RPC only to current members; no per-user breakdowns or counts per person are exposed.
- No NLP, no trend graphs, no per-person attribution or callouts to who did/did not check in.
- Per-user dismissal: `house_pulse_mark_seen` records a marker in `house_pulse_reads` for (`home_id`, `iso_week_year`, `iso_week`, `contract_version`, `pulse_state`). The card hides for that user until `pulse_state` changes.

## Versioning & Stability

- Contract version = `v1`; image_key and pulse_state meaning are fixed. Any rule/threshold change requires a version bump and new snapshot rows (parallel contract_version column).
- Inputs come from existing `home_mood_entries` (one per user/week enforced). Snapshots are recomputed idempotently for the same contract version.

## Non-goals (v1)

- No enforcement, gating, or interventions.
- No cross-home comparisons.
- No auto-publishing to Gratitude Wall.
- Sharing UX is minimal and share-safe: the pulse card can expose a share action using registry-derived copy/image only; no identities or per-user data.

## RPCs (v1)
- `house_pulse_label_get_v1(p_pulse_state, p_contract_version='v1')` → title/summary/image/ui for the state/version.
- `house_pulse_compute_week(p_home_id, p_iso_week_year?, p_iso_week?, p_contract_version='v1')` → computes snapshot from `home_mood_entries` for current members (advisory lock per home/week/version).
- `house_pulse_weekly_get(p_home_id, p_iso_week_year?, p_iso_week?, p_contract_version='v1')` → get-or-compute for Today surface.
- `house_pulse_mark_seen(p_home_id, p_iso_week_year?, p_iso_week?, p_contract_version='v1')` → records per-user dismissal tied to pulse_state/computed_at.
