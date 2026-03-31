---
Domain: Share
Capability: Expenses
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v2.6
---

# Expenses Contracts v2.6

Status: Draft (unit-based allocation extension + home-scoped split integrity + recurring-unit termination metadata + bill evidence photos + transition-based photo quota)

Scope: Extends expenses to support unit-based allocation aligned with Home Units
v1 while preserving debtor-based compatibility. Also keeps the recurrence
every/unit refactor and optional bill evidence photos via `evidencePhotoPath`.
Recurring intent remains modeled via `expense_plans`; each cycle is an
immutable `expenses` row.

## Domain Overview
- Drafts: creator-only; `amountCents` optional; drafts cannot be recurring.
- Activation: supplying amount + splits via `expenses.create` or `expenses.edit` promotes to `status=active`. If recurrence is set, a plan is created, the draft is marked `status=converted`, and the first cycle is generated immediately.
- Activation invariant: at least one debtor must be different from `createdByUserId` (creator cannot be the sole debtor).
- Expenses support two allocation target modes:
  - `debtor_based` - direct person-by-person liability via `expense_splits`
  - `unit_based` - liability via `expense_unit_splits`
- Debtor-based splits live in `expense_splits`. Creator shares (if included) are
  auto-marked `paid`.
- Unit-based splits live in `expense_unit_splits`. A personal unit represents
  one individually liable member; a shared unit represents a grouped debtor.
- Allocation mode is explicit at create/edit time; shopping-list item scope
  does not automatically force `unit_based` or `debtor_based`.
- For recurring plans:
  - debtor-based allocation source lives in `expense_plan_debtors`
  - unit-based allocation source lives in `expense_plan_units`
- Payments are bulk: `expenses.payMyDue(p_recipient_user_id)` marks all unpaid splits the caller owes to a given payer.
- Unit-based Today visibility is unit-scoped and aligned with Home Units. Fully
  settled unit liabilities disappear from Today.
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
- `allocationTargetType` (`ExpenseAllocationTargetType|null`)
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
- `allocationTargetType` (`ExpenseAllocationTargetType`)
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
- `terminationReason` (`text|null`) - one of `UNIT_TARGET_INVALID | UNIT_TARGET_ARCHIVED | UNIT_TARGET_HOME_MISMATCH | MANUAL | OTHER`
- `createdAt` / `updatedAt`

### ExpensePlanDebtor
- `planId` (`uuid`)
- `debtorUserId` (`uuid`)
- `shareAmountCents` (`bigint`)

### ExpensePlanUnit
- `planId` (`uuid`)
- `homeId` (`uuid`)
- `unitId` (`uuid`)
- `shareAmountCents` (`bigint`)

### ExpenseSplit
- `expenseId` (`uuid`)
- `debtorUserId` (`uuid`)
- `amountCents` (`bigint`)
- `status` (`ExpenseShareStatus`)
- `markedPaidAt` (`timestamptz|null`)
- `recipientViewedAt` (`timestamptz|null`)

### ExpenseUnitSplit
- `expenseId` (`uuid`)
- `homeId` (`uuid`)
- `unitId` (`uuid`)
- `amountCents` (`bigint`)
- `paidCents` (`bigint`)
- `fullyPaidAt` (`timestamptz|null`)

### ExpenseSummaryDto
- `id: uuid`
- `homeId: uuid`
- `createdByUserId: uuid`
- `status: ExpenseStatus`
- `allocationTargetType: ExpenseAllocationTargetType|null`
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

### ExpenseAllocationTargetType
`debtor_based | unit_based`

### ExpenseSplitType
`equal | custom`

### ExpenseShareStatus
`unpaid | paid`

## Validation and Paywall Rules
- `allocationTargetType` determines which split table(s) are populated:
  - `debtor_based` -> `expense_splits` / `expense_plan_debtors`
  - `unit_based` -> `expense_unit_splits` / `expense_plan_units`
- `unit_based` and `debtor_based` MUST NOT be mixed within the same expense or
  recurring plan.
- callers MUST choose allocation mode explicitly; backend MUST NOT infer it
  from shopping-list scope, current shared-unit membership, or UI defaults
- For unit-based activation:
  - all `unitId` values MUST belong to the same home as the expense/plan
  - `SUM(shareAmountCents)` or computed unit split totals MUST equal
    `amountCents`
  - archived units MUST be rejected as targets
  - duplicate unit targets in the same expense or plan MUST be rejected
  - creator-personal-unit-only targeting is invalid; the split must include a
    debtor beyond the creator's personal unit
  - internal cost sharing inside a shared unit remains out of scope
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
- `expense_photos` is monotonic (add-only): once charged at activation/plan-creation boundary, it is not decremented by cancel, fully-paid transitions, or plan termination.
- recurring unit-based plans auto-terminate if stored unit targets become
  invalid, archived, or mismatched to the plan home
- shared-unit collapse in Home Units can therefore terminate future recurring
  cycles for plans targeting that archived shared unit with
  `UNIT_TARGET_ARCHIVED`
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
      "allocationTargetType": "ExpenseAllocationTargetType|null",
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
      "allocationTargetType": "ExpenseAllocationTargetType",
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
      "terminationReason": "text|null",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "ExpensePlanDebtor": {
      "planId": "uuid",
      "debtorUserId": "uuid",
      "shareAmountCents": "bigint"
    },
    "ExpensePlanUnit": {
      "planId": "uuid",
      "homeId": "uuid",
      "unitId": "uuid",
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
    "ExpenseUnitSplit": {
      "expenseId": "uuid",
      "homeId": "uuid",
      "unitId": "uuid",
      "amountCents": "bigint",
      "paidCents": "bigint",
      "fullyPaidAt": "timestamptz|null"
    },
    "ExpenseSummaryDto": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "allocationTargetType": "ExpenseAllocationTargetType|null",
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
    "ExpenseAllocationTargetType": [
      "debtor_based",
      "unit_based"
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
      "table": "public.expense_plan_units",
      "rule": "RLS disabled; anon/auth/service roles have no grants. Only RPCs can mutate."
    },
    {
      "table": "public.expense_splits",
      "rule": "RLS disabled; anon/auth have no grants. Splits are only visible/mutated inside SECURITY DEFINER RPCs."
    },
    {
      "table": "public.expense_unit_splits",
      "rule": "RLS disabled; anon/auth have no grants. Unit splits are only visible/mutated inside SECURITY DEFINER RPCs."
    }
  ],
  "functions": {
    "expenses.create": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_create_v5",
      "args": {
        "p_home_id": "uuid",
        "p_description": "text",
        "p_amount_cents": "bigint|null",
        "p_notes": "text|null",
        "p_allocation_target_type": "ExpenseAllocationTargetType|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_unit_ids": "uuid[]|null",
        "p_unit_splits": "jsonb|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_start_date": "date",
        "p_evidence_photo_path": "text|null"
      },
      "returns": "Expense",
      "notes": [
        "p_split_mode NULL => draft (recurrence must be null; amount optional)",
        "p_split_mode set => activation; recurrence null creates one-off active; recurrence set creates plan + first cycle and marks draft converted",
        "p_allocation_target_type determines whether activation writes debtor rows or unit rows",
        "shopping-list scope may inform UX defaults but does not determine p_allocation_target_type",
        "unit_based activation MUST use p_unit_ids/p_unit_splits and MUST NOT also send debtor-based member split payloads",
        "debtor_based activation preserves existing direct debtor semantics",
        "When provided, p_evidence_photo_path must match households/%; recurring activation copies it to both plan and first cycle",
        "Draft photo capture is quota-free until activation; charge occurs once at activation/plan-creation boundary on transition rules",
        "Activation path enforces paywall for active_expenses and expense_photos (no extra +1 for replacements; recurring cycle generation does not increment expense_photos)"
      ]
    },
    "expenses.edit": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_edit_v5",
      "args": {
        "p_expense_id": "uuid",
        "p_amount_cents": "bigint",
        "p_description": "text",
        "p_notes": "text|null",
        "p_allocation_target_type": "ExpenseAllocationTargetType|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_unit_ids": "uuid[]|null",
        "p_unit_splits": "jsonb|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_start_date": "date",
        "p_evidence_photo_path": "text|null"
      },
      "returns": "Expense",
      "notes": [
        "Drafts: allowed and always activates",
        "Drafts may activate as debtor_based or unit_based; this choice determines the persisted split records and recurring plan allocation source",
        "shopping-origin expenses may still choose either mode explicitly",
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
        "Stamps marked_paid_at and fully_paid_at once per expense; decrements active_expenses per newly fully paid expense"
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
        "Does not decrement expense_photos; photo usage is add-only"
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
      "impl": "public.expenses_get_current_owed_v3",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb",
      "notes": [
        "Returns a Today-oriented list of open liabilities",
        "Rows include enough metadata to distinguish debtor-based personal liabilities from unit-based shared liabilities",
        "For unit_based rows, payload includes liabilityKind, liabilityScope, displayMode, unitId, unitName, amountCents, paidCents, and remainingCents",
        "Rows are grouped by payer and include payerDisplay, payerAvatarUrl, totalOwedCents, and containsSharedUnitBalance"
      ]
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
      "impl": "public.expenses_get_for_edit_v3",
      "args": {
        "p_expense_id": "uuid"
      },
      "returns": "jsonb",
      "notes": [
        "Creator-only; returns allocationTargetType, split payloads, unitSplits, planId, planStatus, recurrenceEvery/Unit, startDate, evidencePhotoPath, canEdit flag, and editDisabledReason (ACTIVE_IMMUTABLE, RECURRING_CYCLE_IMMUTABLE, CONVERTED_TO_PLAN)"
      ]
    },
    "expenses.payUnitDue": {
      "type": "rpc",
      "caller": "current member of debtor unit",
      "impl": "public.expenses_pay_unit_due_v2",
      "args": {
        "p_expense_id": "uuid",
        "p_unit_id": "uuid",
        "p_amount_cents": "bigint"
      },
      "returns": "jsonb",
      "notes": [
        "Applies a partial or full payment to one unit-based split",
        "Caller must be a current member of the debtor unit",
        "Rejects payments greater than the remaining unit balance",
        "Emits a payment event and finalizes the parent expense when all unit balances are fully paid"
      ]
    }
  }
}
```

## Boundary with shopping list

- Shopping-list scope and expense liability are related but independent.
- A unit-scoped shopping item does not auto-select `allocationTargetType`.
- A shopping-origin expense may still be created as either:
  - `unit_based` targeting an allowed unit
  - `debtor_based` targeting individual people
- The caller makes that choice explicitly at expense create/edit time.
