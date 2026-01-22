Status: Proposed

Owner: Planner (policy), Release (CI enforcement), all agents (compliance)

Scope: Flutter app (`lib/**`), surface ownership + placement for top-level destinations

Depends on: Kinly Foundation Composable System Contract v1

Non-breaking: Yes (additive, refactor-friendly)

## 1) Goal

Standardize Kinly’s top-level app surfaces so they are treated as foundation
composition hosts, not feature-owned screens.

This prevents:
- feature-to-feature coupling through surface registries
- layout drift
- cyclic imports (Today depends on Billing depends on Today)
- confusion over where registries live

## 2) Definition: Foundation Surface

A Foundation Surface is a primary navigation destination that:
- hosts contributions from multiple independent features
- owns layout + orchestration + slot definitions
- remains stable even if features are added or removed

## 3) Canonical Foundation Surfaces (v1)

The following are foundation surfaces:
- Today: daily orchestration (what to do today)
- Explore: discovery + capability map + feature launch points
- Hub: home/shared experiences (gratitude wall, home rules, shared preferences)
- Profile: user/home actions and settings (permission-gated actions)

## 4) Required folder placement

Foundation surfaces must live under:
- `lib/foundation/surfaces/today/**`
- `lib/foundation/surfaces/explore/**`
- `lib/foundation/surfaces/hub/**`
- `lib/foundation/surfaces/# architecture_guardrails_amendment_foundation_surfaces_v1.md (Kinly)

Status: Proposed  
Owner: Planner (policy), Release (CI enforcement), all agents (compliance)  
Scope: `lib/**` (Flutter app), `tool/**` (dependency linters), CI workflows  
Non-breaking: Yes (additive, refactor-friendly)

## 0) Purpose

This amendment extends **Architecture Guardrails Contract v1.1** to support the **Foundation Surfaces** model
(Today/Explore/Hub/Profile) and a **GoRouter composition-root** approach, while preventing:
- feature-to-feature coupling
- surface-to-feature coupling
- cyclic imports (Today ↔ Billing, etc.)
- routing drift and inconsistent navigation patterns

It introduces a new module root `lib/foundation/**` and clarifies where routing composition is allowed.

## 1) Depends on / Relationship

Depends on:
- Architecture Guardrails Contract v1.1 (Kinly)
- Kinly Foundation Composable System Contract v1
- `kinly_foundation_surfaces_amendment_v1.md`
- `core_placement_rules_v1.md`

Conflict resolution:
- For anything under `lib/foundation/surfaces/**`, `kinly_foundation_surfaces_amendment_v1.md` and this amendment
  override v1.1 if wording conflicts.

## 2) New module root: Foundation

### 2.1 Module roots (amended)
Architecture Guardrails v1.1 defines:
- `lib/core/**`
- `lib/features/<feature>/**`

This amendment adds:
- `lib/foundation/**`

### 2.2 Foundation surface placement (MUST)
Foundation Surfaces MUST live under:
- `lib/foundation/surfaces/today/**`
- `lib/foundation/surfaces/explore/**`
- `lib/foundation/surfaces/hub/**`
- `lib/foundation/surfaces/profile/**`

Surfaces are not feature-owned screens and MUST NOT live in `lib/features/**` or `lib/core/**`.

## 3) GoRouter composition root (hard)

### 3.1 Router is the only navigation composition root (hard)
`lib/app/router/**` is the **composition root** for GoRouter configuration.

- `lib/app/router/**` MAY import `lib/features/**` UI screens to build routes (Pattern A).
- No other module root may import feature UI for navigation composition.

Rationale: keep routing centralized and avoid features/surfaces importing each other.

### 3.2 Navigation usage (hard)
All navigation MUST use named routes:
- `context.goNamed(...)` / `context.pushNamed(...)`

Forbidden:
- navigating by instantiating another feature’s widget directly as a cross-module pattern
- `Navigator.push(MaterialPageRoute(builder: ...))` for cross-feature navigation

(Using Navigator internally within a feature-only subtree is allowed only if it does not create cross-module coupling,
but prefer GoRouter consistently.)

## 4) Dependency direction rules (hard)

### 4.1 Foundation surfaces must not depend on features (hard)
`lib/foundation/surfaces/**` MUST NOT import:
- `lib/features/**`

### 4.2 Core must not depend on features (re-affirm)
`lib/core/**` MUST NOT import:
- `lib/features/**`

### 4.3 Contracts remain dependency-light (re-affirm)
`lib/contracts/**` MUST NOT import:
- `lib/core/**`
- `lib/features/**`
- `lib/foundation/**`

## 5) Cross-feature imports (hard)

### 5.1 Full strictness inside features (hard)
`lib/features/**` MUST NOT import any other `lib/features/**` module, including:
- barrels: `features/<other>/<other>.dart`
- deep imports: `features/<other>/ui/...`, `bloc/...`, `domain/...`, `data/...`

Rationale: features must not couple to other features; composition happens in foundation surfaces and navigation happens via
the router.

### 5.2 Allowed communication mechanisms
If one feature needs to interact with another, it must do so via:
- `lib/contracts/**` (shared types/interfaces/events)
- foundation-owned navigation callbacks in `SurfaceScope` (which call `goNamed`)
- `lib/app/router/**` route names + params (goNamed)

## 6) Feature contribution to foundation surfaces (registry-only) (hard)

Features may contribute content to foundation surfaces only via surface registries.

Allowed contribution file patterns:
- `lib/features/<feature>/ui/today_<thing>.dart`
- `lib/features/<feature>/ui/explore_<thing>.dart`
- `lib/features/<feature>/ui/hub_<thing>.dart`
- `lib/features/<feature>/ui/profile_<thing>.dart`

Forbidden:
- foundation surfaces importing feature widgets directly
- features importing `lib/foundation/surfaces/**/internal/**` (if present)
- features importing other features to obtain widgets

Allowed imports:
- Surfaces may import: `lib/core/**`, `lib/contracts/**`
- Features may import: `lib/core/**`, `lib/contracts/**`, and their own feature

## 7) B-ready routing organization (required for maintainability)

Even while using Pattern A (router imports feature UI), we require per-feature route definitions to keep future migration to
Pattern B low-cost.

### 7.1 Route naming source of truth (hard)
Add:
- `lib/app/router/app_route_names.dart` (route name constants)
Optionally:
- `lib/app/router/app_route_paths.dart` (path constants)

All `goNamed/pushNamed` calls must reference `AppRouteNames.*` (no raw strings).

### 7.2 Feature route spec file (hard)
Each feature that exposes navigable screens MUST define:
- `lib/features/<feature>/routes/<feature>_routes.dart`

This file defines the feature’s GoRoute builders (or route specs) and is imported by the router composition root only.

Rationale: reduces router churn, and allows later migration to Pattern B (registry) if needed.

## 8) Enforcement (CI / local)

Extend dependency checks to include `lib/foundation/**` and router composition root rules.

Hard checks:
1) Fail if any file under `lib/foundation/surfaces/**` imports `lib/features/**`.
2) Fail if any file under `lib/core/**` imports `lib/features/**`.
3) Fail if any file under `lib/contracts/**` imports `lib/core/**` or `lib/features/**` or `lib/foundation/**`.
4) Fail if any file under `lib/features/**` imports another `lib/features/**` (including barrels).
5) Fail if any file outside `lib/app/router/**` imports feature UI solely to compose navigation routes.

Suggested command (existing pattern):
- `dart run tool/check_dependency_rules.dart`

## 9) Definition of Done (surface/routing impacting PRs)

- All navigation uses `goNamed/pushNamed` with `AppRouteNames.*`.
- Router is the only composition root that imports feature screens for routes.
- Foundation surfaces compile without importing any feature code.
- No feature imports another feature.
- Contracts remain dependency-light.
- CI dependency checks green.

## 10) Success criteria

- Today/Explore/Hub/Profile are stable and feature-agnostic.
- Features can be added/removed without changing surface layout code.
- Routing changes are centralized and deterministic.
- Multi-agent changes do not cause module drift or cross-feature coupling.

{
  "domain": "architecture_guardrails",
  "amendment": "foundation_surfaces_v1",
  "router_composition_root": true,
  "feature_to_feature_imports": "forbidden",
  "navigation": "go_router_named_routes_only",
  "b_ready": true
}
/**`

Each surface must define:
- `*_surface.dart` (layout + orchestration)
- `*_slots.dart` (slot types and allowed contribution types)
- `*_registry.dart` (registration API and ordering)

## 5) Feature contribution rule

Features contribute to foundation surfaces only via registries.

Allowed:
- `lib/features/<feature>/ui/today_<thing>.dart`
- `lib/features/<feature>/ui/explore_<thing>.dart`
- `lib/features/<feature>/ui/hub_<thing>.dart`
- `lib/features/<feature>/ui/profile_<thing>.dart`

Forbidden:
- foundation surfaces importing feature widgets directly
- features importing other features to get a widget for a surface

## 6) Hard dependency rules (CI enforced)

Forbidden imports

`lib/foundation/surfaces/**` MUST NOT import:
- `lib/features/**`

`lib/features/**` MUST NOT import:
- `lib/foundation/surfaces/**/internal/**` (if present)
- other `lib/features/**` modules

Allowed imports

Foundation surfaces may import:
- `lib/contracts/**`
- `lib/core/**` (foundation prefixes only)
- `lib/foundation/**` (surface scaffolding, registries, helpers)

Features may import:
- foundation UI primitives
- `lib/contracts/**`
- their own domain/data/bloc/ui

## 7) Registry contract (ordering + safety)

Registries must support:
- stable IDs per entry (`contributionId`)
- deterministic ordering (see shared comparator below)
- optional gating (`isEnabled(scope)`)

Minimum entry model:
```dart
class SurfaceEntry {
  final int slotIndex;
  final SurfaceTier tier;
  final int order;
  final String featureId;
  final String contributionId;
  final Widget Function(SurfaceScope scope) builder;
  final bool Function(SurfaceScope scope)? isEnabled;
}
```

Shared comparator (required):
- Comparator lives in `lib/foundation/registry/**` and is used by all surfaces.
- Render precedence (highest priority first):
  1) slotIndex (surface-defined slot ordering)
  2) tier (critical | standard | experimental)
  3) order (int, default = 500)
  4) featureId (tie-breaker)
  5) contributionId (final tie-breaker)

## 8) SurfaceScope contract (what features are allowed to know)

Each foundation surface exposes a SurfaceScope to builders containing only:
- read-only context needed for composition (homeId, role flags, plan flags)
- navigation callbacks owned by foundation (not feature-to-feature navigation)
- no direct references to feature types/blocs

Example:
```dart
class TodayScope {
  final bool isOwner;
  final String plan;
  final VoidCallback openSubscription;
  final VoidCallback openInviteFlow;
}
```

## 9) What stays in features (explicit)

Feature-owned screens remain inside their feature:
- Flow screens (chore lists, chore details)
- Share screens (bills list, bill details)
- Gratitude wall screen implementation
- Member management screens

Explore/Hub/Profile/Today can link to them, but do not contain their internals.

## 10) Migration strategy

1) Create foundation surface folders + registries.
2) Move existing `*_surface_*` files from features into foundation.
3) Update registrations in features to point to foundation registries.
4) Add CI checks:
   - fail if any `foundation/surfaces/**` imports `features/**`
   - fail if any feature imports another feature
5) Turn warnings to errors after migration.

## 11) Success criteria

- Adding/removing a feature does not require editing Today/Explore/Hub/Profile
  layouts.
- Surfaces remain stable and feature-agnostic.
- No cross-feature imports.
- Registry ordering is deterministic.

```contracts-json
{
  "domain": "composable_system",
  "amendment": "foundation_surfaces_v1",
  "surfaces": ["today", "explore", "hub", "profile"],
  "rls": []
}
```
