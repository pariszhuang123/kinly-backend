SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(14);

CREATE TEMP TABLE tmp_results (
  label text PRIMARY KEY,
  ok    boolean NOT NULL
);

GRANT ALL ON TABLE tmp_results TO anon;
GRANT ALL ON TABLE tmp_results TO service_role;

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

-- Permission surface: service_role only.
SET LOCAL ROLE anon;
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_exec_denied',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_get_or_create(
      NULL,
      '/kinly/market/x',
      '{}'::jsonb,
      'c',
      's',
      'm',
      'kinly-web',
      'page',
      NULL
    )$$,
    '%permission%'
  )
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'anon_exec_denied'),
  'anon cannot execute outreach_short_links_get_or_create'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.outreach_short_links_get_or_create(text,text,jsonb,text,text,text,text,text,timestamptz)',
    'EXECUTE'
  ),
  'service_role can execute outreach_short_links_get_or_create'
);

-- Direct table writes denied for anon.
SET LOCAL ROLE anon;
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_direct_insert_denied',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_short_links (
      short_code, target_path, target_query, utm_campaign, utm_source, utm_medium, app_key, page_key, destination_fingerprint
    ) VALUES (
      'abc123', '/kinly/market/test', '{}'::jsonb, 'c', 's', 'm', 'kinly-web', 'landing', 'x'
    )$$,
    '%permission%'
  )
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'anon_direct_insert_denied'),
  'anon direct insert to outreach_short_links is denied'
);

-- Create canonical link with explicit code.
SET LOCAL ROLE service_role;
WITH created AS (
  SELECT public.outreach_short_links_get_or_create(
    'k8m4qz',
    '/kinly/market/flat-agreements',
    '{"foo":"bar"}'::jsonb,
    'early_interest_2026',
    'offline_event',
    'qr',
    'kinly-web',
    'kinly_market_flat_agreements',
    NULL
  ) AS payload
)
INSERT INTO tmp_results (label, ok) VALUES (
  'create_with_requested_code',
  (SELECT (payload->>'ok')::boolean FROM created)
  AND (SELECT (payload->>'created')::boolean FROM created)
  AND (SELECT payload->>'short_code' FROM created) = 'k8m4qz'
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'create_with_requested_code'),
  'service_role can create a short link with requested code'
);

-- Same fingerprint returns canonical row and ignores requested code/expiry.
SET LOCAL ROLE service_role;
WITH first_call AS (
  SELECT public.outreach_short_links_get_or_create(
    NULL,
    '/kinly/market/flat-agreements',
    '{"foo":"bar"}'::jsonb,
    'early_interest_2026',
    'offline_event',
    'qr',
    'kinly-web',
    'kinly_market_flat_agreements',
    NULL
  ) AS payload
),
second_call AS (
  SELECT public.outreach_short_links_get_or_create(
    'zzzzzz',
    '/kinly/market/flat-agreements',
    '{"foo":"bar"}'::jsonb,
    'early_interest_2026',
    'offline_event',
    'qr',
    'kinly-web',
    'kinly_market_flat_agreements',
    now() + interval '7 days'
  ) AS payload
)
INSERT INTO tmp_results (label, ok) VALUES (
  'fingerprint_idempotent',
  (SELECT (payload->>'created')::boolean FROM first_call) = false
  AND (SELECT (payload->>'created')::boolean FROM second_call) = false
  AND (SELECT payload->>'short_code' FROM second_call) = 'k8m4qz'
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'fingerprint_idempotent'),
  'same fingerprint is idempotent and keeps canonical short code'
);

-- Validation errors.
SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_short_code_rejected',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_get_or_create(
      'BAD CODE',
      '/kinly/market/x',
      '{}'::jsonb,
      'c',
      's',
      'm',
      'kinly-web',
      'page',
      NULL
    )$$,
    '%INVALID_SHORT_CODE%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_target_path_rejected',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_get_or_create(
      NULL,
      '/not-kinly/path',
      '{}'::jsonb,
      'c',
      's',
      'm',
      'kinly-web',
      'page',
      NULL
    )$$,
    '%INVALID_TARGET_PATH%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_target_query_rejected',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_get_or_create(
      NULL,
      '/kinly/market/x',
      '[]'::jsonb,
      'c',
      's',
      'm',
      'kinly-web',
      'page',
      NULL
    )$$,
    '%INVALID_TARGET_QUERY%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_utm_rejected',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_get_or_create(
      NULL,
      '/kinly/market/x',
      '{}'::jsonb,
      '',
      's',
      'm',
      'kinly-web',
      'page',
      NULL
    )$$,
    '%INVALID_UTM%'
  )
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_short_code_rejected'),
  'invalid short code is rejected'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_target_path_rejected'),
  'invalid target path is rejected'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_target_query_rejected'),
  'non-object target_query is rejected'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_utm_rejected'),
  'empty UTM value is rejected'
);

-- Disable behavior.
SET LOCAL ROLE service_role;
WITH disabled AS (
  SELECT public.outreach_short_links_disable('k8m4qz') AS payload
)
INSERT INTO tmp_results (label, ok) VALUES (
  'disable_active_link',
  (SELECT (payload->>'ok')::boolean FROM disabled)
  AND (SELECT (payload->>'disabled')::boolean FROM disabled)
);

WITH already_disabled AS (
  SELECT public.outreach_short_links_disable('k8m4qz') AS payload
)
INSERT INTO tmp_results (label, ok) VALUES (
  'disable_idempotent',
  (SELECT (payload->>'ok')::boolean FROM already_disabled)
  AND NOT (SELECT (payload->>'disabled')::boolean FROM already_disabled)
);

INSERT INTO tmp_results (label, ok) VALUES (
  'disable_missing_not_found',
  pg_temp.exec_raises_like(
    $$SELECT public.outreach_short_links_disable('nope99')$$,
    '%SHORT_CODE_NOT_FOUND%'
  )
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'disable_active_link'),
  'disable marks an active short code as disabled'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'disable_idempotent'),
  'disable is idempotent for already disabled code'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'disable_missing_not_found'),
  'missing short code raises SHORT_CODE_NOT_FOUND'
);

-- Source resolution via alias + normalization by trigger.
SET LOCAL ROLE service_role;
INSERT INTO public.outreach_sources (source_id, label, active)
VALUES ('source_short_links_test', 'Source Short Links Test', true)
ON CONFLICT (source_id) DO NOTHING;

INSERT INTO public.outreach_source_aliases (alias, source_id, active)
VALUES ('qr_source_alias', 'source_short_links_test', true)
ON CONFLICT (alias) DO NOTHING;

SELECT public.outreach_short_links_get_or_create(
  'al1as6',
  '/kinly/market/alias',
  '{}'::jsonb,
  'campaign_alias',
  'QR_SOURCE_ALIAS',
  'QR',
  'kinly-web',
  'page_alias',
  now() - interval '1 day'
);

INSERT INTO tmp_results (label, ok) VALUES (
  'alias_resolves_source',
  (SELECT source_id_resolved = 'source_short_links_test'
     FROM public.outreach_short_links
    WHERE short_code = 'al1as6'::public.citext
    LIMIT 1)
);

INSERT INTO tmp_results (label, ok) VALUES (
  'expired_not_effective',
  (SELECT effective_active = false
     FROM public.outreach_short_links_effective
    WHERE short_code = 'al1as6'::public.citext
    LIMIT 1)
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'alias_resolves_source'),
  'source alias resolves to canonical source_id_resolved'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'expired_not_effective'),
  'effective view marks expired links as not effective_active'
);

SELECT finish();

ROLLBACK;
