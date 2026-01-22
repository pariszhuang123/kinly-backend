# Expenses Contracts v2

Status: Draft (recurrence every/unit refactor)

Scope: Updates expense recurrence from legacy enum to flexible `recurrenceEvery` + `recurrenceUnit`. Recurring intent remains modeled via `expense_plans`; each cycle is an immutable `expenses` row.

## Domain Overview
- Drafts: creator-only; `amountCents` optional; drafts cannot be recurring.
- Activation: supplying amount + splits via `expenses.create` or `expenses.edit` promotes to `status=active`. If recurrence is set, a plan is created, the draft is marked `status=converted`, and the first cycle is generated immediately.
- Splits live in `expense_splits`. Creator shares (if included) are auto-marked `paid`.
- Payments are bulk: `expenses.payMyDue(p_recipient_user_id)` marks all unpaid splits the caller owes to a given payer.
- Recurrence fields are paired: both null for one-off; both set for recurring.

## Entities

### Expense
- `id` (`uuid`)
- `homeId` (`uuid`)
- `createdByUserId` (`uuid`)
- `planId` (`uuid|null`)
- `recurrenceEvery` (`int|null`) — `NULL` for one-off.
- `recurrenceUnit` (`text|null`) — one of `day|week|month|year`; `NULL` for one-off.
- `startDate` (`date`)
- `status` (`ExpenseStatus`)
- `splitType` (`ExpenseSplitType|null`)
- `amountCents` (`bigint|null`)
- `fullyPaidAt` (`timestamptz|null`)
- `description` (`text`)
- `notes` (`text|null`)
- `createdAt` / `updatedAt` (`timestamptz`)

### ExpensePlan
- `id` (`uuid`)
- `homeId` (`uuid`)
- `createdByUserId` (`uuid`)
- `splitType` (`ExpenseSplitType`)
- `amountCents` (`bigint`)
- `description` (`text`)
- `notes` (`text|null`)
- `recurrenceEvery` (`int`) — `>= 1`
- `recurrenceUnit` (`text`) — one of `day|week|month|year`
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
      "impl": "public.expenses_create_v2",
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
        "p_start_date": "date"
      },
      "returns": "Expense",
      "notes": [
        "p_split_mode NULL => draft (recurrence must be null; amount optional)",
        "p_split_mode set => activation; recurrence null creates one-off active; recurrence set creates plan + first cycle and marks draft converted"
      ]
    },
    "expenses.edit": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_edit_v2",
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
        "p_start_date": "date"
      },
      "returns": "Expense",
      "notes": [
        "Only allowed for drafts; always activates",
        "Recurrence set creates plan, marks draft converted, and generates first cycle",
        "Existing active expenses are immutable"
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
        "Stamps marked_paid_at, stamps fully_paid_at once per expense, decrements usage per fully paid expense"
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
        "Stops future cycles; existing expenses remain payable"
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
        "Creator-only; returns splits, planId, recurrenceEvery/Unit, startDate, canEdit flag, and editDisabledReason (ACTIVE_IMMUTABLE, RECURRING_CYCLE_IMMUTABLE, CONVERTED_TO_PLAN)"
      ]
    }
  }
}
```
