---
Domain: Monetization
Capability: Plan status visibility & entry point
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: active
Version: v1.0
---

# Profile App Bar Plan Button — v1.0

Purpose: Provide a discoverable, always-available plan entry point in the Profile app bar that reflects the user's effective home plan and routes to the correct surface.

## UI Placement (Normative)

- The Plan Button appears in the Profile screen app bar, aligned to the right.
- It is visible whenever the Profile screen is shown.

## Clickability & Visual Affordance (Normative)

- Render as a button-like control (e.g., pill with border/background).
- Include at least one affordance marker (e.g., chevron: `Free ▾` / `Premium ▾`).
- Plain text alone MUST NOT be used.

## States & Interaction (Normative)

**Free**
- Label: `S.of(context).planFreeLabel` (recommended: "Free").
- Tap → open Premium paywall.

**Premium**
- Label: `S.of(context).planPremiumLabel` (recommended: "Premium").
- Tap → open non-blocking bottom sheet confirming premium.
- Bottom sheet content:
  - Title: `S.of(context).planPremiumActiveTitle`
  - Body: `S.of(context).planPremiumActiveBody`
  - Close action: `S.of(context).close`

## Localization & Accessibility (Normative)

- All strings use `S.of(context)`.
- Minimum keys:
  - `planFreeLabel`, `planPremiumLabel`, `planButtonHint`, `planPremiumActiveTitle`, `planPremiumActiveBody`, `close`.
- The button exposes a semantic label / tooltip via `S.of(context).planButtonHint`.

## Data Source (Normative)

- Driven by backend RPC [`get_plan_status()`](../../../api/kinly/homes/get_plan_status_v1.md).

### Client Fetch & Refresh (Normative)

- Call `get_plan_status()` when Profile first shows, after home context changes, after purchase/restore completes, and after returning from external subscription management.
- UI shows a loading affordance until RPC completes.
- Failure state: show safe fallback label (e.g., `S.of(context).planUnknownLabel`), tap opens paywall or an info sheet (either is acceptable).

## Non-Goals (Explicit)

- Does not define paywall pricing or purchase flow.
- Does not change quota enforcement.
- Does not specify how premium is computed beyond `_home_effective_plan`.
