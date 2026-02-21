SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(52);

CREATE TEMP TABLE tmp_users (
  label text PRIMARY KEY,
  user_id uuid
);

CREATE TEMP TABLE tmp_home (
  home_id uuid
);

CREATE TEMP TABLE tmp_invite (
  code text
);

CREATE TEMP TABLE tmp_publish_refs (
  first_home_public_id text
);

-- pgTAP deterministic stub: avoid real network/edge invocation from publish RPC.
-- Edge behavior is covered in supabase/functions/house_norms_publish_sync tests.
SELECT set_config('app.settings.supabase_url', 'http://stub.local', true);
SELECT set_config('app.settings.worker_shared_secret', 'test-secret', true);

CREATE OR REPLACE FUNCTION public._house_norms_publish_sync_call(
  p_home_public_id text,
  p_published_at timestamptz,
  p_published_version text,
  p_template_key text,
  p_locale_base text,
  p_published_content jsonb,
  p_public_url_path text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url text := nullif(current_setting('app.settings.supabase_url', true), '');
  v_secret text := nullif(current_setting('app.settings.worker_shared_secret', true), '');
BEGIN
  PERFORM public.api_assert(
    v_supabase_url IS NOT NULL,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Missing app.settings.supabase_url.',
    'P0001'
  );

  PERFORM public.api_assert(
    v_secret IS NOT NULL,
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Missing app.settings.worker_shared_secret.',
    'P0001'
  );

  -- Deterministic failure hook used by rollback-path assertion.
  PERFORM public.api_assert(
    v_secret <> 'wrong-secret-for-test',
    'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
    'Publish sync request failed.',
    'P0001'
  );
END;
$$;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000811', 'avatars/default.png', 'animal', 'House Norms Avatar 1'),
  ('00000000-0000-4000-8000-000000000812', 'avatars/default_2.png', 'animal', 'House Norms Avatar 2'),
  ('00000000-0000-4000-8000-000000000813', 'avatars/default_3.png', 'animal', 'House Norms Avatar 3')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000000411', '00000000-0000-0000-0000-000000000000', 'house-norms-owner@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000412', '00000000-0000-0000-0000-000000000000', 'house-norms-member@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000000413', '00000000-0000-0000-0000-000000000000', 'house-norms-outsider@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id) VALUES
  ('owner', '00000000-0000-4000-8000-000000000411'),
  ('member', '00000000-0000-4000-8000-000000000412'),
  ('outsider', '00000000-0000-4000-8000-000000000413');

-- Owner creates home.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
INSERT INTO tmp_home (home_id)
SELECT (payload->'home'->>'id')::uuid
FROM (SELECT public.homes_create_with_invite() AS payload) t;

INSERT INTO tmp_invite (code)
SELECT i.code::text
FROM public.invites i
WHERE i.home_id = (SELECT home_id FROM tmp_home)
  AND i.revoked_at IS NULL
LIMIT 1;

SELECT ok((SELECT home_id FROM tmp_home) IS NOT NULL, 'owner created home');

-- Member joins home.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT public.homes_join((SELECT code FROM tmp_invite));

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.house_norm_templates
    WHERE template_key = 'house_norms_v1'
      AND locale_base = 'en'
  ),
  'house norms en template seeded'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.house_norm_templates
    WHERE template_key = 'house_norms_v1'
      AND locale_base = 'es'
  ),
  'house norms es template seeded'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.house_norm_templates
    WHERE template_key = 'house_norms_v1'
      AND locale_base = 'ar'
  ),
  'house norms ar template seeded'
);

-- Generate as owner; this should update draft only.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT ok(
  (public.house_norms_generate_for_home(
    (SELECT home_id FROM tmp_home),
    'house_norms_v1',
    'es-MX',
    jsonb_build_object(
      'norms_property_context', 0,
      'norms_relationship_model', 0,
      'norms_rhythm_quiet', 1,
      'norms_shared_spaces', 2,
      'norms_guests_social', 1,
      'norms_responsibility_flow', 0,
      'norms_repair_style', 1,
      'norms_home_identity', 0
    ),
    false
  )->>'ok')::boolean,
  'owner can generate draft with es locale template'
);

SELECT is(
  (SELECT locale_base FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'es',
  'locale resolves to es template for es-MX request'
);

SELECT ok(
  (public.house_norms_generate_for_home(
    (SELECT home_id FROM tmp_home),
    'house_norms_v1',
    'fr-FR',
    jsonb_build_object(
      'norms_property_context', 0,
      'norms_relationship_model', 0,
      'norms_rhythm_quiet', 1,
      'norms_shared_spaces', 2,
      'norms_guests_social', 1,
      'norms_responsibility_flow', 0,
      'norms_repair_style', 1,
      'norms_home_identity', 0
    ),
    true
  )->>'ok')::boolean,
  'owner can force-generate draft with unsupported locale and fallback to en'
);

SELECT is(
  (SELECT locale_base FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'en',
  'locale fallback to en persisted as doc locale_base'
);

SELECT is(
  (SELECT status FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'out_of_date',
  'status is out_of_date before publish'
);

SELECT ok(
  (SELECT published_content IS NULL FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'published_content remains NULL after generate'
);

-- Member read should include draft and unpublished-change flag.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT ok(
  ((public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'has_unpublished_changes')::boolean),
  'member read shows unpublished changes'
);

SELECT ok(
  NOT COALESCE(
    (public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'show_member_review_card')::boolean,
    true
  ),
  'member review card remains hidden within 24-hour debounce window'
);

UPDATE public.house_norms
SET last_edited_at = now() - interval '25 hours'
WHERE home_id = (SELECT home_id FROM tmp_home);

SELECT ok(
  COALESCE(
    (public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'show_member_review_card')::boolean,
    false
  ),
  'member review card appears after debounce when member has not viewed'
);

SELECT ok(
  (
    public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'member_viewed_at'
  ) IS NULL,
  'member read returns null member_viewed_at before recording a view'
);

SELECT ok(
  (public.house_norms_record_view((SELECT home_id FROM tmp_home))->>'ok')::boolean,
  'member can record house norms view'
);

SELECT ok(
  (
    public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'member_viewed_at'
  ) IS NOT NULL,
  'member read includes member_viewed_at after recording a view'
);

SELECT ok(
  NOT COALESCE(
    (public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'show_member_review_card')::boolean,
    true
  ),
  'member review card hides after recording view for current norms change'
);

-- Outsider cannot read.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT throws_like(
  $$ SELECT public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en'); $$,
  '%NOT_HOME_MEMBER%',
  'outsider read denied'
);

SELECT throws_like(
  $$ SELECT public.house_norms_record_view((SELECT home_id FROM tmp_home)); $$,
  '%NOT_HOME_MEMBER%',
  'outsider cannot record member view'
);

-- Owner publish copies draft -> published.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT ok(
  NOT COALESCE(
    (public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'show_member_review_card')::boolean,
    true
  ),
  'owner never sees member review card signal'
);

SELECT ok(
  (public.house_norms_publish_for_home((SELECT home_id FROM tmp_home), 'en')->>'ok')::boolean,
  'owner can publish'
);

SELECT ok(
  (SELECT generated_content IS NOT DISTINCT FROM published_content
   FROM public.house_norms
   WHERE home_id = (SELECT home_id FROM tmp_home)),
  'publish copies generated_content into published_content'
);

SELECT is(
  (SELECT status FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'published',
  'status is published after publish'
);

SELECT is(
  (SELECT published_version FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'v000001',
  'first publish assigns published_version v000001'
);

SELECT ok(
  (SELECT home_public_id IS NOT NULL FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'first publish assigns home_public_id'
);

SELECT ok(
  (SELECT home_public_id::text ~ '^[a-z0-9]{8,32}$' FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'home_public_id format is lowercase alnum 8..32'
);

INSERT INTO tmp_publish_refs (first_home_public_id)
SELECT home_public_id::text
FROM public.house_norms
WHERE home_id = (SELECT home_id FROM tmp_home);

SELECT ok(
  COALESCE(
    (public.house_norms_get_public_by_home_public_id(
      (SELECT first_home_public_id FROM tmp_publish_refs),
      'en'
    )->>'available')::boolean,
    false
  ),
  'public read is available after publish'
);

SELECT ok(
  COALESCE(
    (public.house_norms_get_public_by_home_public_id(
      upper((SELECT first_home_public_id FROM tmp_publish_refs)),
      'en'
    )->>'available')::boolean,
    false
  ),
  'public read lookup is case-insensitive for home_public_id'
);

SELECT ok(
  NOT COALESCE(
    (public.house_norms_get_public_by_home_public_id('missingnorms99', 'en')->>'available')::boolean,
    true
  ),
  'public read returns unavailable for unknown home_public_id'
);

-- Non-owner cannot edit.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT throws_like(
  $$ SELECT public.house_norms_edit_section_text(
       (SELECT home_id FROM tmp_home),
       'en',
       'summary_framing',
       'Trying to edit as non-owner.',
       NULL
     ); $$,
  '%FORBIDDEN_OWNER_ONLY%',
  'member cannot edit'
);

-- Owner edits summary framing: draft changes, published snapshot remains unchanged.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT ok(
  (public.house_norms_edit_section_text(
    (SELECT home_id FROM tmp_home),
    'en',
    'summary_framing',
    'We aim to stay calm together and keep this home workable for everyone.',
    'Tone adjustment'
  )->>'ok')::boolean,
  'owner can edit summary_framing'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member'), true);
SELECT ok(
  NOT COALESCE(
    (public.house_norms_get_for_home((SELECT home_id FROM tmp_home), 'en')->'house_norms'->>'show_member_review_card')::boolean,
    true
  ),
  'member review card re-enters debounce window immediately after owner edit'
);

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);

SELECT ok(
  (SELECT (generated_content #>> '{summary,framing}') = 'We aim to stay calm together and keep this home workable for everyone.'
   FROM public.house_norms
   WHERE home_id = (SELECT home_id FROM tmp_home)),
  'summary_framing updates draft content'
);

SELECT ok(
  (SELECT (published_content #>> '{summary,framing}') <> 'We aim to stay calm together and keep this home workable for everyone.'
   FROM public.house_norms
   WHERE home_id = (SELECT home_id FROM tmp_home)),
  'summary_framing edit does not mutate published snapshot'
);

SELECT is(
  (SELECT status FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'out_of_date',
  'editing draft sets status to out_of_date'
);

SELECT ok(
  (SELECT count(*) FROM public.house_norms_revisions WHERE home_id = (SELECT home_id FROM tmp_home)) >= 1,
  'successful edit writes revision row'
);

-- Validation: section key / unsafe / length constraints.
SELECT throws_like(
  $$ SELECT public.house_norms_edit_section_text(
       (SELECT home_id FROM tmp_home),
       'en',
       'summary_title',
       'Not allowed',
       NULL
     ); $$,
  '%HOUSE_NORMS_INVALID_SECTION%',
  'unknown section key rejected'
);

SELECT throws_like(
  $$ SELECT public.house_norms_edit_section_text(
       (SELECT home_id FROM tmp_home),
       'en',
       'norms_shared_spaces',
       'Everyone must clean immediately or else there are consequences.',
       NULL
     ); $$,
  '%HOUSE_NORMS_UNSAFE_TEXT%',
  'unsafe english text rejected'
);

SELECT throws_like(
  $$ SELECT public.house_norms_edit_section_text(
       (SELECT home_id FROM tmp_home),
       'en',
       'summary_framing',
       repeat('a', 501),
       NULL
     ); $$,
  '%HOUSE_NORMS_INVALID_INPUTS%',
  'summary_framing > 500 chars rejected'
);

SELECT throws_like(
  $$ SELECT public.house_norms_edit_section_text(
       (SELECT home_id FROM tmp_home),
       'en',
       'norms_shared_spaces',
       'Looks okay',
       repeat('b', 281)
     ); $$,
  '%HOUSE_NORMS_INVALID_INPUTS%',
  'change summary > 280 chars rejected'
);

-- Generate short-circuit with same inputs and force=false.
SELECT ok(
  COALESCE(
    (public.house_norms_generate_for_home(
      (SELECT home_id FROM tmp_home),
      'house_norms_v1',
      'en',
      (SELECT inputs FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
      false
    )->>'short_circuited')::boolean,
    false
  ),
  'generate short-circuits when inputs unchanged and force=false'
);

SELECT is(
  public._to_iso_utc_ms('2026-02-17 01:03:12.345+00'::timestamptz),
  '2026-02-17T01:03:12.345Z',
  '_to_iso_utc_ms emits canonical ISO UTC milliseconds'
);

-- Republish after draft edits: public id must be stable, version must increment.
SELECT ok(
  (public.house_norms_publish_for_home((SELECT home_id FROM tmp_home), 'en')->>'ok')::boolean,
  'owner can republish after edits'
);

SELECT is(
  (SELECT home_public_id::text FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  (SELECT first_home_public_id FROM tmp_publish_refs),
  'republish keeps home_public_id stable'
);

SELECT is(
  (SELECT published_version FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'v000002',
  'republish increments published_version'
);

SELECT throws_like(
  $$ UPDATE public.house_norms
     SET home_public_id = 'zzzz9999'::public.citext
     WHERE home_id = (SELECT home_id FROM tmp_home); $$,
  '%HOUSE_NORMS_PUBLIC_ID_IMMUTABLE%',
  'home_public_id cannot be mutated once assigned'
);

-- Prepare out_of_date draft then force publish sync failure via bad secret.
SELECT ok(
  (public.house_norms_edit_section_text(
    (SELECT home_id FROM tmp_home),
    'en',
    'summary_framing',
    'We keep communication calm and practical for everyone sharing this home.',
    'Prepare rollback test'
  )->>'ok')::boolean,
  'owner can edit draft before rollback test'
);

SELECT set_config('app.settings.worker_shared_secret', 'wrong-secret-for-test', true);

SELECT throws_like(
  $$ SELECT public.house_norms_publish_for_home((SELECT home_id FROM tmp_home), 'en'); $$,
  '%HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED%',
  'publish fails when sync call is unauthorized'
);

SELECT is(
  (SELECT published_version FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'v000002',
  'failed publish does not advance published_version'
);

SELECT is(
  (SELECT status FROM public.house_norms WHERE home_id = (SELECT home_id FROM tmp_home)),
  'out_of_date',
  'failed publish keeps draft state as out_of_date'
);

-- Invalid generate payload (unknown key) rejected.
SELECT throws_like(
  $$ SELECT public.house_norms_generate_for_home(
       (SELECT home_id FROM tmp_home),
       'house_norms_v1',
       'en',
       jsonb_build_object(
         'norms_property_context', 0,
         'norms_relationship_model', 0,
         'norms_rhythm_quiet', 1,
         'norms_shared_spaces', 2,
         'norms_guests_social', 1,
         'norms_responsibility_flow', 0,
         'norms_repair_style', 1,
         'norms_home_identity', 0,
         'unknown_key', 1
       ),
       false
     ); $$,
  '%HOUSE_NORMS_INVALID_INPUTS%',
  'generate rejects unknown input keys'
);

-- Direct table insert denied for authenticated role.
SELECT throws_like(
  $$ SET LOCAL ROLE authenticated;
     INSERT INTO public.house_norms_revisions(home_id, editor_user_id, content)
     VALUES (
       '00000000-0000-4000-8000-000000000001'::uuid,
       '00000000-0000-4000-8000-000000000411'::uuid,
       '{}'::jsonb
     ); $$,
  '%permission denied%',
  'direct table insert denied'
);

SELECT throws_like(
  $$ SET LOCAL ROLE authenticated;
     INSERT INTO public.house_norms_member_views(home_id, user_id, viewed_at)
     VALUES (
       '00000000-0000-4000-8000-000000000001'::uuid,
       '00000000-0000-4000-8000-000000000411'::uuid,
       now()
     ); $$,
  '%permission denied%',
  'direct member_views table insert denied'
);

SELECT * FROM finish();
ROLLBACK;
