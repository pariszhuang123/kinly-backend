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

CREATE TEMP TABLE tmp_services (
  label text PRIMARY KEY,
  service_id uuid,
  reminder_id uuid
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
  ('00000000-0000-4000-8000-000000000861', 'avatars/house-directory-1.png', 'animal', 'House Directory Avatar 1'),
  ('00000000-0000-4000-8000-000000000862', 'avatars/house-directory-2.png', 'animal', 'House Directory Avatar 2'),
  ('00000000-0000-4000-8000-000000000863', 'avatars/house-directory-3.png', 'animal', 'House Directory Avatar 3'),
  ('00000000-0000-4000-8000-000000000864', 'avatars/house-directory-4.png', 'animal', 'House Directory Avatar 4')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner', '20000000-0000-4000-9000-000000000201', 'owner-house-directory@example.com'),
  ('member', '20000000-0000-4000-9000-000000000202', 'member-house-directory@example.com'),
  ('outsider', '20000000-0000-4000-9000-000000000203', 'outsider-house-directory@example.com'),
  ('owner_two', '20000000-0000-4000-9000-000000000204', 'owner-two-house-directory@example.com');

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

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_two'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'secondary', (payload->'home'->>'id')::uuid
FROM res;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.get_home_directory_wifi((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->>'ok')::boolean,
  'member can read wifi block'
);

SELECT ok(
  (public.get_home_directory_wifi((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'wifi') IS NULL,
  'wifi block is null before wifi is configured'
);

SELECT ok(
  (public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->>'ok')::boolean,
  'member can read directory content'
);

SELECT ok(
  (public.get_home_directory_member_cards()->>'ok')::boolean,
  'member can read house directory member cards'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_member_cards()->'members'),
  1,
  'member cards include the caller even when no member has personal directory content'
);

SELECT is(
  public.get_home_directory_member_cards()->'members'->0->>'user_id',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  'caller sees their own member card before adding personal directory content'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'services'),
  0,
  'no active services initially'
);

SELECT is(
  jsonb_array_length(public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'due_reminders'),
  0,
  'no due reminders initially'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_wifi(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       'Kinly Wifi',
       'secret-pass'
     ); $$,
  'FORBIDDEN_OWNER_ONLY',
  'member cannot upsert wifi'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_service(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'rent',
       NULL,
       'Landlord Alpha',
       NULL,
       NULL,
       CURRENT_DATE,
       CURRENT_DATE,
       NULL,
       NULL,
       NULL
     ); $$,
  'FORBIDDEN_OWNER_ONLY',
  'member cannot upsert service'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_note(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'Move-in details',
       'Parking is behind the house.',
       'general',
       NULL,
       NULL
     ); $$,
  'FORBIDDEN_OWNER_ONLY',
  'member cannot upsert note'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.dismiss_home_directory_reminder(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       '00000000-0000-4000-8000-000000009999'::uuid
     ); $$,
  'FORBIDDEN_OWNER_ONLY',
  'member cannot dismiss reminder'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.get_home_directory_wifi((SELECT home_id FROM tmp_homes WHERE label = 'primary')); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot read wifi'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.get_home_directory_member_cards(); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot read member cards'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary')); $$,
  'NOT_HOME_MEMBER',
  'outsider cannot list due reminders'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_wifi(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       'Kinly Wifi',
       '   '
     ); $$,
  'HOUSE_DIRECTORY_INVALID_INPUT',
  'whitespace-only wifi password is rejected'
);

SELECT ok(
  (public.upsert_home_directory_wifi(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Kinly:Home;Wifi',
    'pa:ss;word'
  )->>'ok')::boolean,
  'owner can upsert wifi'
);

SELECT ok(
  (
    public.upsert_home_directory_wifi(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      'Kinly:Home;Wifi',
      'pa:ss;word'
    )->'wifi'->>'qr_payload'
  ) = 'WIFI:T:WPA;S:Kinly\\:Home\\;Wifi;P:pa\\:ss\\;word;;',
  'wifi upsert returns escaped QR payload'
);

SELECT ok(
  (public.upsert_member_directory_bank_account(
    'Owner Housemate',
    '11-2222-3333333-44'
  )->>'ok')::boolean,
  'owner can add personal directory content used by member cards'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  NOT ((public.get_home_directory_wifi((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'wifi') ? 'password'),
  'wifi read omits raw password'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_member_cards()->'members'),
  2,
  'member cards include caller and owner after owner adds personal directory content'
);

SELECT is(
  public.get_home_directory_member_cards()->'members'->0->>'user_id',
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  'owner is returned in member cards when they have content'
);

SELECT ok(
  (public.get_home_directory_member_cards()->'members'->0->>'is_owner')::boolean,
  'owner card is flagged as owner'
);

SELECT ok(
  nullif(public.get_home_directory_member_cards()->'members'->0->>'username', '') IS NOT NULL,
  'member card includes username'
);

SELECT ok(
  nullif(public.get_home_directory_member_cards()->'members'->0->>'avatar_storage_path', '') IS NOT NULL,
  'member card includes avatar storage path'
);

SELECT ok(
  (public.create_member_directory_note(
    'allergy',
    'Cats',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
  )->>'ok')::boolean,
  'member can add personal directory content used by member cards'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_member_cards()->'members'),
  2,
  'member cards still return two members once caller also has personal directory content'
);

SELECT is(
  public.get_home_directory_member_cards()->'members'->1->>'user_id',
  (SELECT user_id::text FROM tmp_users WHERE label = 'member'),
  'non-owner member appears after owner in member cards ordering'
);

SELECT ok(
  NOT (public.get_home_directory_member_cards()->'members'->1->>'is_owner')::boolean,
  'non-owner member card is not flagged as owner'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_service(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'rent',
       NULL,
       'Landlord Missing Term',
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL,
       NULL
     ); $$,
  'HOUSE_DIRECTORY_RENT_TERM_REQUIRED',
  'rent service requires term dates'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_service(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'internet',
       NULL,
       'ISP Pair Error',
       NULL,
       NULL,
       CURRENT_DATE,
       CURRENT_DATE + 30,
       1,
       NULL,
       NULL
     ); $$,
  'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
  'reminder offset pair must be complete'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_service(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'internet',
       NULL,
       'ISP Range Error',
       NULL,
       NULL,
       CURRENT_DATE,
       CURRENT_DATE + 5,
       2,
       'month',
       NULL
     ); $$,
  'HOUSE_DIRECTORY_INVALID_REMINDER_OFFSET',
  'out-of-range reminder offset is rejected'
);

WITH rent_due AS (
  SELECT public.upsert_home_directory_service(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    NULL,
    'rent',
    NULL,
    'Landlord Alpha',
    'ACC-100',
    'https://example.com/rent',
    ((now() AT TIME ZONE 'UTC')::date - 120),
    ((now() AT TIME ZONE 'UTC')::date + 20),
    1,
    'month',
    'Primary rent'
  ) AS payload
)
INSERT INTO tmp_services (label, service_id, reminder_id)
SELECT
  'rent_due',
  (payload->'service'->>'id')::uuid,
  (payload->'reminder'->>'id')::uuid
FROM rent_due;

SELECT ok(
  (
    SELECT (payload->'reminder'->>'status') = 'active'
    FROM (
      SELECT public.upsert_home_directory_service(
        (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
        (SELECT service_id FROM tmp_services WHERE label = 'rent_due'),
        'rent',
        NULL,
        'Landlord Alpha',
        'ACC-100',
        'https://example.com/rent',
        ((now() AT TIME ZONE 'UTC')::date - 120),
        ((now() AT TIME ZONE 'UTC')::date + 20),
        1,
        'month',
        'Primary rent'
      ) AS payload
    ) q
  ),
  'service upsert returns active reminder payload when due date is valid'
);

WITH future_service AS (
  SELECT public.upsert_home_directory_service(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    NULL,
    'water',
    NULL,
    'Water Future',
    NULL,
    NULL,
    ((now() AT TIME ZONE 'UTC')::date),
    ((now() AT TIME ZONE 'UTC')::date + 40),
    5,
    'day',
    NULL
  ) AS payload
)
INSERT INTO tmp_services (label, service_id, reminder_id)
SELECT
  'future_due',
  (payload->'service'->>'id')::uuid,
  (payload->'reminder'->>'id')::uuid
FROM future_service;

SELECT ok(
  (
    SELECT public._house_directory_today_utc() < (r.due_at)
    FROM public.home_directory_service_reminders r
    WHERE r.id = (SELECT reminder_id FROM tmp_services WHERE label = 'future_due')
  ),
  'future reminder row exists but is not yet due'
);

WITH internet_service AS (
  SELECT public.upsert_home_directory_service(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    NULL,
    'internet',
    NULL,
    'ISP One',
    NULL,
    'https://example.com/isp',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
  ) AS payload
)
INSERT INTO tmp_services (label, service_id, reminder_id)
SELECT
  'internet_primary',
  (payload->'service'->>'id')::uuid,
  NULL
FROM internet_service;

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_service(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'internet',
       NULL,
       'ISP Two',
       NULL,
       'https://example.com/isp2',
       NULL,
       NULL,
       NULL,
       NULL,
       NULL
     ); $$,
  'HOUSE_DIRECTORY_ACTIVE_SERVICE_CONFLICT',
  'only one active internet service is allowed per home'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_note(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       '  ',
       NULL,
       'general',
       NULL,
       NULL
     ); $$,
  'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
  'note requires title'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_note(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'Alarm',
       NULL,
       'checklist',
       NULL,
       NULL
     ); $$,
  'HOUSE_DIRECTORY_NOTE_INVALID_TYPE',
  'note_type must be general or tutorial'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.upsert_home_directory_note(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       NULL,
       'Alarm',
       'Use the side panel.',
       'general',
       'ftp://example.com/alarm',
       NULL
     ); $$,
  'HOUSE_DIRECTORY_NOTE_INVALID_URL',
  'note reference_url must be http or https when present'
);

WITH note_z AS (
  SELECT public.upsert_home_directory_note(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    NULL,
    'Z Utilities',
    NULL,
    'general',
    'https://example.com/utilities',
    NULL
  ) AS payload
)
INSERT INTO tmp_notes (label, note_id)
SELECT 'z_note', (payload->'note'->>'id')::uuid
FROM note_z;

WITH note_a AS (
  SELECT public.upsert_home_directory_note(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    NULL,
    'A Bond Info',
    'Deposit receipt is filed in the entry drawer.',
    'tutorial',
    NULL,
    'households/primary/notes/bond-info.jpg'
  ) AS payload
)
INSERT INTO tmp_notes (label, note_id)
SELECT 'a_note', (payload->'note'->>'id')::uuid
FROM note_a;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  jsonb_array_length(public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'due_reminders'),
  1,
  'member sees one due reminder before acknowledgement'
);

SELECT ok(
  (public.acknowledge_home_directory_reminder(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT reminder_id FROM tmp_services WHERE label = 'rent_due')
  )->>'ok')::boolean,
  'member can acknowledge due reminder'
);

SELECT is(
  jsonb_array_length(public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'due_reminders'),
  0,
  'acknowledgement hides due reminder for that member'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.acknowledge_home_directory_reminder(
       (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
       (SELECT reminder_id FROM tmp_services WHERE label = 'future_due')
     ); $$,
  'HOUSE_DIRECTORY_REMINDER_NOT_ACTIONABLE',
  'future reminder is not actionable for acknowledgement'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  jsonb_array_length(public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'due_reminders'),
  1,
  'owner still sees due reminder before dismissal'
);

SELECT ok(
  (
    public.dismiss_home_directory_reminder(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT reminder_id FROM tmp_services WHERE label = 'rent_due')
    )->>'ok'
  )::boolean,
  'owner can dismiss due reminder'
);

SELECT is(
  jsonb_array_length(public.list_due_home_directory_reminders((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'due_reminders'),
  0,
  'dismissed reminder is excluded from owner due reminder list'
);

SELECT ok(
  (
    public.dismiss_home_directory_reminder(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT reminder_id FROM tmp_services WHERE label = 'rent_due')
    )->>'already_dismissed'
  )::boolean,
  'repeat dismiss returns already_dismissed=true'
);

SELECT ok(
  (
    public.archive_home_directory_service(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT service_id FROM tmp_services WHERE label = 'internet_primary')
    )->>'ok'
  )::boolean,
  'owner can archive active service'
);

SELECT ok(
  (
    public.archive_home_directory_service(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT service_id FROM tmp_services WHERE label = 'internet_primary')
    )->>'already_archived'
  )::boolean,
  'repeat archive returns already_archived=true for service'
);

SELECT is(
  public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'services'->0->>'provider_name',
  'Landlord Alpha',
  'services are ordered by provider name'
);

SELECT is(
  public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'notes'->0->>'title',
  'Z Utilities',
  'general notes are ordered by title'
);

SELECT is(
  public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'tutorials'->0->>'title',
  'A Bond Info',
  'tutorial notes are split into a separate array'
);

SELECT ok(
  (
    public.archive_home_directory_note(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT note_id FROM tmp_notes WHERE label = 'a_note')
    )->>'ok'
  )::boolean,
  'owner can archive note'
);

SELECT ok(
  (
    public.archive_home_directory_note(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT note_id FROM tmp_notes WHERE label = 'a_note')
    )->>'already_archived'
  )::boolean,
  'repeat archive returns already_archived=true for note'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'notes'),
  1,
  'archived note is excluded from general note reads'
);

SELECT is(
  jsonb_array_length(public.get_home_directory_content((SELECT home_id FROM tmp_homes WHERE label = 'primary'))->'tutorials'),
  0,
  'archived note is excluded from tutorial reads'
);

SELECT ok(
  (
    SELECT status = 'retired'
    FROM public.home_directory_service_reminders
    WHERE id = (SELECT reminder_id FROM tmp_services WHERE label = 'future_due')
  ) IS NOT TRUE,
  'future active reminder remains active before service archive'
);

SELECT ok(
  (
    public.archive_home_directory_service(
      (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
      (SELECT service_id FROM tmp_services WHERE label = 'future_due')
    )->>'ok'
  )::boolean,
  'owner can archive future-due service'
);

SELECT is(
  (
    SELECT status
    FROM public.home_directory_service_reminders
    WHERE id = (SELECT reminder_id FROM tmp_services WHERE label = 'future_due')
  ),
  'retired',
  'archiving a service retires its reminder row'
);

SELECT finish();
ROLLBACK;
