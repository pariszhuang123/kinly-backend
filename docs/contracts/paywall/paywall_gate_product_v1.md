---
Domain: Shared
Capability: Paywall Gate Product
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Paywall Gate Contract (Product / Client Behavior)

Scope: client-side paywall gating + deterministic retry.

## Goal
- Preserve feature BLoC state (forms) across paywall navigation.
- Open paywall exactly once per request.
- Retry the exact intent deterministically after entitlement is granted.

## Non-goals
- No new backend tables or RLS changes.
- No server-side retry queue.
- No feature-specific callbacks for retry.

## Shared module
File: `lib/features/paywall/ui/paywall_gate.dart`

### Types
- `enum PaywallRetryAction { submit /* later: invite, upload, join... */ }`
- `enum PaywallGateStatus { granted, cancelled, failed }`
- `class PaywallGateRequest { String requestId; String homeId; String source; PaywallRetryAction action; int tick; Set<PaywallTrigger> triggers; String? blockedCommandRequestId; }`
- `class PaywallGateOutcome { String requestId; PaywallRetryAction action; PaywallGateStatus status; }`

### Helper
`Future<PaywallGateOutcome> showPaywallAndAwait({ required BuildContext context, required PaywallGateRequest request, required PaywallStrings strings })`

Requirements:
- Push `KinlyPaywallScreen` and await result (forward `request.triggers` so benefits can be ordered by trigger).
- If result indicates purchase success/restore:
  - call `await paywallRepository.refreshStatus(homeId)`
  - optional backoff retry refresh: 250ms + 500ms + 1000ms (max 3)
- Return outcome with status.

## Feature BLoC integration (per feature)

### State additions
- `int paywallRequestTick` (default 0)
- `PaywallRetryAction? paywallAction`
- `PaywallGateRequest? paywallRequest`
- `String? paywallInFlightRequestId` (guard)

### On cap error
If backend error code in `{paywallActiveCap, paywallMediaCap, paywallExpenseActiveCap, paywallMembersCap, paywallAiCommandDailyLimit}`:
- set `paywallAction = PaywallRetryAction.submit`
- increment `paywallRequestTick`
- create `paywallRequest` with:
  - `requestId = uuid` for the paywall interaction itself
  - `homeId = state.homeId`
  - `source = PaywallSource.commandAiQuota` for AI quota exhaustion; otherwise use the feature-specific paywall source constant for the blocked module/action
  - `action = submit`
  - `tick = paywallRequestTick`
  - `blockedCommandRequestId = original command request id` when the blocked action came from command entry and must replay the same request
- **do NOT clear in-progress form fields**
- For AI quota exhaustion specifically, preserve the original command payload and `requestId` for deterministic post-upgrade replay
- For routed command actions that hit a downstream feature cap after classification, preserve enough module payload/context to retry the same action after upgrade

### Event
`PaywallGateResolved({ required PaywallGateOutcome outcome })`

Handler:
- clear `paywallInFlightRequestId`
- if `outcome.status == granted` and `outcome.action == submit`:
  - call the same submit code path again (no new validation flow)
  - when replaying an AI-quota-blocked command, reuse `blockedCommandRequestId` rather than the paywall interaction `requestId`
  - when replaying a routed command action blocked by a downstream feature cap, reuse the preserved module/action payload rather than rebuilding a new intent from scratch
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
- `static const commandAiQuota = 'command.ai_quota';`

Requirement: No inline strings in features.

### Error code mapping

If backend wire-format errors use snake_case and app-layer constants use camelCase, the mapping MUST be explicit.

Example:

- backend: `paywall_ai_command_daily_limit`
- client constant: `paywallAiCommandDailyLimit`
- backend feature-cap errors MUST remain distinct from `paywall_ai_command_daily_limit`

## Acceptance tests (minimum)
- When cap error occurs, paywall opens once.
- If user cancels, no retry happens.
- If user completes purchase, refreshStatus is called and retry is attempted.
- If rebuild happens during paywall open, no second paywall route is pushed.
- Form state remains intact across paywall route.
- AI quota replay after upgrade reuses the original `requestId`.
- Paywall interaction `requestId` and blocked command `requestId` remain distinct.
