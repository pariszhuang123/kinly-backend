---
Domain: HOME
Capability: House Vibe Compute
Scope: backend
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v2.0
---

# House Vibe Compute RPC Contract v2

Status: Approved
Audience: Engineering, Agents
Scope: Server orchestration to compute, store, and return the latest vibe per home.

## RPC

Signature remains unchanged:
`house_vibe_compute(home_id uuid, force boolean default false, include_axes boolean default false)`

## v2 Behavioral Guarantees

- Active mapping version resolves from `house_vibe_versions.status='active'`; operational rollout sets this to `v2`.
- Coverage gate unchanged from v1.
- Conflict gate unchanged in shape (`any mixed axis => mixed_home`) but mixed frequency changes through v2 thresholds:
  - small homes (<=3 members): `min_side_count_small=1`
  - larger homes (>=4 members): `min_side_count_large=3`
- Snapshot upsert key remains `(home_id, mapping_version)`.

## Invalidation Guarantees

- `_house_vibes_mark_out_of_date(home_id)` must not hardcode mapping version.
- Invalidation marks existing rows for the home out-of-date and ensures an active-version placeholder exists.
- Membership and preference triggers continue to call this helper.

## Existing Homes During Cutover

- Migration seeds/refreshes `(home_id,'v2')` rows as `out_of_date=true` so first read recomputes using v2 semantics.
- Existing v1 rows are retained for history and are not used by active compute paths.
