---
Domain: Design System
Capability: Control Color Tokens
Scope: frontend
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

## Kinly Control Color Tokens Contract v1.0

- **Status:** Draft → Ready for Codex  
- **Depends on:** Foundation Colors v1.0, Derived Color Engine v1.0  
- **Scope:** All interactive UI controls in Kinly  
- **Applies to:** Every widget that renders a control color

### 1) Purpose
- Defines the named, semantic color tokens for controls. Tokens sit above the derived engine and encode interaction states so widgets do zero color logic.

### 2) Core Rule (Non-Negotiable)
- Widgets consume `ControlColors.<token>` only. Forbidden in widgets: hex values, direct `ColorScheme` access, state-based color picking, brightness checks.

### 3) Token Categories (v1.0)
- **Filled:** `filledBg`, `filledFg`, `filledDisabledBg`, `filledDisabledFg`, `filledDestructiveBg`, `filledDestructiveFg`, `filledDestructiveDisabledBg`, `filledDestructiveDisabledFg`, plus aliases for `fab` and `addTile`.
- **Outlined:** `outlinedBorder`, `outlinedFg`, `outlinedDisabledBorder`, `outlinedDisabledFg`.
- **Text/Ghost:** `textFg`, `textDisabledFg`.
- **Selection:** `selectionCheckedBg`, `selectionCheckedFg`, `selectionUncheckedBg`, `selectionUncheckedBorder`, `selectionDisabledBg`, `selectionDisabledBorder`, `selectionDisabledFg`.
- **Option/List Rows:** `optionRowBg`, `optionRowFg`, `optionRowSelectedBg`, `optionRowSelectedFg`, `optionRowBorder`.
- **Feedback & Status:** `loader`, `badgeBg`, `badgeFg`, `errorBadgeBg`, `errorBadgeFg`.
- **Misc (v1.0 carry-overs):** `expandBadgeBg`, `expandBadgeIcon`, `commentBoxBg`, `commentBoxBorder`, `pickerPrimary`, `pickerOnPrimary`, `avatarBadgeBg`, `avatarBadgeFg` (to be rationalized later).

### 4) Derivation Rules
- All tokens derive from the Derived Color Engine (no new hex). Examples:
  - Filled = `scheme.primary/onPrimary`; destructive = `scheme.error/onError`.
  - Disabled = blend of `scheme.surface` and `derived.disabled`, with on-colors chosen via contrast helper (no opacity hacks).
  - Outlined = `scheme.outline` (disabled → `derived.disabled`); fg = `scheme.primary` (dark uses `onSurface` if contrast fails).
  - Text/Ghost = `scheme.primary` / disabled = `derived.disabled`.
  - Selection = checked → `scheme.primaryContainer/onPrimaryContainer`; unchecked → `scheme.surface/outline`; disabled → `derived.disabled`.
  - Option rows = `scheme.surfaceContainer` / selected → `scheme.primaryContainer/onPrimaryContainer`; border = `scheme.outlineVariant`.
  - Badges = base on `scheme.primary` (error on `scheme.error`) with low alpha fill; fg uses the tint hue (not a contrast-picked on-color) to avoid alpha-compositing surprises across surfaces.
  - Loader = `scheme.onSurface` (dark) / `scheme.primary` (light).

### 5) State Handling
- Default and disabled defined for all; selected for applicable controls. Future: hover/pressed/focused can extend tokens without widget logic.

### 6) Accessibility
- All fg/bg pairs must meet WCAG thresholds (4.5:1 text, 3.0:1 icons/large). Use the derived engine’s contrast helper; no widget-side decisions.

### 7) Implementation Rules
- Tokens live centrally in `KinlyControlColors` and are injected via Theme extensions.
- Widgets must be migrated to token access only.
- Badge UI must use `KinlyBadge` (default maps to `badgeBg`/`badgeFg`, destructive maps to `errorBadgeBg`/`errorBadgeFg`).
- No new hex values; all derivations use engine outputs.

### 8) Testing Requirements
- Tokens resolve for light & dark; disabled are distinct; selected states differ from defaults; contrast thresholds pass; no token equals its background unintentionally.
- CI runs `bash tool/check_colors.sh` to enforce guardrails (no rogue colors/brightness in UI) and unused token detection; WCAG contrast tests live in `test/core/theme/wcag_contrast_test.dart`.

### 9) Explicit Non-Goals (v1.0)
- Motion/animation colors, per-feature control styling, user-custom themes.

### 10) Definition of Done
- Widgets never pick colors; control visuals are consistent; dark mode works automatically; adding a control does not add color logic or new hex.
