-- ============================================================
-- Route mood_submit_v2 complaint rewrite queueing through RPC
-- - Replace direct table insert with complaint_trigger_enqueue
-- - Preserves queue authority + invariants in one path
-- ============================================================

CREATE OR REPLACE FUNCTION public.mood_submit_v2(
  p_home_id      uuid,
  p_mood         public.mood_scale,
  p_comment      text DEFAULT NULL,
  p_public_wall  boolean DEFAULT FALSE,
  p_mentions     uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id        uuid;
  v_now            timestamptz := now();
  v_iso_week       int;
  v_iso_week_year  int;

  v_entry_id       uuid;
  v_comment_trim   text;

  v_message        text;
  v_post_id        uuid;
  v_source_kind    text;

  v_mentions_raw   uuid[] := COALESCE(p_mentions, ARRAY[]::uuid[]);
  v_mentions_dedup uuid[] := ARRAY[]::uuid[];
  v_mention_count  int := 0;

  v_publish_requested boolean;

  v_pulse_row public.house_pulse_weekly;

  -- complaint rewrite gate (Option A)
  v_should_rewrite boolean := false;
  v_recipient_id uuid;
  v_has_prefs boolean := false;

  -- cheap quality checks (only for negative mention path)
  v_is_negative boolean := false;
  v_meaningful_chars int := 0;
  v_word_count int := 0;
BEGIN
  PERFORM public._assert_authenticated();
  v_user_id := auth.uid();

  PERFORM public.api_assert(p_home_id IS NOT NULL, 'INVALID_HOME', 'Home id is required.', '22023');
  PERFORM public.api_assert(p_mood IS NOT NULL, 'INVALID_MOOD', 'Mood is required.', '22023');

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  -- Canonical UTC ISO week/year
  SELECT w.iso_week_year, w.iso_week
    INTO v_iso_week_year, v_iso_week
    FROM public._iso_week_utc(v_now) w;

  v_comment_trim := NULLIF(btrim(p_comment), '');

  BEGIN
    INSERT INTO public.home_mood_entries (
      home_id, user_id, mood, comment, iso_week_year, iso_week
    )
    VALUES (
      p_home_id,
      v_user_id,
      p_mood,
      CASE WHEN v_comment_trim IS NULL THEN NULL ELSE left(v_comment_trim, 500) END,
      v_iso_week_year,
      v_iso_week
    )
    RETURNING id INTO v_entry_id;
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_assert(
        FALSE,
        'MOOD_ALREADY_SUBMITTED',
        'Mood already submitted for this ISO week (across all homes).',
        'P0001',
        jsonb_build_object('isoWeek', v_iso_week, 'isoYear', v_iso_week_year)
      );
  END;

  -- Eager recompute weekly pulse snapshot after a new entry
  v_pulse_row := public.house_pulse_compute_week(p_home_id, v_iso_week_year, v_iso_week, 'v1');

  v_publish_requested :=
    COALESCE(p_public_wall, FALSE)
    OR COALESCE(array_length(v_mentions_raw, 1), 0) > 0;

  IF NOT v_publish_requested THEN
    RETURN jsonb_build_object(
      'entry_id', v_entry_id,
      'public_post_id', NULL,
      'mention_count', 0,
      'pulse', to_jsonb(v_pulse_row)
    );
  END IF;

  /* ---------- message ---------- */
  v_message := NULLIF(btrim(COALESCE(v_comment_trim, '')), '');
  IF v_message IS NOT NULL THEN
    v_message := left(v_message, 500);
  END IF;

  /* ---------- validate mentions (dedupe + count BEFORE using) ---------- */

  PERFORM public.api_assert(
    NOT EXISTS (SELECT 1 FROM unnest(v_mentions_raw) m WHERE m IS NULL),
    'INVALID_MENTION_USER',
    'Mention list cannot contain nulls.',
    '22023'
  );

  v_mentions_dedup := COALESCE((
    SELECT array_agg(m ORDER BY m)
    FROM (SELECT DISTINCT m FROM unnest(v_mentions_raw) m) s(m)
  ), ARRAY[]::uuid[]);

  v_mention_count := COALESCE(array_length(v_mentions_dedup, 1), 0);

  IF array_length(v_mentions_raw, 1) IS NOT NULL
     AND array_length(v_mentions_raw, 1) <> v_mention_count THEN
    PERFORM public.api_assert(FALSE, 'DUPLICATE_MENTIONS_NOT_ALLOWED', 'Mentions must be unique.', '22023');
  END IF;

  IF v_mention_count > 5 THEN
    PERFORM public.api_assert(FALSE, 'MENTION_LIMIT_EXCEEDED', 'You can mention at most 5 people.', '22023');
  END IF;

  IF v_user_id = ANY (v_mentions_dedup) THEN
    PERFORM public.api_assert(FALSE, 'SELF_MENTION_NOT_ALLOWED', 'You cannot mention yourself.', '22023');
  END IF;

  IF v_mention_count > 0 THEN
    -- comment required whenever mentioning someone
    PERFORM public.api_assert(
      v_message IS NOT NULL,
      'COMMENT_REQUIRED_FOR_MENTION',
      'A comment is required when mentioning someone.',
      '22023'
    );

    -- All mentions must be current members of the home.
    -- (Clearer EXISTS form; avoids reliance on profiles if you ever change that invariant.)
    PERFORM public.api_assert(
      NOT EXISTS (
        SELECT 1
        FROM unnest(v_mentions_dedup) m
        WHERE NOT EXISTS (
          SELECT 1
          FROM public.memberships mem
          WHERE mem.home_id = p_home_id
            AND mem.user_id = m
            AND mem.is_current = TRUE
        )
      ),
      'MENTION_NOT_HOME_MEMBER',
      'All mentions must be current members of the home.',
      '22023'
    );
  END IF;

  /* ---------- negative-mood hard rule: only 1 mention allowed ---------- */
  v_is_negative := (p_mood IN ('rainy','thunderstorm')); -- OK to hardcode enum literals

  IF v_is_negative THEN
    PERFORM public.api_assert(
      v_mention_count <= 1,
      'SINGLE_MENTION_REQUIRED',
      'Only one mention is allowed when triggering complaint rewrite.',
      '22023'
    );
  END IF;

  /* ---------- gratitude wall constraint applies ONLY to public wall ---------- */
  IF COALESCE(p_public_wall, FALSE) THEN
    IF p_mood NOT IN ('sunny','partially_sunny') THEN
      PERFORM public.api_assert(
        FALSE,
        'NOT_POSITIVE_MOOD',
        'Publishing gratitude is only available for Sunny or Partially Sunny weeks.',
        '22023'
      );
    END IF;

    -- Optional: enforce message exists for public posts (recommended if you don’t want empty posts)
    PERFORM public.api_assert(
      v_message IS NOT NULL,
      'COMMENT_REQUIRED_FOR_PUBLIC_WALL',
      'A comment is required to publish on the public wall.',
      '22023'
    );
  END IF;

  /* ---------- cheap quality floor for negative mention complaints ---------- */
  IF v_is_negative AND v_mention_count = 1 THEN
    -- meaningful chars: letters/digits only
    v_meaningful_chars := length(regexp_replace(v_message, '[^[:alnum:]]', '', 'g'));
    -- word count
    v_word_count := array_length(regexp_split_to_array(trim(v_message), '\s+'), 1);

    PERFORM public.api_assert(
      v_meaningful_chars >= 20,
      'COMPLAINT_TOO_SHORT',
      'Please add a bit more detail so your housemate can understand what happened.',
      '22023',
      jsonb_build_object('minMeaningfulChars', 20)
    );

    PERFORM public.api_assert(
      v_word_count >= 6,
      'COMPLAINT_TOO_BRIEF',
      'Please write at least a short sentence (6+ words) so your feedback is actionable.',
      '22023',
      jsonb_build_object('minWords', 6)
    );
  END IF;

  /* ---------- Option A: rewrite gate (mood-based) ---------- */
  IF v_mention_count = 1 THEN
    v_recipient_id := v_mentions_dedup[1];

    v_has_prefs := EXISTS (
      SELECT 1
      FROM public.preference_responses pr
      WHERE pr.user_id = v_recipient_id
      LIMIT 1
    );

    v_should_rewrite :=
      v_is_negative
      AND (v_message IS NOT NULL)
      AND v_has_prefs;
  END IF;

  /* ---------- optional: public wall post ---------- */
  IF COALESCE(p_public_wall, FALSE) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.gratitude_wall_posts WHERE source_entry_id = v_entry_id
    ) THEN
      INSERT INTO public.gratitude_wall_posts (
        home_id, author_user_id, mood, message, created_at, source_entry_id
      )
      SELECT p_home_id, v_user_id, p_mood, v_message, v_now, v_entry_id;
    END IF;

    SELECT id
      INTO v_post_id
      FROM public.gratitude_wall_posts
     WHERE source_entry_id = v_entry_id
     LIMIT 1;
  END IF;

  /* ---------- mentions + personal items ---------- */
  IF v_post_id IS NOT NULL AND v_mention_count > 0 THEN
    INSERT INTO public.gratitude_wall_mentions (post_id, home_id, mentioned_user_id, created_at)
    SELECT v_post_id, p_home_id, m, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_mention_count > 0 THEN
    v_source_kind := CASE WHEN v_post_id IS NULL THEN 'mention_only' ELSE 'home_post' END;

    INSERT INTO public.gratitude_wall_personal_items (
      recipient_user_id, home_id, author_user_id, mood, message,
      source_kind, source_post_id, source_entry_id, created_at
    )
    SELECT
      m, p_home_id, v_user_id, p_mood, v_message,
      v_source_kind, v_post_id, v_entry_id, v_now
    FROM unnest(v_mentions_dedup) m
    ON CONFLICT (recipient_user_id, source_entry_id) DO NOTHING;
  END IF;

  /* ---------- trigger rewrite ---------- */
  IF v_should_rewrite THEN
    PERFORM public.complaint_trigger_enqueue(v_entry_id, v_recipient_id);
  END IF;

  RETURN jsonb_build_object(
    'entry_id', v_entry_id,
    'public_post_id', v_post_id,
    'mention_count', v_mention_count,
    'rewrite_recipient_id', v_recipient_id,
    'pulse', to_jsonb(v_pulse_row)
  );
END;
$$;


-- ============================================================
-- Rewrite batch dispatch guards
-- - Skip edge invocation when no pending rewrite work exists
-- - Send explicit payload to avoid implicit pg_net '{}' defaults
-- - Keep worker auth headers explicit (x-internal-secret)
-- ============================================================

create or replace function public.rewrite_batch_submitter_dispatch_v1()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending_count int := 0;
  v_supabase_url text;
  v_worker_secret text;
  v_request_id bigint;
begin
  select count(*)::int
    into v_pending_count
  from public.rewrite_jobs j
  where j.status = 'queued'
    and (j.not_before_at is null or j.not_before_at <= now())
    and j.provider_batch_id is null
    and j.submitted_at is null;

  if coalesce(v_pending_count, 0) = 0 then
    raise notice 'rewrite_batch_submitter skipped: no pending items';
    return jsonb_build_object(
      'ok', true,
      'skipped_no_pending', true,
      'pending_count', 0
    );
  end if;

  begin
    select s.decrypted_secret
      into v_supabase_url
    from vault.decrypted_secrets s
    where s.name = 'SUPABASE_URL'
    limit 1;
  exception
    when undefined_table or insufficient_privilege then
      v_supabase_url := null;
  end;

  begin
    select s.decrypted_secret
      into v_worker_secret
    from vault.decrypted_secrets s
    where s.name = 'WORKER_SHARED_SECRET'
    limit 1;
  exception
    when undefined_table or insufficient_privilege then
      v_worker_secret := null;
  end;

  if v_supabase_url is null or btrim(v_supabase_url) = '' then
    v_supabase_url := nullif(current_setting('app.settings.supabase_url', true), '');
  end if;

  if v_worker_secret is null or btrim(v_worker_secret) = '' then
    v_worker_secret := nullif(current_setting('app.settings.worker_shared_secret', true), '');
  end if;

  if v_supabase_url is null or v_worker_secret is null then
    raise exception 'rewrite_batch_submitter_dispatch_v1_missing_config';
  end if;

  select net.http_post(
    url := v_supabase_url || '/functions/v1/rewrite_batch_submitter',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', v_worker_secret,
      'x-worker-id', 'cron_batch_submitter'
    ),
    body := jsonb_build_object(
      'pending_count', v_pending_count,
      'source', 'pg_cron',
      'worker', 'rewrite_batch_submitter'
    )
  )
  into v_request_id;

  return jsonb_build_object(
    'ok', true,
    'skipped_no_pending', false,
    'pending_count', v_pending_count,
    'request_id', v_request_id
  );
end;
$$;

revoke all on function public.rewrite_batch_submitter_dispatch_v1() from public;
grant execute on function public.rewrite_batch_submitter_dispatch_v1() to postgres;
grant execute on function public.rewrite_batch_submitter_dispatch_v1() to service_role;

create or replace function public.rewrite_batch_collector_dispatch_v1()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending_count int := 0;
  v_supabase_url text;
  v_worker_secret text;
  v_request_id bigint;
begin
  select count(*)::int
    into v_pending_count
  from public.rewrite_provider_batches b
  where b.status in ('submitted', 'running');

  if coalesce(v_pending_count, 0) = 0 then
    raise notice 'rewrite_batch_collector skipped: no pending items';
    return jsonb_build_object(
      'ok', true,
      'skipped_no_pending', true,
      'pending_count', 0
    );
  end if;

  begin
    select s.decrypted_secret
      into v_supabase_url
    from vault.decrypted_secrets s
    where s.name = 'SUPABASE_URL'
    limit 1;
  exception
    when undefined_table or insufficient_privilege then
      v_supabase_url := null;
  end;

  begin
    select s.decrypted_secret
      into v_worker_secret
    from vault.decrypted_secrets s
    where s.name = 'WORKER_SHARED_SECRET'
    limit 1;
  exception
    when undefined_table or insufficient_privilege then
      v_worker_secret := null;
  end;

  if v_supabase_url is null or btrim(v_supabase_url) = '' then
    v_supabase_url := nullif(current_setting('app.settings.supabase_url', true), '');
  end if;

  if v_worker_secret is null or btrim(v_worker_secret) = '' then
    v_worker_secret := nullif(current_setting('app.settings.worker_shared_secret', true), '');
  end if;

  if v_supabase_url is null or v_worker_secret is null then
    raise exception 'rewrite_batch_collector_dispatch_v1_missing_config';
  end if;

  select net.http_post(
    url := v_supabase_url || '/functions/v1/rewrite_batch_collector',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', v_worker_secret,
      'x-worker-id', 'cron_batch_collector'
    ),
    body := jsonb_build_object(
      'pending_count', v_pending_count,
      'source', 'pg_cron',
      'worker', 'rewrite_batch_collector'
    )
  )
  into v_request_id;

  return jsonb_build_object(
    'ok', true,
    'skipped_no_pending', false,
    'pending_count', v_pending_count,
    'request_id', v_request_id
  );
end;
$$;

revoke all on function public.rewrite_batch_collector_dispatch_v1() from public;
grant execute on function public.rewrite_batch_collector_dispatch_v1() to postgres;
grant execute on function public.rewrite_batch_collector_dispatch_v1() to service_role;

-- Repoint cron jobs to guarded dispatchers.
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_rewrite_batch_submitter_15m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_rewrite_batch_submitter_15m',
      '*/15 * * * *',
      'select public.rewrite_batch_submitter_dispatch_v1();'
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping schedule ensure for complaint_rewrite_batch_submitter_15m.';
  end;
end
$$;

do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_rewrite_batch_collector_30m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;

    perform cron.schedule(
      'complaint_rewrite_batch_collector_30m',
      '*/30 * * * *',
      'select public.rewrite_batch_collector_dispatch_v1();'
    );
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping schedule ensure for complaint_rewrite_batch_collector_30m.';
  end;
end
$$;
