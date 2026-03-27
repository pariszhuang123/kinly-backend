SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label text PRIMARY KEY,
  user_id uuid NOT NULL,
  email text NOT NULL
);

CREATE TEMP TABLE tmp_homes (
  label text PRIMARY KEY,
  home_id uuid NOT NULL
);

CREATE TEMP TABLE tmp_invites (
  label text PRIMARY KEY,
  code text NOT NULL
);

CREATE TEMP TABLE tmp_fit_drafts (
  label text PRIMARY KEY,
  draft_id uuid,
  share_token text,
  draft_session_token text,
  claim_token text,
  payload jsonb
);

CREATE TEMP TABLE tmp_fit_submissions (
  label text PRIMARY KEY,
  submission_id uuid,
  payload jsonb
);

GRANT USAGE ON SCHEMA pgtap TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgtap TO anon, authenticated, service_role;

GRANT ALL ON TABLE tmp_users TO anon, authenticated, service_role;
GRANT ALL ON TABLE tmp_homes TO anon, authenticated, service_role;
GRANT ALL ON TABLE tmp_invites TO anon, authenticated, service_role;
GRANT ALL ON TABLE tmp_fit_drafts TO anon, authenticated, service_role;
GRANT ALL ON TABLE tmp_fit_submissions TO anon, authenticated, service_role;

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

CREATE OR REPLACE FUNCTION pg_temp.exec_raises_like(
  p_sql text,
  p_pattern text
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RETURN false;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RETURN v_msg LIKE p_pattern;
  END;
END;
$$;

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000891', 'avatars/flatmate-fit-1.png', 'animal', 'Flatmate Fit Avatar 1'),
  ('00000000-0000-4000-8000-000000000892', 'avatars/flatmate-fit-2.png', 'animal', 'Flatmate Fit Avatar 2'),
  ('00000000-0000-4000-8000-000000000893', 'avatars/flatmate-fit-3.png', 'animal', 'Flatmate Fit Avatar 3')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner', '40000000-0000-4000-9000-000000000401', 'owner-flatmate-fit@example.com'),
  ('owner_two', '40000000-0000-4000-9000-000000000402', 'owner-two-flatmate-fit@example.com'),
  ('outsider', '40000000-0000-4000-9000-000000000403', 'outsider-flatmate-fit@example.com');

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

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner_two'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'secondary', (payload->'home'->>'id')::uuid
FROM res;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.headers', '{}'::text, true);

WITH res AS (
  SELECT public.fit_check_upsert_draft(
    NULL,
    NULL,
    'en-NZ',
    jsonb_build_object(
      'fit_cleanliness', 0,
      'fit_rhythm', 1,
      'fit_chores', 0,
      'fit_conflict', 0
    )
  ) AS payload
)
INSERT INTO tmp_fit_drafts (label, draft_id, share_token, draft_session_token, claim_token, payload)
SELECT
  'primary',
  (payload->>'draft_id')::uuid,
  payload->'share'->>'share_token',
  payload->'draft_session'->>'draft_session_token',
  payload->'claim'->>'claim_token',
  payload
FROM res;

RESET ROLE;

SELECT ok(
  ((SELECT payload FROM tmp_fit_drafts WHERE label = 'primary')->>'ok')::boolean,
  'anon caller can create fit-check draft'
);

SELECT is(
  (SELECT payload->>'requested_locale_base' FROM tmp_fit_drafts WHERE label = 'primary'),
  'en',
  'draft creation normalizes requested locale to base locale'
);

SELECT is(
  (SELECT payload->>'resolved_locale_base' FROM tmp_fit_drafts WHERE label = 'primary'),
  'en',
  'draft creation resolves available locale'
);

SELECT ok(
  length((SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary')) > 10,
  'draft creation returns a share token'
);

SELECT ok(
  ((SELECT payload->'share'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft creation marks share token as reveal-once'
);

SELECT ok(
  length((SELECT draft_session_token FROM tmp_fit_drafts WHERE label = 'primary')) > 10,
  'draft creation returns a draft session token'
);

SELECT ok(
  ((SELECT payload->'draft_session'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft creation marks draft session token as reveal-once'
);

SELECT ok(
  length((SELECT claim_token FROM tmp_fit_drafts WHERE label = 'primary')) > 10,
  'draft creation returns a claim token'
);

SELECT ok(
  ((SELECT payload->'claim'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft creation marks claim token as reveal-once'
);

SELECT is(
  jsonb_array_length((SELECT payload->'summary'->'labels' FROM tmp_fit_drafts WHERE label = 'primary')),
  4,
  'draft creation returns four summary labels'
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.fit_check_templates
    WHERE template_key = 'fit_check.candidate.entry_prompt'
      AND locale_base = 'en'
  ),
  'fit check templates are seeded'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.fit_check_drafts d
    WHERE d.id = (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
      AND d.owner_user_id IS NULL
      AND d.claimed_at IS NULL
      AND d.claim_token_hash <> (SELECT claim_token FROM tmp_fit_drafts WHERE label = 'primary')
      AND d.draft_session_token_hash <> (SELECT draft_session_token FROM tmp_fit_drafts WHERE label = 'primary')
      AND char_length(d.claim_token_hash) = 64
      AND char_length(d.draft_session_token_hash) = 64
  ),
  'draft stores only hashed claim and draft session tokens'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

WITH res AS (
  SELECT public.fit_check_upsert_draft(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    (SELECT draft_session_token FROM tmp_fit_drafts WHERE label = 'primary'),
    'fr-FR',
    jsonb_build_object(
      'fit_cleanliness', 0,
      'fit_rhythm', 1,
      'fit_chores', 0,
      'fit_conflict', 2
    )
  ) AS payload
)
UPDATE tmp_fit_drafts t
SET payload = res.payload
FROM res
WHERE t.label = 'primary';

RESET ROLE;

SELECT is(
  (SELECT payload->>'draft_id' FROM tmp_fit_drafts WHERE label = 'primary'),
  (SELECT draft_id::text FROM tmp_fit_drafts WHERE label = 'primary'),
  'draft update keeps the same draft_id'
);

SELECT is(
  (SELECT payload->>'requested_locale_base' FROM tmp_fit_drafts WHERE label = 'primary'),
  'fr',
  'draft update persists new requested locale base'
);

SELECT is(
  (SELECT payload->>'resolved_locale_base' FROM tmp_fit_drafts WHERE label = 'primary'),
  'en',
  'draft update falls back to en when requested locale is unavailable'
);

SELECT ok(
  (SELECT payload->'share'->>'share_token' FROM tmp_fit_drafts WHERE label = 'primary') IS NULL,
  'draft update does not reveal share token again'
);

SELECT ok(
  (SELECT payload->'claim'->>'claim_token' FROM tmp_fit_drafts WHERE label = 'primary') IS NULL,
  'draft update does not reveal claim token again'
);

SELECT ok(
  NOT ((SELECT payload->'share'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft update marks share metadata as no longer reveal-once'
);

SELECT ok(
  NOT ((SELECT payload->'draft_session'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft update marks draft session metadata as no longer reveal-once'
);

SELECT ok(
  NOT ((SELECT payload->'claim'->>'reveal_once' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'draft update marks claim metadata as no longer reveal-once'
);

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_upsert_draft(
        '%s'::uuid,
        'fitdraft_wrong_token',
        'en',
        jsonb_build_object(
          'fit_cleanliness', 0,
          'fit_rhythm', 1,
          'fit_chores', 0,
          'fit_conflict', 2
        )
      )
    $sql$,
    (SELECT draft_id::text FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_INVALID_DRAFT_SESSION',
  'draft update rejects invalid draft session token'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

SELECT ok(
  (public.fit_check_get_public_by_token(
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->>'available')::boolean,
  'public share token read returns available candidate flow'
);

SELECT ok(
  public.fit_check_get_public_by_token(
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->'fit_check_public' ? 'scenarios',
  'public share token read returns scenario metadata'
);

SELECT ok(
  NOT (
    public.fit_check_get_public_by_token(
      (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
      'en'
    )->'fit_check_public' ? 'owner_answers'
  ),
  'public share token read does not leak owner answers'
);

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.headers', '{}'::text, true);

WITH res AS (
  SELECT public.fit_check_upsert_draft(
    NULL,
    NULL,
    'en',
    jsonb_build_object(
      'fit_cleanliness', 1,
      'fit_rhythm', 1,
      'fit_chores', 1,
      'fit_conflict', 1
    )
  ) AS payload
)
INSERT INTO tmp_fit_drafts (label, draft_id, share_token, draft_session_token, claim_token, payload)
SELECT
  'exhausted',
  (payload->>'draft_id')::uuid,
  payload->'share'->>'share_token',
  payload->'draft_session'->>'draft_session_token',
  payload->'claim'->>'claim_token',
  payload
FROM res;

RESET ROLE;

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

INSERT INTO public.candidate_fit_submissions (
  draft_id,
  share_token_id,
  display_name,
  answers,
  anonymous_session_hash
)
SELECT
  d.id,
  st.id,
  'Cap ' || g.n,
  jsonb_build_object(
    'fit_cleanliness', 1,
    'fit_rhythm', 1,
    'fit_chores', 1,
    'fit_conflict', 1
  ),
  public._sha256_hex('exhausted-session-' || g.n::text)
FROM public.fit_check_drafts d
JOIN public.fit_check_share_tokens st
  ON st.draft_id = d.id
 AND st.status = 'active'
CROSS JOIN generate_series(1, public._fit_check_submission_cap()) AS g(n)
WHERE d.id = (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'exhausted');

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

SELECT ok(
  NOT (
    public.fit_check_get_public_by_token(
      (SELECT share_token FROM tmp_fit_drafts WHERE label = 'exhausted'),
      'en'
    )->>'available'
  )::boolean,
  'exhausted share token becomes unavailable to public reads'
);

SELECT is(
  public.fit_check_get_public_by_token(
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'exhausted'),
    'en'
  )->'error'->>'code',
  'FIT_CHECK_TOKEN_SUBMISSION_LIMIT_REACHED',
  'exhausted share token returns submission-limit error code'
);

SELECT set_config('request.headers', '{"x-fit-check-session-id":"anon_missing_name_0001"}', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_submit_candidate_by_token(
        %L,
        'en',
        '   ',
        jsonb_build_object(
          'fit_cleanliness', 2,
          'fit_rhythm', 1,
          'fit_chores', 0,
          'fit_conflict', 1
        )
      )
    $sql$,
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_INVALID_INPUTS',
  'candidate submission requires display_name'
);

SELECT set_config('request.headers', '{"x-fit-check-session-id":"anon_fitcheck_alpha_0001"}', true);

WITH res AS (
  SELECT public.fit_check_submit_candidate_by_token(
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
    'en',
    'Alex',
    jsonb_build_object(
      'fit_cleanliness', 2,
      'fit_rhythm', 1,
      'fit_chores', 0,
      'fit_conflict', 1
    )
  ) AS payload
)
INSERT INTO tmp_fit_submissions (label, submission_id, payload)
SELECT
  'alex_first',
  (payload->>'submission_id')::uuid,
  payload
FROM res;

SELECT set_config('request.headers', '{"x-fit-check-session-id":"anon_fitcheck_beta_0001"}', true);

WITH res AS (
  SELECT public.fit_check_submit_candidate_by_token(
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
    'en',
    'Alex',
    jsonb_build_object(
      'fit_cleanliness', 0,
      'fit_rhythm', 1,
      'fit_chores', 0,
      'fit_conflict', 2
    )
  ) AS payload
)
INSERT INTO tmp_fit_submissions (label, submission_id, payload)
SELECT
  'alex_second',
  (payload->>'submission_id')::uuid,
  payload
FROM res;

RESET ROLE;

SELECT ok(
  ((SELECT payload FROM tmp_fit_submissions WHERE label = 'alex_first')->>'ok')::boolean,
  'candidate submission succeeds for first session'
);

SELECT ok(
  ((SELECT payload FROM tmp_fit_submissions WHERE label = 'alex_second')->>'ok')::boolean,
  'candidate submission succeeds for second session with duplicate display_name'
);

SELECT is(
  (SELECT payload->'candidate'->>'display_name' FROM tmp_fit_submissions WHERE label = 'alex_first'),
  'Alex',
  'candidate response echoes display_name only'
);

SELECT ok(
  (SELECT payload->'confirmation'->'reflection'->>'text_key' FROM tmp_fit_submissions WHERE label = 'alex_first')
    = 'fit_check.candidate.reflection.balanced',
  'candidate reflection key is derived from structured answers'
);

SELECT ok(
  (SELECT payload->'confirmation'->'cta'->>'target_url' FROM tmp_fit_submissions WHERE label = 'alex_first')
    = 'https://go.makinglifeeasie.com/kinly',
  'candidate confirmation includes CTA target'
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (
    SELECT count(*)
    FROM public.candidate_fit_briefings b
    WHERE b.submission_id = (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first')
  ),
  1::bigint,
  'candidate submission generates exactly one briefing row'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.candidate_fit_briefings b
    WHERE b.submission_id = (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first')
      AND b.owner_answers_snapshot = jsonb_build_object(
        'fit_cleanliness', 0,
        'fit_rhythm', 1,
        'fit_chores', 0,
        'fit_conflict', 2
      )
  ),
  'briefing stores a frozen snapshot of owner answers at submission time'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.headers', '{"x-fit-check-session-id":"anon_fitcheck_alpha_0001"}', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_submit_candidate_by_token(
        %L,
        'en',
        'Alex',
        jsonb_build_object(
          'fit_cleanliness', 2,
          'fit_rhythm', 1,
          'fit_chores', 0,
          'fit_conflict', 1
        )
      )
    $sql$,
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_DUPLICATE_SUBMISSION',
  'candidate duplicate submission from same session is rejected'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.fit_check_claim_draft(
    (SELECT claim_token FROM tmp_fit_drafts WHERE label = 'primary')
  ) AS payload
)
UPDATE tmp_fit_drafts t
SET payload = res.payload
FROM res
WHERE t.label = 'primary';

RESET ROLE;

SELECT ok(
  ((SELECT payload FROM tmp_fit_drafts WHERE label = 'primary')->>'ok')::boolean,
  'authenticated owner can claim fit-check draft'
);

SELECT is(
  (SELECT payload->>'owner_user_id' FROM tmp_fit_drafts WHERE label = 'primary'),
  (SELECT user_id::text FROM tmp_users WHERE label = 'owner'),
  'claim attaches draft ownership to authenticated user'
);

SELECT ok(
  ((SELECT payload->>'home_attachment_required' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'claim does not attach the draft to a home automatically'
);

SELECT is(
  (SELECT (payload->>'submission_count')::integer FROM tmp_fit_drafts WHERE label = 'primary'),
  2,
  'claim response includes existing submission count'
);

SELECT is(
  (SELECT (payload->>'owner_home_count')::integer FROM tmp_fit_drafts WHERE label = 'primary'),
  1,
  'claim response includes owner home count'
);

SELECT ok(
  NOT ((SELECT payload->>'seed_preferences_prefill_available' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'claim response reports no preference prefill support'
);

SELECT ok(
  ((SELECT payload->>'setup_handoff_recommended' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'claim response recommends setup handoff'
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.fit_check_drafts d
    WHERE d.id = (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
      AND d.owner_user_id = (SELECT user_id FROM tmp_users WHERE label = 'owner')
      AND d.claimed_at IS NOT NULL
      AND d.claim_token_used_at IS NOT NULL
      AND d.draft_session_token_hash IS NULL
  ),
  'claim marks draft claimed and invalidates draft session authority'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_claim_draft(%L)
    $sql$,
    (SELECT claim_token FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_INVALID_OR_USED_CLAIM_TOKEN',
  'claim token cannot be reused after successful claim'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_upsert_draft(
        '%s'::uuid,
        %L,
        'en',
        jsonb_build_object(
          'fit_cleanliness', 0,
          'fit_rhythm', 1,
          'fit_chores', 0,
          'fit_conflict', 2
        )
      )
    $sql$,
    (SELECT draft_id::text FROM tmp_fit_drafts WHERE label = 'primary'),
    (SELECT draft_session_token FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_INVALID_DRAFT_SESSION',
  'claimed draft cannot be updated with the old anonymous draft session token'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.headers', '{}'::text, true);

WITH res AS (
  SELECT public.fit_check_upsert_draft(
    NULL,
    NULL,
    'en',
    jsonb_build_object(
      'fit_cleanliness', 2,
      'fit_rhythm', 2,
      'fit_chores', 2,
      'fit_conflict', 2
    )
  ) AS payload
)
INSERT INTO tmp_fit_drafts (label, draft_id, share_token, draft_session_token, claim_token, payload)
SELECT
  'expired_claim',
  (payload->>'draft_id')::uuid,
  payload->'share'->>'share_token',
  payload->'draft_session'->>'draft_session_token',
  payload->'claim'->>'claim_token',
  payload
FROM res;

RESET ROLE;

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

UPDATE public.fit_check_drafts
   SET created_at = now() - interval '31 days',
       updated_at = now() - interval '31 days'
 WHERE id = (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'expired_claim');

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_claim_draft(%L)
    $sql$,
    (SELECT claim_token FROM tmp_fit_drafts WHERE label = 'expired_claim')
  ),
  'FIT_CHECK_INVALID_OR_USED_CLAIM_TOKEN',
  'claim rejects expired claim token'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.fit_check_get_owner_review(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->>'ok')::boolean,
  'owner can read review list after claim'
);

SELECT is(
  jsonb_array_length(
    public.fit_check_get_owner_review(
      (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
      'en'
    )->'submissions'
  ),
  2,
  'owner review returns one row per submission'
);

SELECT is(
  public.fit_check_get_owner_review(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->'submissions'->0->>'display_name',
  'Alex',
  'owner review keeps duplicate display_name values'
);

SELECT ok(
  public.fit_check_get_owner_review(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->'submissions'->0->>'review_label' IS NOT NULL,
  'owner review includes review_label for duplicate-name disambiguation'
);

SELECT is(
  public.fit_check_get_owner_review(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->'submissions'->1->'preview'->'top_watchouts'->>0,
  'fit_cleanliness',
  'owner review preview exposes top watchouts in canonical priority order'
);

SELECT ok(
  public.fit_check_get_owner_review(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    'en'
  )->'share'->>'share_token_status' = 'active',
  'owner review reports active share token state before rotation'
);

SELECT ok(
  public.fit_check_get_owner_briefing(
    (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first'),
    'en'
  )->'briefing'->>'context_key' = 'fit_check.briefing.context',
  'owner briefing returns context key'
);

SELECT is(
  public.fit_check_get_owner_briefing(
    (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first'),
    'en'
  )->'briefing'->'watchouts'->0->>'direction',
  'candidate_higher',
  'owner briefing uses canonical watchout direction'
);

SELECT is(
  public.fit_check_get_owner_briefing(
    (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first'),
    'en'
  )->'briefing'->'watchouts'->0->>'distance',
  '2',
  'owner briefing exposes watchout distance'
);

SELECT ok(
  (
    public.fit_check_get_owner_briefing(
      (SELECT submission_id FROM tmp_fit_submissions WHERE label = 'alex_first'),
      'en'
    )->'briefing'->'watchouts'->0->>'is_primary_focus'
  )::boolean,
  'owner briefing marks highest-risk watchout as primary focus'
);

SELECT ok(
  (
    public.fit_check_get_prefill_payload(
      (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
    )->'house_norms_prefill'
  ) = jsonb_build_object(
    'norms_shared_spaces', 'clear_now',
    'norms_rhythm_quiet', 'variable',
    'norms_responsibility_flow', 'clear_agreements',
    'norms_repair_style', 'let_small_pass'
  ),
  'prefill payload maps fit-check answers to the expected house norms values'
);

SELECT ok(
  (
    public.fit_check_get_prefill_payload(
      (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
    )->'onboarding_seed'->'house_norms'->'initial_responses'
  ) = jsonb_build_object(
    'norms_shared_spaces', 0,
    'norms_rhythm_quiet', 1,
    'norms_responsibility_flow', 0,
    'norms_repair_style', 2
  ),
  'prefill payload exposes onboarding seed initial responses'
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (
    SELECT count(*)
    FROM public.house_norms
    WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ),
  0::bigint,
  'fit check prefill does not create downstream house_norms rows'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.fit_check_attach_draft_to_home(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary'),
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS payload
)
UPDATE tmp_fit_drafts t
SET payload = res.payload
FROM res
WHERE t.label = 'primary';

SELECT ok(
  ((SELECT payload->>'ok' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'owner can attach claimed draft to owned home'
);

SELECT ok(
  ((SELECT payload->>'setup_prefill_ready' FROM tmp_fit_drafts WHERE label = 'primary')::boolean),
  'attach response exposes setup prefill readiness'
);

WITH res AS (
  SELECT public.fit_check_rotate_share_token(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
  ) AS payload
)
UPDATE tmp_fit_drafts t
SET share_token = res.payload->>'share_token',
    payload = res.payload
FROM res
WHERE t.label = 'primary';

SELECT ok(
  ((SELECT payload FROM tmp_fit_drafts WHERE label = 'primary')->>'ok')::boolean,
  'owner can rotate share token'
);

RESET ROLE;

SELECT ok(
  length((SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary')) > 10,
  'share token rotation returns a new raw token'
);

SET LOCAL ROLE service_role;
SET LOCAL search_path = pgtap, public, auth, extensions;

SELECT is(
  (
    SELECT count(*)
    FROM public.candidate_fit_submissions s
    WHERE s.draft_id = (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  2::bigint,
  'share token rotation preserves existing submissions'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (public.fit_check_revoke_share_token(
    (SELECT draft_id FROM tmp_fit_drafts WHERE label = 'primary')
  )->>'ok')::boolean,
  'owner can revoke active share token'
);

RESET ROLE;

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
SELECT set_config('request.jwt.claim.role', 'anon', true);

SELECT ok(
  NOT (
    public.fit_check_get_public_by_token(
      (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary'),
      'en'
    )->>'available'
  )::boolean,
  'revoked share token becomes unavailable to public reads'
);

SELECT set_config('request.headers', '{"x-fit-check-session-id":"anon_fitcheck_gamma_0001"}', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_submit_candidate_by_token(
        %L,
        'en',
        'Taylor',
        jsonb_build_object(
          'fit_cleanliness', 1,
          'fit_rhythm', 1,
          'fit_chores', 1,
          'fit_conflict', 1
        )
      )
    $sql$,
    (SELECT share_token FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FIT_CHECK_TOKEN_REVOKED',
  'revoked share token rejects candidate submissions'
);

RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
INSERT INTO tmp_fit_submissions (label, payload)
VALUES (
  'authenticated_insert_denied',
  jsonb_build_object(
    'ok',
    pg_temp.exec_raises_like(
      $$INSERT INTO public.fit_check_drafts (
          id,
          owner_answers,
          requested_locale_base,
          claim_token_hash
        ) VALUES (
          gen_random_uuid(),
          '{}'::jsonb,
          'en',
          repeat('a', 64)
        )$$,
      '%permission%'
    )
  )
);
RESET ROLE;

SELECT ok(
  ((SELECT payload->>'ok' FROM tmp_fit_submissions WHERE label = 'authenticated_insert_denied')::boolean),
  'authenticated role cannot directly insert fit-check drafts'
);

SET LOCAL ROLE anon;
SET LOCAL search_path = pgtap, public, auth, extensions;
INSERT INTO tmp_fit_submissions (label, payload)
VALUES (
  'anon_select_denied',
  jsonb_build_object(
    'ok',
    pg_temp.exec_raises_like(
      $$SELECT * FROM public.candidate_fit_submissions$$,
      '%permission%'
    )
  )
);
RESET ROLE;

SELECT ok(
  ((SELECT payload->>'ok' FROM tmp_fit_submissions WHERE label = 'anon_select_denied')::boolean),
  'anon role cannot directly read fit-check submission rows'
);

SET LOCAL ROLE authenticated;
SET LOCAL search_path = pgtap, public, auth, extensions;
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'outsider'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT pg_temp.expect_api_error(
  format(
    $sql$
      SELECT public.fit_check_get_owner_review('%s'::uuid, 'en')
    $sql$,
    (SELECT draft_id::text FROM tmp_fit_drafts WHERE label = 'primary')
  ),
  'FORBIDDEN_OWNER_ONLY',
  'non-owner cannot read fit-check owner review'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
