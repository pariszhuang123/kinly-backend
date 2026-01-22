-- ====================================================================
-- Daily Notifications Phase 1 (Option A: everything via SEC DEFINER RPC)
-- Tables: notification_preferences, device_tokens, notification_sends
-- Helpers: today_has_content(), notifications_daily_candidates()
-- RPCs: notifications_sync_client_state(), notifications_update_preferences()
--       notifications_reserve_send(), notifications_mark_send_success(),
--       notifications_update_send_status(), notifications_mark_token_status()
-- ====================================================================

-- --------------------------------------------------------------------
-- Tables
-- --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notification_preferences (
  user_id              uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  wants_daily          boolean NOT NULL DEFAULT FALSE,
  preferred_hour       integer NOT NULL DEFAULT 9,
  timezone             text NOT NULL,
  locale               text NOT NULL,
  os_permission        text NOT NULL DEFAULT 'unknown', -- allowed | blocked | unknown
  last_os_sync_at      timestamptz,
  last_sent_local_date date,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.device_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  token        text NOT NULL,
  provider     text NOT NULL DEFAULT 'fcm',
  platform     text,
  status       text NOT NULL DEFAULT 'active', -- active | revoked | expired
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_device_tokens_token UNIQUE (token)
);

CREATE TABLE IF NOT EXISTS public.notification_sends (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  local_date  date NOT NULL,
  job_run_id  text,
  status      text NOT NULL, -- reserved | sent | failed
  error       text,
  reserved_at timestamptz,
  sent_at     timestamptz,
  failed_at   timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.notification_sends.status IS
  'Notification send state: reserved | sent | failed';

-- --------------------------------------------------------------------
-- Indexes & uniqueness
-- --------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_device_tokens_user_status
  ON public.device_tokens (user_id, status);

-- Enforce one row per user per local day (any status)
DROP INDEX IF EXISTS uq_notification_sends_user_date;
CREATE UNIQUE INDEX uq_notification_sends_user_date
  ON public.notification_sends (user_id, local_date);

-- --------------------------------------------------------------------
-- RLS (tables are internal; only SEC DEFINER + service_role touch them)
-- --------------------------------------------------------------------
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_sends ENABLE ROW LEVEL SECURITY;

-- No policies defined: anon/authenticated cannot directly read/write
-- Only:
--   * SECURITY DEFINER functions (owned by postgres)
--   * service_role
-- can touch these tables.

-- --------------------------------------------------------------------
-- Helper: today_has_content
-- Uses existing RPCs to decide if Today screen has something meaningful.
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.today_has_content(
  p_user_id    uuid,
  p_timezone   text,
  p_local_date date
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id  uuid;
  v_prev_sub text := current_setting('request.jwt.claim.sub', true);
  v_has      boolean := FALSE;
BEGIN
  -- Use the user's current home membership (one active stint enforced by uq_memberships_user_one_current)
  SELECT home_id
  INTO v_home_id
  FROM public.memberships
  WHERE user_id = p_user_id
    AND is_current = TRUE
  LIMIT 1;

  IF v_home_id IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Impersonate the user for existing RPCs that rely on auth.uid()
  PERFORM set_config('request.jwt.claim.sub', p_user_id::text, true);

  -- Flow/chores: active or draft, due now or overdue (per today_flow_list)
  v_has := EXISTS (
    SELECT 1 FROM public.today_flow_list(v_home_id, 'active')
  ) OR EXISTS (
    SELECT 1 FROM public.today_flow_list(v_home_id, 'draft')
  );

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  -- Expenses: owed to others or created by me
  v_has := (
    SELECT COALESCE(jsonb_array_length(public.expenses_get_current_owed(v_home_id)), 0)
  ) > 0;

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  v_has := (
    SELECT COALESCE(jsonb_array_length(public.expenses_get_created_by_me(v_home_id)), 0)
  ) > 0;

  IF v_has THEN
    PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
    RETURN TRUE;
  END IF;

  -- Gratitude: unread posts
  v_has := EXISTS (
    SELECT 1 FROM public.gratitude_wall_status(v_home_id)
    WHERE has_unread IS TRUE
  );

  -- Restore previous sub claim (best-effort)
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
  RETURN v_has;
END;
$$;

COMMENT ON FUNCTION public.today_has_content(uuid, text, date) IS
  'Returns true when any Today content exists for the user (Flow, expenses owed/created, gratitude unread).';

-- --------------------------------------------------------------------
-- Helper: notifications_daily_candidates
-- Produces paged candidate rows for the scheduler (service role).
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_daily_candidates(
  p_limit  integer DEFAULT 200,
  p_offset integer DEFAULT 0
) RETURNS TABLE (
  user_id    uuid,
  locale     text,
  timezone   text,
  token_id   uuid,
  token      text,
  local_date date
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH eligible_users AS (
    SELECT
      np.user_id,
      np.locale,
      np.timezone,
      (timezone(np.timezone, now()))::date AS local_date
    FROM public.notification_preferences np
    WHERE np.wants_daily = TRUE
      AND np.os_permission = 'allowed'
      AND np.preferred_hour = date_part('hour', timezone(np.timezone, now()))::int
      AND (
        np.last_sent_local_date IS NULL
        OR np.last_sent_local_date < (timezone(np.timezone, now()))::date
      )
      AND public.today_has_content(
        np.user_id,
        np.timezone,
        (timezone(np.timezone, now()))::date
      ) = TRUE
  ),
  eligible_tokens AS (
    SELECT
      eu.user_id,
      eu.locale,
      eu.timezone,
      dt.id   AS token_id,
      dt.token,
      eu.local_date
    FROM eligible_users eu
    JOIN public.device_tokens dt
      ON dt.user_id = eu.user_id
    WHERE dt.status = 'active'
  )
  SELECT
    user_id,
    locale,
    timezone,
    token_id,
    token,
    local_date
  FROM eligible_tokens
  ORDER BY user_id
  LIMIT COALESCE(p_limit, 200)
  OFFSET COALESCE(p_offset, 0);
$$;

COMMENT ON FUNCTION public.notifications_daily_candidates(integer, integer) IS
  'Paged list of users + tokens eligible for the daily notification window.';

-- --------------------------------------------------------------------
-- Client RPC: sync notification state from app
-- (token + locale/tz + OS permission + optional wants_daily)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_sync_client_state(
  p_token           text,
  p_platform        text,          -- 'android', 'ios', etc.
  p_locale          text,          -- e.g. 'en', 'es'
  p_timezone        text,          -- e.g. 'Pacific/Auckland'
  p_os_permission   text,          -- 'allowed' | 'blocked' | 'unknown'
  p_wants_daily     boolean DEFAULT NULL,  -- NULL = no explicit change, use defaults
  p_preferred_hour  integer DEFAULT NULL   -- NULL = keep existing or default 9
)
RETURNS public.notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_current    public.notification_preferences;
  v_effective_wants_daily    boolean;
  v_effective_preferred_hour integer;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  -- Load current prefs if they exist
  SELECT *
  INTO v_current
  FROM public.notification_preferences
  WHERE user_id = v_user_id;

  -- Decide wants_daily:
  --   1) explicit p_wants_daily from app
  --   2) existing DB value
  --   3) default: true if OS permission is allowed, else false
  v_effective_wants_daily :=
    COALESCE(
      p_wants_daily,
      v_current.wants_daily,
      (p_os_permission = 'allowed')
    );

  -- Decide preferred_hour:
  v_effective_preferred_hour :=
    COALESCE(
      p_preferred_hour,
      v_current.preferred_hour,
      9
    );

  -- Upsert into notification_preferences
  INSERT INTO public.notification_preferences (
    user_id,
    wants_daily,
    preferred_hour,
    timezone,
    locale,
    os_permission,
    last_os_sync_at,
    last_sent_local_date,
    created_at,
    updated_at
  )
  VALUES (
    v_user_id,
    v_effective_wants_daily,
    v_effective_preferred_hour,
    p_timezone,
    p_locale,
    p_os_permission,
    now(),
    COALESCE(v_current.last_sent_local_date, NULL),
    COALESCE(v_current.created_at, now()),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET wants_daily          = EXCLUDED.wants_daily,
        preferred_hour       = EXCLUDED.preferred_hour,
        timezone             = EXCLUDED.timezone,
        locale               = EXCLUDED.locale,
        os_permission        = EXCLUDED.os_permission,
        last_os_sync_at      = EXCLUDED.last_os_sync_at,
        updated_at           = EXCLUDED.updated_at
  RETURNING * INTO v_current;

  -- Upsert device token (if provided)
  IF p_token IS NOT NULL THEN
    INSERT INTO public.device_tokens (
      user_id,
      token,
      provider,
      platform,
      status,
      last_seen_at,
      created_at,
      updated_at
    )
    VALUES (
      v_user_id,
      p_token,
      'fcm',
      p_platform,
      'active',
      now(),
      now(),
      now()
    )
    ON CONFLICT (token) DO UPDATE
      SET user_id      = EXCLUDED.user_id,
          platform     = EXCLUDED.platform,
          provider     = EXCLUDED.provider,
          status       = 'active',
          last_seen_at = now(),
          updated_at   = now();
  END IF;

  RETURN v_current;
END;
$$;

-- --------------------------------------------------------------------
-- Client RPC: explicit in-app toggle of wants_daily / preferred_hour
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_update_preferences(
  p_wants_daily    boolean,
  p_preferred_hour integer
)
RETURNS public.notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_pref    public.notification_preferences;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  INSERT INTO public.notification_preferences (
    user_id,
    wants_daily,
    preferred_hour,
    timezone,
    locale,
    os_permission,
    last_os_sync_at,
    last_sent_local_date,
    created_at,
    updated_at
  )
  SELECT
    v_user_id,
    p_wants_daily,
    p_preferred_hour,
    COALESCE(np.timezone, 'UTC'),
    COALESCE(np.locale, 'en'),
    COALESCE(np.os_permission, 'unknown'),
    np.last_os_sync_at,
    np.last_sent_local_date,
    COALESCE(np.created_at, now()),
    now()
  FROM public.notification_preferences np
  WHERE np.user_id = v_user_id
  UNION ALL
  SELECT
    v_user_id,
    p_wants_daily,
    p_preferred_hour,
    'UTC',
    'en',
    'unknown',
    NULL,
    NULL,
    now(),
    now()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.notification_preferences WHERE user_id = v_user_id
  )
  ON CONFLICT (user_id) DO UPDATE
    SET wants_daily    = EXCLUDED.wants_daily,
        preferred_hour = EXCLUDED.preferred_hour,
        updated_at     = EXCLUDED.updated_at
  RETURNING * INTO v_pref;

  RETURN v_pref;
END;
$$;

-- --------------------------------------------------------------------
-- Backend RPC: reserve a send row (idempotent)
-- Returns NULL if another worker already reserved/created a row.
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_reserve_send(
  p_user_id    uuid,
  p_local_date date,
  p_job_run_id text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.notification_sends (
    user_id,
    local_date,
    job_run_id,
    status,
    reserved_at
  )
  VALUES (
    p_user_id,
    p_local_date,
    p_job_run_id,
    'reserved',
    now()
  )
  ON CONFLICT (user_id, local_date) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id; -- NULL if conflict (already reserved/sent/failed)
END;
$$;

-- --------------------------------------------------------------------
-- Backend RPC: mark a send as success + update last_sent_local_date
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_mark_send_success(
  p_send_id    uuid,
  p_user_id    uuid,
  p_local_date date
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.notification_sends
  SET status    = 'sent',
      sent_at   = now(),
      updated_at = now()
  WHERE id = p_send_id;

  UPDATE public.notification_preferences
  SET last_sent_local_date = p_local_date,
      updated_at           = now()
  WHERE user_id = p_user_id;
END;
$$;

-- --------------------------------------------------------------------
-- Backend RPC: update send status (used for failures)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_update_send_status(
  p_send_id uuid,
  p_status  text,   -- 'sent' | 'failed'
  p_error   text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.notification_sends
  SET status    = p_status,
      error     = p_error,
      failed_at = CASE WHEN p_status = 'failed' THEN now() ELSE failed_at END,
      updated_at = now()
  WHERE id = p_send_id;
END;
$$;

-- --------------------------------------------------------------------
-- Backend RPC: update device token status (expired/revoked)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_mark_token_status(
  p_token_id uuid,
  p_status   text -- 'expired' | 'revoked'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.device_tokens
  SET status    = p_status,
      updated_at = now()
  WHERE id = p_token_id;
END;
$$;

-- --------------------------------------------------------------------
-- Permissions (Option A)
-- --------------------------------------------------------------------

-- Lock down client RPCs from PUBLIC
REVOKE ALL ON FUNCTION public.notifications_sync_client_state(
  text, text, text, text, text, boolean, integer
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_update_preferences(
  boolean, integer
) FROM PUBLIC;

-- Allow authenticated (and implicitly service_role, if you want) to call client RPCs
GRANT EXECUTE ON FUNCTION public.notifications_sync_client_state(
  text, text, text, text, text, boolean, integer
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.notifications_update_preferences(
  boolean, integer
) TO authenticated;

-- Lock down backend RPCs from PUBLIC / authenticated
REVOKE ALL ON FUNCTION public.notifications_daily_candidates(
  integer, integer
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_reserve_send(
  uuid, date, text
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_mark_send_success(
  uuid, uuid, date
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_update_send_status(
  uuid, text, text
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_mark_token_status(
  uuid, text
) FROM PUBLIC;

-- Only service_role (Edge) can call backend RPCs
GRANT EXECUTE ON FUNCTION public.notifications_daily_candidates(
  integer, integer
) TO service_role;

GRANT EXECUTE ON FUNCTION public.notifications_reserve_send(
  uuid, date, text
) TO service_role;

GRANT EXECUTE ON FUNCTION public.notifications_mark_send_success(
  uuid, uuid, date
) TO service_role;

GRANT EXECUTE ON FUNCTION public.notifications_update_send_status(
  uuid, text, text
) TO service_role;

GRANT EXECUTE ON FUNCTION public.notifications_mark_token_status(
  uuid, text
) TO service_role;


---------------------------------------------------------------------
-- members.kick(home_id, target_user_id) -> removes a member (owner-only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.members_kick(
  p_home_id uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_target_role        text;
  v_rows_updated       integer;
  v_members_remaining  integer;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);

  --------------------------------------------------------------------
  -- 1) Verify caller is the current owner of the active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id    = v_user
        AND m.home_id    = p_home_id
        AND m.role       = 'owner'
        AND m.is_current = TRUE
        AND h.is_active  = TRUE
    ),
    'FORBIDDEN',
    'Only the current owner can remove members.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 2) Validate target is a current (non-owner) member
  --------------------------------------------------------------------
  SELECT m.role
    INTO v_target_role
    FROM public.memberships m
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
   LIMIT 1;

  PERFORM public.api_assert(
    v_target_role IS NOT NULL,
    'TARGET_NOT_MEMBER',
    'The selected user is not an active member of this home.',
    'P0002',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  PERFORM public.api_assert(
    v_target_role <> 'owner',
    'CANNOT_KICK_OWNER',
    'Owners cannot be removed.',
    '42501',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 3) Serialize with other membership mutations and close the stint
  --------------------------------------------------------------------
  -- Lock the home row to serialize join/leave/kick operations
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  UPDATE public.memberships m
    SET valid_to   = now(),
        updated_at = now()
  WHERE m.user_id    = p_target_user_id
    AND m.home_id    = p_home_id
    AND m.is_current = TRUE
  RETURNING 1 INTO v_rows_updated;

  PERFORM public.api_assert(
    v_rows_updated = 1,
    'STATE_CHANGED_RETRY',
    'Membership state changed; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 4) Return success payload
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO v_members_remaining
    FROM public.memberships m
   WHERE m.home_id    = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'member_removed',
    'message', 'Member removed successfully.',
    'data', jsonb_build_object(
      'home_id',           p_home_id,
      'user_id',           p_target_user_id,
      'members_remaining', v_members_remaining
    )
  );
END;
$$;