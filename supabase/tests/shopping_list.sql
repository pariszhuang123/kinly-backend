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

CREATE TEMP TABLE tmp_invites (
  label text PRIMARY KEY,
  code text
);

CREATE TEMP TABLE tmp_items (
  label text PRIMARY KEY,
  item_id uuid
);

CREATE TEMP TABLE tmp_expenses (
  label text PRIMARY KEY,
  expense_id uuid
);

CREATE TEMP TABLE tmp_metrics (
  label text PRIMARY KEY,
  value integer
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
VALUES ('00000000-0000-4000-8000-000000000701', 'avatars/default.png', 'animal', 'Shopping Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000702', 'avatars/shopping-alt1.png', 'animal', 'Shopping Alt 1'),
  ('00000000-0000-4000-8000-000000000703', 'avatars/shopping-alt2.png', 'animal', 'Shopping Alt 2')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner', '10000000-0000-4000-9000-000000000101', 'owner-shopping@example.com'),
  ('member', '10000000-0000-4000-9000-000000000102', 'member-shopping@example.com'),
  ('outsider', '10000000-0000-4000-9000-000000000103', 'outsider-shopping@example.com');

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

-- Owner creates a home and invite.
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
SELECT 'primary', (payload->'home'->>'id')::uuid
FROM res;

INSERT INTO tmp_invites (label, code)
SELECT 'primary', code::text
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
LIMIT 1;

-- Member joins the home.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));

-- Internal helpers are not callable by authenticated clients.
SELECT throws_like(
  $$ SELECT public._home_assert_quota(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       '{}'::jsonb
     ); $$,
  '%permission denied%',
  '_home_assert_quota is internal-only'
);

SELECT throws_like(
  $$ SELECT public._home_usage_apply_delta(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       '{"shopping_item_photos":1}'::jsonb
     ); $$,
  '%permission denied%',
  '_home_usage_apply_delta is internal-only'
);

-- Owner context for list setup.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Empty view shape before any item exists.
SELECT ok(
  (
    SELECT (public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'list'->>'id') IS NULL
  ),
  'get_for_home returns empty active list object when no list exists'
);

SELECT is(
  (
    SELECT public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'list'->>'home_id'
  ),
  (SELECT home_id::text FROM tmp_homes WHERE label = 'primary'),
  'empty list object still includes requested home_id'
);

SELECT is(
  (
    SELECT jsonb_array_length(public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'items')
  ),
  0,
  'empty list has zero items'
);

-- Non-member blocked.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_add_item(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Milk',
      NULL,
      NULL,
      NULL
    ); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot add item'
);

-- Back to owner.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_add_item(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      '   ',
      NULL,
      NULL,
      NULL
    ); $$,
  'invalid_name',
  'blank name rejected on add'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_add_item(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Bad path',
      NULL,
      NULL,
      'avatars/not-allowed.jpg'
    ); $$,
  'invalid_reference_photo_path',
  'invalid photo path rejected on add'
);

-- Shrink free limit for shopping item photos to validate paywall behavior.
INSERT INTO tmp_metrics (label, value)
SELECT
  'baseline_shopping_item_photos',
  COALESCE(shopping_item_photos, 0)
FROM public.home_usage_counters
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
ON CONFLICT (label) DO UPDATE
SET value = EXCLUDED.value;

INSERT INTO tmp_metrics (label, value)
SELECT
  'baseline_shopping_item_photos',
  0
WHERE NOT EXISTS (
  SELECT 1 FROM tmp_metrics WHERE label = 'baseline_shopping_item_photos'
);

UPDATE public.home_plan_limits
SET max_value = (SELECT value + 1 FROM tmp_metrics WHERE label = 'baseline_shopping_item_photos')
WHERE plan = 'free'
  AND metric = 'shopping_item_photos';

WITH first_item AS (
  SELECT public.shopping_list_add_item(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Milk',
    '2',
    '2L whole milk',
    'households/test/milk.jpg'
  ) AS item
)
INSERT INTO tmp_items (label, item_id)
SELECT 'milk', (item).id
FROM first_item;

SELECT is(
  (
    SELECT shopping_item_photos
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  (SELECT value + 1 FROM tmp_metrics WHERE label = 'baseline_shopping_item_photos'),
  'adding item with photo increments shopping_item_photos usage'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_add_item(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Eggs',
      NULL,
      NULL,
      'households/test/eggs.jpg'
    ); $$,
  'PAYWALL_LIMIT_SHOPPING_ITEM_PHOTOS',
  'second photo add blocked by quota'
);

-- Item without photo can still be added when photo quota is maxed.
WITH item_without_photo AS (
  SELECT public.shopping_list_add_item(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Bread',
    NULL,
    NULL,
    NULL
  ) AS item
)
INSERT INTO tmp_items (label, item_id)
SELECT 'bread', (item).id
FROM item_without_photo;

SELECT is(
  (
    SELECT jsonb_array_length(public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'items')
  ),
  2,
  'list contains two unarchived items'
);

SELECT is(
  (
    SELECT (public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'list'->>'items_unarchived_count')::int
  ),
  2,
  'list metadata includes unarchived count'
);

SELECT is(
  (
    SELECT (public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'list'->>'items_uncompleted_count')::int
  ),
  2,
  'list metadata includes uncompleted count'
);

-- Update validations.
SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_update_item(
      (SELECT item_id FROM tmp_items WHERE label = 'bread'),
      NULL,
      NULL,
      NULL,
      NULL,
      'bad/path.jpg',
      FALSE
    ); $$,
  'invalid_reference_photo_path',
  'invalid photo path rejected on update'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_update_item(
      (SELECT item_id FROM tmp_items WHERE label = 'milk'),
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      TRUE
    ); $$,
  'photo_delete_not_allowed',
  'photo delete not allowed'
);

-- Member completes both items.
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.shopping_list_update_item(
  (SELECT item_id FROM tmp_items WHERE label = 'milk'),
  NULL,
  NULL,
  NULL,
  TRUE,
  NULL,
  FALSE
);

SELECT public.shopping_list_update_item(
  (SELECT item_id FROM tmp_items WHERE label = 'bread'),
  NULL,
  NULL,
  NULL,
  TRUE,
  NULL,
  FALSE
);

SELECT is(
  (
    SELECT item_count
    FROM public.shopping_list_prepare_expense_for_user((SELECT home_id FROM tmp_homes WHERE label = 'primary'))
  ),
  2,
  'prepare_expense returns both completed unlinked items for caller'
);

-- invalid_expense on foreign expense owner.
CREATE TEMP TABLE tmp_owner_expenses (
  expense_id uuid PRIMARY KEY
);

WITH inserted AS (
  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    start_date
  )
  VALUES (
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    'active',
    'equal',
    2000,
    'Owner groceries',
    current_date
  )
  RETURNING id
)
INSERT INTO tmp_owner_expenses (expense_id)
SELECT id
FROM inserted;

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_link_items_to_expense_for_user(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT expense_id FROM tmp_owner_expenses),
      ARRAY[(SELECT item_id FROM tmp_items WHERE label = 'milk')]
    ); $$,
  'invalid_expense',
  'caller cannot link to expense owned by another user'
);

-- Member-owned expense for successful linking.
WITH inserted AS (
  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    start_date
  )
  VALUES (
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'member'),
    'active',
    'equal',
    1000,
    'Member groceries',
    current_date
  )
  RETURNING id
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'member_expense', id
FROM inserted;

INSERT INTO tmp_metrics (label, value)
SELECT
  'baseline_active_expenses',
  COALESCE(active_expenses, 0)
FROM public.home_usage_counters
WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
ON CONFLICT (label) DO UPDATE
SET value = EXCLUDED.value;

INSERT INTO tmp_metrics (label, value)
SELECT
  'baseline_active_expenses',
  0
WHERE NOT EXISTS (
  SELECT 1 FROM tmp_metrics WHERE label = 'baseline_active_expenses'
);

SELECT is(
  (
    SELECT COALESCE(active_expenses, 0)
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  (SELECT value FROM tmp_metrics WHERE label = 'baseline_active_expenses'),
  'captures baseline active_expenses before linking'
);

SELECT is(
  public.shopping_list_link_items_to_expense_for_user(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT expense_id FROM tmp_expenses WHERE label = 'member_expense'),
    ARRAY[(SELECT item_id FROM tmp_items WHERE label = 'milk')]
  ),
  1,
  'first link archives and links one item'
);

SELECT is(
  (
    SELECT COALESCE(active_expenses, 0)
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  (SELECT value + 1 FROM tmp_metrics WHERE label = 'baseline_active_expenses'),
  'first link to an expense increments active_expenses once'
);

SELECT is(
  public.shopping_list_link_items_to_expense_for_user(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT expense_id FROM tmp_expenses WHERE label = 'member_expense'),
    ARRAY[(SELECT item_id FROM tmp_items WHERE label = 'bread')]
  ),
  1,
  'second link to same expense links remaining item'
);

SELECT is(
  (
    SELECT COALESCE(active_expenses, 0)
    FROM public.home_usage_counters
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  (SELECT value + 1 FROM tmp_metrics WHERE label = 'baseline_active_expenses'),
  'second link to same expense does not increment active_expenses again'
);

SELECT is(
  (
    SELECT item_count
    FROM public.shopping_list_prepare_expense_for_user((SELECT home_id FROM tmp_homes WHERE label = 'primary'))
  ),
  NULL,
  'prepare_expense returns zero rows after all items linked'
);

-- Archived rows are no longer updatable by item id.
SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_update_item(
      (SELECT item_id FROM tmp_items WHERE label = 'milk'),
      'Milk Updated',
      NULL,
      NULL,
      NULL,
      NULL,
      FALSE
    ); $$,
  'item_not_found',
  'cannot update archived item'
);

SELECT is(
  public.shopping_list_archive_items_for_user(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    ARRAY[(SELECT item_id FROM tmp_items WHERE label = 'milk')]
  ),
  0,
  'archive RPC ignores already archived rows'
);

SELECT * FROM finish();
ROLLBACK;
