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

-- Starter avatar for profiles
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000601', 'avatars/default.png', 'animal', 'Test Avatar'),
  ('00000000-0000-4000-8000-000000000602', 'avatars/recurrence-alt-a.png', 'animal', 'Recurrence Avatar A'),
  ('00000000-0000-4000-8000-000000000603', 'avatars/recurrence-alt-b.png', 'animal', 'Recurrence Avatar B')
ON CONFLICT (id) DO NOTHING;

-- Seed logical users
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator',     '30000000-0000-4000-9000-000000000001', 'creator-expenses-v2@example.com'),
  ('member_one',  '30000000-0000-4000-9000-000000000002', 'member1-expenses-v2@example.com'),
  ('member_two',  '30000000-0000-4000-9000-000000000003', 'member2-expenses-v2@example.com');

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

-- v2 rejects recurrence on drafts
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v2(
      '%s',
      'Draft recurrence',
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      1,
      'week',
      current_date
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  'INVALID_RECURRENCE_DRAFT',
  'Draft creation rejects recurrence in v2'
);

-- v2 rejects partial recurrence params
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v2(
      '%s',
      'Bad recurrence',
      1000,
      NULL,
      'equal',
      ARRAY['%s'::uuid, '%s'::uuid],
      NULL,
      2,
      NULL,
      current_date
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_two')
  ),
  'INVALID_RECURRENCE',
  'Recurrence every and unit must be paired in v2'
);

-- v2 rejects invalid unit
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v2(
      '%s',
      'Bad unit',
      1000,
      NULL,
      'equal',
      ARRAY['%s'::uuid, '%s'::uuid],
      NULL,
      1,
      'fortnight',
      current_date
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
    (SELECT user_id FROM tmp_users WHERE label = 'member_two')
  ),
  'INVALID_RECURRENCE',
  'Recurrence unit must be day/week/month/year'
);

-- Create recurring expense with v2 parameters
WITH created AS (
  SELECT public.expenses_create_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Biweekly snacks',
    2000,
    NULL,
    'equal',
    ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'member_one'),
      (SELECT user_id FROM tmp_users WHERE label = 'member_two'),
      (SELECT user_id FROM tmp_users WHERE label = 'creator')
    ],
    NULL,
    2,
    'week',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'recurring_v2', (expense).id FROM created;

SELECT ok(
  (SELECT plan_id IS NOT NULL FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2')),
  'Recurring v2 creation returns a cycle with plan_id'
);

SELECT is(
  (SELECT recurrence_every FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2')),
  2,
  'Recurring v2 cycle stores recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2')),
  'week',
  'Recurring v2 cycle stores recurrence_unit'
);

SELECT is(
  (SELECT recurrence_every FROM public.expense_plans WHERE id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2'))),
  2,
  'Recurring v2 plan stores recurrence_every'
);

SELECT is(
  (SELECT recurrence_unit FROM public.expense_plans WHERE id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2'))),
  'week',
  'Recurring v2 plan stores recurrence_unit'
);

SELECT is(
  (SELECT next_cycle_date FROM public.expense_plans WHERE id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_v2'))),
  (current_date + 14),
  'Recurring v2 plan computes next_cycle_date from every/unit'
);

SELECT finish();
ROLLBACK;
