# House Vibe v1 — Overview Contract
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Feature: House Vibe (Personal Preferences)  
Audience: Product, Design, Engineering, Agents  
Scope: Home-level vibe summary derived from Personal Preferences

## Purpose

House Vibe is a share-safe, home-level summary derived from member Personal Preferences. It is descriptive and conflict-aware; “mixed” is valid. Outputs are transparent about coverage and are stable so small input changes do not flip the vibe.

House Vibe is not enforcement, permissions, rules, or judgement.

## Privacy & Sharing Boundaries (non-negotiable)

- Personal Preference detail remains mobile-only.
- Social sharing may expose the Vibe Card only: title + short summary + image + optional “based on X of Y members”.
- Sharing must never expose per-user preferences, per-preference answers, member identities/breakdowns, or taxonomy question text.
- House Rules may later be web-visible; House Vibe stays share-safe and separate.

## Pipeline (conceptual)

1) Canonical preferences: interpret member responses into canonical one-hot selections (see `house_vibe_canonical_preference_schema_v1.md`).
2) Aggregate to axes: map selections to axes and compute lean/score/confidence/coverage + conflict detection (see `house_vibe_aggregation_contract_v1.md`).
3) Resolve label: deterministic mapping from axes to a single `label_id` with fallbacks (see `house_vibe_mapping_contract_v1.md`).
4) Render Vibe Card: join `label_id` to presentation metadata (title/summary/image/ui tokens) from the server registry (see `house_vibe_label_registry_contract_v1.md`) and resolve illustration assets client-side (see `house_vibe_asset_resolution_v1.md`).
5) Share: social share renders the Vibe Card image only; payload is safe by design (see `house_vibe_share_contract_v1.md`). Share logging uses `share_events.feature = 'house_vibe'`.

## Output Surfaces (v1)

- In-app (members): Group Personal Preferences page shows a top Vibe Card with image + title + summary + coverage note.
- Sharing (public): Social share image shows title + summary + image + coverage note only (no identities).

## Determinism & Versioning

- Same inputs + same mapping version → same output.
- Explicitly version:
  - Canonical schema interpretation
  - Aggregation rules
  - Label mapping rules
  - Presentation registry entries (copy/images may change without altering meaning)
- Mapping version v1 is fixed for MVP; any rule change requires bumping versions.

## Implementation Policy (Option C)

- Server selects and stores `label_id` and snapshot per home.
- Supabase registry stores presentation metadata only; UI never invents titles/summaries.
- Client consumes render-ready payload from RPC/Edge function.

## Acceptance Criteria (v1)

1) A home with enough contributors shows a Vibe Card with title, summary, image, coverage.
2) Mixed homes resolve to `mixed_home` rather than flattening to neutral.
3) Social sharing renders only the Vibe Card; no preference/member leakage.
4) Copy/image updates do not change label selection meaning.
5) Outputs are deterministic under fixed mapping_version.

## Non-Goals (v1)

- No per-user vibe scoring or compatibility.
- No enforcement or gating.
- No public access to personal preferences.
- No dependency on preference report templates/copy.

## Dependencies & Inputs

- Preference taxonomy v1 (see `preference_taxonomy_v1.md`).
- Published personal preference data (subject-owned).
- Active home membership (current members only; respects `home.is_active`).
- Home Dynamics contract governs preferences, vibe, and rules separation.
