# Kinly Backend — Multi-Agent Development Guide (AGENTS.md)

**Scope:** `kinly-backend` repository only

This document defines roles, boundaries, workflows, guardrails, and the Definition of Done (DoD) for Kinly’s backend.

`kinly-backend` is the **authority** for:
- Database schema and migrations
- Row Level Security (RLS) and policies
- RPC functions (public API surface)
- Edge functions (only when needed)
- Contract authoring and backend verification guardrails

This repo is **not** responsible for frontend behavior, UI flows, or client implementation details.

---

## Quick Reference

### Run before every commit (Linux / WSL recommended on Windows)

```bash
supabase start
supabase db reset
./tool/backend_guardrails.sh
Situational:

bash
Copy code
supabase migration new <name>
supabase db push
supabase stop
Rule: Anything that fails locally is assumed to fail in CI.

Source of Truth: Contracts (Backend)
Contracts live in this repo under:

bash
Copy code
docs/contracts/**
Contracts must reflect enforceable reality:

Schema, types, constraints, and indexes

RLS and security invariants

RPC behavior (inputs/outputs/errors)

Deterministic guarantees and invariants

Publication & Lifecycle
Contract lifecycle, approval, and distribution live in the kinly-contracts repository.

This repo does not contain CONTRACT_LIFECYCLE.md.

Rules:

Do not update contracts without updating the database to match.

Do not publish contracts directly from this repo to clients.

Publishing always happens via kinly-contracts.

Naming Conventions (Backend)
Element	Pattern	Example
Schema	<domain>	homes
Table	<plural_noun>	memberships
RPC	<domain>.<action>	homes.join
Edge fn	<domain>_<action>	homes_join
Migration	action-based, descriptive	add_invites

Dependency Direction (Never Violate)
text
Copy code
Database (schema / RLS / RPC)
  → Contracts (docs/contracts)
    → Published contracts (kinly-contracts)
      → Clients
Principle: The database is the authority. Contracts describe promises made by the database. Clients consume published contracts only.

Mandatory Context Before Any Change
Before proposing or implementing backend changes, you MUST:

Read the relevant contract(s) in docs/contracts/**.

Inspect existing migrations and RLS in supabase/migrations/**.

Decide whether the change is:

New capability (new contract + new DB objects), or

Change to existing capability (version bump + compatibility plan).

If contract and database disagree, fix one immediately.

Prefer updating the database when the contract is correct.

Prefer updating the contract when the database behavior is correct.

Roles (Lightweight by Design)
Roles are lightweight coordination labels. Guardrails + CI enforce correctness.

Planner

Owns scope and sequencing

Approves breaking or high-impact changes

Supabase / DB

Owns enforceable truth: schema, RLS, RPCs, migrations

Contracts

Ensures contracts accurately describe real DB behavior

Test / Verification

Prevents regressions via guardrails and checks

Release / CI

Enforces parity, safety, repeatability in CI

Docs

Maintains AGENTS.md and backend-facing documentation

Boundaries & Ownership
Schema / RLS / RPC → Supabase/DB (Planner + Test review)

Contracts (docs/contracts/**) → Contracts + Supabase/DB

Edge functions → Supabase/DB + Release

CI / infra → Release (Planner approval)

Frontend roles/concerns → out of scope for this repo

Versioning & Compatibility (No Silent Breaks)
A change is breaking if it impacts any of:

RPC input validation, required fields, or semantics

RPC output shape/types/meaning

Authorization behavior (RLS outcomes)

Invariants relied upon by clients

Rules:

Never change RPC output shape without contract versioning.

Prefer additive changes:

Add new fields (nullable) rather than rename/remove

Add new RPCs rather than mutate semantics

If semantics must change:

Version the contract

Provide a compatibility plan (migration period, dual RPCs, etc.)

Workflow (Vertical Slices)
Work in vertical slices in this order:

Contract intent

Migration (tables, types, indexes, constraints)

RLS (policies + invariants)

RPC (public interface)

Verification (guardrails, regression checks)

DoD pass

Merge checklist

Definition of Done (Backend)
A backend change is complete only when ALL apply:

✅ Migration(s) added or updated

✅ RLS policies added or updated

✅ RPCs updated/created if client-facing

✅ Contract updated or versioned to match behavior

✅ ./tool/backend_guardrails.sh passes locally

✅ No silent breaking changes (version contracts)

✅ CI green

Guardrails (Prohibited)
❌ Table-first client exposure without explicit design

❌ Silent breaking changes (version contracts)

❌ Auth-by-convention (always enforce auth.uid() / RLS truth)

❌ Tables without RLS (unless explicitly justified)

❌ Documentation-only contracts (must reflect enforceable reality)

Logging & Observability
Prefer deterministic DB outcomes over logs.

Log in edge functions only when needed:

Authentication failures

Input validation failures

External API errors

Never log secrets or personal data.

CI / Parity
CI mirrors local development as closely as possible.

Rule: Any change that fails in CI is treated as unsafe, even if it appears to work locally.

Troubleshooting
Guardrails failing
Read the failing section in script output.

Fix root cause (order, mismatch, missing policy).

Re-run after a clean reset (supabase db reset).

RLS denying unexpectedly
Confirm auth.uid() context is present in tests.

Verify membership/role rows exist and match expected home/user.

Confirm policy logic matches schema and indexes.

Contract mismatch
Update the database or the contract.

Version the contract if meaning changes.

Multi-Agent Operating Mode
When multiple agents work on backend changes:

DB agent → schema, RLS, RPC, migrations

Contracts agent → contract text + machine blocks

Test agent → verification + regression coverage

Release agent → CI + parity enforcement

Planner approval required for:

Breaking changes

New domains or major capabilities

CI behavior changes

Public API surface expansions (new RPC families)

Design Philosophy
If the backend is unclear, the product is unsafe.

This repo favors:

Explicitness over convenience

Contracts over tribal knowledge

Fewer capabilities, done properly

Slow change with high confidence

pgsql
Copy code
