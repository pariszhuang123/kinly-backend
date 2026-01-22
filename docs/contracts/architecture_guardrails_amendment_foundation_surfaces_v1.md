## Architecture Guardrails Amendment — Foundation Surfaces v1 (Kinly)

- Status: Proposed
- Owner: Planner (policy), Release (CI enforcement), all agents (compliance)
- Scope: `lib/**` (Flutter app), `tool/**` (dependency linters), CI workflows
- Non-breaking: Yes (additive, refactor-friendly)

This amendment extends Architecture Guardrails v1.1 to support the Foundation
Surfaces model (Today/Explore/Hub/Profile) and a GoRouter composition-root
approach while preventing:
- feature-to-feature coupling
- surface-to-feature coupling
- cyclic imports (Today ↔ Billing, etc.)
- routing drift and inconsistent navigation patterns

It introduces a new module root `lib/foundation/**` and clarifies where routing
composition is allowed.

### 1) Depends on / Relationship

Depends on:
- Architecture Guardrails Contract v1.1 (Kinly)
- Kinly Foundation Composable System Contract v1
- `kinly_foundation_surfaces_amendment_v1.md`
- `core_placement_rules_v1.md`

Conflict resolution:
- For anything under `lib/foundation/surfaces/**`,
  `kinly_foundation_surfaces_amendment_v1.md` and this amendment override v1.1
  if wording conflicts.

### 2) New module root: Foundation

#### 2.1 Module roots (amended)
Architecture Guardrails v1.1 defines:
- `lib/core/**`
- `lib/features/<feature>/**`

This amendment adds:
- `lib/foundation/**`

#### 2.2 Foundation surface placement (MUST)
Foundation Surfaces MUST live under:
- `lib/foundation/surfaces/today/**`
- `lib/foundation/surfaces/explore/**`
- `lib/foundation/surfaces/hub/**`
- `lib/foundation/surfaces/profile/**`

Surfaces are not feature-owned screens and MUST NOT live in `lib/features/**`
or `lib/core/**`.

Other screens (e.g., Welcome, auth, onboarding, settings sub-screens) remain
feature-owned unless explicitly promoted to a Foundation Surface.

### 3) GoRouter composition root (hard)

#### 3.1 Router is the only navigation composition root (hard)
`lib/app/router/**` is the only composition root for GoRouter configuration.

- `lib/app/router/**` MAY import `lib/features/**` UI screens to build routes
  (Pattern A).
- `lib/app/router/**` MAY import `lib/foundation/**` surface hosts.
- No other module root may import feature UI for navigation composition.

Rationale: keep routing centralized and avoid features/surfaces importing each
other.

#### 3.2 Navigation usage (hard, phased)
Target: all cross-feature navigation uses named routes via
`context.goNamed(...)` / `context.pushNamed(...)`.

Phase 1 (now):
- Allow `context.go(...)` / `context.push(...)` with `AppRoutes.*` path constants.

Phase 2 (after route name migration):
- Enforce named-route usage only.

#### 3.3 Design System boundary (hard)
Design System rules are enforced by the umbrella contract:
`kinly_design_system_v1.md`.

Hard rule:
- `package:flutter/material.dart` imports are allowed only under `lib/renderer/**`.

### 4) Dependency direction rules (hard)

#### 4.1 Foundation surfaces must not depend on features (hard)
`lib/foundation/surfaces/**` MUST NOT import:
- `lib/features/**`

#### 4.2 Core must not depend on features (re-affirm)
`lib/core/**` MUST NOT import:
- `lib/features/**`

#### 4.3 Contracts remain dependency-light (re-affirm)
`lib/contracts/**` MUST NOT import:
- `lib/core/**`
- `lib/features/**`
- `lib/foundation/**`

### 5) Cross-feature imports (hard)

#### 5.1 Full strictness inside features (hard)
`lib/features/**` MUST NOT import any other `lib/features/**` module, including:
- barrels: `features/<other>/<other>.dart`
- deep imports: `features/<other>/ui/...`, `bloc/...`, `domain/...`, `data/...`

#### 5.2 Allowed communication mechanisms
If one feature needs to interact with another, it must do so via:
- `lib/contracts/**` (shared types/interfaces/events)
- foundation-owned navigation callbacks in `SurfaceScope` (which call `goNamed`)
- `lib/app/router/**` route names + params (goNamed)

### 6) Feature contribution to foundation surfaces (registry-only) (hard)

Features may contribute content to foundation surfaces only via surface
registries.

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

### 7) B-ready routing organization (required for maintainability)

Even while using Pattern A (router imports feature UI), we require per-feature
route definitions to keep future migration to Pattern B low-cost.

#### 7.1 Route naming source of truth (hard, phased)
Add:
- `lib/app/router/app_route_names.dart` (route name constants)
Optionally:
- `lib/app/router/app_route_paths.dart` (path constants)

Phase 1 (now): optional but recommended.
Phase 2 (after migration): required; all navigation uses `AppRouteNames.*`.

#### 7.2 Feature route spec file (hard)
Each feature that exposes navigable screens MUST define:
- `lib/features/<feature>/routes/<feature>_routes.dart`

This file defines the feature’s GoRoute builders (or route specs) and is
imported by the router composition root only.

Rationale: reduces router churn and allows later migration to Pattern B
(registry).

### 8) Enforcement (CI / local)

Extend dependency checks to include `lib/foundation/**` and router composition
root rules.

Hard checks:
1) Fail if any file under `lib/foundation/surfaces/**` imports `lib/features/**`.
2) Fail if any file under `lib/core/**` imports `lib/features/**`.
3) Fail if any file under `lib/contracts/**` imports `lib/core/**`,
   `lib/features/**`, or `lib/foundation/**`.
4) Fail if any file under `lib/features/**` imports another `lib/features/**`
   (including barrels).
5) Fail if any file outside `lib/app/router/**` imports feature UI to compose
   navigation routes.

Suggested command (existing pattern):
- `dart run tool/check_dependency_rules.dart`

### 9) Definition of Done (surface/routing impacting PRs)

- Router is the only composition root that imports feature screens for routes.
- Foundation surfaces compile without importing any feature code.
- No feature imports another feature.
- Contracts remain dependency-light.
- CI dependency checks green.

### 10) Success criteria

- Today/Explore/Hub/Profile are stable and feature-agnostic.
- Features can be added/removed without changing surface layout code.
- Routing changes are centralized and deterministic.
- Multi-agent changes do not cause module drift or cross-feature coupling.

```contracts-json
{
  "domain": "architecture_guardrails",
  "amendment": "foundation_surfaces_v1",
  "router_composition_root": true,
  "feature_to_feature_imports": "forbidden",
  "navigation": "go_router_named_routes_only",
  "b_ready": true,
  "rls": []
}
```
