# Expenses Contracts v1

Status: Draft (updated for recurring plans + bulk pay)

Scope: Defines the household shared expenses lifecycle (one-off and recurring cycles) for the Home-only MVP so UI, BLoC, repositories, and Supabase schema share one contract. Recurring intent is captured as expense plans; every plan cycle is an immutable `expenses` row.

## Domain Overview
- Any active home member can author expenses. Drafts are creator-only; active rows are immutable snapshots.
- Drafts: quick capture with optional `amountCents` and `startDate`. Drafts cannot be recurring (`recurrenceInterval` must stay `none`).
- Activation: supplying amount + splits via `expenses.create` or `expenses.edit` promotes to `status=active`. If `recurrenceInterval != none`, the draft is marked `status=converted`, a plan is created, and the first cycle expense is generated immediately.
- Splits live in `expense_splits`. Each row is “debtor X owes Y cents to the creator for this expense.” The creator’s own share (if included) is auto-marked `paid`.
- Payments are bulk: `expenses.payMyDue(p_recipient_user_id)` marks all unpaid splits the caller owes to a given payer. `expenses.fully_paid_at` stamps once when an expense is fully paid (idempotent usage decrement).
- Derived surfaces: Today shows “what I owe” grouped by payer; Explore/Share list creator-authored expenses with progress (paidShares includes the creator’s auto-paid split).

## Entities

### Expense
- `id` (`uuid`) — primary key.
- `homeId` (`uuid`) — FK `homes.id`.
- `createdByUserId` (`uuid`) — FK `profiles.id`; payer/author.
- `planId` (`uuid|null`) — FK `expense_plans.id`; `NULL` for one-off; set for recurring cycles.
- `recurrenceInterval` (`recurrence_interval`) — `none | weekly | every_2_weeks | monthly | every_2_months | annual`; `none` for one-off.
- `startDate` (`date`) — cycle start/effective date (date only, never tz-shifted).
- `status` (`ExpenseStatus`) — `draft | active | cancelled | converted`.
- `splitType` (`ExpenseSplitType|null`) — `equal | custom | null` (draft).
- `amountCents` (`bigint|null`) — `NULL` allowed only for drafts; otherwise > 0.
- `fullyPaidAt` (`timestamptz|null`) — stamped once when the last split becomes paid (idempotent usage guard).
- `description` (`text`) — required, trimmed length 1–280.
- `notes` (`text|null`) — optional, <= 2000 chars.
- `createdAt` / `updatedAt` (`timestamptz`).

### ExpensePlan
- `id` (`uuid`) — primary key.
- `homeId` (`uuid`) — FK `homes.id`.
- `createdByUserId` (`uuid`) — payer/author; also payer for generated cycles.
- `splitType` (`ExpenseSplitType`) — `equal | custom`.
- `amountCents` (`bigint`) — immutable once active.
- `description` (`text`)
- `notes` (`text|null`)
- `recurrenceInterval` (`recurrence_interval`) — non-`none`.
- `startDate` (`date`) — first cycle anchor.
- `nextCycleDate` (`date`) — cron cursor.
- `status` (`ExpensePlanStatus`) — `active | terminated`.
- `terminatedAt` (`timestamptz|null`)
- `createdAt` / `updatedAt`

### ExpensePlanDebtor
Template rows used to generate splits for each cycle.
- `planId` (`uuid`) — FK `expense_plans.id`.
- `debtorUserId` (`uuid`) — FK `profiles.id`.
- `shareAmountCents` (`bigint`) — immutable once active; sum must equal `amountCents` for custom splits.

### ExpenseSplit
- `expenseId` (`uuid`) — FK `expenses.id`.
- `debtorUserId` (`uuid`) — FK `profiles.id`; must be a current member of the same home at split time.
- `amountCents` (`bigint`) — per-person share in cents (> 0).
- `status` (`ExpenseShareStatus`) — `unpaid | paid`.
- `markedPaidAt` (`timestamptz|null`) — when the debtor’s split became paid (bulk path stamps now).
- `recipientViewedAt` (`timestamptz|null`) — when the creator viewed a paid split; `NULL` means unseen.
- Composite PK: `(expenseId, debtorUserId)`.

### ExpenseSummaryDto
Projection for list views (Explore + Share, repository caches).
- `id: uuid`
- `homeId: uuid`
- `createdByUserId: uuid`
- `status: ExpenseStatus`
- `planId: uuid|null`
- `recurrenceInterval: recurrence_interval`
- `startDate: date`
- `splitType: ExpenseSplitType|null`
- `amountCents: bigint|null`
- `fullyPaidAt: timestamptz|null`
- `description: text`
- `createdAt: timestamptz`
- `totalShares: int`
- `paidShares: int` (counts the creator’s auto-paid split plus any paid member splits)
- `paidAmountCents: bigint` (sum of all paid splits, including the creator’s auto-paid amount)
- `allPaid: boolean` — `totalShares > 0 AND paidShares = totalShares`.

## Enums

### RecurrenceInterval
`none | weekly | every_2_weeks | monthly | every_2_months | annual`

### ExpenseStatus
`draft | active | cancelled | converted`
- `draft` — quick capture; creator-only; amount optional.
- `active` — immutable payable obligation (one-off or cycle).
- `cancelled` — creator invalidated the expense; splits remain for audit but are hidden from Today.
- `converted` — original draft shell was converted into an expense plan; financial impact lives in generated cycle expenses.

### ExpensePlanStatus
`active | terminated`
- `active` — plan continues generating cycles via cron.
- `terminated` — no new cycles; existing expenses stay payable.

### ExpenseSplitType
`equal | custom`
- `equal` — integer division across selected members (remainder to the last entry).
- `custom` — explicit cents per debtor; sum must equal `amountCents`.

### ExpenseShareStatus
`unpaid | paid`
- `unpaid` — debtor still owes the share.
- `paid` — debtor declared payment (declarative only; Kinly does not reconcile bank data).

## Contracts JSON

```contracts-json
{
  "domain": "expenses",
  "version": "v1",
  "entities": {
    "Expense": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "planId": "uuid|null",
      "recurrenceInterval": "RecurrenceInterval",
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
      "recurrenceInterval": "RecurrenceInterval",
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
      "recurrenceInterval": "RecurrenceInterval",
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
    "RecurrenceInterval": [
      "none",
      "weekly",
      "every_2_weeks",
      "monthly",
      "every_2_months",
      "annual"
    ],
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
  "functions": {
    "expenses.create": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_create",
      "args": {
        "p_home_id": "uuid",
        "p_description": "text",
        "p_amount_cents": "bigint|null",
        "p_notes": "text|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_recurrence": "RecurrenceInterval",
        "p_start_date": "date"
      },
      "returns": "Expense",
      "notes": [
        "p_split_mode NULL => draft (recurrence must be none; amount optional)",
        "p_split_mode set => activation; recurrence none creates one-off active; recurrence != none creates plan + first cycle and marks draft converted"
      ]
    },
    "expenses.edit": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.expenses_edit",
      "args": {
        "p_expense_id": "uuid",
        "p_amount_cents": "bigint",
        "p_description": "text",
        "p_notes": "text|null",
        "p_split_mode": "ExpenseSplitType|null",
        "p_member_ids": "uuid[]|null",
        "p_splits": "jsonb|null",
        "p_recurrence": "RecurrenceInterval",
        "p_start_date": "date"
      },
      "returns": "Expense",
      "notes": [
        "Only allowed for drafts; always activates",
        "Recurrence != none creates plan, marks draft converted, and generates first cycle",
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
        "Bulk marks caller’s unpaid splits owed to the recipient as paid",
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
        "Creator-only; returns splits, planId, recurrenceInterval, startDate, canEdit flag, and editDisabledReason (ACTIVE_IMMUTABLE, RECURRING_CYCLE_IMMUTABLE, CONVERTED_TO_PLAN)"
      ]
    }
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
  ]
}
```

## Behavioral Notes
- Payer is always `created_by_user_id`; `main_payer_user_id` is removed.
- Drafts are quota-free. Paywall increments/decrements `active_expenses` only when an active expense (one-off or generated cycle) is created or when an expense becomes fully paid (counter decremented once using `fully_paid_at`).
- Activation requires ≥2 distinct debtors (at least one debtor other than the creator), positive split sums that match `amountCents`, and startDate within [joinDate, joinDate+∞] but not earlier than 90 days back.
- Active expenses are immutable; editing drafts is the only path to activation.
- Recurring cycles are generated by cron daily at 03:00 UTC using `next_cycle_date`; cron ignores paywall checks but still stamps counters for new active expenses.

## Who paid me (Today + drilldown) v1.1 — Draft
- Goal: when a debtor marks their split paid, the creator can see “Who paid me” in Today (avatars + totals), open a debtor list, drill into that debtor’s paid items, and mark those items as viewed.
- Scope: active expenses only; payer is always `expenses.created_by_user_id`; debtors mark their own split as paid; no partial payments or bank verification.
- Data model: `expense_splits.recipientViewedAt` (`timestamptz|null`) tracks whether the creator has seen a paid split; transitions to `NULL` when a split becomes paid; only the creator sets it via a dedicated RPC. Existing paid splits stay unseen (no backfill) so badges surface during testing.
- Summary/list RPC (JSON):
  - `expenses.getCurrentPaidToMeDebtors(p_home_id)` → `[ { debtorUserId, debtorUsername, debtorAvatarUrl, isOwner, totalPaidCents, unseenCount, latestPaidAt } ]` ordered by most recent payment. `debtorAvatarUrl` is nullable (placeholder in UI) and `isOwner` is derived by comparing `homes.owner_user_id` to `debtorUserId`. Creator auto-paid splits are excluded (`debtor_user_id != created_by_user_id`). UI slices to top 3 + overflow for Today.
- Drilldown RPC (JSON):
  - `expenses.getCurrentPaidToMeByDebtorDetails(p_home_id, p_debtor_user_id)` → `[ { expenseId, description, notes, amountCents, markedPaidAt, debtorUsername, debtorAvatarUrl, isOwner } ]` ordered by newest payment. Creator auto-paid splits are excluded.
- View-state RPC:
  - `expenses.markPaidReceivedViewedForDebtor(p_home_id, p_debtor_user_id)` → integer count of paid splits that were marked viewed (sets `recipientViewedAt=now()` for unseen items). Called when opening debtor detail.
- UX contract: Today tile is hidden when `totalPaidCents == 0`; tile shows up to three debtor avatars with overflow `+N` and aggregates `totalPaidCents`. Debtor detail marks only that debtor’s unseen items as viewed.
