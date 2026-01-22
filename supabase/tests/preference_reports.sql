SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(36);

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE invite_codes (
  label text PRIMARY KEY,
  code  text
);

-- Ensure enough avatars exist (homes_join assigns unique avatars per home)
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000701', 'avatars/default.png', 'animal', 'Pref Reports Avatar 1'),
  ('00000000-0000-4000-8000-000000000702', 'avatars/default_2.png', 'animal', 'Pref Reports Avatar 2'),
  ('00000000-0000-4000-8000-000000000703', 'avatars/default_3.png', 'animal', 'Pref Reports Avatar 3')
ON CONFLICT (id) DO NOTHING;

-- Seed auth users
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000311', '00000000-0000-0000-0000-000000000000', 'owner-pref@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000312', '00000000-0000-0000-0000-000000000000', 'member-pref@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000313', '00000000-0000-0000-0000-000000000000', 'outsider-pref@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',  '00000000-0000-4000-8000-000000000311', 'owner-pref@example.com'),
  ('member', '00000000-0000-4000-8000-000000000312', 'member-pref@example.com'),
  ('outsider', '00000000-0000-4000-8000-000000000313', 'outsider-pref@example.com');

-- Owner creates home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);

INSERT INTO tmp_homes (label, home_id)
SELECT 'home', (payload->'home'->>'id')::uuid
FROM (SELECT public.homes_create_with_invite() AS payload) AS t;

INSERT INTO invite_codes (label, code)
SELECT 'home', (SELECT code::text FROM public.invites WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'home') AND revoked_at IS NULL LIMIT 1);

SELECT ok(
  (SELECT home_id FROM tmp_homes WHERE label = 'home') IS NOT NULL,
  'homes_create_with_invite returned a home id'
);

-- Member joins home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT public.homes_join((SELECT code FROM invite_codes WHERE label = 'home'));

-- Owner sets notification locale (region) for template resolution
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
INSERT INTO public.notification_preferences (
  user_id,
  locale,
  timezone,
  preferred_hour,
  preferred_minute,
  created_at,
  updated_at
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'en-NZ',
  'Pacific/Auckland',
  9,
  0,
  now(),
  now()
)
ON CONFLICT (user_id) DO UPDATE
SET locale = EXCLUDED.locale;

-- Template selection should resolve base locale
SELECT is(
  (public.preference_templates_get_for_user('personal_preferences_v1')->>'resolved_locale'),
  'en',
  'template resolves to base locale'
);

-- Missing locale should fall back to en
DELETE FROM public.notification_preferences
WHERE user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner');

SELECT is(
  (public.preference_templates_get_for_user('personal_preferences_v1')->>'resolved_locale'),
  'en',
  'template falls back to en when locale missing'
);

-- Unsupported locale should fall back to en
INSERT INTO public.notification_preferences (
  user_id,
  locale,
  timezone,
  preferred_hour,
  preferred_minute,
  created_at,
  updated_at
) VALUES (
  (SELECT user_id FROM tmp_users WHERE label = 'owner'),
  'xx-ZZ',
  'Pacific/Auckland',
  9,
  0,
  now(),
  now()
)
ON CONFLICT (user_id) DO UPDATE
SET locale = EXCLUDED.locale;

SELECT is(
  (public.preference_templates_get_for_user('personal_preferences_v1')->>'resolved_locale'),
  'en',
  'template falls back to en when locale unsupported'
);

-- Submit full set of responses
SELECT ok(
  (public.preference_responses_submit(
    (SELECT jsonb_object_agg(preference_id, 0) FROM public.preference_taxonomy_active_defs)
  )->>'ok')::boolean,
  'preference_responses_submit accepts full answers'
);

-- Invalid option_index (out of range) should fail
SELECT throws_like(
  $$ SELECT public.preference_responses_submit(
       (SELECT jsonb_object_agg(
         preference_id,
         CASE WHEN preference_id = 'environment_noise_tolerance' THEN 3 ELSE 0 END
       ) FROM public.preference_taxonomy_active_defs)
     ); $$,
  '%INVALID_OPTION_INDEX%',
  'preference_responses_submit rejects option_index out of range'
);

-- Invalid option_index (non-integer) should fail
SELECT throws_like(
  $$ SELECT public.preference_responses_submit(
       (SELECT jsonb_object_agg(
         preference_id,
         CASE
           WHEN preference_id = 'environment_noise_tolerance'
             THEN to_jsonb('nope'::text)
           ELSE to_jsonb(0)
         END
       ) FROM public.preference_taxonomy_active_defs)
     ); $$,
  '%INVALID_OPTION_INDEX%',
  'preference_responses_submit rejects non-integer option_index'
);

-- Missing answer set should fail
SELECT throws_like(
  $$ SELECT public.preference_responses_submit(
       (SELECT jsonb_object_agg(preference_id, 0)
        FROM public.preference_taxonomy_active_defs
        WHERE preference_id <> 'environment_noise_tolerance')
     ); $$,
  '%INCOMPLETE_ANSWERS%',
  'preference_responses_submit requires all preference ids'
);

-- Generate report with region locale; should normalize to base
SELECT ok(
  (public.preference_reports_generate('personal_preferences_v1', 'en-NZ', false)->>'ok')::boolean,
  'preference_reports_generate succeeded'
);

-- Invalid template key format should fail
SELECT throws_like(
  $$ SELECT public.preference_reports_generate('bad key', 'en-NZ', false); $$,
  '%INVALID_TEMPLATE_KEY%',
  'preference_reports_generate rejects invalid template key'
);

-- Invalid locale format should fail
SELECT throws_like(
  $$ SELECT public.preference_reports_generate('personal_preferences_v1', 'en-zz', false); $$,
  '%INVALID_LOCALE%',
  'preference_reports_generate rejects malformed locale'
);

-- Invalid locale should fail
SELECT throws_like(
  $$ SELECT public.preference_reports_generate('personal_preferences_v1', 'xx-ZZ', false); $$,
  '%INVALID_LOCALE%',
  'preference_reports_generate rejects invalid locale'
);

SELECT is(
  (SELECT locale FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1),
  'en',
  'report locale stored as base locale'
);

-- Generate again without force should not create a new report row
SELECT ok(
  (SELECT count(*) FROM public.preference_reports
   WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
     AND template_key = 'personal_preferences_v1'
     AND locale = 'en') = 1,
  'preference_reports_generate reuses existing row'
);

-- Edit a section
SELECT ok(
  (public.preference_reports_edit_section_text('personal_preferences_v1', 'en-NZ', 'environment', 'Custom env text', NULL)->>'ok')::boolean,
  'preference_reports_edit_section_text succeeded'
);

-- Invalid section key should fail
SELECT throws_like(
  $$ SELECT public.preference_reports_edit_section_text(
       'personal_preferences_v1',
       'en-NZ',
       'unknown_section',
       'Bad text',
       NULL
     ); $$,
  '%SECTION_NOT_FOUND_OR_DUPLICATE%',
  'preference_reports_edit_section_text rejects unknown section'
);

-- Non-owner cannot edit another user's report
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT throws_like(
  $$ SELECT public.preference_reports_edit_section_text(
       'personal_preferences_v1',
       'en-NZ',
       'environment',
       'Should not edit',
       NULL
     ); $$,
  '%No published preference report found to edit%',
  'preference_reports_edit_section_text rejects non-owner edits'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);

-- Template validation failures (service role)
CREATE TEMP TABLE tmp_template_errors (
  label text PRIMARY KEY,
  message text
);
GRANT INSERT ON TABLE tmp_template_errors TO service_role;

SET LOCAL ROLE service_role;
SET LOCAL search_path = public, auth, extensions;

DO $$
DECLARE
  v_first_pref_id text;
  v_prefs jsonb;
BEGIN
  BEGIN
    INSERT INTO public.preference_report_templates (template_key, locale, body)
    VALUES ('bad_schema', 'en', jsonb_build_object('summary', jsonb_build_object('title','t','subtitle','s'), 'preferences', jsonb_build_array('bad')));
    INSERT INTO tmp_template_errors (label, message) VALUES ('bad_schema', NULL);
  EXCEPTION WHEN others THEN
    INSERT INTO tmp_template_errors (label, message) VALUES ('bad_schema', SQLERRM);
  END;

  BEGIN
    SELECT d.preference_id
      INTO v_first_pref_id
    FROM public.preference_taxonomy_defs d
    JOIN public.preference_taxonomy t USING (preference_id)
    WHERE t.is_active = true
    ORDER BY d.preference_id
    LIMIT 1;

    SELECT jsonb_object_agg(
      d.preference_id,
      jsonb_build_array(
        jsonb_build_object('value_key', d.value_keys[1], 'title','t','text','x'),
        jsonb_build_object('value_key', d.value_keys[2], 'title','t','text','x'),
        jsonb_build_object('value_key', d.value_keys[3], 'title','t','text','x')
      )
    )
    INTO v_prefs
    FROM public.preference_taxonomy_defs d
    JOIN public.preference_taxonomy t USING (preference_id)
    WHERE t.is_active = true;

    v_prefs := jsonb_set(
      v_prefs,
      ARRAY[v_first_pref_id, '0', 'value_key'],
      '"wrong"',
      false
    );

    INSERT INTO public.preference_report_templates (template_key, locale, body)
    VALUES (
      'bad_value_key',
      'en',
      jsonb_build_object(
        'summary', jsonb_build_object('title','t','subtitle','s'),
        'sections', jsonb_build_array(),
        'preferences', v_prefs
      )
    );
    INSERT INTO tmp_template_errors (label, message) VALUES ('bad_value_key', NULL);
  EXCEPTION WHEN others THEN
    INSERT INTO tmp_template_errors (label, message) VALUES ('bad_value_key', SQLERRM);
  END;
END $$;

-- Remove ES template so locale mismatch fails
DELETE FROM public.preference_report_templates
WHERE template_key = 'personal_preferences_v1'
  AND locale = 'es';

RESET ROLE;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT ok(
  (SELECT message FROM tmp_template_errors WHERE label = 'bad_schema') LIKE '%INVALID_TEMPLATE_SCHEMA%',
  'template validation rejects non-object preferences'
);

SELECT ok(
  (SELECT message FROM tmp_template_errors WHERE label = 'bad_value_key') LIKE '%INVALID_TEMPLATE_VALUE_KEYS%',
  'template validation rejects mismatched value_key'
);

-- Locale with no matching template should fail
SELECT throws_like(
  $$ SELECT public.preference_reports_generate('personal_preferences_v1', 'es-ES', false); $$,
  '%TEMPLATE_NOT_FOUND%',
  'preference_reports_generate rejects locale with no matching template'
);

SELECT is(
  (SELECT (published_content->'sections'->0->>'text') FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1),
  'Custom env text',
  'section text updated in published_content'
);

-- Change responses -> mark out_of_date
SELECT ok(
  (public.preference_responses_submit(
    (SELECT jsonb_object_agg(
      preference_id,
      CASE WHEN preference_id = 'environment_noise_tolerance' THEN 1 ELSE 0 END
    ) FROM public.preference_taxonomy_active_defs)
  )->>'ok')::boolean,
  'preference_responses_submit accepts updated answers'
);

SELECT is(
  (SELECT status FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1),
  'out_of_date',
  'report marked out_of_date after response change'
);

-- Out-of-date reports cannot be edited
SELECT throws_like(
  $$ SELECT public.preference_reports_edit_section_text(
       'personal_preferences_v1',
       'en-NZ',
       'environment',
       'Blocked edit',
       NULL
     ); $$,
  '%No published preference report found to edit%',
  'preference_reports_edit_section_text rejects edits while out_of_date'
);

-- Out-of-date reports cannot be acknowledged
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);

SELECT throws_like(
  $$ SELECT public.preference_reports_acknowledge(
       (SELECT id FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1)
     ); $$,
  '%REPORT_NOT_PUBLISHED%',
  'preference_reports_acknowledge rejects out_of_date reports'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);

-- Regenerate without force should update generated_content and preserve published_content
SELECT ok(
  (public.preference_reports_generate('personal_preferences_v1', 'en-NZ', false)->>'ok')::boolean,
  'preference_reports_generate succeeded for out_of_date report'
);

SELECT is(
  (SELECT (published_content->'sections'->0->>'text') FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1),
  'Custom env text',
  'edited published_content preserved on regeneration'
);

-- Subject can fetch report for home
SELECT ok(
  (public.preference_reports_get_for_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'home'),
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    'personal_preferences_v1',
    'en-NZ'
  )->>'found')::boolean,
  'preference_reports_get_for_home returns report for subject'
);

-- Member can fetch report for home
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);

SELECT ok(
  (public.preference_reports_get_for_home(
    (SELECT home_id FROM tmp_homes WHERE label = 'home'),
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    'personal_preferences_v1',
    'en-NZ'
  )->>'found')::boolean,
  'preference_reports_get_for_home returns report'
);

SELECT ok(
  jsonb_array_length(
    public.preference_reports_list_for_home(
      (SELECT home_id FROM tmp_homes WHERE label = 'home'),
      'personal_preferences_v1',
      'en-NZ'
    )->'items'
  ) >= 1,
  'preference_reports_list_for_home returns items'
);

-- Outsider cannot access home reports
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);

SELECT throws_like(
  $$ SELECT public.preference_reports_get_for_home(
       (SELECT home_id FROM tmp_homes WHERE label = 'home'),
       (SELECT user_id FROM tmp_users WHERE label = 'owner'),
       'personal_preferences_v1',
       'en-NZ'
     ); $$,
  '%NOT_HOME_MEMBER%',
  'outsider cannot get report for home'
);

SELECT throws_like(
  $$ SELECT public.preference_reports_list_for_home(
       (SELECT home_id FROM tmp_homes WHERE label = 'home'),
       'personal_preferences_v1',
       'en-NZ'
     ); $$,
  '%NOT_HOME_MEMBER%',
  'outsider cannot list reports for home'
);

-- Acknowledge report
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);

SELECT ok(
  (public.preference_reports_acknowledge(
    (SELECT id FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1)
  )->>'ok')::boolean,
  'preference_reports_acknowledge succeeds'
);

-- Acknowledge is idempotent
SELECT ok(
  (public.preference_reports_acknowledge(
    (SELECT id FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1)
  )->>'ok')::boolean,
  'preference_reports_acknowledge is idempotent'
);

-- Outsider cannot acknowledge
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);

SELECT throws_like(
  $$ SELECT public.preference_reports_acknowledge(
       (SELECT id FROM public.preference_reports WHERE subject_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner') LIMIT 1)
     ); $$,
  '%NOT_IN_SAME_HOME%',
  'outsider cannot acknowledge report'
);

SELECT is(
  (SELECT count(*) FROM public.preference_report_acknowledgements WHERE viewer_user_id = (SELECT user_id FROM tmp_users WHERE label = 'member')),
  1::bigint,
  'acknowledgement recorded'
);

SELECT * FROM finish();

ROLLBACK;
