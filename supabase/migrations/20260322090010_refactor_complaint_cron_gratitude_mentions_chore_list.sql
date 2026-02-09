-- ============================================================
-- Refactor complaint rewrite scheduling to Edge Scheduler pattern
-- - Remove DB -> HTTP cron calls that require DB-held URL/secrets
-- - Keep DB-only cron jobs (watchdog/terminalizer) untouched
--
-- Rationale:
--   Secrets should live in Edge env only.
--   Postgres remains queue/RPC authority, not HTTP orchestrator.
-- ============================================================

-- 1) Unschedule complaint trigger runner HTTP cron job (if present)
do $$
declare
  v_job_id integer;
begin
  begin
    select j.jobid
      into v_job_id
      from cron.job j
     where j.jobname = 'complaint_trigger_runner_every_5m'
     limit 1;

    if v_job_id is not null then
      perform cron.unschedule(v_job_id);
    end if;
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping unschedule for complaint_trigger_runner_every_5m.';
  end;
end
$$;

-- 2) Unschedule complaint rewrite batch submitter HTTP cron job (if present)
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
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping unschedule for complaint_rewrite_batch_submitter_15m.';
  end;
end
$$;

-- 3) Unschedule complaint rewrite batch collector HTTP cron job (if present)
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
  exception
    when undefined_table or insufficient_privilege then
      raise notice 'Skipping unschedule for complaint_rewrite_batch_collector_30m.';
  end;
end
$$;

-- 4) Drop DB helper that performed HTTP call to runner (no longer used)
drop function if exists public._cron_call_complaint_trigger_runner();

-- NOTE:
-- complaint_trigger_watchdog_every_10m and complaint_trigger_fail_exhausted_every_25m
-- remain DB-only cron jobs by design and are intentionally retained.


-- ---------------------------------------------------------------------
-- 8) Personal inbox: status + mark read (nudge only if truly unread)
--     ✅ Excludes moods: rainy / thunderstorm (ignored for unread + list + stats)
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_wall_status_v1();

CREATE OR REPLACE FUNCTION public.personal_gratitude_wall_status_v1()
RETURNS TABLE (
  has_unread   boolean,
  last_read_at timestamptz
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id           uuid := auth.uid();
  v_latest_created_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT r.last_read_at
    INTO last_read_at
  FROM public.gratitude_wall_personal_reads r
  WHERE r.user_id = v_user_id
  LIMIT 1;

  SELECT i.created_at
    INTO v_latest_created_at
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND i.author_user_id <> v_user_id
    AND i.mood NOT IN ('rainy', 'thunderstorm')
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT 1;

  has_unread :=
    CASE
      WHEN v_latest_created_at IS NULL THEN FALSE
      WHEN last_read_at IS NULL THEN TRUE
      ELSE v_latest_created_at > last_read_at
    END;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_wall_status_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_wall_status_v1()
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_wall_status_v1() IS
  'Self-only unread status for personal gratitude wall. Ignores moods rainy/thunderstorm (not counted as unread).';


DROP FUNCTION IF EXISTS public.personal_gratitude_wall_mark_read_v1();

CREATE OR REPLACE FUNCTION public.personal_gratitude_wall_mark_read_v1()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  INSERT INTO public.gratitude_wall_personal_reads (user_id, last_read_at)
  VALUES (v_user_id, now())
  ON CONFLICT (user_id)
  DO UPDATE SET last_read_at = EXCLUDED.last_read_at;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_wall_mark_read_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_wall_mark_read_v1()
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_wall_mark_read_v1() IS
  'Self-only marker to record last_read_at for personal gratitude wall.';



-- ---------------------------------------------------------------------
-- 9) Personal inbox list (paged) — resolves author username + avatar storage_path
--     Enforce cursor: both or neither (p_before_at + p_before_id)
--     ✅ Excludes moods: rainy / thunderstorm
--     ✅ Uses LEFT JOIN avatars so missing avatar does not hide items
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid);

CREATE OR REPLACE FUNCTION public.personal_gratitude_inbox_list_v1(
  p_limit     int DEFAULT 30,
  p_before_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
) RETURNS TABLE (
  id                 uuid,
  created_at         timestamptz,
  home_id            uuid,
  mood               public.mood_scale,
  message            text,
  source_kind        text,
  source_post_id     uuid,
  source_entry_id    uuid,

  author_user_id     uuid,
  author_username    public.citext,
  author_avatar_id   uuid,
  author_avatar_path text
) LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  p_limit := GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));

  -- Enforce: both cursor parts must be provided together, or neither.
  PERFORM public.api_assert(
    (p_before_at IS NULL AND p_before_id IS NULL)
    OR (p_before_at IS NOT NULL AND p_before_id IS NOT NULL),
    'INVALID_PAGINATION_CURSOR',
    'Pagination cursor requires both before_at and before_id, or neither.',
    '22023',
    jsonb_build_object('before_at', p_before_at, 'before_id', p_before_id)
  );

  RETURN QUERY
  SELECT
    i.id,
    i.created_at,
    i.home_id,
    i.mood,
    i.message,
    i.source_kind,
    i.source_post_id,
    i.source_entry_id,

    p.id           AS author_user_id,
    p.username     AS author_username,
    p.avatar_id    AS author_avatar_id,
    a.storage_path AS author_avatar_path
  FROM public.gratitude_wall_personal_items i
  JOIN public.profiles p
    ON p.id = i.author_user_id
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE i.recipient_user_id = v_user_id
    AND i.mood NOT IN ('rainy', 'thunderstorm')
    AND (
      p_before_at IS NULL
      OR i.created_at < p_before_at
      OR (i.created_at = p_before_at AND i.id < p_before_id)
    )
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid)
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_inbox_list_v1(int, timestamptz, uuid) IS
  'Recipient personal gratitude inbox list (paged). Resolves author username + avatar storage_path at read time. Cursor requires both before_at and before_id. Excludes rainy/thunderstorm moods.';



-- ---------------------------------------------------------------------
-- 10) Personal gratitude showcase stats (no p_since)
--     ✅ Excludes moods: rainy / thunderstorm
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.personal_gratitude_showcase_stats_v1(boolean);

CREATE OR REPLACE FUNCTION public.personal_gratitude_showcase_stats_v1(
  p_exclude_self boolean DEFAULT TRUE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_total   bigint;
  v_authors bigint;
  v_homes   bigint;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT i.author_user_id)::bigint,
    COUNT(DISTINCT i.home_id)::bigint
  INTO v_total, v_authors, v_homes
  FROM public.gratitude_wall_personal_items i
  WHERE i.recipient_user_id = v_user_id
    AND i.mood NOT IN ('rainy', 'thunderstorm')
    AND (NOT p_exclude_self OR i.author_user_id <> v_user_id);

  RETURN jsonb_build_object(
    'total_received',     v_total,
    'unique_individuals', v_authors,
    'unique_homes',       v_homes
  );
END;
$$;

REVOKE ALL ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean)
  TO authenticated;

COMMENT ON FUNCTION public.personal_gratitude_showcase_stats_v1(boolean) IS
  'Showcase stats for auth.uid() from personal gratitude inbox: total received items, unique authors, unique homes. Excludes rainy/thunderstorm moods.';

DROP FUNCTION IF EXISTS public.home_assignees_list_v2(uuid);

CREATE OR REPLACE FUNCTION public.home_assignees_list_v2(
  p_home_id uuid
)
RETURNS TABLE (
  user_id              uuid,
  username             text,
  full_name            text,
  email                text,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Require auth
  PERFORM public._assert_authenticated();

  -- Ensure caller belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- Return all active members as potential assignees
  RETURN QUERY
  SELECT
    m.user_id,
    p.username,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
  ORDER BY
    COALESCE(NULLIF(p.full_name, ''), NULLIF(p.username, ''), p.email);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.home_assignees_list_v2(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.home_assignees_list_v2(uuid) TO authenticated;
