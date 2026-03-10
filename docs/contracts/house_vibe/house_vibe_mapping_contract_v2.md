---
Domain: HOME
Capability: House Vibe Mapping
Scope: shared
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v2.0
---

# House Vibe Mapping Contract v2 (Axes -> Label)

Status: Approved
Audience: Engineering, Agents
Scope: Deterministically resolve aggregated axes to a single primary `label_id`.

## Purpose

v2 keeps the same label taxonomy and scoring behavior as v1, but reduces `mixed_home` sensitivity for larger homes.

## Deterministic Resolution Rules (v2)

1) Coverage gate
- If `member_count_total == 0` or `member_count_contributed < 2` or `(member_count_contributed / member_count_total) < 0.4`: return `insufficient_data`.

2) Conflict gate
- If any axis lean is `mixed`: return `mixed_home` immediately.

3) Mixed threshold source
- `min_side_count` comes from `house_vibe_versions` for the active `mapping_version`.
- v2 values:
  - `min_side_count_small = 1` when total current members <= 3
  - `min_side_count_large = 3` when total current members >= 4

4) Candidate scoring and fallback
- Same candidate conditions/order and confidence behavior as v1.
- If conflict gate is not hit, resolve to strongest matching non-mixed label; fallback `default_home`.

## Compatibility

- v1 remains historical only.
- Active operational behavior must use v2.
