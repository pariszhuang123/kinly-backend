SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT plan(21);

CREATE TEMP TABLE tmp_results (
  label text PRIMARY KEY,
  ok boolean NOT NULL
);

GRANT ALL ON TABLE tmp_results TO anon;
GRANT ALL ON TABLE tmp_results TO authenticated;
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

SELECT ok(
  to_regclass('public.outreach_poll_result_messages') IS NOT NULL,
  'outreach_poll_result_messages table exists'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'outreach_poll_result_messages'
      AND c.relrowsecurity
  ),
  'RLS enabled on outreach_poll_result_messages'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'outreach_poll_result_messages'
      AND t.tgname = 'trg_outreach_poll_result_messages_touch_updated_at'
      AND NOT t.tgisinternal
  ),
  'updated_at trigger exists on outreach_poll_result_messages'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (c.conkey)
    JOIN pg_class ft ON ft.oid = c.confrelid
    JOIN pg_namespace fn ON fn.oid = ft.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'outreach_poll_result_messages'
      AND c.contype = 'f'
      AND a.attname = 'option_id'
      AND array_length(c.conkey, 1) = 1
      AND fn.nspname = 'public'
      AND ft.relname = 'outreach_poll_options'
  ),
  'direct option_id foreign key to outreach_poll_options exists'
);

SET LOCAL ROLE service_role;

INSERT INTO public.outreach_sources (source_id, label, active)
VALUES ('oprm_test_source', 'OPRM Test Source', true)
ON CONFLICT (source_id) DO NOTHING;

INSERT INTO public.outreach_polls (id, app_key, page_key, title, question, description, active)
VALUES (
  '61111111-1111-4111-8111-111111111111',
  'kinly-web',
  'oprm_test_page_a',
  'OPRM poll A',
  'Which option?',
  NULL,
  true
),
(
  '61111111-1111-4111-8111-111111111112',
  'kinly-web',
  'oprm_test_page_b',
  'OPRM poll B',
  'Which option?',
  NULL,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.outreach_poll_options (id, poll_id, option_key, label, position, active)
VALUES
  ('62222222-2222-4222-8222-222222222221', '61111111-1111-4111-8111-111111111111', 'opt_a1', 'A1', 1, true),
  ('62222222-2222-4222-8222-222222222222', '61111111-1111-4111-8111-111111111111', 'opt_a2', 'A2', 2, true),
  ('62222222-2222-4222-8222-222222222223', '61111111-1111-4111-8111-111111111112', 'opt_b1', 'B1', 1, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.outreach_poll_result_messages (
  id, poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
)
VALUES (
  '63333333-3333-4333-8333-333333333331',
  '61111111-1111-4111-8111-111111111111',
  '62222222-2222-4222-8222-222222222221',
  'Global active message',
  'Open App',
  NULL,
  NULL,
  true
);

RESET ROLE;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.outreach_poll_result_messages
    WHERE id = '63333333-3333-4333-8333-333333333331'
  ),
  'service_role can insert outreach poll result messages'
);

SET LOCAL ROLE service_role;

INSERT INTO tmp_results (label, ok) VALUES (
  'campaign_without_source_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Invalid campaign without source',
        'Open',
        NULL,
        'campaign_only',
        true
      )$$,
    '%chk_outreach_poll_result_messages_target_pairing%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'composite_fk_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222223',
        'Invalid mismatched option',
        'Open',
        NULL,
        NULL,
        true
      )$$,
    '%fk_outreach_poll_result_messages_poll_option%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'primary_message_length_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        '   ',
        'Open',
        NULL,
        NULL,
        true
      )$$,
    '%chk_outreach_poll_result_messages_primary_message_len%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'cta_label_length_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Valid message',
        '   ',
        NULL,
        NULL,
        true
      )$$,
    '%chk_outreach_poll_result_messages_cta_label_len%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'campaign_length_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Valid message',
        'Open',
        'oprm_test_source',
        repeat('x', 129),
        true
      )$$,
    '%chk_outreach_poll_result_messages_campaign_len%'
  )
);

INSERT INTO public.outreach_poll_result_messages (
  id, poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
)
VALUES (
  '63333333-3333-4333-8333-333333333332',
  '61111111-1111-4111-8111-111111111111',
  '62222222-2222-4222-8222-222222222221',
  'Source-only active',
  'Open App',
  'oprm_test_source',
  NULL,
  true
);

INSERT INTO public.outreach_poll_result_messages (
  id, poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
)
VALUES (
  '63333333-3333-4333-8333-333333333333',
  '61111111-1111-4111-8111-111111111111',
  '62222222-2222-4222-8222-222222222221',
  'Exact active',
  'Open App',
  'oprm_test_source',
  'oprm_campaign_a',
  true
);

INSERT INTO tmp_results (label, ok) VALUES (
  'duplicate_global_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Duplicate global',
        'Open App',
        NULL,
        NULL,
        true
      )$$,
    '%uq_outreach_poll_result_messages_target_tuple%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'duplicate_source_only_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Duplicate source only',
        'Open App',
        'oprm_test_source',
        NULL,
        true
      )$$,
    '%uq_outreach_poll_result_messages_target_tuple%'
  )
);

INSERT INTO tmp_results (label, ok) VALUES (
  'duplicate_exact_rejected',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Duplicate exact',
        'Open App',
        'oprm_test_source',
        'oprm_campaign_a',
        true
      )$$,
    '%uq_outreach_poll_result_messages_target_tuple%'
  )
);

RESET ROLE;

SELECT ok((SELECT ok FROM tmp_results WHERE label = 'campaign_without_source_rejected'), 'campaign without source is rejected');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'composite_fk_rejected'), 'mismatched poll/option pair is rejected');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'primary_message_length_rejected'), 'primary_message trimmed length check enforced');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'cta_label_length_rejected'), 'cta_label trimmed length check enforced');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'campaign_length_rejected'), 'utm_campaign length check enforced');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'duplicate_global_rejected'), 'duplicate global target tuple is rejected');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'duplicate_source_only_rejected'), 'duplicate source-only target tuple is rejected');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'duplicate_exact_rejected'), 'duplicate exact target tuple is rejected');

SET LOCAL ROLE anon;
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_reads_active_only',
  (
    SELECT count(*)
    FROM public.outreach_poll_result_messages
    WHERE poll_id = '61111111-1111-4111-8111-111111111111'
      AND option_id = '62222222-2222-4222-8222-222222222221'
  ) = 3
);
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_insert_denied',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Anon insert attempt',
        'Open',
        NULL,
        NULL,
        true
      )$$,
    '%permission%'
  )
);
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_update_denied',
  pg_temp.exec_raises_like(
    $$UPDATE public.outreach_poll_result_messages
      SET primary_message = 'Anon update attempt'
      WHERE id = '63333333-3333-4333-8333-333333333331'$$,
    '%permission%'
  )
);
INSERT INTO tmp_results (label, ok) VALUES (
  'anon_delete_denied',
  pg_temp.exec_raises_like(
    $$DELETE FROM public.outreach_poll_result_messages
      WHERE id = '63333333-3333-4333-8333-333333333331'$$,
    '%permission%'
  )
);
RESET ROLE;

SELECT ok((SELECT ok FROM tmp_results WHERE label = 'anon_reads_active_only'), 'anon can read only active rows');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'anon_insert_denied'), 'anon cannot insert rows');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'anon_update_denied'), 'anon cannot update rows');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'anon_delete_denied'), 'anon cannot delete rows');

SET LOCAL ROLE authenticated;
INSERT INTO tmp_results (label, ok) VALUES (
  'authenticated_reads_active_only',
  (
    SELECT count(*)
    FROM public.outreach_poll_result_messages
    WHERE poll_id = '61111111-1111-4111-8111-111111111111'
      AND option_id = '62222222-2222-4222-8222-222222222221'
  ) = 3
);
INSERT INTO tmp_results (label, ok) VALUES (
  'authenticated_insert_denied',
  pg_temp.exec_raises_like(
    $$INSERT INTO public.outreach_poll_result_messages (
        poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active
      ) VALUES (
        '61111111-1111-4111-8111-111111111111',
        '62222222-2222-4222-8222-222222222221',
        'Authenticated insert attempt',
        'Open',
        NULL,
        NULL,
        true
      )$$,
    '%permission%'
  )
);
RESET ROLE;

SELECT ok((SELECT ok FROM tmp_results WHERE label = 'authenticated_reads_active_only'), 'authenticated can read only active rows');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'authenticated_insert_denied'), 'authenticated cannot insert rows');

SET LOCAL ROLE service_role;
UPDATE public.outreach_poll_result_messages
SET primary_message = 'Global active message updated',
    updated_at = '2000-01-01 00:00:00+00'
WHERE id = '63333333-3333-4333-8333-333333333331';

INSERT INTO tmp_results (label, ok) VALUES (
  'updated_at_touch_trigger_applied',
  (
    SELECT updated_at > '2020-01-01 00:00:00+00'::timestamptz
    FROM public.outreach_poll_result_messages
    WHERE id = '63333333-3333-4333-8333-333333333331'
  )
);

DELETE FROM public.outreach_poll_result_messages
WHERE id = '63333333-3333-4333-8333-333333333333';

INSERT INTO tmp_results (label, ok) VALUES (
  'service_role_delete_works',
  (
    SELECT count(*)
    FROM public.outreach_poll_result_messages
    WHERE id = '63333333-3333-4333-8333-333333333333'
  ) = 0
);
RESET ROLE;

SELECT ok((SELECT ok FROM tmp_results WHERE label = 'updated_at_touch_trigger_applied'), 'updated_at trigger overrides stale updated_at on update');
SELECT ok((SELECT ok FROM tmp_results WHERE label = 'service_role_delete_works'), 'service_role can delete rows');

SELECT finish();

ROLLBACK;
