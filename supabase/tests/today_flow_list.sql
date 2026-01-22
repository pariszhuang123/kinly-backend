SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(5);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',    '00000000-0000-4000-8000-000000000411', 'owner-today@example.com'),
  ('helper',   '00000000-0000-4000-8000-000000000412', 'helper-today@example.com'),
  ('outsider', '00000000-0000-4000-8000-000000000413', 'outsider-today@example.com');

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000711', 'avatars/default.png', 'animal', 'Today Flow Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000712', 'avatars/today-alt.png', 'animal', 'Today Flow Avatar Alt')
ON CONFLICT (id) DO NOTHING;

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

-- Owner creates the home via homes_create_with_invite
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

-- Helper joins same home
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'helper'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join(
  (SELECT code
   FROM public.invites
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
     AND revoked_at IS NULL
   LIMIT 1)
);

-- Seed chores: two drafts, two active for helper, one active for owner
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Draft Yesterday',
  NULL,
  current_date - 1,
  'none',
  NULL,
  'Draft chore happening first',
  NULL
);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Draft Today',
  NULL,
  current_date,
  'none',
  NULL,
  'Draft chore happening later',
  NULL
);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Draft Tomorrow',
  NULL,
  current_date + 1,
  'none',
  NULL,
  'Draft chore tomorrow local day',
  NULL
);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Active Due Yesterday',
  (SELECT user_id FROM tmp_users WHERE label = 'helper'),
  current_date - 1,
  'none',
  NULL,
  NULL,
  NULL
);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Active Due Today',
  (SELECT user_id FROM tmp_users WHERE label = 'helper'),
  current_date,
  'none',
  NULL,
  NULL,
  NULL
);

SELECT public.chores_create(
  (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
  'Active Owner Task',
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  current_date + 5,
  'none',
  NULL,
  NULL,
  NULL
);

-- Draft listings: owner sees both drafts ordered by start_date ASC.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT COALESCE(array_agg(name ORDER BY start_date, name), ARRAY[]::text[])
    FROM public.today_flow_list(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'draft'
    )
  ),
  ARRAY['Draft Yesterday', 'Draft Today']::text[],
  'today_flow_list(draft) returns creator drafts due today or earlier ordered by start date'
);

SELECT is(
  (
    SELECT COALESCE(array_agg(name ORDER BY start_date, name), ARRAY[]::text[])
    FROM public.today_flow_list(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'draft',
      current_date + 1  -- simulate caller a day ahead of server
    )
  ),
  ARRAY['Draft Yesterday', 'Draft Today', 'Draft Tomorrow']::text[],
  'today_flow_list(draft) honors caller local date when ahead of UTC'
);

-- Active listings: helper sees chores assigned to them, not creator-owned.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'helper'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT COALESCE(array_agg(name ORDER BY start_date, name), ARRAY[]::text[])
    FROM public.today_flow_list(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'active'
    )
  ),
  ARRAY['Active Due Yesterday', 'Active Due Today']::text[],
  'today_flow_list(active) returns helper-assigned chores due today or earlier ordered ASC'
);

-- Owner calling active does not see helper-assigned chores.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT COALESCE(array_agg(name ORDER BY start_date, name), ARRAY[]::text[])
    FROM public.today_flow_list(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'active'
    )
  ),
  ARRAY[]::text[],
  'today_flow_list(active) excludes chores not assigned to the caller'
);

-- Outsider cannot call the RPC.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT throws_like(
  format(
    $fmt$
    SELECT *
    FROM public.today_flow_list('%s', 'draft')
    $fmt$,
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  '%"code" : "NOT_HOME_MEMBER"%',
  'non-members cannot list today flow data'
);

SELECT * FROM finish();
ROLLBACK;
