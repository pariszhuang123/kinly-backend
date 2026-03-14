SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(28);

-- Helper UUIDs (temp table for reuse)
CREATE TEMP TABLE consts AS
SELECT
  '00000000-0000-4000-8000-000000000901'::uuid AS req_id,
  '00000000-0000-4000-8000-000000000902'::uuid AS home_id,
  '00000000-0000-4000-8000-000000000903'::uuid AS sender_id,
  '00000000-0000-4000-8000-000000000904'::uuid AS recipient_id,
  '00000000-0000-4000-8000-000000000905'::uuid AS snap_id,
  '00000000-0000-4000-8000-000000000906'::uuid AS pref_snap_id;

INSERT INTO public.rewrite_requests (
  rewrite_request_id, home_id, sender_user_id, recipient_user_id,
  surface, original_text, source_locale, target_locale, lane,
  topics, intent, rewrite_strength,
  classifier_result, context_pack, rewrite_request,
  classifier_version, context_pack_version, policy_version
)
SELECT
  req_id, home_id, sender_id, recipient_id,
  'weekly_harmony', 'hello', 'en', 'en', 'same_language',
  '["noise","communication"]'::jsonb, 'request', 'light_touch',
  '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
  'v1', 'v1', 'v1'
FROM consts
ON CONFLICT DO NOTHING;

-- Snapshots tied to request (for downstream FK tests)
INSERT INTO public.recipient_snapshots(recipient_snapshot_id, rewrite_request_id, home_id, recipient_user_ids)
SELECT snap_id, req_id, home_id, ARRAY[recipient_id] FROM consts
ON CONFLICT DO NOTHING;

INSERT INTO public.recipient_preference_snapshots(recipient_preference_snapshot_id, rewrite_request_id, recipient_user_id, preference_payload)
SELECT pref_snap_id, req_id, recipient_id, '{}'::jsonb FROM consts
ON CONFLICT DO NOTHING;

-- 1) Topics enum guard: bad value rejected
SELECT throws_like(
  $$
  INSERT INTO public.rewrite_requests (
    rewrite_request_id, home_id, sender_user_id, recipient_user_id,
    surface, original_text, source_locale, target_locale, lane,
    topics, intent, rewrite_strength,
    classifier_result, context_pack, rewrite_request,
    classifier_version, context_pack_version, policy_version
  ) VALUES (
    '00000000-0000-4000-8000-000000000911',
    '00000000-0000-4000-8000-000000000912',
    '00000000-0000-4000-8000-000000000913',
    '00000000-0000-4000-8000-000000000914',
    'other', 'text', 'en', 'en', 'same_language',
    '["noise","bad_topic"]'::jsonb, 'request', 'light_touch',
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    'v1', 'v1', 'v1'
  );
  $$::text,
  '.*',
  'rejects topics outside allowed set'
);

-- 2) Topics length guard: empty array rejected
SELECT throws_like(
  $$
  INSERT INTO public.rewrite_requests (
    rewrite_request_id, home_id, sender_user_id, recipient_user_id,
    surface, original_text, source_locale, target_locale, lane,
    topics, intent, rewrite_strength,
    classifier_result, context_pack, rewrite_request,
    classifier_version, context_pack_version, policy_version
  ) VALUES (
    '00000000-0000-4000-8000-000000000921',
    '00000000-0000-4000-8000-000000000922',
    '00000000-0000-4000-8000-000000000923',
    '00000000-0000-4000-8000-000000000924',
    'other', 'text', 'en', 'en', 'same_language',
    '[]'::jsonb, 'request', 'light_touch',
    '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    'v1', 'v1', 'v1'
  );
  $$::text,
  '.*',
  'rejects empty topics array'
);

-- 3) rewrite_outputs locale primary must match
SELECT throws_like(
  $$
  INSERT INTO public.rewrite_outputs(
    rewrite_request_id, recipient_user_id,
    rewritten_text, output_language, target_locale,
    model, provider, prompt_version, policy_version, lexicon_version, eval_result
  ) VALUES (
    '00000000-0000-4000-8000-000000000901',
    '00000000-0000-4000-8000-000000000904',
    'hi', 'fr', 'en-NZ',
    'gpt', 'openai', 'v1', 'v1', 'v1', '{}'::jsonb
  );
  $$::text,
  '.*',
  'rejects mismatched output_language / target_locale primary'
);

-- 4) rewrite_jobs status check catches invalid status
SELECT throws_like(
  $$
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status
  ) VALUES (
    '00000000-0000-4000-8000-000000000901',
    '00000000-0000-4000-8000-000000000904',
    '00000000-0000-4000-8000-000000000905',
    '00000000-0000-4000-8000-000000000906',
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'unknown_status'
  );
  $$::text,
  '.*',
  'invalid status rejected'
);

-- 5) complaint_rewrite_job_fail_or_requeue requeues with backoff when attempts remain
DELETE FROM public.rewrite_jobs
WHERE rewrite_request_id = (SELECT req_id FROM consts)
  AND recipient_user_id = (SELECT recipient_id FROM consts);

WITH job_retry AS (
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status,
    attempt_count, max_attempts
  ) VALUES (
    (SELECT req_id FROM consts),
    (SELECT recipient_id FROM consts),
    (SELECT snap_id FROM consts),
    (SELECT pref_snap_id FROM consts),
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'queued',
    0, 2
  ) RETURNING job_id
)
SELECT lives_ok(
  $$ select public.complaint_rewrite_job_fail_or_requeue((select job_id from job_retry), 'err', 120); $$,
  'fail_or_requeue executes'
),
is(
  (SELECT status FROM public.rewrite_jobs WHERE job_id = (SELECT job_id FROM job_retry)),
  'queued'::text,
  'job remains queued for retry'
),
ok(
  (SELECT not_before_at > now() FROM public.rewrite_jobs WHERE job_id = (SELECT job_id FROM job_retry)),
  'not_before_at set in future'
);

-- 6) complaint_rewrite_job_fail_or_requeue marks failed when attempts exhausted
DELETE FROM public.rewrite_jobs
WHERE rewrite_request_id = (SELECT req_id FROM consts)
  AND recipient_user_id = (SELECT recipient_id FROM consts);

WITH job_fail AS (
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status,
    attempt_count, max_attempts
  ) VALUES (
    (SELECT req_id FROM consts),
    (SELECT recipient_id FROM consts),
    (SELECT snap_id FROM consts),
    (SELECT pref_snap_id FROM consts),
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'queued',
    2, 2
  ) RETURNING job_id
)
SELECT lives_ok(
  $$ select public.complaint_rewrite_job_fail_or_requeue((select job_id from job_fail), 'err', 60); $$,
  'fail_or_requeue executes at max attempts'
),
is(
  (SELECT status FROM public.rewrite_jobs WHERE job_id = (SELECT job_id FROM job_fail)),
  'failed'::text,
  'job marked failed when attempts exhausted'
);

-- 7) mark_rewrite_jobs_batch_submitted transitions processing -> batch_submitted and sets provider_batch_id
DELETE FROM public.rewrite_jobs
WHERE rewrite_request_id = (SELECT req_id FROM consts)
  AND recipient_user_id = (SELECT recipient_id FROM consts);

INSERT INTO public.rewrite_provider_batches(provider_batch_id, provider, endpoint, status, job_count)
VALUES ('batch_test_1', 'openai', '/v1/responses', 'submitted', 1)
ON CONFLICT DO NOTHING;

WITH job_batch AS (
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status
  ) VALUES (
    (SELECT req_id FROM consts),
    (SELECT recipient_id FROM consts),
    (SELECT snap_id FROM consts),
    (SELECT pref_snap_id FROM consts),
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'processing'
  ) RETURNING job_id
)
SELECT lives_ok(
  $$ select public.mark_rewrite_jobs_batch_submitted_v1(ARRAY[ (SELECT job_id FROM job_batch)], 'batch_test_1'); $$,
  'mark_rewrite_jobs_batch_submitted_v1 executes'
),
is(
  (SELECT status FROM public.rewrite_jobs WHERE job_id =  (SELECT job_id FROM job_batch)),
  'batch_submitted'::text,
  'job status updated to batch_submitted'
),
is(
  (SELECT provider_batch_id FROM public.rewrite_jobs WHERE job_id =  (SELECT job_id FROM job_batch)),
  'batch_test_1',
  'provider_batch_id set'
);

-- 8) complete_complaint_rewrite_job inserts output and completes request when sole job
INSERT INTO public.rewrite_requests(
  rewrite_request_id, home_id, sender_user_id, recipient_user_id,
  surface, original_text, source_locale, target_locale, lane,
  topics, intent, rewrite_strength,
  classifier_result, context_pack, rewrite_request,
  classifier_version, context_pack_version, policy_version,
  status
) VALUES (
  '00000000-0000-4000-8000-000000000931',
  '00000000-0000-4000-8000-000000000935',
  '00000000-0000-4000-8000-000000000936',
  '00000000-0000-4000-8000-000000000932',
  'direct_message', 'please help', 'en', 'en-US', 'same_language',
  '["noise"]'::jsonb, 'request', 'light_touch',
  '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
  'v1', 'v1', 'v1',
  'processing'
) ON CONFLICT DO NOTHING;

INSERT INTO public.recipient_snapshots(recipient_snapshot_id, rewrite_request_id, home_id, recipient_user_ids)
VALUES ('00000000-0000-4000-8000-000000000933', '00000000-0000-4000-8000-000000000931', '00000000-0000-4000-8000-000000000935', ARRAY['00000000-0000-4000-8000-000000000932'::uuid])
ON CONFLICT DO NOTHING;

INSERT INTO public.recipient_preference_snapshots(recipient_preference_snapshot_id, rewrite_request_id, recipient_user_id, preference_payload)
VALUES ('00000000-0000-4000-8000-000000000934', '00000000-0000-4000-8000-000000000931', '00000000-0000-4000-8000-000000000932', '{}'::jsonb)
ON CONFLICT DO NOTHING;

WITH job_batch AS (
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status
  ) VALUES (
    '00000000-0000-4000-8000-000000000931',
    '00000000-0000-4000-8000-000000000932',
    '00000000-0000-4000-8000-000000000933',
    '00000000-0000-4000-8000-000000000934',
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'processing'
  ) RETURNING job_id, rewrite_request_id, recipient_user_id
)
SELECT lives_ok(
  $$
  select public.complete_complaint_rewrite_job(
     (SELECT job_id FROM job_batch),
    (select rewrite_request_id from job),
    (select recipient_user_id from job),
    'Rewritten text',
    'en',
    'en-US',
    'gpt-5',
    'openai',
    'v1',
    'v1',
    'lex_v1',
    '{}'::jsonb
  );
  $$,
  'complete_complaint_rewrite_job executes'
),
is(
  (SELECT status FROM public.rewrite_jobs WHERE job_id =  (SELECT job_id FROM job_batch)),
  'completed'::text,
  'job marked completed'
),
is(
  (SELECT status FROM public.rewrite_requests WHERE rewrite_request_id = (SELECT rewrite_request_id FROM job_batch)),
  'completed'::text,
  'request marked completed when all jobs terminal'
),
is(
  (SELECT rewritten_text FROM public.rewrite_outputs WHERE rewrite_request_id = (SELECT rewrite_request_id FROM job_batch)),
  'Rewritten text',
  'output row inserted'
);

-- 9) rewrite_jobs_requeue_by_provider_batch nulls provider_batch_id and backoffs
INSERT INTO public.rewrite_provider_batches(provider_batch_id, provider, endpoint, status, job_count)
VALUES ('batch_test_2', 'openai', '/v1/responses', 'submitted', 1)
ON CONFLICT DO NOTHING;

INSERT INTO public.rewrite_requests(
  rewrite_request_id, home_id, sender_user_id, recipient_user_id,
  surface, original_text, source_locale, target_locale, lane,
  topics, intent, rewrite_strength,
  classifier_result, context_pack, rewrite_request,
  classifier_version, context_pack_version, policy_version
) VALUES (
  '00000000-0000-4000-8000-000000000941',
  '00000000-0000-4000-8000-000000000941',
  '00000000-0000-4000-8000-000000000941',
  '00000000-0000-4000-8000-000000000942',
  'weekly_harmony', 'text', 'en', 'en', 'same_language',
  '["other"]'::jsonb, 'concern', 'light_touch',
  '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
  'v1', 'v1', 'v1'
) ON CONFLICT DO NOTHING;

INSERT INTO public.recipient_snapshots(recipient_snapshot_id, rewrite_request_id, home_id, recipient_user_ids)
VALUES (
  '00000000-0000-4000-8000-000000000943',
  '00000000-0000-4000-8000-000000000941',
  '00000000-0000-4000-8000-000000000941',
  ARRAY['00000000-0000-4000-8000-000000000942'::uuid]
)
ON CONFLICT DO NOTHING;

INSERT INTO public.recipient_preference_snapshots(recipient_preference_snapshot_id, rewrite_request_id, recipient_user_id, preference_payload)
VALUES ('00000000-0000-4000-8000-000000000944', '00000000-0000-4000-8000-000000000941', '00000000-0000-4000-8000-000000000942', '{}'::jsonb)
ON CONFLICT DO NOTHING;

WITH job_batch AS (
  INSERT INTO public.rewrite_jobs(
    rewrite_request_id, recipient_user_id,
    recipient_snapshot_id, recipient_preference_snapshot_id,
    task, surface, rewrite_strength, lane,
    language_pair, routing_decision, status,
    provider_batch_id
  ) VALUES (
    '00000000-0000-4000-8000-000000000941',
    '00000000-0000-4000-8000-000000000942',
    '00000000-0000-4000-8000-000000000943',
    '00000000-0000-4000-8000-000000000944',
    'complaint_rewrite', 'weekly_harmony', 'light_touch', 'same_language',
    '{}'::jsonb, '{}'::jsonb, 'batch_submitted',
    'batch_test_2'
  ) RETURNING job_id
)
SELECT lives_ok(
  $$ select * from public.rewrite_jobs_requeue_by_provider_batch_v1('batch_test_2', 'missing_output', 600, 10); $$,
  'rewrite_jobs_requeue_by_provider_batch_v1 executes'
),
is(
  (SELECT status FROM public.rewrite_jobs WHERE job_id =  (SELECT job_id FROM job_batch)),
  'queued'::text,
  'job requeued from batch_submitted'
),
ok(
  (SELECT provider_batch_id IS NULL FROM public.rewrite_jobs WHERE job_id =  (SELECT job_id FROM job_batch)),
  'provider_batch_id cleared on requeue'
);

-- 10) Deleting rewrite_request cascades to snapshots and jobs
DELETE FROM public.rewrite_jobs
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid;

DELETE FROM public.recipient_preference_snapshots
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid;

DELETE FROM public.recipient_snapshots
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid;

DELETE FROM public.rewrite_requests
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid;

INSERT INTO public.rewrite_requests(
  rewrite_request_id, home_id, sender_user_id, recipient_user_id,
  surface, original_text, source_locale, target_locale, lane,
  topics, intent, rewrite_strength,
  classifier_result, context_pack, rewrite_request,
  classifier_version, context_pack_version, policy_version
) VALUES (
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  'other', 'bye', 'en', 'en', 'same_language',
  '["other"]'::jsonb, 'concern', 'full_reframe',
  '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
  'v1', 'v1', 'v1'
);

INSERT INTO public.recipient_snapshots(recipient_snapshot_id, rewrite_request_id, home_id, recipient_user_ids)
VALUES (
  '00000000-0000-4000-8000-000000000952',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  ARRAY['00000000-0000-4000-8000-000000000951'::uuid]
);

INSERT INTO public.recipient_preference_snapshots(
  recipient_preference_snapshot_id,
  rewrite_request_id,
  recipient_user_id,
  preference_payload
)
VALUES (
  '00000000-0000-4000-8000-000000000953',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  '{}'::jsonb
);

INSERT INTO public.rewrite_jobs(
  job_id, rewrite_request_id, recipient_user_id,
  recipient_snapshot_id, recipient_preference_snapshot_id,
  task, surface, rewrite_strength, lane,
  language_pair, routing_decision, status
)
VALUES (
  '00000000-0000-4000-8000-000000000954',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000951',
  '00000000-0000-4000-8000-000000000952',
  '00000000-0000-4000-8000-000000000953',
  'complaint_rewrite', 'other', 'full_reframe', 'same_language',
  '{}'::jsonb, '{}'::jsonb, 'queued'
);

DELETE FROM public.rewrite_requests
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid;

SELECT is(
  (SELECT COUNT(*) FROM public.recipient_snapshots WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid),
  0::bigint,
  'recipient_snapshots cascade deleted'
);

SELECT is(
  (SELECT COUNT(*) FROM public.rewrite_jobs WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000951'::uuid),
  0::bigint,
  'rewrite_jobs cascade deleted'
);

-- 11) complaint_fetch_entry_locales returns authoritative row data for a real mood entry
CREATE TEMP TABLE complaint_fetch_users (
  label text PRIMARY KEY,
  user_id uuid NOT NULL,
  email text NOT NULL
);

CREATE TEMP TABLE complaint_fetch_runtime (
  home_id uuid,
  entry_id uuid
);

INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000977', 'avatars/default.png', 'animal', 'Complaint Rewrite Avatar')
ON CONFLICT (id) DO NOTHING;

INSERT INTO complaint_fetch_users (label, user_id, email) VALUES
  ('author', '00000000-0000-4000-8000-000000000971', 'complaint-author@example.com'),
  ('recipient', '00000000-0000-4000-8000-000000000972', 'complaint-recipient@example.com');

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
FROM complaint_fetch_users
ON CONFLICT (id) DO NOTHING;

DELETE FROM public.home_mood_entries
WHERE user_id IN (SELECT user_id FROM complaint_fetch_users);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM complaint_fetch_users WHERE label = 'author'),
  true
);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO complaint_fetch_runtime (home_id)
SELECT (payload->'home'->>'id')::uuid FROM res;

WITH payload AS (
  SELECT *
  FROM public.mood_submit(
    (SELECT home_id FROM complaint_fetch_runtime LIMIT 1),
    'thunderstorm',
    'Please keep the kitchen quieter late at night',
    false
  )
)
UPDATE complaint_fetch_runtime
SET entry_id = (SELECT entry_id FROM payload);

SELECT is(
  (
    SELECT recipient_locale
    FROM public.complaint_fetch_entry_locales(
      (SELECT entry_id FROM complaint_fetch_runtime LIMIT 1),
      (SELECT user_id FROM complaint_fetch_users WHERE label = 'recipient')
    )
  ),
  'en'::text,
  'complaint_fetch_entry_locales defaults recipient locale to en'
);

SELECT is(
  (
    SELECT home_id
    FROM public.complaint_fetch_entry_locales(
      (SELECT entry_id FROM complaint_fetch_runtime LIMIT 1),
      (SELECT user_id FROM complaint_fetch_users WHERE label = 'recipient')
    )
  ),
  (SELECT home_id FROM complaint_fetch_runtime LIMIT 1),
  'complaint_fetch_entry_locales returns the entry home_id'
);

SELECT is(
  (
    SELECT author_user_id
    FROM public.complaint_fetch_entry_locales(
      (SELECT entry_id FROM complaint_fetch_runtime LIMIT 1),
      (SELECT user_id FROM complaint_fetch_users WHERE label = 'recipient')
    )
  ),
  (SELECT user_id FROM complaint_fetch_users WHERE label = 'author'),
  'complaint_fetch_entry_locales returns the entry author_user_id'
);

SELECT is(
  (
    SELECT recipient_user_id
    FROM public.complaint_fetch_entry_locales(
      (SELECT entry_id FROM complaint_fetch_runtime LIMIT 1),
      (SELECT user_id FROM complaint_fetch_users WHERE label = 'recipient')
    )
  ),
  (SELECT user_id FROM complaint_fetch_users WHERE label = 'recipient'),
  'complaint_fetch_entry_locales returns the requested recipient_user_id'
);

-- 12) complaint_rewrite_enqueue accepts the orchestrator payload shape and persists snapshots/jobs
DELETE FROM public.rewrite_jobs
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid;

DELETE FROM public.recipient_preference_snapshots
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid;

DELETE FROM public.recipient_snapshots
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid;

DELETE FROM public.rewrite_requests
WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid;

SELECT ok(
  public.complaint_rewrite_enqueue(
    '00000000-0000-4000-8000-000000000981'::uuid,
    '00000000-0000-4000-8000-000000000982'::uuid,
    '00000000-0000-4000-8000-000000000983'::uuid,
    '00000000-0000-4000-8000-000000000984'::uuid,
    'weekly_harmony',
    'Please leave the dishes soaking instead of piling them up',
    '{"rewrite_request_id":"00000000-0000-4000-8000-000000000981"}'::jsonb,
    '{"classifier_version":"v1","detected_language":"en","topics":["noise"],"intent":"concern","rewrite_strength":"full_reframe","safety_flags":[]}'::jsonb,
    '{"tone":"gentle"}'::jsonb,
    'en',
    'en',
    'same_language',
    '["noise"]'::jsonb,
    'concern',
    'full_reframe',
    'v1',
    'v1.1',
    'v1',
    '{"provider":"openai","model":"gpt-5-mini"}'::jsonb,
    '{"from":"en","to":"en"}'::jsonb,
    '{"preferences":{"communication_directness":"gentle"}}'::jsonb,
    2
  ) IS NOT NULL,
  'complaint_rewrite_enqueue accepts orchestrator payload shape'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.rewrite_requests
    WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid
      AND recipient_snapshot_id IS NOT NULL
      AND recipient_preference_snapshot_id IS NOT NULL
  ),
  'complaint_rewrite_enqueue stores snapshot ids on rewrite_requests'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.rewrite_jobs
    WHERE rewrite_request_id = '00000000-0000-4000-8000-000000000981'::uuid
      AND recipient_user_id = '00000000-0000-4000-8000-000000000984'::uuid
  ),
  'complaint_rewrite_enqueue inserts the rewrite job'
);

SELECT * FROM finish();
ROLLBACK;
