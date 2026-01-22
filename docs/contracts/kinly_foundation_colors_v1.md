## Kinly Foundation Colors Contract v1.0

- **Status:** Approved for implementation  
- **Scope:** Foundation color inputs only  
- **Audience:** Codex (implementation), human reviewer (sign-off)  
- **Applies to:** All Kinly apps, features, and themes (light & dark)

### 1) Purpose
- Defines the minimum, immutable set of foundation colors for Kinly.
- Foundation colors are the only hard-coded hex values allowed in the color system and are the inputs from which all other colors (surfaces, sections, tokens, controls) are derived.
- They are brand-defining, not feature-specific. All other colors must be derived from these foundations via tinting, elevation, or contrast rules (handled in later contracts).

### 2) Design Principles (Kinly-specific)
- Calm, warm, grounded (not loud, not playful).
- Nature-adjacent (green, sage, honey).
- High legibility first, delight second.
- Light & dark are peers, not inversions.
- Features feel distinct without fragmenting the brand.

### 3) Foundation Color Set (v1.0) — 8 total (exactly once)
**Surfaces (2)** — Used as base for all backgrounds and elevations.
- `surfaceLight` = `Color(0xFFFAFAF9)`
- `surfaceDark` = `Color(0xFF101312)`

**Brand (3)** — Defines Kinly’s identity.
- `brandPrimary` (Kinly Teal) = `Color(0xFF366D59)`
- `brandSecondary` (Sage) = `Color(0xFF8BAA91)`
- `brandAccent` (Honey) = `Color(0xFFF6B73C)`

**Neutral Ink & Structure (2)**
- `ink` (foreground anchor) = `Color(0xFF101312)`
- `outline` (dividers, borders, disabled) = `Color(0xFFB7C7C0)`

**Semantics (1)**
- `error` (destructive/failure only) = `Color(0xFFE53935)`

### 4) Rules & Constraints
- No additional hex colors outside this set; no per-feature colors; no ramps/containers here.
- Foundation colors do not have light/dark duplicates; mode differences come from surface choice and derived rules.
- Feature identity comes later via accent assignment, tint strength, layout/iconography/motion.
- Accessibility: chosen to support WCAG when paired correctly; foreground/background pairing is enforced in derived layers.

### 5) Code Structure Requirements
- Single source of truth: `lib/core/theme/foundation/kinly_foundation_colors.dart`.
- Expose colors as `static const Color`.
- No other file may introduce new color literals; add a lint/check to block `Color(0x...)` outside the foundation file (temporary allowlist may be used while migrating legacy values).

### 6) Explicit Non-Goals (v1.0)
- Does not define ColorScheme mapping, containers/elevation, section backgrounds, controls, success/warning/info, or contrast helpers. These belong to derived contracts (Derived Color Engine, Section Colors, Control Tokens).

### 7) Acceptance Criteria
- Exactly 8 foundation colors exist and are brand-aligned/calm.
- No other hex colors appear in the app (post-migration).
- Light/dark render using the same foundations (surface choice differs only).
- Codex does not add “just one more color.”

### 8) Why This Is Deliberate
- A small, locked foundation prevents visual drift, simplifies accessibility, and keeps Kinly cohesive across many features/platforms over time.
