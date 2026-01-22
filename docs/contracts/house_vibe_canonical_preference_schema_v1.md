---
Domain: HOME
Capability: House Vibe Preferences Schema
Scope: backend
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# House Vibe Canonical Preference Schema v1
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Canonical representation of Personal Preference selections for House Vibe and related aggregation.

## Purpose

Provide a deterministic shape for Personal Preferences so aggregation and sharing logic are stable across storage backends and report templates. Taxonomy text may be edited manually in Supabase UI; structure (question ids, option counts) is stable for v1.

## Canonical Shape

```json
{
  "preferences": {
    "<pref_id>": [false, true, false]
  }
}
```

- `taxonomy_version` is implicitly v1 (text-only updates in Supabase do not change structure; no taxonomy_version column exists today).
- `preferences`: map of `pref_id` to fixed-length array of booleans, indexed by `option_index` (0-based).
- Arrays are length 3 for v1 taxonomy; do not generate logic for more than 3 options.
- Exactly one `true` indicates a chosen option; all `false` means unanswered/unknown.

## Validation Rules (v1)

- `pref_id` must exist in taxonomy v1 (stable ids).
- Array length must equal taxonomy option count (3). Reject mismatched length; v1 guarantees 3 options to avoid fatigue.
- Values must be boolean only; no nulls or strings.
- Allow only 0 or 1 `true` values. Multiple `true` values are invalid for v1.
- Unknown `pref_id` keys are rejected.
- If taxonomy structure ever changes, a new schema version is required; until then treat current schema as v1.

## Coverage Semantics

- A member is considered “contributed” only if they have a published payload with all 14 required preferences answered (one-hot). Partial submissions are not published and do not count toward coverage.
- `coverage_answered` counts members with published, complete payloads.
- `coverage_total` equals current active members in the home.
- Individual unanswered preferences remain omitted (all-false) and do not count toward answered.

## Storage / Transport Notes

- Implementations may store raw responses row-based or JSON; they must be able to emit this canonical shape.
- Canonical payload is the input to aggregation and share-safe computation. Do not expose canonical payloads outside server aggregation logic or public surfaces.
- Changes to taxonomy or option counts require a new schema version; until then treat this as v1.
