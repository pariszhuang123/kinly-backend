## Kinly Foundation Composable System Contract v1

- Status: Proposed
- Owner: Planner (policy), Release (CI enforcement), all agents (compliance)
- Scope: Flutter app (`lib/**`), surface composition, feature slots, registry wiring
- Non-breaking: Yes (additive, refactor-friendly)

This contract sits between the Design System (visuals) and Architecture Guardrails (dependencies). It defines how UI and features are composed without dictating appearance or data models.

### 1) Goals
- Compose screens from small, predictable units.
- Keep layout control with surfaces, not features.
- Make dependency direction explicit and enforceable.
- Allow safe multi-agent changes without structural drift.

### 2) Non-goals
- Redesign visuals (Design System owns this).
- Mandate a state management framework (BLoC is common but not required).
- Force a clean-architecture rewrite.

### 3) Definitions
**Composable unit**
- Single responsibility UI or feature element.
- Declares inputs and slots.
- Does not assume parent/child layout.

**Slot**
- Named, typed extension point for content.
- Structural, not visual.

**Surface**
- Owns layout and orchestration.
- Exposes slots.
- Does not know feature internals.

**Feature module**
- Owns its UI, state, and composition.
- Registers itself into surfaces.
- Never imports other features directly.
- Never mutates surface layout.

**Contracts layer**
- Shared, read-only DTOs and ports used across features.
- Contains no business logic or state transitions.
- Safe to import from any feature.
- Lives under `lib/contracts/**`.

### 4) Hard rules
1) Composition over screens  
   - Screens are assembled from composable units.  
   - Agents compose, not paint.

2) Surfaces own layout, features own content  
   - Surface defines slots.  
   - Feature fills slots.  
   - Feature never positions itself globally.

3) No core to feature imports  
   - `lib/core/**` must not import `lib/features/**` (already enforced by guardrails).

4) Slot contracts are explicit  
   - Each surface declares: available slots, required slots, optional slots, and ordering rules.

### 5) Canonical slot model (v1)
All surfaces use a subset of the canonical model unless an exception is documented.

```
abstract class SurfaceSlots {
  Widget? header;
  Widget body;
  Widget? empty;
  Widget? footer;
  List<Widget>? actions;
}
```

Allowed extensions must be documented per surface.

### 6) Canonical state model (recommended)
Composable units should support these baseline states:

`idle | loading | empty | error | ready`

Rules:
- Surfaces never assume `ready`.
- `empty` is first-class, not an edge case.
- `error` must render without crashing the surface.

### 7) Feature registration contract
Features register into surfaces via explicit registries.

Example:
```
typedef TodayCardFactory = Widget Function(BuildContext);

class TodayRegistry {
  static final List<TodayCardFactory> cards = [];
}

void registerFlowTodayCard() {
  TodayRegistry.cards.add((_) => FlowTodayCard());
}
```

Surfaces must not import feature widgets directly.

#### 7.1) Registration examples (short)
Register a tile/section from a feature module without touching the surface layout:
```
ExploreRegistry.register(
  ExploreSectionEntry(
    id: 'my_feature_tile',
    order: 40,
    builder: (scope) => MyFeatureTile(onTap: scope.actions.onShareTap),
  ),
);
```
Apply the same pattern for Hub/Today/Flow registries (register sections, not layouts).

### 8) Dependency direction rules (CI enforced)
Allowed:
- `core -> foundation`
- `features -> foundation` (theme, UI primitives, DI, logging)
- `features -> contracts/**` (ports + DTOs only)
- `features -> own domain`

Forbidden:
- `core -> features`
- `feature A -> feature B`
- `surface -> feature internals`
- `features -> core/**` (outside foundation)

Foundation scope (v1):
- `lib/core/ui/**`
- `lib/core/theme/**`
- `lib/core/di/**`
- `lib/core/logging/**`
- `lib/core/time/**`
- `lib/core/config/**`
- `lib/core/notifications/**`

### 9) Design system boundary
- Design System governs appearance; Composable System governs structure.
- The umbrella Design System contract (`kinly_design_system_v1.md`) references:
  - `kinly_foundation_colors_v1.md`
  - `kinly_derived_color_engine_v1.md`
  - `kinly_control_color_tokens_v1.md`
- Tokens and primitives can be used anywhere; slot/layout rules cannot be bypassed.
- Renderer boundary: `package:flutter/material.dart` imports are allowed only under
  `lib/renderer/**` (renderer adapters). All other layers must use renderer-agnostic
  primitives.
- Enforcement: `tool/check_design_system.dart` (material import + raw widget guard),
  `tool/check_no_raw_material.dart`, and `tool/check_colors.sh` (color/brightness).

### 10) Agent rules
AI agents must:
- Use existing slots.
- Register features, never hard-wire them.
- Support empty/loading states.
- Avoid new screens without a surface owner.
- Prefer extending registries over branching logic.

### 11) CI enforcement (required)
Checks to add or extend:
- Import graph enforcement (core must not import features).
- Feature isolation (no cross-feature imports).
- Surface slot usage lint (no direct layout overrides).
- Registry usage check (no direct feature references in surfaces).
- Core/contract boundary lint (features must use `contracts/**` for shared DTOs/ports).

#### 11.1) Contracts layer lint (required)

Scope: `lib/contracts/**`

Goal: Keep contracts as dumb, stable inter-module agreements.

Contracts may contain only:
- Ports (interfaces / abstract classes / typedefs)
- DTOs / read models (immutable data-only shapes)
- Serialization helpers (`toJson/fromJson`) and equality (`Equatable`)

Contracts must not contain:
- Widgets, UI code, or surface logic
- Business rules, invariants, or state transitions
- Formatting/localization logic (currency/date formatting)

Forbidden imports from `lib/contracts/**`:
- Any Flutter/UI packages (e.g. `package:flutter/**`, `material.dart`)
- `package:intl/**`
- Any feature modules (`lib/features/**`)
- Any non-foundation core modules (`lib/core/**` outside approved foundation scope)

Allowed imports from `lib/contracts/**`:
- Dart SDK libraries
- `package:equatable/equatable.dart` (optional)
- Other `lib/contracts/**` files
- Foundation primitives if explicitly approved (default: discouraged)

DTO rules (dumb DTO requirement):
- DTOs are immutable (prefer `final` fields + `const` constructors)
- No instance methods except: constructors, `toJson/fromJson`, `props`
- No computed getters that encode UI or business meaning
- No formatting helpers (e.g. `NumberFormat`, `DateFormat`)

CI must fail if contracts violate these rules.
Initial rollout: warning-only until migrated; then error.

Initial rollout: run checks in warning mode until legacy surfaces are migrated.

### 12) Migration strategy
This contract is additive.

Recommended order:
1) Define slot models for Today and Hub.
2) Introduce registries.
3) Migrate features incrementally.
4) Turn CI rules from warning to error.

### 13) Success criteria
- New features require less decision-making.
- Screens emerge from composition, not duplication.
- Features can be added without touching core.
- Visual changes do not break structure.
- Structural changes do not break visuals.

### 14) One-line summary
The Design System defines how Kinly looks.  
The Composable System defines how Kinly grows.

```contracts-json
{
  "domain": "composable_system",
  "entities": {},
  "functions": {},
  "rls": []
}
```
