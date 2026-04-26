SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label text PRIMARY KEY,
  user_id uuid,
  email text
);

CREATE TEMP TABLE tmp_homes (
  label text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_units (
  label text PRIMARY KEY,
  unit_id uuid
);

CREATE TEMP TABLE tmp_memberships (
  label text PRIMARY KEY,
  membership_id uuid
);

CREATE TEMP TABLE tmp_expenses (
  label text PRIMARY KEY,
  expense_id uuid
);

CREATE OR REPLACE FUNCTION pg_temp.expect_api_error(
  p_sql text,
  p_error_code text,
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

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8100-000000000001', 'avatars/unit-a.png', 'animal', 'Unit Avatar A'),
  ('00000000-0000-4000-8100-000000000002', 'avatars/unit-b.png', 'animal', 'Unit Avatar B'),
  ('00000000-0000-4000-8100-000000000003', 'avatars/unit-c.png', 'animal', 'Unit Avatar C'),
  ('00000000-0000-4000-8100-000000000004', 'avatars/unit-d.png', 'animal', 'Unit Avatar D'),
  ('00000000-0000-4000-8100-000000000005', 'avatars/unit-e.png', 'animal', 'Unit Avatar E')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator', '30000000-0000-4000-8100-000000000001', 'creator-unit@example.com'),
  ('alice',   '30000000-0000-4000-8100-000000000002', 'alice-unit@example.com'),
  ('bob',     '30000000-0000-4000-8100-000000000003', 'bob-unit@example.com'),
  ('carol',   '30000000-0000-4000-8100-000000000004', 'carol-unit@example.com'),
  ('dave',    '30000000-0000-4000-8100-000000000005', 'dave-unit@example.com');

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

INSERT INTO public.profiles (id, email, username, avatar_id)
VALUES
  ((SELECT user_id FROM tmp_users WHERE label = 'creator'), (SELECT email FROM tmp_users WHERE label = 'creator'), 'creatorunit', '00000000-0000-4000-8100-000000000001'),
  ((SELECT user_id FROM tmp_users WHERE label = 'alice'),   (SELECT email FROM tmp_users WHERE label = 'alice'),   'aliceunit',   '00000000-0000-4000-8100-000000000002'),
  ((SELECT user_id FROM tmp_users WHERE label = 'bob'),     (SELECT email FROM tmp_users WHERE label = 'bob'),     'bobunit',     '00000000-0000-4000-8100-000000000003'),
  ((SELECT user_id FROM tmp_users WHERE label = 'carol'),   (SELECT email FROM tmp_users WHERE label = 'carol'),   'carolunit',   '00000000-0000-4000-8100-000000000004'),
  ((SELECT user_id FROM tmp_users WHERE label = 'dave'),    (SELECT email FROM tmp_users WHERE label = 'dave'),    'daveunit',    '00000000-0000-4000-8100-000000000005')
ON CONFLICT (id) DO UPDATE
SET email = EXCLUDED.email,
    username = EXCLUDED.username,
    avatar_id = EXCLUDED.avatar_id;

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
SELECT 'primary', (payload->'home'->>'id')::uuid
FROM res;

DO $$
DECLARE
  v_code text;
  v_label text;
BEGIN
  SELECT code
  INTO v_code
  FROM public.invites
  WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    AND revoked_at IS NULL
  LIMIT 1;

  FOREACH v_label IN ARRAY ARRAY['alice', 'bob', 'carol', 'dave']
  LOOP
    PERFORM set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = v_label), true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM public.homes_join(v_code);
  END LOOP;
END
$$;

INSERT INTO tmp_memberships (label, membership_id)
SELECT
  u.label,
  m.id
FROM tmp_users u
JOIN public.memberships m
  ON m.user_id = u.user_id
WHERE u.label IN ('creator', 'alice', 'bob', 'carol', 'dave')
  AND m.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND m.valid_to IS NULL;

INSERT INTO tmp_units (label, unit_id)
SELECT
  'carol_personal',
  hu.id
FROM public.home_units hu
JOIN public.memberships m
  ON m.id = hu.personal_membership_id
WHERE hu.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND hu.unit_type = 'personal'
  AND hu.archived_at IS NULL
  AND m.user_id = (SELECT user_id FROM tmp_users WHERE label = 'carol')
  AND m.valid_to IS NULL;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'alice'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH new_unit AS (
  INSERT INTO public.home_units (
    home_id,
    unit_type,
    name,
    created_by_user_id
  )
  VALUES (
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'shared',
    'Alice + Bob',
    (SELECT user_id FROM tmp_users WHERE label = 'alice')
  )
  RETURNING id
),
members AS (
  INSERT INTO public.home_unit_members (unit_id, membership_id, home_id)
  SELECT
    (SELECT id FROM new_unit),
    tm.membership_id,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  FROM tmp_memberships tm
  WHERE tm.label IN ('alice', 'bob')
  RETURNING unit_id
)
INSERT INTO tmp_units (label, unit_id)
SELECT 'shared_ab', unit_id
FROM members
LIMIT 1;

SELECT is(
  (SELECT (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab') <> (SELECT unit_id FROM tmp_units WHERE label = 'carol_personal')),
  TRUE,
  'Shared unit and personal unit get distinct unit ids'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_selectable_expense_units(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  1,
  'home_units_list_selectable_expense_units returns only the personal unit before shared membership exists'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_selectable_expense_units_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  5,
  'home_units_list_selectable_expense_units_v2 returns every active personal unit before shared membership exists for the caller'
);

SELECT ok(
  (
    SELECT EXISTS (
      SELECT 1
      FROM public.home_units_list_selectable_expense_units_v2(
        (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      ) selectable
      JOIN public.home_units hu
        ON hu.id = selectable.unit_id
      JOIN public.memberships m
        ON m.id = hu.personal_membership_id
      WHERE m.user_id = (SELECT user_id FROM tmp_users WHERE label = 'carol')
    )
  ),
  'home_units_list_selectable_expense_units_v2 includes another member personal unit as a separate row'
);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v5(
      p_home_id => '%s',
      p_description => 'Invalid personal-only unit split',
      p_amount_cents => 1200,
      p_notes => NULL,
      p_allocation_target_type => 'unit_based',
      p_split_mode => 'equal',
      p_unit_ids => ARRAY[
        (SELECT hu.id
         FROM public.home_units hu
         JOIN public.memberships m
           ON m.id = hu.personal_membership_id
         WHERE hu.home_id = '%s'
           AND hu.unit_type = 'personal'
           AND hu.archived_at IS NULL
           AND m.user_id = '%s'::uuid
           AND m.valid_to IS NULL)
      ]::uuid[],
      p_start_date => current_date
    );
  $sql$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ),
  'SPLIT_UNITS_REQUIRED',
  'Unit-based create rejects creator personal unit as the sole debtor target'
);

WITH created AS (
  SELECT public.expenses_create_v5(
    p_home_id => (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    p_description => 'Power bill',
    p_amount_cents => 5000,
    p_notes => 'Unit charge',
    p_allocation_target_type => 'unit_based',
    p_split_mode => 'equal',
    p_unit_ids => ARRAY[(SELECT unit_id FROM tmp_units WHERE label = 'shared_ab')]::uuid[],
    p_start_date => current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'power', (expense).id
FROM created;

SELECT is(
  (SELECT allocation_target_type::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'power')),
  'unit_based',
  'expenses_create_v5 stores unit_based allocation target'
);

SELECT is(
  (SELECT count(*)::int FROM public.expense_unit_splits WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'power')),
  1,
  'Unit-based expense writes one expense_unit_splits row'
);

SELECT is(
  (SELECT home_id FROM public.expense_unit_splits WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'power') LIMIT 1),
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'expense_unit_splits rows persist the parent home_id'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'alice'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_selectable_expense_units(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  2,
  'home_units_list_selectable_expense_units returns shared and personal units for a caller in an active shared unit'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_selectable_expense_units_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  6,
  'home_units_list_selectable_expense_units_v2 returns the caller shared unit plus every active personal unit'
);

SELECT is(
  (
    SELECT unit_type
    FROM public.home_units_list_selectable_expense_units_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
    LIMIT 1
  ),
  'shared',
  'home_units_list_selectable_expense_units_v2 orders the caller active shared unit before personal units'
);

SELECT is(
  (
    SELECT unit_id::text
    FROM public.home_units_list_selectable_expense_units_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
    OFFSET 1
    LIMIT 1
  ),
  (
    SELECT hu.id::text
    FROM public.home_units hu
    JOIN public.memberships m
      ON m.id = hu.personal_membership_id
    WHERE hu.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND hu.unit_type = 'personal'
      AND hu.archived_at IS NULL
      AND m.user_id = (SELECT user_id FROM tmp_users WHERE label = 'alice')
      AND m.valid_to IS NULL
    LIMIT 1
  ),
  'home_units_list_selectable_expense_units_v2 orders the caller personal unit immediately after the active shared unit'
);

SELECT is(
  (
    SELECT unit_type
    FROM public.home_units_list_selectable_expense_units(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
    LIMIT 1
  ),
  'shared',
  'home_units_list_selectable_expense_units orders the active shared unit before the personal unit'
);

WITH owed AS (
  SELECT public.expenses_get_current_owed_v3(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM owed),
  1,
  'Member of debtor shared unit sees one payer group in current owed v3'
);

WITH owed AS (
  SELECT public.expenses_get_current_owed_v3(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT body->0->'items'->0->>'liabilityKind' FROM owed),
  'shared',
  'Unit-based shared liability is tagged shared'
);

WITH payment AS (
  SELECT public.expenses_pay_unit_due_v2(
    (SELECT expense_id FROM tmp_expenses WHERE label = 'power'),
    (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab'),
    2000
  ) AS body
)
SELECT is(
  (SELECT (body->>'remainingCents')::int FROM payment),
  3000,
  'Partial unit payment reduces remaining balance'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'carol'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_pay_unit_due_v2('%s', '%s', 1000);
  $sql$,
    (SELECT expense_id FROM tmp_expenses WHERE label = 'power'),
    (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab')
  ),
  'INVALID_UNIT_SCOPE',
  'Member outside debtor unit cannot pay against another unit liability'
);

WITH owed AS (
  SELECT public.expenses_get_current_owed_v3(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM owed),
  0,
  'Member outside debtor unit does not see another unit liability'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'bob'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payment AS (
  SELECT public.expenses_pay_unit_due_v2(
    (SELECT expense_id FROM tmp_expenses WHERE label = 'power'),
    (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab'),
    3000
  ) AS body
)
SELECT is(
  (SELECT (body->>'expenseFullyPaid')::boolean FROM payment),
  TRUE,
  'Second member of debtor unit can settle the remaining shared balance'
);

SELECT is(
  (SELECT fully_paid_at IS NOT NULL FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'power')),
  TRUE,
  'Unit-based expense becomes fully paid once all unit balances are settled'
);

WITH owed AS (
  SELECT public.expenses_get_current_owed_v3(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM owed),
  0,
  'Fully paid shared liabilities disappear from current owed v3'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH created AS (
  SELECT public.expenses_create_v5(
    p_home_id => (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    p_description => 'Internet bundle',
    p_amount_cents => 9000,
    p_notes => 'Recurring unit allocation',
    p_allocation_target_type => 'unit_based',
    p_split_mode => 'custom',
    p_unit_splits => jsonb_build_array(
      jsonb_build_object(
        'unit_id', (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab'),
        'amount_cents', 6000
      ),
      jsonb_build_object(
        'unit_id', (SELECT unit_id FROM tmp_units WHERE label = 'carol_personal'),
        'amount_cents', 3000
      )
    ),
    p_recurrence_every => 1,
    p_recurrence_unit => 'week',
    p_start_date => current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'internet', (expense).id
FROM created;

SELECT is(
  (SELECT count(*)::int FROM public.expense_plan_units WHERE plan_id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'internet'))),
  2,
  'Recurring unit-based expense persists expense_plan_units rows'
);

SELECT is(
  (SELECT count(*)::int FROM public.expense_plan_units
    WHERE plan_id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'internet'))
      AND home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  2,
  'expense_plan_units rows persist the parent home_id'
);

SELECT is(
  (SELECT count(*)::int FROM public.expense_unit_splits WHERE expense_id = (SELECT expense_id FROM tmp_expenses WHERE label = 'internet')),
  2,
  'Recurring unit-based expense generates cycle expense_unit_splits rows'
);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v5(
      p_home_id => '%s',
      p_description => 'Invalid unit',
      p_amount_cents => 1000,
      p_notes => NULL,
      p_allocation_target_type => 'unit_based',
      p_split_mode => 'equal',
      p_unit_ids => ARRAY['00000000-0000-4000-9000-000000009999']::uuid[],
      p_start_date => current_date
    );
  $sql$, (SELECT home_id FROM tmp_homes WHERE label = 'primary')),
  'INVALID_UNIT_TARGET',
  'Unit-based create rejects unit ids outside the home'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'bob'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.home_units_leave_shared(
  (SELECT unit_id FROM tmp_units WHERE label = 'shared_ab')
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'creator'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public._expense_plan_generate_cycle_v3(
      '%s',
      current_date + 7,
      false
    );
  $sql$,
    (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'internet'))
  ),
  'PLAN_TERMINATED_INVALID_TARGETS',
  'Recurring unit-based plan terminates when a stored target unit is archived'
);

SELECT is(
  (SELECT termination_reason
   FROM public.expense_plans
   WHERE id = (SELECT plan_id FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'internet'))),
  'UNIT_TARGET_ARCHIVED',
  'Plan termination reason is recorded for archived unit targets'
);

SELECT * FROM finish();
ROLLBACK;
