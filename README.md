# Kinly Backend

> **Kinly Backend** is the authoritative backend for the Kinly ecosystem.  
> It defines **what exists**, **what is allowed**, and **what is guaranteed** — independently of any client.

This repository is the **source of truth** for Kinly’s data model, business rules, and API contracts.

---

## What this repo is

This repo owns:

- 🧠 **Domain logic** (Postgres + Supabase)
- 📜 **Contracts** that describe backend capabilities
- 🔐 **Security rules** (RLS, policies, invariants)
- 🧪 **Backend guardrails** enforced in CI
- 🔁 **Contract lifecycle** from proposal → approval → publication

If something affects **data integrity, permissions, or shared behavior**, it belongs here.

---

## What this repo is *not*

This repo does **not**:

- Contain frontend code
- Define UI flows or UX decisions
- Expose raw tables directly to clients
- Act as a shared “utilities” repo

Clients **consume** this backend — they do not shape it.

---

## Architectural principles

Kinly Backend follows a few non-negotiable rules:

### 1. Backend is the authority

- Frontends **do not infer** behavior
- Frontends **do not guess** schema
- Frontends **do not bypass rules**

Everything meaningful flows from backend → contracts → clients.

---

### 2. Contracts are explicit and versioned

Backend behavior is described in **human-readable + machine-readable contracts**.

Contracts live in:

docs/contracts/


Each contract:

- Is versioned (`_v1`, `_v2`, …)
- Describes intent, inputs, outputs, and invariants
- Is extracted into a machine registry for CI enforcement

Contracts are **not documentation** — they are **promises**.

---

### 3. RPC-first, not table-first

Clients interact with the backend primarily through:

- `rpc_*` functions
- Narrow, purpose-built queries
- Explicit permission checks

Raw table access is avoided except where explicitly safe and intentional.

---

### 4. Security is enforced at the database level

- Row Level Security (RLS) is mandatory
- Policies are explicit and testable
- Identity (`auth.uid()`) is required for meaningful actions

If a rule can be enforced in Postgres, it **must** be enforced there.

---

### 5. CI is a guardrail, not a suggestion

CI checks ensure:

- Migrations are valid and ordered
- Contracts are internally consistent
- Contract promises match the observed database
- No silent breaking changes are introduced

If CI fails, the backend is considered **unsafe to consume**.

---

## Repository structure

kinly-backend/
├── supabase/
│ ├── migrations/ # Authoritative schema & logic
│ ├── functions/ # Edge functions (when needed)
│ └── seed.sql
│
├── docs/
│ └── contracts/
│
├── tool/
│ ├── backend_guardrails.sh
│ └── contract_extract.dart
│
└── README.md



## Contracts lifecycle (high level)

1. **Propose**  
   A new capability is described in a versioned contract file.

2. **Implement**  
   Migrations, RPCs, and policies are written to satisfy the contract.

3. **Verify**  
   CI asserts that:
   - The contract is valid
   - The database actually supports it

4. **Publish**  
   The approved contract is extracted into `registry.json`.

5. **Consume**  
   Client repos (e.g. `kinly-contracts`, frontend apps) depend only on published contracts — never on assumptions.
---

## Relationship to other repos

### kinly-backend (this repo)

- **Authority**
- Owns schema, logic, security
- Generates approved contracts

### kinly-contracts

- **Distribution layer**
- Receives approved contracts
- Is consumed by frontend and tooling

### Frontend repos

- **Consumers**
- Must align strictly to published contracts
- Cannot invent backend behavior

This separation is intentional and enforced.

---

## Local development

Backend development is Linux-based (WSL on Windows is supported).

Typical workflow:

```bash
supabase start
supabase db reset
./tool/backend_guardrails.sh

## CI parity

CI mirrors the local development setup as closely as possible.

Any change that passes locally but fails in CI is treated as unsafe.
The backend is considered **not ready for consumption** unless CI is green.

---

## Why this exists

Kinly is a **shared-living system**.

That means:

- Multiple people
- Shared state
- Real consequences
- Long-lived data

This backend exists to ensure:

- Fairness is enforced, not implied
- Rules are visible, not hidden in clients
- Evolution happens safely and intentionally

---

## Design philosophy

> **If the backend is unclear, the product is unsafe.**

This repo favors:

- Explicitness over convenience
- Contracts over tribal knowledge
- Fewer capabilities, done properly
- Slow change with high confidence