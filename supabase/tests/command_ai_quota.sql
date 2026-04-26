SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(13);

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

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000009999', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES
  ('00000000-0000-4000-8000-000000009801', '00000000-0000-0000-0000-000000000000', 'command-quota-free@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret'),
  ('00000000-0000-4000-8000-000000009802', '00000000-0000-0000-0000-000000000000', 'command-quota-premium@example.com', '{}'::jsonb, '{"provider":"email"}'::jsonb, 'authenticated', 'authenticated', 'secret')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.homes (id, owner_user_id)
VALUES
  ('00000000-0000-4000-8000-000000009901', '00000000-0000-4000-8000-000000009801'),
  ('00000000-0000-4000-8000-000000009902', '00000000-0000-4000-8000-000000009802')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.memberships (user_id, home_id, role, valid_from)
VALUES
  ('00000000-0000-4000-8000-000000009801', '00000000-0000-4000-8000-000000009901', 'owner', now()),
  ('00000000-0000-4000-8000-000000009802', '00000000-0000-4000-8000-000000009902', 'owner', now())
ON CONFLICT DO NOTHING;

INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES
  ('00000000-0000-4000-8000-000000009901', 'free', NULL),
  ('00000000-0000-4000-8000-000000009902', 'premium', now() + interval '10 days')
ON CONFLICT (home_id) DO UPDATE
SET plan = EXCLUDED.plan,
    expires_at = EXCLUDED.expires_at;

SELECT set_config('app.settings.command_ai_quota_daily_limit', '1', true);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000009801', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  public._command_ai_quota_limit(),
  1,
  'quota limit reads configured value'
);

SELECT is(
  (public._command_ai_quota_charge(
    '00000000-0000-4000-8000-000000009901',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  )->>'used')::int,
  1,
  'first charge increments used count'
);

SELECT is(
  (public._command_ai_quota_charge(
    '00000000-0000-4000-8000-000000009901',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  )->>'used')::int,
  1,
  'same request_id is idempotent within the same day'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public._command_ai_quota_charge(
       '00000000-0000-4000-8000-000000009901',
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     ); $$,
  'paywall_ai_command_daily_limit',
  'new request_id beyond limit raises paywall ai quota error'
);

SELECT is(
  (public._command_ai_quota_status('00000000-0000-4000-8000-000000009901')->>'bypassed_by_premium_home')::boolean,
  false,
  'free home status is not bypassed'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000009802', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT is(
  (public._command_ai_quota_charge(
    '00000000-0000-4000-8000-000000009902',
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
  )->>'bypassed_by_premium_home')::boolean,
  true,
  'premium home bypasses command ai quota'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.command_ai_requests
    WHERE user_id = '00000000-0000-4000-8000-000000009802'
      AND quota_date = public._command_ai_quota_date(now())
  ),
  0,
  'premium bypass does not create a quota ledger row'
);

SELECT lives_ok(
  $$ SELECT public._command_log_unrecognized_intent(
       '00000000-0000-4000-8000-000000009902',
       'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
       'text',
       'book me a flight to Sydney',
       NULL,
       'en-NZ',
       'Pacific/Auckland',
       'unknown',
       'low',
       'command-router-v1',
       'openai',
       'gpt-classifier'
     ); $$,
  'unrecognized intent logging succeeds for home member'
);

SELECT is(
  (
    SELECT classifier_intent
    FROM public.unrecognized_intents
    WHERE request_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
  ),
  'unknown',
  'unrecognized intent row is recorded'
);

CREATE OR REPLACE FUNCTION public._command_pipeline_call(
  p_home_id uuid,
  p_request_id uuid,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_request_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid THEN
    RETURN jsonb_build_object(
      'ok', true,
      'result', jsonb_build_object(
        'classification', jsonb_build_object(
          'primary_intent', 'unknown',
          'confidence', 'low',
          'provider', 'openai',
          'model', 'gpt-5-nano',
          'intents_detected', jsonb_build_array('unknown')
        ),
        'intent_work_items', '[]'::jsonb
      )
    );
  END IF;

  RAISE EXCEPTION 'simulated pipeline failure for %', p_request_id
    USING ERRCODE = 'P0001';
END;
$$;

SELECT is(
  public.command_submit_v1(
    '00000000-0000-4000-8000-000000009902',
    'text',
    'book me a flight to Sydney',
    NULL,
    'Pacific/Auckland',
    'en-NZ',
    now(),
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
  )->'result'->>'kind',
  'unknown',
  'unknown command submit returns unknown top-level result'
);

SELECT is(
  (
    SELECT classifier_intent
    FROM public.unrecognized_intents
    WHERE request_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
  ),
  'unknown',
  'active command_submit_v1 logs unrecognized unknown intents'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT public.command_submit_v1(
       '00000000-0000-4000-8000-000000009901',
       'text',
       'add milk',
       NULL,
       'Pacific/Auckland',
       'en-NZ',
       now(),
       'ffffffff-ffff-4fff-8fff-ffffffffffff'
     ); $$,
  'simulated pipeline failure',
  'pipeline failures still surface to callers'
);

SELECT is(
  (
    SELECT count(*)::int
    FROM public.command_ai_requests
    WHERE user_id = '00000000-0000-4000-8000-000000009801'
      AND request_id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
  ),
  0,
  'quota ledger row is released when pipeline fails before classification completes'
);

SELECT * FROM finish();
ROLLBACK;
