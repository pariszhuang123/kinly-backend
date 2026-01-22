-- Notifications: capture preferred minute alongside hour
-- - Adds preferred_minute to notification_preferences (0-59, default 0)
-- - Extends client RPCs to read/write preferred_minute
-- - Tightens candidate selection to include preferred_minute

-- Add column and guardrails
ALTER TABLE public.notification_preferences
  ADD COLUMN IF NOT EXISTS preferred_minute integer NOT NULL DEFAULT 0;

ALTER TABLE public.notification_preferences
  DROP CONSTRAINT IF EXISTS chk_notification_preferences_preferred_minute,
  ADD CONSTRAINT chk_notification_preferences_preferred_minute
    CHECK (preferred_minute >= 0 AND preferred_minute < 60);

-- -------------------------------------------------------------------
-- notifications_daily_candidates: match both hour and minute
-- -------------------------------------------------------------------
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
      AND np.preferred_minute = date_part('minute', timezone(np.timezone, now()))::int
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

-- -------------------------------------------------------------------
-- notifications_sync_client_state: add p_preferred_minute
-- -------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.notifications_sync_client_state(
  text, text, text, text, text, boolean, integer
);

CREATE OR REPLACE FUNCTION public.notifications_sync_client_state(
  p_token            text,
  p_platform         text,
  p_locale           text,
  p_timezone         text,
  p_os_permission    text,          -- 'allowed' | 'blocked' | 'unknown'
  p_wants_daily      boolean DEFAULT NULL,
  p_preferred_hour   integer DEFAULT NULL,
  p_preferred_minute integer DEFAULT NULL
)
RETURNS public.notification_preferences
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_current     public.notification_preferences;
  v_effective_wants_daily      boolean;
  v_effective_preferred_hour   integer;
  v_effective_preferred_minute integer;
  v_should_upsert boolean;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT *
  INTO v_current
  FROM public.notification_preferences
  WHERE user_id = v_user_id;

  v_effective_wants_daily :=
    COALESCE(
      p_wants_daily,
      v_current.wants_daily,
      (p_os_permission = 'allowed')
    );

  -- Force off when OS is blocked/unknown so UI toggle mirrors system status
  IF p_os_permission IS DISTINCT FROM 'allowed' THEN
    v_effective_wants_daily := FALSE;
  END IF;

  v_effective_preferred_hour :=
    COALESCE(
      p_preferred_hour,
      v_current.preferred_hour,
      9
    );

  v_effective_preferred_minute :=
    COALESCE(
      p_preferred_minute,
      v_current.preferred_minute,
      0
    );

  -- Upsert only when we have an explicit change, an existing row, or OS is allowed.
  -- Do NOT upsert just because a token is present if permission is blocked/unknown.
  v_should_upsert :=
       v_current.user_id IS NOT NULL
    OR p_wants_daily IS NOT NULL
    OR p_preferred_hour IS NOT NULL
    OR p_preferred_minute IS NOT NULL
    OR p_os_permission = 'allowed';

  IF NOT v_should_upsert THEN
    RETURN (
      v_user_id,
      v_effective_wants_daily,
      v_effective_preferred_hour,
      COALESCE(p_timezone, 'UTC'),
      COALESCE(p_locale, 'en'),
      p_os_permission,
      now(),
      v_current.last_sent_local_date,
      COALESCE(v_current.created_at, now()),
      now(),
      v_effective_preferred_minute
    )::public.notification_preferences;
  END IF;

  INSERT INTO public.notification_preferences (
    user_id,
    wants_daily,
    preferred_hour,
    preferred_minute,
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
    v_effective_preferred_minute,
    p_timezone,
    p_locale,
    p_os_permission,
    now(),
    COALESCE(v_current.last_sent_local_date, NULL),
    COALESCE(v_current.created_at, now()),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET wants_daily      = EXCLUDED.wants_daily,
        preferred_hour   = EXCLUDED.preferred_hour,
        preferred_minute = EXCLUDED.preferred_minute,
        timezone         = EXCLUDED.timezone,
        locale           = EXCLUDED.locale,
        os_permission    = EXCLUDED.os_permission,
        last_os_sync_at  = EXCLUDED.last_os_sync_at,
        updated_at       = EXCLUDED.updated_at
  RETURNING * INTO v_current;

  IF p_token IS NOT NULL THEN
    INSERT INTO public.device_tokens (
      user_id, token, provider, platform, status,
      last_seen_at, created_at, updated_at
    )
    VALUES (
      v_user_id, p_token, 'fcm', p_platform, 'active',
      now(), now(), now()
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

-- notifications_update_preferences: add preferred_minute
-- -------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.notifications_update_preferences(
  boolean, integer
);

CREATE OR REPLACE FUNCTION public.notifications_update_preferences(
  p_wants_daily     boolean,
  p_preferred_hour  integer,
  p_preferred_minute integer
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
    preferred_minute,
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
    p_preferred_minute,
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
    p_preferred_minute,
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
    SET wants_daily     = EXCLUDED.wants_daily,
        preferred_hour  = EXCLUDED.preferred_hour,
        preferred_minute = EXCLUDED.preferred_minute,
        updated_at      = EXCLUDED.updated_at
  RETURNING * INTO v_pref;

  RETURN v_pref;
END;
$$;

-- Permissions for updated signatures
REVOKE ALL ON FUNCTION public.notifications_sync_client_state(
  text, text, text, text, text, boolean, integer, integer
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.notifications_update_preferences(
  boolean, integer, integer
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.notifications_sync_client_state(
  text, text, text, text, text, boolean, integer, integer
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.notifications_update_preferences(
  boolean, integer, integer
) TO authenticated;


CREATE OR REPLACE FUNCTION public.today_onboarding_hints()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_home_id uuid;

  v_lifetime_authored_chore_count int := 0;

  -- Default to 'unknown' so "no row" behaves like unknown.
  v_notif_os_permission text := 'unknown';
  v_notif_wants_daily boolean := FALSE;

  v_has_flatmate_invite_share boolean := FALSE;
  v_has_invite_share boolean := FALSE;

  v_prompt_notifications boolean := FALSE;
  v_prompt_flatmate_invite_share boolean := FALSE;
  v_prompt_invite_share boolean := FALSE;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT m.home_id
  INTO v_home_id
  FROM public.memberships AS m
  WHERE m.user_id    = v_user_id
    AND m.is_current = TRUE
  LIMIT 1;

  IF v_home_id IS NULL THEN
    RETURN jsonb_build_object(
      'userAuthoredChoreCountLifetime', 0,
      'shouldPromptNotifications', FALSE,
      'shouldPromptFlatmateInviteShare', FALSE,
      'shouldPromptInviteShare', FALSE
    );
  END IF;

  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  SELECT COUNT(*)
  INTO v_lifetime_authored_chore_count
  FROM public.chores AS c
  WHERE c.created_by_user_id = v_user_id;

  -- Normalize "no prefs row" to ('unknown', FALSE).
  -- This avoids the SELECT INTO "no row -> NULL overwrite" footgun.
  SELECT
    COALESCE(np.os_permission, 'unknown'),
    COALESCE(np.wants_daily, FALSE)
  INTO v_notif_os_permission, v_notif_wants_daily
  FROM public.notification_preferences AS np
  WHERE np.user_id = v_user_id
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1
    FROM public.share_events AS se
    WHERE se.user_id = v_user_id
      AND se.feature = 'invite_housemate'
      AND se.channel IS NOT NULL
  )
  INTO v_has_flatmate_invite_share;

  SELECT EXISTS (
    SELECT 1
    FROM public.share_events AS se
    WHERE se.user_id = v_user_id
      AND se.feature = 'invite_button'
      AND se.channel IS NOT NULL
  )
  INTO v_has_invite_share;

  -- Step 1: prompt notifications when permission is unknown (including "no row")
  -- and the user has authored at least 1 chore.
  IF v_notif_os_permission = 'unknown'
     AND v_lifetime_authored_chore_count >= 1 THEN
    v_prompt_notifications := TRUE;

  ELSIF v_lifetime_authored_chore_count >= 2
        AND NOT v_has_flatmate_invite_share THEN
    v_prompt_flatmate_invite_share := TRUE;

  ELSIF v_lifetime_authored_chore_count >= 5
        AND NOT v_has_invite_share THEN
    v_prompt_invite_share := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'userAuthoredChoreCountLifetime', v_lifetime_authored_chore_count,
    'shouldPromptNotifications', v_prompt_notifications,
    'shouldPromptFlatmateInviteShare', v_prompt_flatmate_invite_share,
    'shouldPromptInviteShare', v_prompt_invite_share
  );
END;
$$;
