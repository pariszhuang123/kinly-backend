---
Domain: SHARE
Capability: Recurring Expenses UX
Scope: shared
Artifact-Type: contract
Stability: stable
Status: Draft
Version: v1.1
---

# Kinly Share — One-Off & Recurring Expenses (Product) v1.1

Purpose: product-facing rules and UX expectations for recurring expenses. API/DB details live in `share_recurring_api_v1.md`.

## Core Principles (product lens)
- Plans define intent; expenses are immutable snapshots once active.
- Drafts are creator-only and quota-free; activation is a one-way door.
- Activation requires ≥2 distinct debtors; creator cannot be sole debtor.
- Cron always generates cycles; paywall blocks users, not cron.
- Termination stops future cycles; history remains payable.
- Payments are harmony-first (bulk “pay what I owe to payer X”).

## Lifecycle (user-facing)
- Draft → Activate one-off: validate splits, set active, immutable thereafter.
- Draft → Activate recurring: create plan, convert draft to `converted`, generate first cycle immediately, then cron generates future cycles.
- Terminate: creator stops future cycles; past cycles remain payable.

## Surface Expectations
- Recurring cycles appear in Today/Explore as regular active expenses with `planId` + `recurrenceInterval`.
- `expenses_get_for_edit` returns `editDisabledReason` of `ACTIVE_IMMUTABLE`, `RECURRING_CYCLE_IMMUTABLE`, or `CONVERTED_TO_PLAN` when edits are blocked.
- Cron-generated cycles should not prompt user paywall flows; user-triggered activation enforces quota/paywall.

## Paywall & Usage (product slice)
- Drafts do not consume `active_expenses`.
- First cycle activation enforces quota; cron cycles bypass quota but still increment usage; decrement on full payment.

## Copy / UX Notes
- Reflect recurring state in titles/subtitles (e.g., “Every month”) via l10n keys.
- Use non-blocking messaging for cancellation/termination confirmations; do not block history views.
- Keep creator’s form state intact when hitting paywall; retry post-entitlement using the same inputs.
