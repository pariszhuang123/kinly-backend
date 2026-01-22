---
Domain: Engineering System
Capability: Testing Guardrails
Scope: platform
Artifact-Type: contract
Stability: stable
Status: Approved
Version: v1.0
---

# Testing — Unified Contract (v1)

Scope: Kinly MVP (Flow, Share, Pulse/Gratitude, Home, Auth, Paywall). Applies to Flutter app, Supabase RPCs/migrations, and Edge Functions.

## Purpose
- Keep Kinly safe, predictable, and calm while shipping fast on trunk.
- Important behaviour is codified in tests; changes that matter are never untested.
- Bugs, once fixed, do not come back.

## General Principles
1) If it can break a home, it must be tested (Auth, membership, Flow, Share, Pulse, paywall, notifications).  
2) Every bug fix adds a test; no regression fix ships without a failing-before/ passing-after test, or a written justification.  
3) Business logic lives in testable places (Flutter blocs/services; Supabase RPCs/functions).  
4) Tests assert behaviour, not implementation details.  
5) Flaky tests are bugs; fix or rewrite them.

## Surfaces Under Test
- Flutter app: `lib/**` with tests in `test/**` (unit, bloc, widget, golden).
- Supabase Edge Functions: `supabase/functions/**` with Deno tests co-located per function folder (at least one `*.test.ts`, e.g., `index.test.ts`).
- Supabase backend: `supabase/migrations/**` with tests in `supabase/tests/**` (pgTap/SQL-style).
- Contracts/types (soft v1): generated schemas in `tool/` or `contracts/` as available.

## Minimum Expectations Per Change
- Flutter (`lib/**`): If you add/change a screen, bloc, validation, branching, navigation, error handling, or paywall UI, update or add at least one relevant test.  
  - Prefer bloc tests for event-to-state behaviour.  
  - Widget tests for interaction/navigation changes.  
  - Golden tests only when visual structure must stay stable.
- Supabase migrations/RPCs (`supabase/migrations/**`): For new/edited RPCs, tables, constraints, views, or limit checks, add a pgTap test in `supabase/tests/**` that exercises the RPC or constraint (success + unauthorized + boundary where meaningful).
- Supabase functions (`supabase/functions/**`): Each function folder must contain at least one Deno test (`*.test.ts`, e.g., `index.test.ts`) covering the function entry point. Keep core logic in SQL when possible; otherwise add a smoke test via pgTap or the minimal harness you have.

## Deterministic Time and Animation
- Use a clock abstraction (or `package:clock`) for any logic that depends on time (cooldowns, rate limits, timestamps). Tests use a fake/fixed clock. Avoid direct `DateTime.now()` in logic.  
- For animations/goldens, fix ticker/frame timing and clamp durations to test constants; prefer reduce-motion mode for goldens to avoid flakes.

## Golden Matrix (lean, deterministic)
- Devices: compact phone (375x812) and medium/tall Android (411x915).  
- Themes: light and dark for both.  
- Locale/direction: add RTL (e.g., `ar`) on the compact device in light mode.  
- Text scale: default 1.0; add 1.3 where layouts are sensitive.  
- Goldens capture end states (especially with reduce-motion enabled).

## CI Expectations for Trunk
- If `lib/**` or `supabase/migrations/**` change and neither `test/**` nor `supabase/tests/**` change, fail with a hint to add/justify tests.  
- If the commit message contains `fix`, `bug`, or `regression`, require a test diff or an explicit justification.  
- Each Supabase Edge Function folder must ship at least one `*.test.ts`; CI guard fails if missing and `deno test` runs for all functions.  
- Optional: warn when migrations touching RPCs/limits have no pgTap references.

## Acceptance Criteria (v1)
- At least one test changed or a clear justification is recorded for why tests were not needed (e.g., copy-only change).  
- Each Supabase Edge Function folder contains a Deno test (`*.test.ts`).  
- New/updated RPCs are exercised in pgTap.  
- New/updated blocs have a meaningful test unless trivial; bug fixes include a regression test.  
- RLS is via security-definer RPCs; auth/limit checks must still be covered by pgTap.

## Future v2 (not required yet)
- Modest coverage floor for bloc/repository packages (e.g., 60–70%).  
- Scripts to list RPCs and enforce pgTap presence.  
- Contract drift checks for OpenAPI/types.
