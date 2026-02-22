---
Domain: HOME
Capability: House Vibe Mapping Effects
Scope: backend
Artifact-Type: reference
Stability: stable
Status: Approved
Version: v1.0
---

# House Vibe Mapping Effects v1 (pref_id → axes)
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Mapping Personal Preference options to House Vibe axes for `mapping_version = 'v1'`.

## Axes Direction

- `energy_level`: -1 calm, +1 lively
- `structure_level`: -1 structured, +1 flexible
- `social_level`: -1 private, +1 social
- `repair_style`: -1 avoidant, 0 balanced, +1 direct
- `noise_tolerance`: -1 quiet, +1 okay_with_noise
- `cleanliness_rhythm`: -1 consistent, +1 ad_hoc

`delta` is -1/0/1; `weight` is ≥0.1 and ≤3.0. Rows are versioned by `mapping_version`; changes require a new version.
Use only the rows below; do not invent mappings, normalize weights, or infer relationships beyond this table.

## Mapping Table (v1)

| pref_id | option_key (option_index) | axis → (delta, weight) |
| --- | --- | --- |
| environment_noise_tolerance | low (0) | noise_tolerance → (-1, 1.25); energy_level → (-1, 0.40) |
| environment_noise_tolerance | medium (1) | — |
| environment_noise_tolerance | high (2) | noise_tolerance → (1, 1.25); energy_level → (1, 0.40) |
| environment_light_preference | dim (0) | energy_level → (-1, 0.40) |
| environment_light_preference | balanced (1) | — |
| environment_light_preference | bright (2) | energy_level → (1, 0.40) |
| environment_scent_sensitivity | sensitive (0) | cleanliness_rhythm → (-1, 0.50) |
| environment_scent_sensitivity | neutral (1) | — |
| environment_scent_sensitivity | tolerant (2) | cleanliness_rhythm → (1, 0.50) |
| schedule_quiet_hours_preference | early_evening (0) | noise_tolerance → (-1, 1.00) |
| schedule_quiet_hours_preference | late_evening_or_night (1) | noise_tolerance → (-1, 0.60) |
| schedule_quiet_hours_preference | none (2) | noise_tolerance → (1, 1.00) |
| schedule_sleep_timing | early (0) | energy_level → (-1, 1.00) |
| schedule_sleep_timing | standard (1) | — |
| schedule_sleep_timing | late (2) | energy_level → (1, 1.00) |
| communication_channel | text (0) | social_level → (-1, 0.50) |
| communication_channel | call (1) | social_level → (1, 0.30) |
| communication_channel | in_person (2) | social_level → (1, 0.80) |
| communication_directness | gentle (0) | repair_style → (-1, 1.10) |
| communication_directness | balanced (1) | repair_style → (0, 0.60) |
| communication_directness | direct (2) | repair_style → (1, 1.10) |
| cleanliness_shared_space_tolerance | low (0) | cleanliness_rhythm → (-1, 1.30) |
| cleanliness_shared_space_tolerance | medium (1) | — |
| cleanliness_shared_space_tolerance | high (2) | cleanliness_rhythm → (1, 1.30) |
| privacy_room_entry | always_ask (0) | social_level → (-1, 0.80) |
| privacy_room_entry | usually_ask (1) | social_level → (-1, 0.40) |
| privacy_room_entry | open_door (2) | social_level → (1, 0.80) |
| privacy_notifications | none (0) | social_level → (-1, 0.60) |
| privacy_notifications | limited (1) | social_level → (-1, 0.30) |
| privacy_notifications | ok (2) | social_level → (1, 0.60) |
| social_hosting_frequency | rare (0) | social_level → (-1, 1.10); energy_level → (-1, 0.60) |
| social_hosting_frequency | sometimes (1) | social_level → (1, 0.50) |
| social_hosting_frequency | often (2) | social_level → (1, 1.10); energy_level → (1, 0.60) |
| social_togetherness | mostly_solo (0) | social_level → (-1, 1.20) |
| social_togetherness | balanced (1) | — |
| social_togetherness | mostly_together (2) | social_level → (1, 1.20) |
| routine_planning_style | planner (0) | structure_level → (-1, 1.30) |
| routine_planning_style | mixed (1) | — |
| routine_planning_style | spontaneous (2) | structure_level → (1, 1.30) |
| conflict_resolution_style | cool_off (0) | repair_style → (-1, 1.00) |
| conflict_resolution_style | talk_soon (1) | repair_style → (0, 0.60) |
| conflict_resolution_style | mediate (2) | repair_style → (1, 1.00) |

Notes:
- Neutral entries are omitted (no mapping rows) to avoid noise.
- Weights stay within 0.1–3.0; deltas stay within -1/0/1.
- `MIN_SIDE_COUNT` for `mixed` is 2 in v1.
