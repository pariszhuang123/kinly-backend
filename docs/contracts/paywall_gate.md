---
Domain: MONETIZATION
Capability: Paywall Gate Behavior
Scope: mobile
Artifact-Type: contract
Stability: stable
Status: Draft
Version: v1.0
---

# Paywall Gate Contract (Client)

Note: Split into `paywall_gate_product_v1.md` (behavior) and `paywall_gate_copy_v1.md` (copy). Keep this file as the legacy combined view until migration completes.

Scope: client-side paywall gating + deterministic retry.

## Goal
- Preserve feature BLoC state (forms) across paywall navigation.
- Open paywall exactly once per request.
- Retry the exact intent deterministically after entitlement is granted.

## Non-goals
- No new backend tables or RLS changes.
- No server-side “retry queue”.
- No feature-specific callbacks for retry.

## Shared module
File: `lib/features/paywall/ui/paywall_gate.dart`

### Types
- `enum PaywallRetryAction { submit /* later: invite, upload, join... */ }`
- `enum PaywallGateStatus { granted, cancelled, failed }`
- `class PaywallGateRequest { String requestId; String homeId; String source; PaywallRetryAction action; int tick; Set<PaywallTrigger> triggers; }`
- `class PaywallGateOutcome { String requestId; PaywallRetryAction action; PaywallGateStatus status; }`

### Helper
`Future<PaywallGateOutcome> showPaywallAndAwait({ required BuildContext context, required PaywallGateRequest request, required PaywallStrings strings })`

Requirements:
- Push `KinlyPaywallScreen` and await result (forward `request.triggers` so benefits can be ordered by trigger).
- If result indicates purchase success/restore:
  - call `await paywallRepository.refreshStatus(homeId)`
  - optional backoff retry refresh: 250ms → 500ms → 1000ms (max 3)
- Return outcome with status.

## Feature BLoC integration (per feature)

### State additions
- `int paywallRequestTick` (default 0)
- `PaywallRetryAction? paywallAction`
- `PaywallGateRequest? paywallRequest`
- `String? paywallInFlightRequestId` (guard)

### On cap error
If backend error code in `{paywallActiveCap, paywallMediaCap}`:
- set `paywallAction = PaywallRetryAction.submit`
- increment `paywallRequestTick`
- create `paywallRequest` with:
  - `requestId = uuid`
  - `homeId = state.homeId`
  - `source = PaywallSource.flowCreateChore` (constant)
  - `action = submit`
  - `tick = paywallRequestTick`
- **do NOT clear in-progress form fields**

### Event
`PaywallGateResolved({ required PaywallGateOutcome outcome })`

Handler:
- clear `paywallInFlightRequestId`
- if `outcome.status == granted` and `outcome.action == submit`:
  - call the same submit code path again (no new validation flow)
- else do nothing (optionally emit a non-blocking message on cancelled/failed)

## UI integration (shared wrapper preferred)

- Implement `PaywallGateListener` widget to reduce per-screen boilerplate.
- Trigger only when `state.paywallRequestTick` changes OR `paywallRequest.requestId` changes.
- In-flight guard:
  - if `state.paywallInFlightRequestId == request.requestId` → ignore
  - when starting paywall open, dispatch `PaywallGateOpened(requestId)` OR set in-flight in bloc
  - after awaiting, dispatch `PaywallGateResolved(outcome)`

## Source constants
File: `lib/core/paywall/paywall_sources.dart`

Examples:
- `static const flowCreateChore = 'flow.create_chore';`
- `static const flowEditChore = 'flow.edit_chore';`
- `static const shareCreateExpense = 'share.create_expense';`

Requirement: No inline strings in features.

## Acceptance tests (minimum)
- When cap error occurs, paywall opens once.
- If user cancels, no retry happens.
- If user completes purchase, refreshStatus is called and retry is attempted.
- If rebuild happens during paywall open, no second paywall route is pushed.
- Form state remains intact across paywall route.
