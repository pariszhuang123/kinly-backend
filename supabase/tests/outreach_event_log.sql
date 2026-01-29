SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(18);

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

-- Anonymous callers can log page views via RPC
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

SELECT ok(
  public.outreach_log_event(
    'page_view',
    'kinly-web',
    'landing',
    'campaign-a',
    'utm_web',
    'qr',
    'anon_session_00000001',
    NULL,
    'US',
    'en',
    NULL
  ) IS NOT NULL,
  'anon caller can log page_view'
);

SET LOCAL ROLE anon;
INSERT INTO tmp_results (label, ok) VALUES (
  'direct_insert_denied',
  pg_temp.exec_raises_like(
  $$INSERT INTO public.outreach_event_logs (id, event, app_key, page_key, utm_campaign, utm_source, utm_medium, session_id)
    VALUES (gen_random_uuid(), 'page_view', 'kinly-web', 'landing', 'campaign-a', 'utm_web', 'qr', 'sess-direct')$$,
  '%permission%'
));
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'direct_insert_denied'),
  'direct insert denied by RLS/privileges'
);

-- Invalid store should error
INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_store',
  pg_temp.exec_raises_like(
  $$SELECT public.outreach_log_event(
    'page_view','kinly-web','landing','campaign-a','utm_web','qr','anon_1234567890abcdef','bad_store','US','en',NULL)$$,
  '%INVALID_STORE%'
));
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_store'),
  'invalid store rejected'
);

-- Invalid session format should error
INSERT INTO tmp_results (label, ok) VALUES (
  'invalid_session',
  pg_temp.exec_raises_like(
  $$SELECT public.outreach_log_event(
    'page_view','kinly-web','landing','campaign-a','utm_web','qr','notanon',NULL,'US','en',NULL)$$,
  '%INVALID_SESSION%'
));
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_session'),
  'invalid session format rejected'
);

-- Seed a resolvable source as service_role
SET LOCAL ROLE service_role;
INSERT INTO public.outreach_sources (source_id, label)
VALUES ('source-allowed', 'Test Source')
ON CONFLICT (source_id) DO NOTHING;
INSERT INTO public.outreach_source_aliases (alias, source_id) VALUES ('fish&chips', 'fish_and_chips')
ON CONFLICT (alias) DO NOTHING;
-- Seeded defaults should exist
RESET ROLE;
SELECT ok(
  (SELECT count(*) FROM public.outreach_sources WHERE source_id IN ('fish_and_chips','uc','go_get_page','unknown')) >= 4,
  'default outreach sources are seeded'
);

-- Log CTA click with resolvable source + store
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

WITH ins AS (
  SELECT public.outreach_log_event(
    'cta_click',
    'kinly-web',
    'landing',
    'campaign-b',
    'utm_social',
    'social',
    'anon_session_00000002',
    'web',
    NULL,
    'en-US',
    NULL
  ) AS id
)
SELECT ok(
  (SELECT id IS NOT NULL FROM ins),
  'cta_click logged with resolvable source'
);

-- Validate stored values as service_role (bypasses RLS)
SET LOCAL ROLE service_role;

INSERT INTO tmp_results (label, ok) VALUES
  (
    'source_resolved_known',
    (SELECT source_id_resolved FROM public.outreach_event_logs WHERE session_id = 'anon_session_00000002' LIMIT 1) = 'source-allowed'
  ),
  (
    'source_resolved_unknown',
    (SELECT source_id_resolved FROM public.outreach_event_logs WHERE session_id = 'anon_session_00000001' LIMIT 1) = 'unknown'
  ),
  (
    'store_persists',
    (SELECT store FROM public.outreach_event_logs WHERE session_id = 'anon_session_00000002' LIMIT 1) = 'web'
  );
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'source_resolved_known'),
  'utm_source resolves via registry'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'source_resolved_unknown'),
  'unknown fallback when source not in registry'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'store_persists'),
  'store value persists'
);

-- Country/locale invalid values nulled
SELECT public.outreach_log_event(
  'page_view','kinly-web','landing','campaign-c','utm_social','qr','anon_aaaaaaaaaaaaaaaaaaaaaa',NULL,'ZZZ','en bad',NULL
);

SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES
  (
    'invalid_country_nulled',
    (SELECT country FROM public.outreach_event_logs WHERE utm_campaign = 'campaign-c' LIMIT 1) IS NULL
  ),
  (
    'invalid_locale_nulled',
    (SELECT ui_locale FROM public.outreach_event_logs WHERE utm_campaign = 'campaign-c' LIMIT 1) IS NULL
  );
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_country_nulled'),
  'invalid country nulled'
);
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'invalid_locale_nulled'),
  'invalid locale nulled'
);

-- Alias resolution
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

SELECT public.outreach_log_event(
  'page_view','kinly-web','landing','campaign-alias','fish&chips','qr','anon_alias_session_0001',NULL,'US','en',NULL
);

SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES
  (
    'alias_resolves',
    (SELECT source_id_resolved FROM public.outreach_event_logs WHERE utm_campaign = 'campaign-alias' LIMIT 1) = 'fish_and_chips'
  );
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'alias_resolves'),
  'alias resolves to canonical source'
);

-- Idempotency: same client_event_id returns same id
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
WITH first_call AS (
  SELECT (public.outreach_log_event(
    'page_view','kinly-web','landing','campaign-idem','utm_social','qr','anon_idem_session_0001',NULL,'US','en','3d6c2b57-ff8f-4d52-9c1e-9a28f1bd2e9a'
  )->>'id')::uuid AS id
),
second_call AS (
  SELECT (public.outreach_log_event(
    'page_view','kinly-web','landing','campaign-idem','utm_social','qr','anon_idem_session_0001',NULL,'US','en','3d6c2b57-ff8f-4d52-9c1e-9a28f1bd2e9a'
  )->>'id')::uuid AS id
)
SELECT ok(
  (SELECT id FROM first_call) = (SELECT id FROM second_call),
  'idempotent on client_event_id'
);

-- Rate limit per session (100/hr): 101st should fail
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..100 LOOP
    PERFORM public.outreach_log_event(
      'page_view','kinly-web','landing','campaign-rl','utm_web','qr','anon_rl_session_token1234',NULL,'US','en',NULL
    );
  END LOOP;
END$$;

SELECT throws_like(
  $$SELECT public.outreach_log_event(
    'page_view','kinly-web','landing','campaign-rl','utm_web','qr','anon_rl_session_token1234',NULL,'US','en',NULL)$$,
  '%RATE_LIMIT_SESSION%',
  'per-session rate limit enforced'
);

-- Global rate limit helper: bucketed counter should cap at limit
DO $$
DECLARE
  v_bucket timestamptz := date_trunc('minute', now());
  v_key text := 'test-global-' || gen_random_uuid()::text;
BEGIN
  PERFORM ok(public._outreach_rate_limit_bucketed(v_key, v_bucket, 2), 'global helper first hit');
  PERFORM ok(public._outreach_rate_limit_bucketed(v_key, v_bucket, 2), 'global helper second hit');
  PERFORM ok(NOT public._outreach_rate_limit_bucketed(v_key, v_bucket, 2), 'global helper blocks third hit');
END$$;

-- Global rate limit not easily hit here; placeholder ok

SELECT ok(
  (SELECT count(*) FROM public.outreach_event_logs WHERE event = 'page_view') <> 0,
  'page_view rows are present'
);

RESET ROLE;

SELECT finish();

ROLLBACK;
