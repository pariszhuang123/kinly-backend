Status: Proposed
Owner: Planner (policy), Release (CI enforcement), all agents (compliance)
Scope: Flutter app (`lib/**`) — file placement + dependency direction
Non-breaking: Yes (additive, refactor-friendly)

## 0) Purpose

This contract standardizes where code lives in `lib/**` so we can:
- avoid feature-to-feature coupling
- prevent cyclic imports and registry drift
- keep top-level surfaces stable as features change
- make multi-agent refactors predictable and safe

This is a placement + dependency contract (not visual design, not data modeling).

## 1) Depends on / Amendments

Depends on:
- Kinly Foundation Composable System Contract v1

Amended by:
- `kinly_foundation_surfaces_amendment_v1.md`

If any rules conflict, the Foundation Surfaces amendment wins for anything under:
- `lib/foundation/surfaces/**`

## 2) Canonical module buckets

Kinly code must be placed in one of these buckets:

### A) Foundation Surfaces (top-level app destinations)
Path:
- `lib/foundation/surfaces/today/**`
- `lib/foundation/surfaces/explore/**`
- `lib/foundation/surfaces/hub/**`
- `lib/foundation/surfaces/profile/**`

Owns:
- layout + orchestration + slot definitions
- registries (registration + ordering)
- SurfaceScopes (read-only composition context)

Must define per surface:
- `*_surface.dart` (layout + orchestration)
- `*_slots.dart` (slot types and allowed contribution types)
- `*_registry.dart` (registration API + ordering rules)

### B) Core (foundation primitives + generic adapters)
Path:
- `lib/core/**`

Owns:
- generic UI primitives (buttons, cards, typography wrappers, layout primitives)
- routing/navigation primitives (not surface layouts)
- platform/infra adapters (share capability adapter, logging adapters)
- non-feature utilities (small helpers, token wrappers)
- cross-cutting wiring that is not surface orchestration

Must NOT contain:
- top-level surface hosts (Today/Explore/Hub/Profile orchestration)
- feature BLoCs, feature screens, feature registries
- domain-specific product behavior owned by a single feature

### C) Contracts (shared types/interfaces/enums)
Path:
- `lib/contracts/**`

Owns:
- shared DTOs, entry models, scopes, interfaces
- shared enums (including backend error codes)
- ports used by 2+ features OR consumed by foundation surfaces

Notes:
- Contracts are the stable seam: `lib/contracts/**` must not import
  anything from `lib/core/**` or `lib/features/**`.
- Shared helpers used by contracts (for example, timezone helpers) must live
  under `lib/contracts/**` (for example, `lib/contracts/time/**`).

### D) Features (feature-owned behavior)
Path:
- `lib/features/<feature>/**`

Owns:
- feature BLoCs/state management
- feature screens + feature UI
- feature domain logic
- feature data/repositories/mappers
- feature-specific error mapping + failures

Special case: surface contributions
Features may contribute UI to foundation surfaces only via registries.
Allowed contribution files:
- `lib/features/<feature>/ui/today_<thing>.dart`
- `lib/features/<feature>/ui/explore_<thing>.dart`
- `lib/features/<feature>/ui/hub_<thing>.dart`
- `lib/features/<feature>/ui/profile_<thing>.dart`

## 3) High-level placement rules (MUST)

1) Surfaces live in foundation, not core, not features
- Today/Explore/Hub/Profile surface hosts MUST live under
  `lib/foundation/surfaces/**`.

2) Core is primitives + adapters only
- If code is generic and reusable and not a top-level surface, it may live in
  `lib/core/**`.
- If code encodes feature behavior or feature UX, it MUST live in
  `lib/features/**`.

3) Contracts are shared semantics
- If a type/enum/interface is used by 2+ features OR referenced by foundation
  surfaces, it MUST live in `lib/contracts/**`.
- Backend/Supabase error enums MUST NOT live in core; they belong in contracts
  (shared) or feature domain (local).

4) Features own behavior
- BLoCs, repositories, mappers, services, and feature screens are feature-owned
  and MUST live in `lib/features/<feature>/**`.

## 4) Dependency direction rules (MUST)

### 4.1 Forbidden imports (hard rules)

A) Foundation surfaces
- `lib/foundation/surfaces/**` MUST NOT import:
  - `lib/features/**`

B) Features
- `lib/features/**` MUST NOT import:
  - other `lib/features/**` modules (no cross-feature imports)
  - `lib/foundation/surfaces/**/internal/**` (if present)
  - `lib/foundation/surfaces/**` (surface internals are off-limits)

C) Core
- `lib/core/**` MUST NOT import:
  - `lib/features/**`

D) Contracts
- `lib/contracts/**` MUST NOT import:
  - `lib/core/**`
  - `lib/features/**`

### 4.2 Allowed imports

A) Foundation surfaces may import:
- `lib/core/**` foundation primitives + adapters
- `lib/contracts/**` (slots, SurfaceScopes, entry models, shared enums/interfaces)
- Flutter SDK + approved third-party packages

B) Features may import:
- `lib/core/**` primitives + adapters
- `lib/contracts/**`
- their own feature modules only: `lib/features/<feature>/**`

C) Core may import:
- Flutter SDK + approved packages
- `lib/contracts/**` (only when core adapters implement contract interfaces)

D) Contracts may import:
- Dart/Flutter SDK types (as needed)
- other `lib/contracts/**` files

## 5) Surface composition rule (registry-only) (MUST)

- Features contribute to foundation surfaces only via registries.
- Forbidden:
  - foundation surfaces importing feature widgets directly
  - features importing other features to get a widget for a surface
- Required:
  - surface registries accept entries and builders; surfaces render entries
    deterministically

Minimum entry model (example shape; actual location may vary):
```dart
class SurfaceEntry {
  final String id;
  final int order;
  final Widget Function(SurfaceScope scope) builder;
  final bool Function(SurfaceScope scope)? isEnabled;
}
```

## 6) Linting + rollout

- Placement lints start in warning mode.
- CI is strict for:
  - contracts importing core
  - feature to feature imports
  - feature to foundation surface imports
- Use `--strict` (or `--placement-strict`) to fail CI once migrations land.
