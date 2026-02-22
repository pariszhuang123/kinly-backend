---
Domain: HOME
Capability: House Vibe Mapping
Scope: shared
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# House Vibe Mapping Contract v1 (Axes → Label)
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Deterministically resolve aggregated axes to a single primary `label_id`.

## Purpose

Convert axis results into a single, share-safe vibe label that is deterministic, conflict-aware, and stable under small changes.

## Inputs

- Aggregation result (see `house_vibe_aggregation_contract_v1.md`):
  - per-axis lean/score/confidence
  - member_count_total / member_count_contributed
  - mapping_version (v1)

## Outputs

```json
{
  "mapping_version": "v1",
  "label_id": "quiet_care_home",
  "confidence": 0.62,
  "coverage": { "answered": 4, "total": 5 }
}
```

## Deterministic Resolution Rules (v1)

1) **Coverage gate**  
   - If `member_count_total == 0` or `member_count_contributed < 2` or `(member_count_contributed / member_count_total) < 0.4`: return `insufficient_data`.

2) **Conflict gate**  
   - If any axis lean is `mixed`: return `mixed_home` immediately (takes precedence over balanced).

3) **Candidate scoring**  
   Evaluate candidates in this fixed priority order. Each candidate has conditions; the first matching candidate wins. When multiple conditions match, the highest computed `candidate_score` wins; ties fall back to earlier priority order.

   - `quiet_care_home`  
     - Conditions: `energy_level` leans_low OR `noise_tolerance` leans_low; `social_level` not leans_high.  
     - `candidate_score = avg(confidence of contributing axes)`.
   - `social_home`  
     - Conditions: `social_level` leans_high AND `energy_level` leans_high.  
   - `structured_home`  
     - Conditions: `structure_level` leans_high AND `cleanliness_rhythm` leans_high.  
   - `easygoing_home`  
     - Conditions: `structure_level` leans_low OR `cleanliness_rhythm` leans_low; `noise_tolerance` not leans_low.  
   - `independent_home`  
     - Conditions: `social_level` leans_low AND (`structure_level` balanced or leans_high).  
   - Fallback: `default_home`.

4) **Label confidence**  
   - `label_confidence = min(1, min(axis_confidences used in match))`. If fallback triggers without matching axes, set `label_confidence = member_count_contributed / member_count_total` (or 0 if total=0).

5) **Coverage output**  
   - `coverage.answered = member_count_contributed`
   - `coverage.total = member_count_total`

6) **Determinism**  
   - No randomness. Priority order and tie-breaking are fixed above.
   - Any change to conditions or priorities requires mapping_version bump.

## Prohibited

- No client-side overrides or alternative labels.
- No incorporation of identity, role, or owner weighting.
- Do not hide `mixed` states; conflict must surface as `mixed_home`.
