# Kinly Contract v1 - Preference Taxonomy

Status: Draft for MVP (home-only)

Scope: Personal preference capture and interpretation for Home-only MVP.

Audience: Product, design, engineering, AI agents.

Purpose

Define a stable taxonomy so personal preferences can be captured consistently,
interpreted safely, and aggregated into Home Vibe without drifting semantics.

This taxonomy applies only to personal preferences. It does not apply to
Home Vibe or Home Rules. See `docs/contracts/home_dynamics_v1.md`.

Core Principles
- Preferences are self-reported and descriptive, not enforceable.
- Taxonomy provides stable meaning via IDs that do not change.
- Wording can evolve without changing IDs.
- New preference IDs require governance approval.
- Deprecations must be non-breaking and documented.

## Taxonomy Structure

Database shape (authoritative)
- `preference_taxonomy` stores the active preference ids.
- `preference_taxonomy_defs` stores domains, labels, descriptions, and value_keys.
- `value_keys` map 1:1 to option_index 0..2.

Each preference is a structured item with:
- `id`: stable identifier (snake_case).
- `domain`: top-level grouping (see below).
- `label`: short UI label.
- `description`: meaning and scope for interpretation.
- `values`: allowed values and scale (if any).
- `value_keys`: stable option identifiers aligned with option_index 0..2.
- `aggregation`: how this signal rolls up into Home Vibe.
- `safety`: privacy or sensitivity constraints.

### Domains (v1)
- `environment` (sound, light, temperature, scent)
- `schedule` (sleep/wake patterns, timing preferences)
- `communication` (channel and tone preferences)
- `cleanliness` (shared-space tidiness expectations)
- `privacy` (personal space and notification boundaries)
- `social` (hosting, togetherness vs. solo time)
- `routine` (structure and planning habits)
- `conflict` (disagreement style and resolution)

### Machine-readable taxonomy (v1)

```preference-taxonomy-json
{
  "domains": [
    "environment",
    "schedule",
    "communication",
    "cleanliness",
    "privacy",
    "social",
    "routine",
    "conflict"
  ],
  "items": [
    {
      "id": "environment_noise_tolerance",
      "domain": "environment",
      "value_keys": ["low", "medium", "high"]
    },
    {
      "id": "environment_light_preference",
      "domain": "environment",
      "value_keys": ["dim", "balanced", "bright"]
    },
    {
      "id": "environment_scent_sensitivity",
      "domain": "environment",
      "value_keys": ["sensitive", "neutral", "tolerant"]
    },
    {
      "id": "schedule_quiet_hours_preference",
      "domain": "schedule",
      "value_keys": ["early_evening", "late_evening_or_night", "none"]
    },
    {
      "id": "schedule_sleep_timing",
      "domain": "schedule",
      "value_keys": ["early", "standard", "late"]
    },
    {
      "id": "communication_channel",
      "domain": "communication",
      "value_keys": ["text", "call", "in_person"]
    },
    {
      "id": "communication_directness",
      "domain": "communication",
      "value_keys": ["gentle", "balanced", "direct"]
    },
    {
      "id": "cleanliness_shared_space_tolerance",
      "domain": "cleanliness",
      "value_keys": ["low", "medium", "high"]
    },
    {
      "id": "privacy_room_entry",
      "domain": "privacy",
      "value_keys": ["always_ask", "usually_ask", "open_door"]
    },
    {
      "id": "privacy_notifications",
      "domain": "privacy",
      "value_keys": ["none", "limited", "ok"]
    },
    {
      "id": "social_hosting_frequency",
      "domain": "social",
      "value_keys": ["rare", "sometimes", "often"]
    },
    {
      "id": "social_togetherness",
      "domain": "social",
      "value_keys": ["mostly_solo", "balanced", "mostly_together"]
    },
    {
      "id": "routine_planning_style",
      "domain": "routine",
      "value_keys": ["planner", "mixed", "spontaneous"]
    },
    {
      "id": "conflict_resolution_style",
      "domain": "conflict",
      "value_keys": ["cool_off", "talk_soon", "mediate"]
    }
  ]
}
```

### IDs and Definitions (v1)

environment
- `environment_noise_tolerance`
  - Description: comfort with ambient noise in shared spaces.
  - Values: `low` | `medium` | `high`
  - Aggregation: mode + distribution noted (e.g., "mostly low").
  - Safety: none.
- `environment_light_preference`
  - Description: lighting comfort in shared spaces.
  - Values: `dim` | `balanced` | `bright`
  - Aggregation: mode.
  - Safety: none.
- `environment_scent_sensitivity`
  - Description: sensitivity to strong scents (cleaners, candles).
  - Values: `sensitive` | `neutral` | `tolerant`
  - Aggregation: mode with caution messaging if mixed.
  - Safety: none.

schedule
- `schedule_quiet_hours_preference`
  - Description: preferred quiet time window for the individual.
  - Values: `early_evening` | `late_evening_or_night` | `none`
  - Aggregation: distribution only (no single-hour enforcement).
  - Safety: do not expose exact hours in vibe.
- `schedule_sleep_timing`
  - Description: when the person typically sleeps.
  - Values: `early` | `standard` | `late`
  - Aggregation: mode + range.
  - Safety: aggregate only; avoid singling out.

communication
- `communication_channel`
  - Description: preferred coordination channel.
  - Values: `text` | `call` | `in_person`
  - Aggregation: mode.
  - Safety: none.
- `communication_directness`
  - Description: comfort with direct feedback vs. soft framing.
  - Values: `gentle` | `balanced` | `direct`
  - Aggregation: mode.
  - Safety: none.

cleanliness
- `cleanliness_shared_space_tolerance`
  - Description: tolerance for clutter in shared areas.
  - Values: `low` | `medium` | `high`
  - Aggregation: mode with note if mixed extremes.
  - Safety: none.

privacy
- `privacy_room_entry`
  - Description: preference for knock/ask before entering room.
  - Values: `always_ask` | `usually_ask` | `open_door`
  - Aggregation: distribution only.
  - Safety: do not imply permissions as rules.
- `privacy_notifications`
  - Description: comfort with notifications after quiet hours.
  - Values: `none` | `limited` | `ok`
  - Aggregation: mode.
  - Safety: none.

social
- `social_hosting_frequency`
  - Description: comfort with guests visiting the home.
  - Values: `rare` | `sometimes` | `often`
  - Aggregation: mode + distribution.
  - Safety: none.
- `social_togetherness`
  - Description: preference for shared activities vs. solo time.
  - Values: `mostly_solo` | `balanced` | `mostly_together`
  - Aggregation: mode.
  - Safety: none.

routine
- `routine_planning_style`
  - Description: preference for planning vs. spontaneity.
  - Values: `planner` | `mixed` | `spontaneous`
  - Aggregation: mode.
  - Safety: none.

conflict
- `conflict_resolution_style`
  - Description: preferred approach to resolving disagreements.
  - Values: `cool_off` | `talk_soon` | `mediate`
  - Aggregation: mode.
  - Safety: none.

## Aggregation Rules (v1)
- Vibe aggregation uses distribution-aware summaries; never map 1:1 to rules.
- Aggregation never exposes single-person signals when member count < 3.
- Mixed extremes should be phrased as "varied" to avoid pressure.
- Aggregation is recalculated when members join/leave or update preferences.

## Governance

Owners:
- Owner: Product (taxonomy meaning and scope)
- Steward: Docs (documentation and versioning)
- Enforcer: Engineering (lint and registry)
Approvals: Planner + Docs for new IDs or domain changes.

Versioning
- IDs are stable and never renamed.
- Deprecation requires:
  - a replacement ID (if applicable)
  - migration guidance for stored preferences
  - a version bump
- Breaking changes require new taxonomy version and ADR.

Non-goals
- No medical, diagnostic, or identity classification.
- No enforcement or gating based on preferences.
- No rule inference.

```contracts-json
{
  "domain": "preference_taxonomy",
  "version": "v1",
  "entities": {
    "PreferenceTaxonomyItem": {
      "id": "text",
      "domain": "text",
      "label": "text",
      "description": "text",
      "values": "text[]",
      "aggregation": "text",
      "safety": "text|null"
    }
  },
  "functions": {},
  "rls": []
}
```
