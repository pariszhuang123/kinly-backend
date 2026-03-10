---
Domain: Growth
Capability: outreach_poll_result_messages
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: active
Version: v1.0
Audience: internal
Last updated: 2026-03-03
---

# Contract - Outreach Poll Result Messages API v1.0

## Purpose
Define the backend schema and access contract for data-driven poll results messaging (`message + CTA label`) keyed by poll option, with optional targeting overrides.

This contract is the authoritative backend definition for `public.outreach_poll_result_messages`.

## Publication and Enforceability State
- This contract is enforceable by DB objects in `20260322090023_outreach_poll_result_messages_v1.sql`.
- Contract publication remains gated by passing local/CI guardrails.

## Design Constraints
- Frontend resolves message fallback in client flow (`EXACT -> SOURCE_ONLY -> GLOBAL_DEFAULT -> FALLBACK`).
- No dedicated resolver RPC is introduced in v1.0.
- Poll tables remain RPC-first for writes; this table is read-only for public clients.

## Authoritative Table
Table: `public.outreach_poll_result_messages`

Required columns:
- `id uuid primary key default gen_random_uuid()`
- `poll_id uuid not null references public.outreach_polls(id) on delete cascade`
- `option_id uuid not null references public.outreach_poll_options(id) on delete cascade`
- `primary_message text not null`
- `cta_label text not null`
- `source_id_resolved text null references public.outreach_sources(source_id)`
- `utm_campaign text null`
- `active boolean not null default true`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

## Constraints and Invariants
Required constraints:
- trimmed `primary_message` length MUST be `1..280`
- trimmed `cta_label` length MUST be `1..60`
- if `utm_campaign` is set, trimmed length MUST be `1..128` (blank not allowed)
- if `utm_campaign` is set, `source_id_resolved` MUST be set
- uniqueness MUST enforce at most one row for:
  - `(poll_id, option_id, source_id_resolved, utm_campaign)`
  - `NULL` targeting values MUST be treated as equal for this uniqueness rule

Data invariants:
- `option_id` MUST reference an existing poll option row.
- `(poll_id, option_id)` MUST reference an existing poll/option pair.
- `active = true` rows are eligible for frontend resolution.
- inactive rows MUST never be returned to unauthenticated readers.

## Trigger Requirement
Table MUST include trigger:
- `trg_outreach_poll_result_messages_touch_updated_at`

Behavior:
- BEFORE UPDATE trigger MUST invoke `_touch_updated_at()` to maintain `updated_at`.

## Read Surface and Query Semantics
Public results flow (unauthenticated) MUST be able to read active rows for:
- requested `poll_id`
- requested `option_id`
- optional `source_id_resolved` and `utm_campaign` targeting

Expected client query shape (non-normative SQL sketch):
- filter `poll_id`, `option_id`, `active = true`
- include rows where targeting matches one of:
  - exact source + campaign
  - source only (`utm_campaign is null`)
  - global (`source_id_resolved is null` and `utm_campaign is null`)
- frontend then applies deterministic tier ordering.

No resolver RPC is required in v1.0.

## RLS and Permissions
RLS MUST be enabled on `outreach_poll_result_messages`.

Permissions:
- unauthenticated/public clients MUST have read access only to `active = true` rows.
- unauthenticated/public clients MUST NOT insert/update/delete.
- writes SHOULD be restricted to `service_role` or authenticated admin workflow.

Required policy/grant shape:
- `SELECT` policy for anon/authenticated constrained by `active = true`.
- no `INSERT/UPDATE/DELETE` policy for anon/authenticated.
- table `SELECT` grant to `anon` and `authenticated`.
- full DML grants may be given to `service_role` only.

## Consistency and Failure Expectations
- Missing matching rows are valid and MUST be handled by frontend fallback copy/CTA.
- Duplicate targeted active rows for the same uniqueness tuple MUST be prevented by DB constraint.
- Constraint violations on writes MUST fail transactionally (no partial writes).

## Dependencies
- Poll API contract: `outreach_polls_v1.md`
- Tracking API contract: `outreach_tracking_v1_1.md`
- Frontend behavior contract: `../../../product/kinly/web/growth/outreach_poll_result_messages_contract_v1.md`

## Acceptance Criteria
1. Table exists with required columns and foreign keys.
2. Length checks and uniqueness tuple are enforced.
3. DB enforces campaign/source pairing (`utm_campaign` requires `source_id_resolved`).
4. `updated_at` trigger exists and updates timestamp on row mutation.
5. Anon/authenticated can read only `active = true` rows.
6. Anon/authenticated cannot insert/update/delete rows.
7. Frontend can fetch enough rows to deterministically execute:
   - `EXACT -> SOURCE_ONLY -> GLOBAL_DEFAULT -> FALLBACK`.
