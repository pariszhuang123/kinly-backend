---
Domain: Design System
Capability: Design System Foundations
Scope: frontend
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

## Kinly Design System Contract v1

- Status: Proposed
- Owner: Planner (policy), Release (CI enforcement), all agents (compliance)
- Scope: Flutter app (`lib/**`), design system tokens, primitives, renderers
- Non-breaking: Yes (additive, refactor-friendly)

This contract is the umbrella for Kinly visual rules. It references token/color
contracts without re-stating their contents.

### 1) Goals
- Keep UI renderer-agnostic while preserving Kinly visual identity.
- Ensure all visuals are expressed through semantic tokens and primitives.
- Make light/dark mode behavior stable without widget-side branching.

### 2) Non-goals
- Redesign visuals or redefine token values (see referenced contracts).
- Replace Flutter's rendering engine or impose platform-specific UI.
- Require a folder move to `lib/design_system/**` (optional future work).

### 3) References (source of truth)
- `kinly_foundation_colors_v1.md`
- `kinly_derived_color_engine_v1.md`
- `kinly_control_color_tokens_v1.md`
- `kinly_composable_system_v1.md` (composition boundary)
- `core_placement_rules_v1.md` (placement and dependency rules)

### 4) Design system boundaries (hard)
1) Token-first rendering  
   - UI may use tokens and primitives only; no raw colors or brightness checks.
2) Renderer containment  
   - `package:flutter/material.dart` imports are allowed only under
     `lib/renderer/**`.
3) Renderer-agnostic primitives  
   - Primitives and tokens must not depend on renderer-specific widgets.

### 5) Placement (current)
- Tokens + theme extensions: `lib/core/theme/**`
- Primitives: `lib/core/ui/**`
- Renderers (future): `lib/renderer/**`

### 6) Enforcement (CI)
- `tool/check_design_system.dart` (raw Material widgets + material.dart import boundary)
- `tool/check_no_raw_material.dart` (raw Material widgets in features/foundation)
- `tool/check_colors.sh` (color literals, Colors.*, brightness branching)
- `tool/check_theme_tokens.dart` (theme extension and opacity token usage)

### 7) Definition of Done (UI changes)
- Uses Kinly primitives and tokens.
- No renderer imports outside `lib/renderer/**`.
- Passes design system guardrails and color checks.

```contracts-json
{
  "domain": "design_system",
  "entities": {},
  "functions": {},
  "rls": []
}
```
