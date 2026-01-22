## Kinly Derived Color Engine Contract v1.0

- **Status:** Draft → Ready for Codex  
- **Depends on:** Kinly Foundation Colors Contract v1.0  
- **Scope:** All derived colors (light & dark), including ColorScheme, surfaces, sections, and semantic roles  
- **Applies to:** Every UI color used in Kinly widgets

### 1) Purpose
- Converts foundation colors into usable UI colors for both light and dark.
- Guarantees legibility/contrast and removes brightness checks from widgets.
- If a color appears on screen, it must come from this engine.

### 2) Core Principle (Non-Negotiable)
- Foundation colors never appear directly in UI.
- Derived colors always resolve light & dark inside the engine.
- Forbidden: widgets checking `Brightness`, picking black/white manually, or referencing foundation colors directly.

### 3) Responsibilities
- Provide: ColorScheme (light & dark), surface system, section colors (Flow/Share/Pulse/Empty), semantic colors (error/destructive), contrast-safe on-colors.
- Contrast is handled centrally; widgets only consume resolved colors.

### 4) Inputs
- Foundation colors (v1.0), brightness, fixed numeric parameters (tint %, contrast thresholds).  
- No new hex values allowed.

### 5) Output Structure
```
class KinlyDerivedColors {
  final ColorScheme scheme;
  final KinlySections sections;
  final KinlyBrandTextColors brandText;
  final KinlyColorTokens tokens; // includes success/warning/info/disabled
}
```
All outputs are brightness-aware.

### 6) Surface System (Light & Dark)
Base surfaces derive from foundation surfaces; elevation is tinting (no new hex).

Light (base = surfaceLight):
- surface = base
- surfaceContainerLowest = tint(base → white, 2%)
- surfaceContainerLow = tint(base → white, 4%)
- surfaceContainer = tint(base → white, 6%)
- surfaceContainerHigh = tint(base → white, 8%)
- surfaceContainerHighest = tint(base → white, 12%)
- surfaceBright = tint(base → white, 10%)
- surfaceDim = shade(base → black, 8%)
- inverseSurface = shade(base → black, 82%)

Dark (base = surfaceDark):
- surface = base
- surfaceContainerLowest = tint(base → white, 5%)
- surfaceContainerLow = tint(base → white, 8%)
- surfaceContainer = tint(base → white, 12%)
- surfaceContainerHigh = tint(base → white, 16%)
- surfaceContainerHighest = tint(base → white, 22%)
- surfaceBright = tint(base → white, 20%)
- surfaceDim = shade(base → black, 6%)
- inverseSurface = tint(base → white, 92%)

Outline:
- Light: outline = foundation outline; variant = blend(outline, surface, 35%)
- Dark: outline = blend(outline, surface, 65%); variant = blend(outline, surface, 35%)

### 7) Brand Roles
- primary = brandPrimary (light), brandPrimary lifted 8% to white (dark)
- primaryContainer = blend(primary, surface/white, 18% light, 28% dark)
- secondary = brandSecondary (light), brandSecondary lifted 6% to white (dark)
- secondaryContainer = blend(secondary, surface/white, 18% light, 26% dark)
- tertiary = brandAccent (light), brandAccent lifted 2% to white (dark)
- tertiaryContainer = blend(tertiary, surface/white, 16% light, 24% dark)
- inversePrimary = blend(primary, white, 55%)
- surfaceTint = primary

On-colors are chosen via the contrast helper (prefers white/ink, must meet threshold).

### 8) Section Color Derivation
- Accent sources: Flow → primary, Share → brandAccent, Pulse → brandSecondary, Empty → blend(outline, surface, 40%).
- background = blend(surface, accent, 8% light, 18% dark)
- card = blend(surface, accent, 12% light, 24% dark)
- icon = contrast-picked against card (prefers accent, threshold 3.0)
- accent = resolved accent color

### 9) Contrast & Legibility
- Thresholds: normal text ≥ 4.5:1, icons/large text ≥ 3.0:1.
- Helper: `pickOnColor(background, preferred, threshold=4.5)` tries preferred, then chooses best of white vs ink to pass.
- Widgets must never pick foregrounds themselves.

### 10) ColorScheme Generation
- Built entirely inside the engine; no widget brightness branching.
- onPrimary/onSurface/etc. use the contrast helper; error uses foundation error tinted per mode.

### 11) Hard Rules (Enforced)
- No widget may check Brightness.
- No widget may use foundation colors directly.
- No per-feature color logic outside the engine.
- No new hex colors introduced.

### 12) Testing Requirements
- Derived colors exist for both light & dark.
- Flow/Share/Pulse accents are distinct.
- Section background ≠ card.
- Foreground colors meet contrast thresholds.
- No null or identical role collisions.

### 13) Explicit Non-Goals (v1.0)
- Motion/animation colors, brand variants, user-custom colors.

### 14) Definition of Done
- All UI colors come from the derived engine.
- Light/dark mode works without widget changes.
- No brightness checks outside the engine.
- Sections feel distinct but cohesive.
- Contrast is guaranteed by the helper.
