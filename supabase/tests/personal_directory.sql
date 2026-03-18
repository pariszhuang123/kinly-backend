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

CREATE TEMP TABLE tmp_notes (
  label text PRIMARY KEY,
  note_id uuid
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
  ('00000000-0000-4000-8000-000000000881', 'avatars/personal-directory-1.png', 'animal', 'Personal Directory Avatar 1'),
  ('00000000-0000-4000-8000-000000000882', 'avatars/personal-directory-2.png', 'animal', 'Personal Directory Avatar 2'),
  ('00000000-0000-4000-8000-000000000883', 'avatars/personal-directory-3.png', 'animal', 'Personal Directory Avatar 3'),
  ('00000000-0000-4000-8000-000000000884', 'avatars/personal-directory-4.png', 'animal', 'Personal Directory Avatar 4')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner', '30000000-0000-4000-9000-000000000301', 'owner-personal-directory@example.com'),
  ('member', '30000000-0000-4000-9000-000000000302', 'member-personal-directory@example.com'),
  ('outsider', '30000000-0000-4000-9000-000000000303', 'outsider-personal-directory@example.com'),
  ('solo', '30000000-0000-4000-9000-000000000304', 'solo-personal-directory@example.com');

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

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid
FROM res;

INSERT INTO tmp_invites (label, code)
SELECT 'primary', i.code::text
FROM public.invites i
WHERE i.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND i.revoked_at IS NULL
LIMIT 1;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invites WHERE label = 'primary'));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'secondary', (payload->'home'->>'id')::uuid
FROM res;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'solo'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.get_member_directory_bank_account()->>'ok')::boolean,
  'user with no home can read own bank account block'
);

SELECT ok(
  NOT (public.get_member_directory_bank_account()->>'has_bank_account')::boolean,
  'own bank account is absent before creation'
);

SELECT ok(
  public.get_member_directory_bank_account()->'bank_account' IS NULL,
  'own bank account is null before creation'
);

SELECT is(
  jsonb_array_length(public.get_member_directory_notes()->'notes'),
  0,
  'user with no home can read own notes'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_member_directory_bank_account('   ', '02-1234'); $$,
  'MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS',
  'blank account holder rejected'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_member_directory_bank_account('Solo User', '   '); $$,
  'MEMBER_DIRECTORY_BANK_ACCOUNT_REQUIRED_FIELDS',
  'blank account number rejected'
);

SELECT ok(
  (public.upsert_member_directory_bank_account('Solo User', '02-1234-0123456-00')->>'ok')::boolean,
  'user with no home can upsert own bank account'
);

SELECT is(
  public.get_member_directory_bank_account()->'bank_account'->>'account_number',
  '02-1234-0123456-00',
  'own bank account read returns stored account number'
);

SELECT ok(
  (public.create_member_directory_note('allergy', 'Peanuts', NULL, NULL, NULL, NULL, NULL)->>'ok')::boolean,
  'user with no home can create allergy note without a photo'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.get_member_bank_account((SELECT user_id FROM tmp_users WHERE label = 'owner')); $$,
  'NOT_HOME_MEMBER',
  'user with no shared home cannot read another member bank account'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.upsert_member_directory_bank_account('Owner Person', '11-2222-3333333-44')->>'ok')::boolean,
  'owner can create own bank account'
);

SELECT is(
  public.upsert_member_directory_bank_account('Owner Legal Name', '11-2222-3333333-55')->'bank_account'->>'account_holder_name',
  'Owner Legal Name',
  'bank account upsert updates in place'
);

SELECT ok(
  (public.create_member_directory_note('emergency_contact', NULL, NULL, 'Mum', '0211234567', NULL, NULL)->>'ok')::boolean,
  'owner can create emergency contact note without details'
);

INSERT INTO tmp_notes (label, note_id)
SELECT
  'owner_emergency',
  (public.get_member_directory_notes()->'notes'->0->>'id')::uuid;

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('emergency_contact', NULL, NULL, 'Dad', '0219990000', NULL, NULL); $$,
  'MEMBER_DIRECTORY_NOTE_TYPE_CONFLICT',
  'second active emergency contact is rejected'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('allergy', NULL, NULL, NULL, NULL, NULL, NULL); $$,
  'MEMBER_DIRECTORY_ALLERGY_LABEL_REQUIRED',
  'allergy note requires label'
);

SELECT ok(
  (public.create_member_directory_note('allergy', 'Peanuts', NULL, NULL, NULL, NULL, NULL)->>'ok')::boolean,
  'owner can create allergy note with label only'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('allergy', 'Peanuts', NULL, NULL, NULL, 'EpiPen in top drawer.', NULL); $$,
  'MEMBER_DIRECTORY_DETAILS_FORBIDDEN',
  'allergy details are forbidden'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('other', NULL, NULL, NULL, NULL, 'Spare key in lockbox.', NULL); $$,
  'MEMBER_DIRECTORY_OTHER_TITLE_REQUIRED',
  'other note requires custom title'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('allergy', 'Peanuts', 'Wrong', NULL, NULL, NULL, NULL); $$,
  'MEMBER_DIRECTORY_OTHER_TITLE_FORBIDDEN',
  'custom title forbidden for non-other note'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('allergy', 'Peanuts', NULL, 'Not allowed', '021', NULL, NULL); $$,
  'MEMBER_DIRECTORY_CONTACT_FIELDS_FORBIDDEN',
  'contact fields forbidden for non emergency note'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('other', NULL, 'Parking', NULL, NULL, 'Bay 14', 'households/not-allowed.jpg'); $$,
  'MEMBER_DIRECTORY_NOTE_INVALID_PHOTO_PATH',
  'invalid member note photo path rejected'
);

SELECT ok(
  (
    public.create_member_directory_note(
      'other',
      NULL,
      'Parking spot',
      NULL,
      NULL,
      'Bay 14, level B2',
      'house_directory/'
      || (SELECT home_id::text FROM tmp_homes WHERE label = 'primary')
      || '/member_directory/'
      || (SELECT user_id::text FROM tmp_users WHERE label = 'owner')
      || '/parking.jpg'
    )->>'ok'
  )::boolean,
  'owner can create other note with valid photo path'
);

INSERT INTO tmp_notes (label, note_id)
SELECT
  'owner_allergy',
  (
    SELECT (elem->>'id')::uuid
    FROM jsonb_array_elements(public.get_member_directory_notes()->'notes') AS elem
    WHERE elem->>'note_type' = 'allergy'
    LIMIT 1
  );

INSERT INTO tmp_notes (label, note_id)
SELECT
  'owner_other',
  (
    SELECT (elem->>'id')::uuid
    FROM jsonb_array_elements(public.get_member_directory_notes()->'notes') AS elem
    WHERE elem->>'note_type' = 'other'
    LIMIT 1
  );

SELECT ok(
  (
    public.update_member_directory_note(
      (SELECT note_id FROM tmp_notes WHERE label = 'owner_other'),
      NULL,
      'Parking spot updated',
      NULL,
      NULL,
      'Bay 27, level B1',
      'house_directory/'
      || (SELECT home_id::text FROM tmp_homes WHERE label = 'primary')
      || '/member_directory/'
      || (SELECT user_id::text FROM tmp_users WHERE label = 'owner')
      || '/parking-updated.jpg'
    )->>'ok'
  )::boolean,
  'owner can update other note in place'
);

SELECT is(
  public.update_member_directory_note(
    (SELECT note_id FROM tmp_notes WHERE label = 'owner_other'),
    NULL,
    'Parking title final',
    NULL,
    NULL,
    'Bay 28, level B1',
    NULL
  )->'note'->>'custom_title',
  'Parking title final',
  'other note update returns new custom title'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.update_member_directory_note(
       (SELECT note_id FROM tmp_notes WHERE label = 'owner_allergy'),
       NULL,
       NULL,
       NULL,
       NULL,
       'Updated details',
       NULL
     ); $$,
  'MEMBER_DIRECTORY_DETAILS_FORBIDDEN',
  'allergy note update rejects details'
);

SELECT is(
  public.get_member_directory_notes()->'notes'->0->>'note_type',
  'emergency_contact',
  'notes are ordered with emergency contact first'
);

SELECT is(
  public.get_member_directory_notes()->'notes'->1->>'note_type',
  'allergy',
  'notes are ordered with allergy second'
);

SELECT is(
  public.get_member_directory_notes()->'notes'->1->>'label',
  'Peanuts',
  'allergy note read returns label'
);

SELECT is(
  public.get_member_directory_notes()->'notes'->2->>'custom_title',
  'Parking title final',
  'other note read returns custom title'
);

SELECT is(
  jsonb_array_length(public.get_member_directory_notes()->'notes'),
  3,
  'owner sees all three active notes'
);

SELECT is(
  jsonb_array_length(public.get_member_directory_nudge()->'missing'),
  0,
  'nudge returns empty missing list when bank account exists'
);

SELECT ok(
  NOT (public.get_member_directory_nudge()->>'show')::boolean,
  'nudge is hidden when bank account exists'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.get_member_directory_notes((SELECT user_id FROM tmp_users WHERE label = 'owner'))->>'ok')::boolean,
  'member can read another shared-home member notes'
);

SELECT is(
  public.get_member_directory_notes((SELECT user_id FROM tmp_users WHERE label = 'owner'))->'notes'->0->>'contact_name',
  'Mum',
  'member sees emergency contact details for shared-home member'
);

SELECT ok(
  public.get_member_bank_account((SELECT user_id FROM tmp_users WHERE label = 'owner'))->'bank_account' ? 'account_number',
  'member can read shared-home member bank account for payments'
);

SELECT ok(
  (public.get_member_directory_nudge()->>'show')::boolean,
  'member with no bank account sees member directory nudge'
);

SELECT is(
  jsonb_array_length(public.get_member_directory_nudge()->'missing'),
  1,
  'nudge lists only missing bank account'
);

SELECT is(
  public.get_member_directory_nudge()->'missing'->>0,
  'bank_account',
  'nudge missing entry is bank_account'
);

SELECT ok(
  (public.dismiss_member_directory_nudge()->>'ok')::boolean,
  'member can dismiss nudge'
);

SELECT ok(
  (public.dismiss_member_directory_nudge()->>'already_dismissed')::boolean,
  'nudge dismiss is idempotent'
);

SELECT ok(
  NOT (public.get_member_directory_nudge()->>'show')::boolean,
  'dismissed nudge stays hidden in same home'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.get_member_directory_notes((SELECT user_id FROM tmp_users WHERE label = 'owner')); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot read another user notes'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.get_member_bank_account((SELECT user_id FROM tmp_users WHERE label = 'owner')); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot read another user bank account'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.archive_member_directory_note((SELECT note_id FROM tmp_notes WHERE label = 'owner_other')); $$,
  'MEMBER_DIRECTORY_NOTE_NOT_FOUND',
  'member cannot archive another user note'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.archive_member_directory_note((SELECT note_id FROM tmp_notes WHERE label = 'owner_other'))->>'ok')::boolean,
  'owner can archive own note'
);

SELECT ok(
  (public.archive_member_directory_note((SELECT note_id FROM tmp_notes WHERE label = 'owner_other'))->>'already_archived')::boolean,
  'archive note is idempotent'
);

SELECT is(
  jsonb_array_length(public.get_member_directory_notes()->'notes'),
  2,
  'archived notes are excluded from reads'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'solo'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  public.get_member_bank_account((SELECT user_id FROM tmp_users WHERE label = 'solo'))->'bank_account' ? 'account_number',
  'get_member_bank_account allows own user id without home membership'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.create_member_directory_note('invalid_type', NULL, NULL, NULL, NULL, 'Whatever', NULL); $$,
  'MEMBER_DIRECTORY_INVALID_ENUM',
  'invalid note type is rejected'
);

SELECT *
FROM finish();

ROLLBACK;
