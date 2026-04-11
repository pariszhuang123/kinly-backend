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

CREATE TEMP TABLE tmp_units (
  label text PRIMARY KEY,
  unit_id uuid
);

CREATE TEMP TABLE tmp_items (
  label text PRIMARY KEY,
  item_id uuid
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
  ('00000000-0000-4000-8000-000000000711', 'avatars/default.png', 'animal', 'Scope Memory 1'),
  ('00000000-0000-4000-8000-000000000712', 'avatars/default2.png', 'animal', 'Scope Memory 2'),
  ('00000000-0000-4000-8000-000000000713', 'avatars/default3.png', 'animal', 'Scope Memory 3'),
  ('00000000-0000-4000-8000-000000000714', 'avatars/default4.png', 'animal', 'Scope Memory 4')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '10000000-0000-4000-9000-000000000201', 'owner-scope@example.com'),
  ('member', '10000000-0000-4000-9000-000000000202', 'member-scope@example.com'),
  ('third',  '10000000-0000-4000-9000-000000000203', 'third-scope@example.com'),
  ('fourth', '10000000-0000-4000-9000-000000000204', 'fourth-scope@example.com');

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

DO $$
DECLARE
  v_label text;
BEGIN
  FOREACH v_label IN ARRAY ARRAY['member', 'third', 'fourth']
  LOOP
    PERFORM set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = v_label), true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    PERFORM public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));
  END LOOP;
END
$$;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT (public.home_units_get_my_context((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'personal_unit'->>'unit_type')
  ),
  'personal',
  'home_units_get_my_context returns the caller personal unit before any shared unit exists'
);

SELECT ok(
  (
    SELECT (public.home_units_get_my_context((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'active_shared_unit') IS NULL
  ),
  'home_units_get_my_context returns null active_shared_unit before shared membership exists'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_create_shared_candidates(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  3,
  'home_units_list_create_shared_candidates returns other current members before shared creation'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_joinable_shared_units(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  0,
  'home_units_list_joinable_shared_units is empty before any shared units exist'
);

WITH created AS (
  SELECT public.home_units_create_shared(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Owner + Member',
    ARRAY[
      (SELECT m.id
       FROM public.memberships m
       WHERE m.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
         AND m.user_id = (SELECT user_id FROM tmp_users WHERE label = 'member')
         AND m.valid_to IS NULL)
    ]::uuid[]
  ) AS unit_id
)
INSERT INTO tmp_units (label, unit_id)
SELECT 'couple_a', unit_id
FROM created;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'third'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH created AS (
  SELECT public.home_units_create_shared(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Third + Fourth',
    ARRAY[
      (SELECT m.id
       FROM public.memberships m
       WHERE m.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
         AND m.user_id = (SELECT user_id FROM tmp_users WHERE label = 'fourth')
         AND m.valid_to IS NULL)
    ]::uuid[]
  ) AS unit_id
)
INSERT INTO tmp_units (label, unit_id)
SELECT 'couple_b', unit_id
FROM created;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT (public.home_units_get_my_context((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'active_shared_unit'->>'unit_id')
  ),
  (SELECT unit_id::text FROM tmp_units WHERE label = 'couple_a'),
  'home_units_get_my_context returns the caller active shared unit after shared creation'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_create_shared_candidates(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  0,
  'home_units_list_create_shared_candidates returns empty when caller is already in a shared unit'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.home_units_list_joinable_shared_units(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary')
    )
  ),
  0,
  'home_units_list_joinable_shared_units returns empty when caller is already in a shared unit'
);

SELECT isnt(
  (SELECT unit_id::text FROM tmp_units WHERE label = 'couple_a'),
  (SELECT unit_id::text FROM tmp_units WHERE label = 'couple_b'),
  'two couples in the same home get distinct shared unit ids'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.shopping_list_add_item_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Eggs',
      NULL,
      NULL,
      NULL,
      'unit',
      (SELECT unit_id FROM tmp_units WHERE label = 'couple_b')
    ); $$,
  'invalid_unit_scope',
  'owner cannot add an item into another couple unit'
);

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'House Milk',
    NULL,
    NULL,
    NULL,
    'house',
    NULL
  ) AS payload
)
INSERT INTO tmp_items (label, item_id)
SELECT 'house_milk', (payload->'item'->>'id')::uuid
FROM payload;

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Farmer''s Eggs',
    NULL,
    NULL,
    NULL,
    'unit',
    (SELECT unit_id FROM tmp_units WHERE label = 'couple_a')
  ) AS payload
)
INSERT INTO tmp_items (label, item_id)
SELECT 'couple_a_eggs', (payload->'item'->>'id')::uuid
FROM payload;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'third'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Couple Bread',
    NULL,
    NULL,
    NULL,
    'unit',
    (SELECT unit_id FROM tmp_units WHERE label = 'couple_b')
  ) AS payload
)
INSERT INTO tmp_items (label, item_id)
SELECT 'couple_b_bread', (payload->'item'->>'id')::uuid
FROM payload;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT jsonb_array_length(public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'items')
  ),
  2,
  'owner default read shows house items plus their exact unit items only'
);

SELECT ok(
  (
    SELECT NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'items') item
      WHERE item->>'id' = (SELECT item_id::text FROM tmp_items WHERE label = 'couple_b_bread')
    )
  ),
  'owner does not see another couple unit item'
);

SELECT is(
  (
    SELECT jsonb_array_length(public.shopping_list_get_for_home_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'house',
      NULL
    )->'items')
  ),
  1,
  'house filter returns only house-scoped items'
);

SELECT is(
  (
    SELECT jsonb_array_length(public.shopping_list_get_for_home_v2(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'unit',
      (SELECT unit_id FROM tmp_units WHERE label = 'couple_a')
    )->'items')
  ),
  1,
  'unit filter returns only owner exact unit items'
);

SELECT public.shopping_list_update_item_v2(
  p_item_id => (SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs'),
  p_details => 'Keep chilled'
);

SELECT is(
  (
    SELECT details
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs')
  ),
  'Keep chilled',
  'shopping_list_update_item_v2 supports named arguments with omitted trailing params'
);

SELECT is(
  (
    SELECT scope_type
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs')
  ),
  'unit',
  'shopping_list_update_item_v2 keeps existing scope when p_scope_type is omitted'
);

SELECT is(
  (
    SELECT unit_id::text
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs')
  ),
  (SELECT unit_id::text FROM tmp_units WHERE label = 'couple_a'),
  'shopping_list_update_item_v2 keeps existing unit_id when unit scope params are omitted'
);

SELECT public.shopping_list_update_item_v2(
  p_item_id => (SELECT item_id FROM tmp_items WHERE label = 'house_milk'),
  p_reference_photo_path => 'households/test-home/items/house-milk-1.jpg'
);

SELECT is(
  (
    SELECT reference_photo_path
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'house_milk')
  ),
  'households/test-home/items/house-milk-1.jpg',
  'shopping_list_update_item_v2 adds a reference photo when none exists'
);

SELECT public.shopping_list_update_item_v2(
  p_item_id => (SELECT item_id FROM tmp_items WHERE label = 'house_milk'),
  p_reference_photo_path => 'households/test-home/items/house-milk-2.jpg'
);

SELECT is(
  (
    SELECT reference_photo_path
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'house_milk')
  ),
  'households/test-home/items/house-milk-1.jpg',
  'shopping_list_update_item_v2 does not replace an existing photo unless p_replace_photo=true'
);

SELECT public.shopping_list_update_item(
  (SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs'),
  NULL,
  NULL,
  NULL,
  TRUE,
  NULL,
  FALSE
);

SELECT is(
  public.shopping_list_archive_items_for_user(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    ARRAY[(SELECT item_id FROM tmp_items WHERE label = 'couple_a_eggs')]
  ),
  1,
  'owner archives completed couple A eggs item'
);

SELECT is(
  (
    SELECT scope_type
    FROM public.shopping_list_purchase_memory
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND unit_id = (SELECT unit_id FROM tmp_units WHERE label = 'couple_a')
      AND canonical_name = 'farmer egg'
  ),
  'unit',
  'purchase memory is written to the exact unit bucket using the normalised canonical name'
);

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Farmer Egg',
    NULL,
    NULL,
    NULL,
    'unit',
    (SELECT unit_id FROM tmp_units WHERE label = 'couple_a')
  ) AS payload
)
SELECT ok(
  ((payload->'purchase_memory') IS NOT NULL),
  'same couple gets purchase memory reminder across punctuation and plural variants'
)
FROM payload;

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Farmer Egg',
    NULL,
    NULL,
    NULL,
    'unit',
    (SELECT unit_id FROM tmp_units WHERE label = 'couple_a')
  ) AS payload
)
SELECT ok(
  ((payload->'purchase_memory'->'purchase_count') IS NULL),
  'purchase memory payload uses recency fields and does not expose purchase_count'
)
FROM payload;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'third'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Farmer Egg',
    NULL,
    NULL,
    NULL,
    'unit',
    (SELECT unit_id FROM tmp_units WHERE label = 'couple_b')
  ) AS payload
)
SELECT ok(
  ((payload->'purchase_memory') IS NULL),
  'different couple does not inherit purchase memory from couple A even with the same normalised name'
)
FROM payload;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.shopping_list_add_item_v2(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Farmer Egg',
    NULL,
    NULL,
    NULL,
    'house',
    NULL
  ) AS payload
)
SELECT ok(
  ((payload->'purchase_memory') IS NULL),
  'house-scoped item does not read unit-scoped memory even with the same normalised name'
)
FROM payload;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'fourth'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.home_units_leave_shared(
  (SELECT unit_id FROM tmp_units WHERE label = 'couple_b')
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM tmp_users WHERE label = 'third'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (
    SELECT scope_type
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'couple_b_bread')
  ),
  'house',
  'Open incomplete shared-unit item is reassigned to house when the shared unit collapses'
);

SELECT ok(
  (
    SELECT unit_id IS NULL
    FROM public.shopping_list_items
    WHERE id = (SELECT item_id FROM tmp_items WHERE label = 'couple_b_bread')
  ),
  'Reassigned item clears unit_id when moved to house'
);

SELECT ok(
  (
    SELECT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(public.shopping_list_get_for_home((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'items') item
      WHERE item->>'id' = (SELECT item_id::text FROM tmp_items WHERE label = 'couple_b_bread')
        AND item->>'scope_type' = 'house'
    )
  ),
  'Remaining home member still sees the rehomed item via house scope after shared-unit collapse'
);

SELECT * FROM finish();
ROLLBACK;
