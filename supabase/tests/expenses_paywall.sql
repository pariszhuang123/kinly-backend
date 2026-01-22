SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_home (
  home_id uuid
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

-- Seed avatars for handle_new_user trigger
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-9000-000000000111', 'avatars/default.png', 'animal', 'Test A'),
  ('00000000-0000-4000-9000-000000000112', 'avatars/default.png', 'animal', 'Test B'),
  ('00000000-0000-4000-9000-000000000113', 'avatars/default.png', 'animal', 'Test C')
ON CONFLICT (id) DO NOTHING;

-- Users: owner + two members
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',   '20000000-0000-4000-9000-000000000001', 'paywall-owner@example.com'),
  ('member1', '20000000-0000-4000-9000-000000000002', 'paywall-m1@example.com'),
  ('member2', '20000000-0000-4000-9000-000000000003', 'paywall-m2@example.com');

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

-- Home + memberships
INSERT INTO public.homes (id, owner_user_id)
VALUES ('20000000-0000-4000-9000-000000000101', (SELECT user_id FROM tmp_users WHERE label = 'owner'));
INSERT INTO tmp_home VALUES ('20000000-0000-4000-9000-000000000101');

INSERT INTO public.memberships (user_id, home_id, role)
SELECT user_id, (SELECT home_id FROM tmp_home), CASE WHEN label = 'owner' THEN 'owner' ELSE 'member' END
FROM tmp_users;

-- Free plan so quota applies
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ((SELECT home_id FROM tmp_home), 'free', NULL)
ON CONFLICT (home_id) DO UPDATE SET plan = EXCLUDED.plan, expires_at = EXCLUDED.expires_at;

-- Act as owner
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- 1) initial counter
SELECT is(
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  0,
  'initial active_expenses counter starts at 0'
);

-- 2) Drafts do not consume quota
DO $$
DECLARE i integer;
BEGIN
  FOR i IN 1..3 LOOP
    PERFORM public.expenses_create(
      (SELECT home_id FROM tmp_home),
      format('Draft %s', i),
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'none',
      current_date
    );
  END LOOP;
END;
$$;

SELECT is(
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  0,
  'draft creation leaves active_expenses unchanged'
);

-- 3) Create 10 active expenses (hit free cap)
DO $$
DECLARE i integer;
BEGIN
  FOR i IN 1..10 LOOP
    PERFORM public.expenses_create(
      (SELECT home_id FROM tmp_home),
      format('Active %s', i),
      1000,
      NULL,
      'equal',
      ARRAY[
        (SELECT user_id FROM tmp_users WHERE label = 'owner'),
        (SELECT user_id FROM tmp_users WHERE label = 'member1')
      ],
      NULL,
      'none',
      current_date
    );
  END LOOP;
END;
$$;

SELECT is(
  (SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)),
  10,
  'active_expenses increments to 10 after 10 active expenses'
);

-- 4) 11th active on free plan is blocked
SELECT pg_temp.expect_api_error(
  $$ SELECT public.expenses_create(
        (SELECT home_id FROM tmp_home),
        'Blocked active',
        1200,
        NULL,
        'equal',
        ARRAY[
          (SELECT user_id FROM tmp_users WHERE label = 'owner'),
          (SELECT user_id FROM tmp_users WHERE label = 'member1')
        ],
        NULL,
        'none',
        current_date
     ); $$,
  'PAYWALL_LIMIT_ACTIVE_EXPENSES',
  '11th active expense on free plan hits active_expenses cap'
);

-- 5) Premium bypasses quota and allows another active expense
UPDATE public.home_entitlements
SET plan = 'premium', expires_at = now() + interval '1 day'
WHERE home_id = (SELECT home_id FROM tmp_home);

INSERT INTO tmp_expenses (label, expense_id)
SELECT 'premium_one', (expense).id
FROM (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_home),
    'Premium allowed',
    1200,
    NULL,
    'equal',
    ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT user_id FROM tmp_users WHERE label = 'member1')
    ],
    NULL,
    'none',
    current_date
  ) AS expense
) t;

SELECT is(
  (SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)),
  11,
  'premium creation increments counter to 11'
);

-- 6) Debtor bulk pay clears all owed items and decrements counter accordingly
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.expenses_pay_my_due((SELECT user_id FROM tmp_users WHERE label = 'owner')) AS body
)
SELECT ok(
  (SELECT (body->>'splitsPaid')::int FROM payload) >= 10,
  'Bulk pay touches all owed splits for member1'
);

SELECT is(
  (SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)),
  0,
  'active_expenses decremented for 11 fully paid expenses'
);

-- 7) apply_delta floors at zero
SELECT public._home_usage_apply_delta(
  (SELECT home_id FROM tmp_home),
  jsonb_build_object('active_expenses', -50)
);

SELECT is(
  (SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)),
  0,
  '_home_usage_apply_delta floors active_expenses at 0'
);

-- 8) plan limits seeded
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.home_plan_limits
    WHERE plan = 'free' AND metric = 'active_expenses' AND max_value = 10
  ),
  'home_plan_limits seeded with free cap for active_expenses'
);

SELECT * FROM finish();

ROLLBACK;
