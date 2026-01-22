## PR Summary

- Brief purpose and scope:
- Feature area:
- Linked Spec / Pseudocode / Plan:
- Contract version (if any):

Given/When/Then
- [ ] Given
- [ ] When
- [ ] Then

## Evidence

- Screenshots/GIFs (UI changes):
- Notes for reviewer:

## Testing

- [ ] Unit tests added/updated (BLoC/Repositories)
- [ ] Widget tests for affected screens
- [ ] DB tests (RLS/RPC) for DB changes

## Solo Mode — Self‑Review Checklist

- [ ] Small, single‑concern PR (trunk‑based)
- [ ] CI green (format, analyze, tests, build)
- [ ] TDD followed for business logic (BLoC/Repositories)
- [ ] Coverage gates pass: Overall ≥95%; 100% for `lib/features/*/{bloc,repositories}/**`
- [ ] Guardrails respected:
  - [ ] No direct Supabase/HTTP in UI or BLoC
  - [ ] All UI strings via `S.of(context)` (no hard‑coded strings)
  - [ ] Cross‑feature imports only via `lib/core/**`
  - [ ] Writes only via approved RPCs; no public invite/join endpoints
- [ ] Contracts/DTOs versioned and linked (if applicable)
- [ ] DB changes include migrations + RLS policies + tests (if applicable)
- [ ] Reflect: What I verified and remaining risks are described in the PR body

## Definition of Done

- [ ] Tests added/updated (BLoC/Repository/UI as applicable)
- [ ] RLS/RPC tests added/updated for DB changes
- [ ] CI green (format, analyze, tests, build)
- [ ] i18n strings via `S.of(context)`
- [ ] Artifacts/screens attached where applicable

## Memory Bank & Coordination

- [ ] Considered updates to `coordination/memory_bank/*` (parameters/failures/dependencies)
- [ ] Progress noted in `coordination/orchestration/progress_tracker.md` if cross-role work
- [ ] Integration dependencies considered in `coordination/orchestration/integration_plan.md`

## Voice & Reasoning

- [ ] Used Paris’ reasoning (see `docs/agents/paris.md`)
- [ ] Added a brief “So what for Kinly”
- [ ] Optional: include `docs/templates/reasoning_note.md` in description
