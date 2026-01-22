SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_invites (
  label text PRIMARY KEY,
  code  text
);

CREATE TEMP TABLE tmp_expenses (
  label      text PRIMARY KEY,
  expense_id uuid
);

CREATE TEMP TABLE tmp_counters (
  label            text PRIMARY KEY,
  active_expenses  integer
);

CREATE TEMP TABLE tmp_due (
  label       text PRIMARY KEY,
  splits_due  integer,
  expenses_due integer
);

CREATE OR REPLACE FUNCTION pg_temp.expect_api_error(
  p_sql         text,
  p_error_code  text,
  p_description text
)
RETURNS text
LANGUAGE sql
AS $$
  SELECT throws_like(
    p_sql,
    '%' || p_error_code || '%',
    p_description
  );
$$;

-- Starter avatars required by handle_new_user trigger
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000501', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Additional avatars to allow unique assignment when multiple members join
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-9000-000000000901', 'avatars/expense-alt-a.png', 'animal', 'Expense Avatar A'),
  ('00000000-0000-4000-9000-000000000902', 'avatars/expense-alt-b.png', 'animal', 'Expense Avatar B')
ON CONFLICT (id) DO NOTHING;

-- Seed logical users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator',     '10000000-0000-4000-9000-000000000001', 'creator-expenses@example.com'),
  ('member_one',  '10000000-0000-4000-9000-000000000002', 'member1-expenses@example.com'),
  ('member_two',  '10000000-0000-4000-9000-000000000003', 'member2-expenses@example.com'),
  ('outsider',    '10000000-0000-4000-9000-000000000004', 'outsider-expenses@example.com');

-- Seed auth users (profiles auto-created via trigger)
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  email,
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
FROM tmp_users
ON CONFLICT (id) DO NOTHING;

-- Creator establishes home + invite
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

INSERT INTO tmp_invites (label, code)
SELECT 'primary', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
LIMIT 1;

-- Members join via invite
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_two'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));

-- Back to creator context for expense RPCs
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Constraint: active expense must set split_type and start_date
SELECT pg_temp.expect_api_error(
  format($sql$
    INSERT INTO public.expenses (home_id, created_by_user_id, status, amount_cents, description, start_date)
    VALUES ('%s', '%s', 'active', 1000, 'Needs split', current_date);
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ),
  'chk_expenses_active_split_required',
  'Active expenses require split_type'
);

-- Constraint: amount_cents may be null, but if set must be positive
SELECT pg_temp.expect_api_error(
  format($sql$
    INSERT INTO public.expenses (home_id, created_by_user_id, status, split_type, amount_cents, description, start_date)
    VALUES ('%s', '%s', 'draft', 'equal', -5, 'Bad amount', current_date);
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ),
  'chk_expenses_amount_positive',
  'Drafts allow NULL amount, otherwise must be positive'
);

-- Draft creation (split mode null, amount optional)
WITH created AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    '  Draft Lunch  ',
    NULL,
    '  messy note  ',
    NULL,
    NULL,
    NULL,
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'draft_one', (expense).id FROM created;

SELECT is(
  (SELECT status::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one')),
  'draft',
  'expenses_create stores draft when split_mode is null'
);

SELECT is(
  (SELECT amount_cents FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one')),
  NULL,
  'expenses_create allows null amount for drafts'
);

SELECT is(
  (SELECT recurrence_every FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one')),
  NULL,
  'Drafts store null recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one')),
  NULL,
  'Drafts store null recurrence_unit'
);

-- Draft cannot be recurring
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create(
      '%s','Recurring Draft',NULL,NULL,NULL,NULL,NULL,'monthly',current_date
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'INVALID_RECURRENCE_DRAFT',
  'Draft creation rejects recurrence'
);

-- Non-member cannot create expenses
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_temp.expect_api_error(
  $$ SELECT public.expenses_create(
        (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
        'Blocked expense',
        3000,
        NULL,
        NULL,
        NULL,
        NULL,
        'none',
        current_date
     ); $$,
  'NOT_HOME_MEMBER',
  'Non-members cannot call expenses_create'
);

-- Restore creator context
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Active equal split creation (one-off)
WITH created AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Groceries',
    101,
    NULL,
    'equal',
    ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
      (SELECT user_id FROM tmp_users WHERE label = 'member_two'),
      (SELECT user_id FROM tmp_users WHERE label = 'creator')
    ],
    NULL,
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'active_equal', (expense).id FROM created;

SELECT is(
  (SELECT recurrence_every FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'active_equal')),
  NULL,
  'One-off expense stores null recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'active_equal')),
  NULL,
  'One-off expense stores null recurrence_unit'
);

SELECT is(
  (SELECT COUNT(*)::int FROM public.expense_splits WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'active_equal')),
  3,
  'Equal split stores rows for all selected members (creator included)'
);

SELECT is(
  (SELECT status::text FROM public.expense_splits
    WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'active_equal')
      AND debtor_user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')),
  'paid',
  'Creator split row is marked paid immediately'
);

-- Editing active expense blocked
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_edit(
      '%s',
      5000,
      'Groceries bigger',
      NULL,
      'equal',
      ARRAY['%s'::uuid,'%s'::uuid],
      NULL,
      'none',
      current_date
    );
  $sql$,
    (SELECT expense_id FROM tmp_expenses WHERE label = 'active_equal'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_two')
  ),
  'EDIT_NOT_ALLOWED',
  'Active expenses are immutable'
);

-- Promote draft to active one-off via edit
SELECT public.expenses_edit(
  (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one'),
  5050,
  'Shared dinner',
  'bring drinks',
  'equal',
  ARRAY[
    (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_two'),
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ],
  NULL,
  'none',
  current_date
);

SELECT is(
  (SELECT status::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_one')),
  'active',
  'Draft promotion sets status=active'
);

-- Recurring activation converts draft and generates first cycle
WITH draft AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Weekly groceries',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'recurring_draft', (expense).id FROM draft;

WITH activated AS (
  SELECT public.expenses_edit(
    (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_draft'),
    3000,
    'Weekly groceries',
    'note',
    'equal',
    ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
      (SELECT user_id FROM tmp_users WHERE label = 'member_two'),
      (SELECT user_id FROM tmp_users WHERE label = 'creator')
    ],
    NULL,
    'monthly',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'recurring_cycle', (expense).id FROM activated;

SELECT ok(
  (SELECT plan_id IS NOT NULL FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')),
  'Recurring activation returns a cycle with plan_id'
);

SELECT is(
  (SELECT recurrence_every FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')),
  1,
  'Recurring cycle stores recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')),
  'month',
  'Recurring cycle stores recurrence_unit'
);

SELECT is(
  (SELECT status::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')),
  'active',
  'Generated cycle is active'
);

-- expenses_get_created_by_me includes recurrence and start date for recurring cycles
WITH payload AS (
  SELECT public.expenses_get_created_by_me(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
),
recurring_entry AS (
  SELECT elem
  FROM payload,
  LATERAL jsonb_array_elements(body) elem
  WHERE elem->>'expenseId' = (
    SELECT expense_id::text FROM tmp_expenses WHERE label = 'recurring_cycle'
  )
)
SELECT is(
  (SELECT elem->>'recurrenceEvery' FROM recurring_entry),
  '1',
  'Created list payload includes recurrenceEvery for recurring cycle'
);

WITH payload AS (
  SELECT public.expenses_get_created_by_me(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
),
recurring_entry AS (
  SELECT elem
  FROM payload,
  LATERAL jsonb_array_elements(body) elem
  WHERE elem->>'expenseId' = (
    SELECT expense_id::text FROM tmp_expenses WHERE label = 'recurring_cycle'
  )
)
SELECT is(
  (SELECT elem->>'recurrenceUnit' FROM recurring_entry),
  'month',
  'Created list payload includes recurrenceUnit for recurring cycle'
);

WITH payload AS (
  SELECT public.expenses_get_created_by_me(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
),
recurring_entry AS (
  SELECT elem
  FROM payload,
  LATERAL jsonb_array_elements(body) elem
  WHERE elem->>'expenseId' = (
    SELECT expense_id::text FROM tmp_expenses WHERE label = 'recurring_cycle'
  )
)
SELECT is(
  (SELECT (elem->>'startDate')::date FROM recurring_entry),
  current_date,
  'Created list payload includes startDate for recurring cycle'
);

SELECT is(
  (SELECT status::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_draft')),
  'converted',
  'Original draft marked converted after plan creation'
);

-- expenses_get_for_edit shows disabled reason for converted draft
WITH payload AS (
  SELECT public.expenses_get_for_edit((SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_draft')) AS body
)
SELECT is(
  (SELECT body->>'editDisabledReason' FROM payload),
  'CONVERTED_TO_PLAN',
  'Edit payload clarifies converted draft cannot be edited'
);

WITH payload AS (
  SELECT public.expenses_get_for_edit((SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')) AS body
)
SELECT is(
  (SELECT body->>'planStatus' FROM payload),
  'active',
  'expenses_get_for_edit returns planStatus=active for recurring cycle'
);

-- Terminate plan and ensure planStatus surfaces as terminated
SELECT public.expense_plans_terminate(
  (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle'))
);

WITH payload AS (
  SELECT public.expenses_get_for_edit((SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_cycle')) AS body
)
SELECT is(
  (SELECT body->>'planStatus' FROM payload),
  'terminated',
  'expenses_get_for_edit returns planStatus=terminated after termination'
);

-- Bulk pay via expenses_pay_my_due decrements usage once per fully paid expense
-- Create new active expense with unpaid split for member_one and observe counter delta
INSERT INTO tmp_counters (label, active_expenses)
SELECT
  'before_paydown',
  COALESCE(active_expenses, 0)
FROM public.home_usage_counters
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
ON CONFLICT (label) DO UPDATE SET active_expenses = EXCLUDED.active_expenses;

WITH created AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Paydown',
    1500,
    NULL,
    'equal',
    ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'creator'),
      (SELECT user_id FROM tmp_users WHERE label = 'member_one')
    ],
    NULL,
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'paydown', (expense).id FROM created;

SELECT is(
  (SELECT COALESCE(active_expenses, 0)
     FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  (SELECT active_expenses + 1 FROM tmp_counters WHERE label = 'before_paydown'),
  'Active expense increments active_expenses counter by 1'
);

-- Member_one pays what they owe to creator
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member_one'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

INSERT INTO tmp_due (label, splits_due, expenses_due)
SELECT
  'before_bulk_pay',
  COUNT(*)::int,
  COUNT(DISTINCT e.id)::int
FROM public.expense_splits s
JOIN public.expenses e ON e.id = s.expense_id
WHERE s.debtor_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')
  AND s.status = 'unpaid'
  AND e.status = 'active'
  AND e.created_by_user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator');

WITH result AS (
  SELECT public.expenses_pay_my_due((SELECT user_id FROM tmp_users WHERE label = 'creator')) AS body
)
SELECT is(
  (SELECT (body->>'splitsPaid')::int FROM result),
  (SELECT splits_due FROM tmp_due WHERE label = 'before_bulk_pay'),
  'Bulk pay marks all owed splits for the recipient'
);

WITH result AS (
  SELECT public.expenses_pay_my_due((SELECT user_id FROM tmp_users WHERE label = 'creator')) AS body
)
SELECT is(
  (SELECT (body->>'expensesNewlyFullyPaid')::int FROM result),
  0,
  'Second bulk pay is idempotent (no newly fully paid expenses)'
);

-- Creator context to verify counters
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (SELECT status::text FROM public.expense_splits
    WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'paydown')
      AND debtor_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member_one')),
  'paid',
  'Debtor split marked paid via bulk pay'
);

SELECT ok(
  (SELECT fully_paid_at IS NOT NULL FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'paydown')),
  'fully_paid_at stamped when last split paid'
);

SELECT is(
  (SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  (SELECT active_expenses FROM tmp_counters WHERE label = 'before_paydown'),
  'active_expenses decremented when expense becomes fully paid'
);

SELECT * FROM finish();
ROLLBACK;
