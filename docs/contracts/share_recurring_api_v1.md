---
Domain: Share
Capability: Share Recurring Api
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly Share — One-Off & Recurring Expenses (API) v1.1

Status: Updated (recurring folded into expenses_create/edit; bulk pay)
Applies to: expenses, expense_splits, expense_plans, expense_plan_debtors, paywall, cron

## 1. Purpose
Introduce recurring shared expenses while keeping one-off behavior stable, audit-friendly, and paywall-aware. Recurring intent is expressed as plans; each cycle is a normal immutable `expenses` row.

## 2. Core Principles
- Plans define intent; expenses record reality.
- Draft is provisional (creator-only, quota-free); activation is a one-way door.
- Assignment is the commitment trigger: activation requires >=1 debtor, and creator must not be sole debtor.
- Each cycle is independent; there is no global “settled plan.”
- System generation is never blocked: cron always generates cycles; paywall blocks users, not cron.
- Termination stops future cycles only; historical expenses remain payable.
- Harmony-first payments: bulk “pay what I owe to payer X,” no cherry-picking per-cycle UI.
- Active one-off expenses allow creator-only edits for `description`/`notes`; amount/splits/startDate/recurrence are immutable. Recurring cycle rows and converted rows are immutable.

## 3. Definitions
- **Draft**: Creator-only placeholder. May include amount + startDate, but cannot be recurring. No paywall impact.
- **Expense Plan**: Recurring intent owned by the payer (`created_by_user_id`). Immutable amount/split/debtors once active.
- **Cycle Expense**: An `expenses` row generated from a plan for a specific period. `plan_id` set, `recurrence_every`/`recurrence_unit` set, `status=active`.
- **Debtor**: Household member who owes money for an expense via `expense_splits`.

## 4. Enums & Reuse
- `expense_split_type`: `equal | custom`
- `expense_status`: `draft | active | cancelled | converted` (converted = draft shell promoted into plan)
- `expense_plan_status`: `active | terminated`
- `expense_share_status`: `unpaid | paid`

## 5. Schema Contract
### 5.1 expense_plans
First-class recurring intent.
- `id uuid PK default gen_random_uuid()`
- `home_id uuid` FK homes (restrict delete)
- `created_by_user_id uuid` FK profiles (payer)
- `split_type expense_split_type`
- `amount_cents bigint`
- `description text`, `notes text`
- `recurrence_every integer` (`>=1`)
- `recurrence_unit text` (`day | week | month | year`)
- `start_date date`
- `next_cycle_date date`
- `status expense_plan_status default 'active'`
- `terminated_at timestamptz?`
- `created_at timestamptz default now()`, `updated_at timestamptz default now()`
Invariants: >=1 debtor, and creator must not be sole debtor; amount/split/debtors immutable once active.

### 5.2 expense_plan_debtors
Template for cycle generation.
- `plan_id uuid` FK expense_plans
- `debtor_user_id uuid` FK profiles
- `share_amount_cents bigint`
Invariants: >=1 debtor, and creator must not be sole debtor; for `custom`, sum = plan amount.

### 5.3 expenses (extended)
- `plan_id uuid?` FK expense_plans; NULL for one-off.
- `recurrence_every integer?` (`NULL` for one-off)
- `recurrence_unit text?` (`NULL` for one-off; `day | week | month | year` for recurring)
- `start_date date not null`
- `fully_paid_at timestamptz?`
- `status expense_status` (includes `converted`)
Classification:
- One-off: `recurrence_every IS NULL AND recurrence_unit IS NULL AND plan_id IS NULL`.
- Cycle expense: `recurrence_every IS NOT NULL AND recurrence_unit IS NOT NULL AND plan_id IS NOT NULL AND status='active'`.
Invariants:
- If `status='active'`: `amount_cents > 0` and `split_type` present.
- `amount_cents NULL OR amount_cents > 0` (drafts may store amount or leave null).
- Recurrence alignment: `(recurrence_every IS NULL) = (recurrence_unit IS NULL)`.
- Plan alignment: recurrence NULL pair implies `plan_id IS NULL`; recurrence set implies `plan_id` required.

### 5.4 expense_splits
Generated per expense (one-off or cycle).
- `recipient_viewed_at` retained for “Who paid me” badges.

## 6. Lifecycle
### 6.1 Draft Creation (`expenses.create` with `p_split_mode=NULL`)
- Recurrence must be unset (`recurrenceEvery=NULL`, `recurrenceUnit=NULL`).
- Amount optional but, if set, must be >0.
- No quota consumption; no splits inserted.

### 6.2 One-off Activation
- Call `expenses.create` or `expenses.edit` with split params and recurrence null (`recurrenceEvery=NULL`, `recurrenceUnit=NULL`).
- Validates: >=1 debtor, creator not sole debtor, split sums, start_date within membership window (not older than 90 days).
- Writes `status=active`, inserts splits (creator share auto-paid), increments `active_expenses` usage.
- Active one-off expenses allow creator-only edits for `description`/`notes`; amount/splits/startDate/recurrence remain immutable.

### 6.3 Recurring Activation
- Invoke `expenses.create`/`expenses.edit` with split params and recurrence set (`recurrenceEvery>=1` plus valid `recurrenceUnit`).
- Creates `expense_plans` + `expense_plan_debtors`.
- Marks the original draft `status=converted` with `plan_id` set (no quota hit).
- Generates the first cycle expense immediately (via `_expense_plan_generate_cycle`), which increments `active_expenses`.
- Future cycles generated daily at 03:00 UTC via `expense_plans_generate_due_cycles` (cron); cron bypasses quota checks by design.

### 6.4 Plan Termination
- `expense_plans_terminate(plan_id)` (creator-only) sets `status=terminated`, `terminated_at=now()`, stops future cycles. Existing cycles remain payable.
- `homes_leave` and `members_kick` call `_expense_plans_terminate_for_member_change` to stop plans owned by or involving the departing member.

## 7. Payments
- RPC: `expenses_pay_my_due(p_recipient_user_id uuid)`
  - Caller: debtor (`auth.uid()`), recipient = payer/creator.
  - Marks all of caller’s unpaid splits owed to that recipient as `paid`, stamps `marked_paid_at`.
  - When an expense has no remaining unpaid splits, stamps `fully_paid_at` once and decrements `active_expenses` for that home (idempotent).
  - Locks order: homes (sorted) -> expenses (sorted) -> splits update.
- Single-split marking RPC (`expenses_mark_share_paid`) is removed.

## 8. Paywall & Usage
- Drafts do not count toward `active_expenses`.
- User-triggered activation (one-off or first cycle) enforces `_home_assert_quota({'active_expenses':1})`.
- Cron-generated cycles do not call quota checks but still increment usage and must decrement on full payment.
- `_home_usage_apply_delta` is the canonical counter mutator; `fully_paid_at` prevents double-decrementing.

## 9. Validation Guards
- Start date required; must be within membership stint and not more than 90 days backdated.
- Recurrence fields are paired; when set: `recurrenceEvery>=1` and `recurrenceUnit in (day, week, month, year)`.
- Splits require >=1 unique debtor and positive amounts; creator must not be the sole debtor.
- Active one-off expenses support creator-only description/notes edits; recurring cycles and converted rows are immutable.

## 10. Cron
- Job name: `expense_plans_generate_daily`
- Schedule: `0 3 * * *`
- Command: `SELECT public.expense_plans_generate_due_cycles();`
- Upsert-like behavior; re-running migration reschedules idempotently.
