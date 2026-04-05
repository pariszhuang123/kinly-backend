SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(10);

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

CREATE OR REPLACE FUNCTION pg_temp.call_withyou_log_pack_download_as_anon(
  p_language text,
  p_pack_version text,
  p_platform text,
  p_app_version text,
  p_request_path text,
  p_user_agent text,
  p_country_code text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  r jsonb;
BEGIN
  PERFORM set_config('role', 'anon', true);
  SELECT public.withyou_log_pack_download_v1(
    p_language,
    p_pack_version,
    p_platform,
    p_app_version,
    p_request_path,
    p_user_agent,
    p_country_code
  ) INTO r;
  PERFORM set_config('role', 'postgres', true);
  RETURN r;
END;
$$;

TRUNCATE TABLE public.withyou_pack_downloads;

SELECT has_table('public', 'withyou_pack_downloads', 'withyou pack downloads table exists');

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE relname = 'withyou_pack_downloads') = true,
  'RLS enabled on withyou_pack_downloads'
);

SELECT is(
  has_table_privilege('anon', 'public.withyou_pack_downloads', 'insert'),
  false,
  'anon has no direct insert privilege on withyou_pack_downloads'
);

SELECT is(
  (SELECT (pg_temp.call_withyou_log_pack_download_as_anon(
    ' EN ',
    '2026.04.05',
    ' iOS ',
    '1.2.3',
    '/withyou/download/audio/en',
    'KinlyTest/1.0',
    ' nz '
  )->>'ok')::boolean),
  true,
  'withyou_log_pack_download_v1 returns ok=true'
);

SET ROLE postgres;

SELECT is(
  (SELECT COUNT(*) FROM public.withyou_pack_downloads),
  1::bigint,
  'rpc inserts one durable download row'
);

SELECT is(
  (SELECT language FROM public.withyou_pack_downloads LIMIT 1),
  'en',
  'language is trimmed and lowercased before insert'
);

SELECT is(
  (SELECT platform FROM public.withyou_pack_downloads LIMIT 1),
  'ios',
  'platform is normalized to lowercase'
);

SELECT is(
  (SELECT country_code FROM public.withyou_pack_downloads LIMIT 1),
  'NZ',
  'country_code is uppercased when provided'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_withyou_log_pack_download_as_anon('english', null, null, null, null, null, null); $$,
  'WITHYOU_LANGUAGE_INVALID',
  'language longer than 3 chars is rejected'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_withyou_log_pack_download_as_anon(' ', null, null, null, null, null, null); $$,
  'WITHYOU_LANGUAGE_INVALID',
  'blank language is rejected'
);

SELECT * FROM finish();
ROLLBACK;
