---
Domain: Design System
Capability: Paywall Gate Copy
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: Draft
Version: v1.0
---

# Paywall Gate Copy Contract (Client)

Purpose: define copy rules for paywall gate surfaces and retries, aligned with the product behavior in `paywall_gate_product_v1.md`.

Rules
- All strings are localized via `S.of(context)`; no inline literals in features or BLoC.
- Benefit ordering must follow `PaywallTrigger` → benefit mapping (source constants in `paywall_sources.dart`); copy should reference the active trigger where applicable.
- Outcome messaging:
  - `granted`: show success/entitlement confirmed copy.
  - `cancelled`/`failed`: optional non-blocking message; no blocking dialogs.
- Forms keep state intact across paywall; copy must not instruct users to re-enter data.

Artifacts
- String keys live with paywall UI module; keep naming consistent with existing paywall l10n keys (e.g., `paywallGate_title`, `paywallGate_benefit_primary`, `paywallGate_retry_message`).
- Any new trigger-specific benefit lines must be added to l10n files and referenced via the trigger-to-benefit mapping (no hardcoded per-feature text).
