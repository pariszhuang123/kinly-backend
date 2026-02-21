---
Domain: Share
Capability: Expenses
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v2.4
---

# Expenses Contracts v2

Status: Draft (recurrence every/unit refactor + bill evidence photos + transition-based photo quota)

Scope: Updates expense recurrence from legacy enum to flexible `recurrenceEvery` + `recurrenceUnit`, and adds optional bill evidence photos via `evidencePhotoPath`. Recurring intent remains modeled via `expense_plans`; each cycle is an immutable `expenses` row.

## Domain Overview
- Drafts: creator-only; `amountCents` optional; drafts cannot be recurring.
- Activation: supplying amount + splits via `expenses.create` or `expenses.edit` promotes to `status=active`. If recurrence is set, a plan is created, the draft is marked `status=converted`, and the first cycle is generated immediately.
- Activation invariant: at least one debtor must be different from `createdByUserId` (creator cannot be the sole debtor).
- Splits live in `expense_splits`. Creator shares (if included) are auto-marked `paid`.
- Payments are bulk: `expenses.payMyDue(p_recipient_user_id)` marks all unpaid splits the caller owes to a given payer.
- Recurrence fields are paired: both null for one-off; both set for recurring.
- Bills can carry one optional evidence photo (`evidencePhotoPath`) to document the amount owed.
- For recurring bills, `evidencePhotoPath` is stored on the plan and copied to generated cycle expenses.

## Entities

### Expense
- `id` (`uuid`)
- `homeId` (`uuid`)
- `createdByUserId` (`uuid`)
- `planId` (`uuid|null`)
- `recurrenceEvery` (`int|null`) - `NULL` for one-off.
- `recurrenceUnit` (`text|null`) - one of `day|week|month|year`; `NULL` for one-off.
- `startDate` (`date`)
- `status` (`ExpenseStatus`)
- `splitType` (`ExpenseSplitType|null`)
- `amountCents` (`bigint|null`)
- `fullyPaidAt` (`timestamptz|null`)
- `description` (`text`)
- `notes` (`text|null`)
- `evidencePhotoPath` (`text|null`) - evidence image storage path; must match `households/%` when present.
- `createdAt` / `updatedAt` (`timestamptz`)

### ExpensePlan
- `id` (`uuid`)
- `homeId` (`uuid`)
- `createdByUserId` (`uuid`)
- `splitType` (`ExpenseSplitType`)
- `amountCents` (`bigint`)
- `description` (`text`)
- `notes` (`text|null`)
- `evidencePhotoPath` (`text|null`) - default evidence image for generated bill cycles.
- `recurrenceEvery` (`int`) - `>= 1`
- `recurrenceUnit` (`text`) - one of `day|week|month|year`
- `startDate` (`date`)
- `nextCycleDate` (`date`)
- `status` (`ExpensePlanStatus`)
- `terminatedAt` (`timestamptz|null`)
- `createdAt` / `updatedAt`

### ExpensePlanDebtor
- `planId` (`uuid`)
- `debtorUserId` (`uuid`)
- `shareAmountCents` (`bigint`)

### ExpenseSplit
- `expenseId` (`uuid`)
- `debtorUserId` (`uuid`)
- `amountCents` (`bigint`)
- `status` (`ExpenseShareStatus`)
- `markedPaidAt` (`timestamptz|null`)
- `recipientViewedAt` (`timestamptz|null`)

### ExpenseSummaryDto
- `id: uuid`
- `homeId: uuid`
- `createdByUserId: uuid`
- `status: ExpenseStatus`
- `planId: uuid|null`
- `recurrenceEvery: int|null`
- `recurrenceUnit: text|null`
- `startDate: date`
- `splitType: ExpenseSplitType|null`
- `amountCents: bigint|null`
- `fullyPaidAt: timestamptz|null`
- `description: text`
- `evidencePhotoPath: text|null`
- `createdAt: timestamptz`
- `totalShares: int`
- `paidShares: int`
- `paidAmountCents: bigint`
- `allPaid: boolean`

## Enums

### ExpenseStatus
`draft | active | cancelled | converted`

### ExpensePlanStatus
`active | terminated`

### ExpenseSplitType
`equal | custom`

### ExpenseShareStatus
`unpaid | paid`

## Validation and Paywall Rules
- `recurrenceEvery` is NULL iff `recurrenceUnit` is NULL.
- `evidencePhotoPath` is optional and must start with `households/` when provided.
- A bill/expense stores at most one evidence photo path at a time.
- `expenses.edit` path semantics: omitted/`NULL` keeps existing draft `evidencePhotoPath`; sending empty string clears it before activation.
- Drafts are quota-free while still draft: adding/replacing photo on a draft does not consume `active_expenses` or `expense_photos`.
- `expense_photos` is charged on activation/plan-creation boundary:
  - One-off path (`status=draft -> active`): if `planId is null` and `evidencePhotoPath` is non-null, apply `+1 expense_photos`.
  - Recurring path (`status=draft -> converted` + plan create): if plan `evidencePhotoPath` is non-null, apply `+1 expense_photos` (at plan creation only).
  - Direct active create follows the same rule on the quota-owning record.
  - Replacing photo (`non-null -> non-null`) never increments usage.
- User-triggered activation (`expenses.create`/`expenses.edit` with `p_split_mode` set) enforces paywall quota for:
  - `active_expenses` (+1 for the activated one-off or first recurring cycle)
  - `expense_photos` (+1 once at activation/plan-creation boundary when evidence exists)
- Recurring bill conversion stores `evidencePhotoPath` on `expense_plans`; generated cycles snapshot the plan value into each cycle `expenses` row.
- Recurring cycles do not increment `expense_photos` when using plan photo (first cycle and cron cycles are no-op for this metric).
- Decrement model (transition-based, idempotent):
  - One-off photo charge decrements once when a charged one-off exits counting state:
    - on `active -> cancelled` when `planId is null` and `evidencePhotoPath` is non-null, OR
    - on first `fullyPaidAt NULL -> non-NULL` when `planId is null` and `evidencePhotoPath` is non-null.
  - Recurring plan photo charge decrements once on first plan termination (`terminatedAt NULL -> non-NULL`) when plan `evidencePhotoPath` is non-null (including membership-change auto-termination flows).
- Canonical errors include `PAYWALL_LIMIT_ACTIVE_EXPENSES`, `PAYWALL_LIMIT_EXPENSE_PHOTOS`, and `INVALID_EVIDENCE_PHOTO_PATH`.

## Contracts JSON

```contracts-json
{
  "domain": "expenses",
  "version": "v2",
  "entities": {
    "Expense": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "planId": "uuid|null",
      "recurrenceEvery": "int|null",
      "recurrenceUnit": "text|null",
      "startDate": "date",
      "status": "ExpenseStatus",
      "splitType": "ExpenseSplitType|null",
      "amountCents": "bigint|null",
      "fullyPaidAt": "timestamptz|null",
      "description": "text",
      "notes": "text|null",
      "evidencePhotoPath": "text|null",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "ExpensePlan": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "splitType": "ExpenseSplitType",
      "amountCents": "bigint",
      "description": "text",
      "notes": "text|null",
      "evidencePhotoPath": "text|null",
      "recurrenceEvery": "int",
      "recurrenceUnit": "text",
      "startDate": "date",
      "nextCycleDate": "date",
      "status": "ExpensePlanStatus",
      "terminatedAt": "timestamptz|null",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "ExpensePlanDebtor": {
      "planId": "uuid",
      "debtorUserId": "uuid",
      "shareAmountCents": "bigint"
    },
    "ExpenseSplit": {
      "expenseId": "uuid",
      "debtorUserId": "uuid",
      "amountCents": "bigint",
      "status": "ExpenseShareStatus",
      "markedPaidAt": "timestamptz|null",
      "recipientViewedAt": "timestamptz|null"
    },
    "ExpenseSummaryDto": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "planId": "uuid|null",
      "recurrenceEvery": "int|null",
      "recurrenceUnit": "text|null",
      "startDate": "date",
      "status": "ExpenseStatus",
      "splitType": "ExpenseSplitType|null",
      "amountCents": "bigint|null",
      "fullyPaidAt": "timestamptz|null",
      "description": "text",
      "evidencePhotoPath": "text|null",
      "createdAt": "timestamptz",
      "totalShares": "int",
      "paidShares": "int",
      "paidAmountCents": "bigint",
      "allPaid": "boolean"
    }
  },
  "enums": {
    "ExpenseStatus": [
      "draft",
      "active",
      "cancelled",
      "converted"
    ],
    "ExpensePlanStatus": [
      "active",
      "terminated"
    ],
    "ExpenseSplitType": [
      "equal",
      "custom"
    ],
    "ExpenseShareStatus": [
      "unpaid",
      "paid"
    ]
  },
  "rls": [
    {
      "table": "public.expenses",
      "rule": "RLS disabled; anon/auth/service roles have no grants. All read/write access flows through SECURITY DEFINER RPCs."
    },
    {
      "table": "public.expense_plans",
      "rule": "RLS disabled; anon/auth/service roles have no grants. Only RPCs can mutate."
    },
    {
      "table": "public.expense_plan_debtors",
      "rule": "RLS disabled; anon/auth/service roles have no grants. Only RPCs can mutate."
    },
    {
      "table": "public.expense_splits",
      "rule": "RLS disabled; anon/auth have no grants. Splits are only visible/mutated inside SECURITY DEFINER RPCs."
    }
  ],
  "functions": {
    "expenses.create": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_create_v3",
      "args": {
        "p_home_id": "uuid",
        "p_description": "text",
        "p_amount_cents": "bigint|null",
        "p_notes": "text|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_start_date": "date",
        "p_evidence_photo_path": "text|null"
      },
      "returns": "Expense",
      "notes": [
        "p_split_mode NULL => draft (recurrence must be null; amount optional)",
        "p_split_mode set => activation; recurrence null creates one-off active; recurrence set creates plan + first cycle and marks draft converted",
        "When provided, p_evidence_photo_path must match households/%; recurring activation copies it to both plan and first cycle",
        "Draft photo capture is quota-free until activation; charge occurs once at activation/plan-creation boundary on transition rules",
        "Activation path enforces paywall for active_expenses and expense_photos (no extra +1 for replacements; recurring cycle generation does not increment expense_photos)"
      ]
    },
    "expenses.edit": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_edit_v3",
      "args": {
        "p_expense_id": "uuid",
        "p_amount_cents": "bigint",
        "p_description": "text",
        "p_notes": "text|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_start_date": "date",
        "p_evidence_photo_path": "text|null"
      },
      "returns": "Expense",
      "notes": [
        "Drafts: allowed and always activates",
        "Drafts may add or replace evidencePhotoPath before activation; clearing is supported by sending empty string",
        "Draft photo updates do not consume expense_photos until activation/plan-creation boundary",
        "Active one-off expenses: creator may edit description/notes only",
        "For active one-off expenses, amount/splits/recurrence/startDate are immutable",
        "For active one-off expenses, evidencePhotoPath is immutable",
        "Recurrence set creates plan, marks draft converted, and generates first cycle",
        "Recurring cycles and converted rows remain immutable"
      ]
    },
    "expenses.payMyDue": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_pay_my_due",
      "args": {
        "p_recipient_user_id": "uuid"
      },
      "returns": "jsonb",
      "notes": [
        "Bulk marks caller's unpaid splits owed to the recipient as paid",
        "Stamps marked_paid_at, stamps fully_paid_at once per expense, decrements usage per fully paid expense for metrics incremented at expense level (including charged one-off expense_photos)"
      ]
    },
    "expensePlans.terminate": {
      "type": "rpc",
      "caller": "member (plan creator only)",
      "impl": "public.expense_plans_terminate",
      "args": {
        "p_plan_id": "uuid"
      },
      "returns": "ExpensePlan",
      "notes": [
        "Stops future cycles; existing expenses remain payable",
        "If plan carries evidencePhotoPath, decrements expense_photos once on first termination transition"
      ]
    },
    "expenses.cancel": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_cancel",
      "args": {
        "p_expense_id": "uuid"
      },
      "returns": "Expense"
    },
    "expenses.getCurrentOwed": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_get_current_owed",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "expenses.getCreatedByMe": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_get_created_by_me",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "expenses.getForEdit": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_get_for_edit",
      "args": {
        "p_expense_id": "uuid"
      },
      "returns": "jsonb",
      "notes": [
        "Creator-only; returns splits, planId, recurrenceEvery/Unit, startDate, evidencePhotoPath, canEdit flag, and editDisabledReason (ACTIVE_IMMUTABLE, RECURRING_CYCLE_IMMUTABLE, CONVERTED_TO_PLAN)"
      ]
    }
  }
}
```
