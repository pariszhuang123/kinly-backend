SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(22);

CREATE TEMP TABLE tmp_results (
  label text PRIMARY KEY,
  ok boolean NOT NULL
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

-- -------------------------------------------------------------------
-- Tracking event enum rollout checks
-- -------------------------------------------------------------------
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

SELECT lives_ok(
  $$SELECT public.outreach_log_event(
      'poll_vote',
      'kinly-web',
      'polls_page_active',
      'campaign_polls_active',
      'uc',
      'qr',
      'anon_rollout_evt_0001',
      'web',
      'US',
      'en-US',
      NULL
    )$$,
  'outreach_log_event accepts poll_vote after enum rollout'
);

SELECT throws_like(
  $$SELECT public.outreach_log_event(
      'totally_invalid_event',
      'kinly-web',
      'polls_page_active',
      'campaign_polls_active',
      'uc',
      'qr',
      'anon_rollout_evt_0002',
      'web',
      'US',
      'en-US',
      NULL
    )$$,
  '%INVALID_EVENT%',
  'outreach_log_event rejects unknown event values'
);

-- -------------------------------------------------------------------
-- Seed poll + options + short links as service_role
-- -------------------------------------------------------------------
SET LOCAL ROLE service_role;

SELECT public.outreach_short_links_get_or_create(
  'plqa11',
  '/kinly/market/polls-active',
  '{}'::jsonb,
  'campaign_polls_active',
  'uc',
  'qr',
  'kinly-web',
  'polls_page_active',
  NULL
);

SELECT public.outreach_short_links_get_or_create(
  'plqi11',
  '/kinly/market/polls-inactive',
  '{}'::jsonb,
  'campaign_polls_inactive',
  'uc',
  'qr',
  'kinly-web',
  'polls_page_inactive',
  NULL
);

SELECT public.outreach_short_links_disable('plqi11');

SELECT public.outreach_short_links_get_or_create(
  'plqe11',
  '/kinly/market/polls-expired',
  '{}'::jsonb,
  'campaign_polls_expired',
  'uc',
  'qr',
  'kinly-web',
  'polls_page_expired',
  now() - interval '1 day'
);

SELECT public.outreach_short_links_get_or_create(
  'plqn11',
  '/kinly/market/polls-no-poll',
  '{}'::jsonb,
  'campaign_polls_no_poll',
  'uc',
  'qr',
  'kinly-web',
  'polls_page_no_poll',
  NULL
);

INSERT INTO public.outreach_polls (id, app_key, page_key, title, question, description, active)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'kinly-web', 'polls_page_active', 'Active poll', 'Pick one', 'desc', true),
  ('11111111-1111-4111-8111-111111111112', 'kinly-web', 'polls_page_inactive_record', 'Inactive poll', 'Pick one', NULL, false);

INSERT INTO public.outreach_poll_options (id, poll_id, option_key, label, position, active)
VALUES
  ('22222222-2222-4222-8222-222222222221', '11111111-1111-4111-8111-111111111111', 'option_yes', 'Yes', 2, true),
  ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'option_no', 'No', 1, true),
  ('22222222-2222-4222-8222-222222222223', '11111111-1111-4111-8111-111111111112', 'option_x', 'X', 1, true);

RESET ROLE;

-- -------------------------------------------------------------------
-- Permission surface
-- -------------------------------------------------------------------
SELECT ok(
  has_function_privilege(
    'anon',
    'public.outreach_poll_get_v1(text,text)',
    'EXECUTE'
  ),
  'anon can execute outreach_poll_get_v1'
);

SET LOCAL ROLE anon;
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_direct_vote_insert_denied',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_votes (
        poll_id, option_id, session_id, short_link_id, page_key,
        source_id_resolved, utm_campaign, utm_source, utm_medium, store
      ) VALUES (
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222221',
        'anon_poll_dir_0000001',
        (SELECT id FROM public.outreach_short_links WHERE short_code = 'plqa11'::public.citext LIMIT 1),
        'polls_page_active',
        'uc',
        'campaign_polls_active',
        'uc',
        'qr',
        'web'
      )$$,
    '%permission%'
  )
);
RESET ROLE;
SELECT ok(
  (SELECT ok FROM tmp_results WHERE label = 'anon_direct_vote_insert_denied'),
  'anon direct insert into outreach_poll_votes is denied'
);

-- -------------------------------------------------------------------
-- outreach_poll_get_v1 behavior
-- -------------------------------------------------------------------
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);

SELECT is(
  (public.outreach_poll_get_v1('kinly-web', 'polls_page_active')->>'ok')::boolean,
  true,
  'outreach_poll_get_v1 returns ok=true for active poll'
);

SELECT is(
  (public.outreach_poll_get_v1('kinly-web', 'polls_page_active')->'options'->0->>'option_key'),
  'option_no',
  'outreach_poll_get_v1 returns options ordered by position asc'
);

SELECT is(
  public.outreach_poll_get_v1('kinly-web', 'polls_page_inactive_record')->>'error',
  'POLL_NOT_FOUND',
  'outreach_poll_get_v1 returns POLL_NOT_FOUND for inactive poll'
);

-- -------------------------------------------------------------------
-- outreach_poll_vote_submit_v1 validation/error mapping
-- -------------------------------------------------------------------
SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'BAD CODE',
      'option_yes',
      'anon_pollsess_00000001',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%INVALID_SHORT_CODE%',
  'vote RPC rejects malformed short_code'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plzz99',
      'option_yes',
      'anon_pollsess_00000002',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%SHORT_CODE_NOT_FOUND%',
  'vote RPC returns SHORT_CODE_NOT_FOUND when code does not exist'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plqi11',
      'option_yes',
      'anon_pollsess_00000003',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%SHORT_CODE_INACTIVE%',
  'vote RPC returns SHORT_CODE_INACTIVE for disabled code'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plqn11',
      'option_yes',
      'anon_pollsess_00000004',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%POLL_NOT_FOUND%',
  'vote RPC returns POLL_NOT_FOUND when short link maps to page without active poll'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plqa11',
      'option_missing',
      'anon_pollsess_00000005',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%INVALID_OPTION%',
  'vote RPC returns INVALID_OPTION for unknown option_key'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plqa11',
      'option_yes',
      'not_anon',
      'web',
      NULL,
      'US',
      'en-US'
    )$$,
  '%INVALID_SESSION%',
  'vote RPC rejects invalid session_id'
);

SELECT throws_like(
  $$SELECT public.outreach_poll_vote_submit_v1(
      'plqa11',
      'option_yes',
      'anon_pollsess_00000006',
      'bad_store',
      NULL,
      'US',
      'en-US'
    )$$,
  '%INVALID_STORE%',
  'vote RPC rejects invalid store'
);

-- -------------------------------------------------------------------
-- vote happy path + one-net-vote + idempotency + event side effects
-- -------------------------------------------------------------------
SELECT is(
  (public.outreach_poll_vote_submit_v1(
    'plqa11',
    'option_no',
    'anon_pollsess_00000010',
    'web',
    NULL,
    'US',
    'en-US'
  )->>'ok')::boolean,
  true,
  'vote RPC succeeds for first vote'
);

SELECT public.outreach_poll_vote_submit_v1(
  'plqa11',
  'option_yes',
  'anon_pollsess_00000010',
  'web',
  NULL,
  'US',
  'en-US'
);

SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES
  (
    'one_net_vote_row_count',
    (
      SELECT count(*)
      FROM public.outreach_poll_votes
      WHERE poll_id = '11111111-1111-4111-8111-111111111111'
        AND session_id = 'anon_pollsess_00000010'
    ) = 1
  ),
  (
    'one_net_vote_updated_option',
    (
      SELECT o.option_key
      FROM public.outreach_poll_votes v
      JOIN public.outreach_poll_options o ON o.id = v.option_id
      WHERE v.poll_id = '11111111-1111-4111-8111-111111111111'
        AND v.session_id = 'anon_pollsess_00000010'
      LIMIT 1
    ) = 'option_yes'
  );
RESET ROLE;

SELECT is(
  (public.outreach_poll_vote_submit_v1(
    'plqa11',
    'option_no',
    'anon_pollsess_00000020',
    'web',
    '33333333-3333-4333-8333-333333333333',
    'US',
    'en-US'
  )->>'selected_option_key'),
  'option_no',
  'first vote with client_vote_id selects option_no'
);

SELECT is(
  (public.outreach_poll_vote_submit_v1(
    'plqa11',
    'option_yes',
    'anon_pollsess_00000020',
    'web',
    '33333333-3333-4333-8333-333333333333',
    'US',
    'en-US'
  )->>'selected_option_key'),
  'option_no',
  'duplicate client_vote_id is idempotent and returns original logical vote'
);

SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES
  (
    'idempotent_vote_single_row',
    (
      SELECT count(*)
      FROM public.outreach_poll_votes
      WHERE client_vote_id = '33333333-3333-4333-8333-333333333333'
    ) = 1
  );
RESET ROLE;

SELECT public.outreach_poll_vote_submit_v1(
  'plqa11',
  'option_yes',
  'anon_pollsess_00000030',
  'web',
  NULL,
  'US',
  'en-US'
);

SET LOCAL ROLE service_role;
INSERT INTO tmp_results (label, ok) VALUES
  (
    'event_emitted_once',
    (
      SELECT count(*)
      FROM public.outreach_event_logs
      WHERE event = 'poll_vote'
        AND session_id = 'anon_pollsess_00000030'
    ) = 1
  ),
  (
    'event_fields_match_short_link_snapshot',
    (
      SELECT
        e.page_key = s.page_key
        AND e.utm_campaign = s.utm_campaign
        AND e.utm_source = s.utm_source
        AND e.utm_medium = s.utm_medium
        AND e.store = 'web'
      FROM public.outreach_event_logs e
      JOIN public.outreach_short_links s
        ON s.short_code = 'plqa11'::public.citext
      WHERE e.event = 'poll_vote'
        AND e.session_id = 'anon_pollsess_00000030'
      LIMIT 1
    )
  );
RESET ROLE;

SELECT ok((SELECT ok FROM tmp_results WHERE label = 'one_net_vote_row_count'), 'one-net-vote keeps one row per poll/session');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'one_net_vote_updated_option'), 'one-net-vote updates selected option');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'idempotent_vote_single_row'), 'duplicate client_vote_id does not create extra vote rows');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'event_emitted_once'), 'successful vote emits one poll_vote event');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'event_fields_match_short_link_snapshot'), 'poll_vote event payload matches short-link snapshot');

SELECT * FROM finish();
ROLLBACK;
