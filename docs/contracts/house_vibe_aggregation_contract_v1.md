# House Vibe Aggregation Contract v1
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Convert canonical Personal Preferences into aggregated home-level vibe axes.

## Purpose

Aggregate member Personal Preferences into descriptive axes that reflect tendencies, not rules. Outputs are axis results only; presentation is handled elsewhere.

## Inputs

- Home membership: current members for an active home (`homes.is_active = true`).
- Contributors: only current members whose published preferences include **all** preference_ids required by the active `mapping_version` (derived from `house_vibe_mapping_effects`, not hard-coded counts). Partial sets do not contribute.
- Canonical preferences per member: see `house_vibe_canonical_preference_schema_v1.md`.
- Mapping effects: (pref_id, option_index) → axis deltas + weights (versioned, v1).

## Axes (v1 identifiers)

- `energy_level` (calm ↔ lively)
- `structure_level` (structured ↔ flexible)
- `social_level` (private ↔ social)
- `repair_style` (avoidant ↔ balanced ↔ direct; encoded via -1/0/+1)
- `noise_tolerance` (quiet ↔ okay_with_noise)
- `cleanliness_rhythm` (consistent ↔ ad_hoc)

## Mapping Effects Contract (v1)

Each valid selection may contribute to one or more axes:

```json
{
  "pref_id": "noise_late_night",
  "option_index": 2,
  "effects": [
    { "axis": "noise_tolerance", "delta": 1, "weight": 1.0 },
    { "axis": "energy_level", "delta": 1, "weight": 0.5 }
  ]
}
```

- `delta` is -1, 0, or 1. `repair_style` may use all three values; other axes use -1/1 only.
- `weight` is ≥ 0.1, ≤ 3.0. Use mapping defaults; do not invent weights client-side.
- Mapping rows are versioned; v1 is fixed. Changes require a new mapping_version.

## Aggregation Algorithm (deterministic; contributors only)

For each axis:
1. Per-contributor score: `member_score = SUM(delta * weight) / SUM(weight)` across that contributor’s rows for the axis (skip if SUM(weight)=0).
2. Vote assignment per member:
   - `high` if `member_score > 0.20`
   - `low` if `member_score < -0.20`
   - `neutral` otherwise
3. Count votes: `high_n`, `low_n`, `neutral_n`, `contributed_n` (votes that are not null).
4. `min_side_count` derives from `house_vibe_versions`: use `min_side_count_small` when total current members ≤ 3; otherwise `min_side_count_large`.
5. Lean (precedence: mixed > leans > balanced):
   - `mixed` if `high_n >= min_side_count` AND `low_n >= min_side_count`
   - `leans_high` if `high_n >= min_side_count` AND `high_n > low_n`
   - `leans_low` if `low_n >= min_side_count` AND `low_n > high_n`
   - else `balanced`
6. Confidence (0–1):
   - coverage term: `contributed_n / contributor_total` (0 if none)
   - imbalance term: `abs(high_n - low_n) / (high_n + low_n + neutral_n)` (0 if no votes)
   - `confidence = min(1, max(0, coverage_term * imbalance_term))`

Outputs per axis (when requested):
```json
{
  "axis": "energy_level",
  "lean": "balanced|mixed|leans_low|leans_high",
  "score": -0.33, // per-axis average score, rounded
  "confidence": 0.58,
  "counts": {
    "high": 1,
    "low": 1,
    "neutral": 0,
    "contributed": 2,
    "contributors_total": 2,
    "total_members": 3
  }
}
```

## Stability & Recompute Triggers

- Aggregation uses only current members and their latest canonical preferences. Members without a complete required set for the active mapping_version are excluded from coverage and weight.
- Mark House Vibe snapshot `out_of_date = true` when:
  - membership changes (join/leave/transfer owner)
  - preference data updates or taxonomy_version changes
  - mapping_version changes
- `force=true` in compute RPC bypasses change detection.

## Prohibited

- Do not branch on client/platform.
- Do not infer effects outside the mapping table.
- Do not average identities (no per-user scores are exposed).
