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

CREATE OR REPLACE FUNCTION pg_temp.call_leads_upsert_as_anon(
  p_email text,
  p_country_code text,
  p_ui_locale text,
  p_source text
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  r jsonb;
BEGIN
  PERFORM set_config('role', 'anon', true);
  SELECT public.leads_upsert_v1(p_email, p_country_code, p_ui_locale, p_source) INTO r;
  PERFORM set_config('role', 'postgres', true);
  RETURN r;
END;
$$;

-- Clean slate
TRUNCATE TABLE public.leads_rate_limits;
TRUNCATE TABLE public.leads;

-- Tables and protections
SELECT has_table('public', 'leads', 'leads table exists');
SELECT has_table('public', 'leads_rate_limits', 'leads_rate_limits table exists');

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE relname = 'leads') = true,
  'RLS enabled on leads'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE relname = 'leads_rate_limits') = true,
  'RLS enabled on leads_rate_limits'
);

SELECT is(
  has_table_privilege('anon', 'public.leads', 'insert'),
  false,
  'anon has no direct insert privilege on leads'
);

SELECT is(
  has_table_privilege('anon', 'public.leads_rate_limits', 'insert'),
  false,
  'anon has no direct insert privilege on leads_rate_limits'
);

SELECT is(
  (SELECT (pg_temp.call_leads_upsert_as_anon('User@Example.com', 'nz', 'en-NZ', 'kinly_web_get')->>'ok')::boolean),
  true,
  'leads_upsert_v1 returns ok=true on insert'
);

SELECT is(
  (SELECT (pg_temp.call_leads_upsert_as_anon('User@Example.com', 'nz', 'en-NZ', 'kinly_web_get')->>'deduped')::boolean),
  false,
  'leads_upsert_v1 returns deduped=false on first insert'
);

SET ROLE postgres;

SELECT is(
  (SELECT COUNT(*) FROM public.leads WHERE email = 'User@Example.com'),
  1::bigint,
  'lead inserted once'
);

SELECT is(
  (SELECT country_code FROM public.leads WHERE email = 'User@Example.com'),
  'NZ',
  'country_code uppercased'
);

SELECT is(
  (SELECT source FROM public.leads WHERE email = 'User@Example.com'),
  'kinly_web_get',
  'source defaults to kinly_web_get'
);

-- Dedupe + overwrite
SELECT is(
  (SELECT (pg_temp.call_leads_upsert_as_anon('user@example.com', 'au', 'en-AU', 'kinly_dating_web_get')->>'deduped')::boolean),
  true,
  'deduped=true on conflict update'
);

SET ROLE postgres;

SELECT is(
  (SELECT source FROM public.leads WHERE email = 'User@Example.com'),
  'kinly_dating_web_get',
  'source updated on dedupe'
);

SELECT is(
  (SELECT ui_locale FROM public.leads WHERE email = 'User@Example.com'),
  'en-AU',
  'ui_locale updated on dedupe'
);

-- Validation errors
SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_leads_upsert_as_anon('bad-email', 'NZ', 'en', 'kinly_web_get'); $$,
  'LEADS_EMAIL_INVALID',
  'invalid email rejected'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_leads_upsert_as_anon('ok@example.com', 'NZ', 'en NZ', 'kinly_web_get'); $$,
  'LEADS_UI_LOCALE_INVALID',
  'ui_locale with space rejected'
);

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_leads_upsert_as_anon('ok@example.com', 'NZ', 'en', 'not_allowed'); $$,
  'LEADS_SOURCE_INVALID',
  'source allowlist enforced'
);

-- Per-email rate limit
SET ROLE postgres;
WITH params AS (
  SELECT
    'limit@example.com'::text AS email_val,
    date_trunc('day', now()) AS window_start
),
hashed AS (
  SELECT encode(
    digest('email:' || (email_val::citext)::text || ':' || window_start::text, 'sha256'),
    'hex'
  ) AS k
  FROM params
)
INSERT INTO public.leads_rate_limits (k, n, updated_at)
SELECT k, 5, now() FROM hashed
ON CONFLICT (k) DO UPDATE SET n = EXCLUDED.n, updated_at = EXCLUDED.updated_at;

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_leads_upsert_as_anon('limit@example.com', 'NZ', 'en-NZ', 'kinly_web_get'); $$,
  'LEADS_RATE_LIMIT_EMAIL',
  'per-email limiter enforced'
);

-- Global rate limit
SET ROLE postgres;
WITH params AS (
  SELECT date_trunc('minute', now()) AS window_start
),
hashed AS (
  SELECT encode(
    digest('global:' || window_start::text, 'sha256'),
    'hex'
  ) AS k
  FROM params
)
INSERT INTO public.leads_rate_limits (k, n, updated_at)
SELECT k, 300, now() FROM hashed
ON CONFLICT (k) DO UPDATE SET n = EXCLUDED.n, updated_at = EXCLUDED.updated_at;

SELECT pg_temp.expect_api_error(
  $$ SELECT pg_temp.call_leads_upsert_as_anon('global@example.com', 'NZ', 'en-NZ', 'kinly_web_get'); $$,
  'LEADS_RATE_LIMIT_GLOBAL',
  'global limiter enforced'
);

SELECT * FROM finish();
ROLLBACK;
