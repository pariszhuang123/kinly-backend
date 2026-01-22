-- Notifications: support multi-device sends and cap active tokens per platform
-- - notification_sends now tracks token_id and reserves per token/date
-- - enforce a per-platform active token cap on sync

-- --------------------------------------------------------------------
-- notification_sends: add token_id + unique per token/date
-- --------------------------------------------------------------------
ALTER TABLE public.notification_sends
  ADD COLUMN IF NOT EXISTS token_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_notification_sends_token_id'
  ) THEN
    ALTER TABLE public.notification_sends
      ADD CONSTRAINT fk_notification_sends_token_id
      FOREIGN KEY (token_id)
      REFERENCES public.device_tokens(id)
      ON DELETE CASCADE;
  END IF;
END $$;

DROP INDEX IF EXISTS uq_notification_sends_user_date;

CREATE UNIQUE INDEX IF NOT EXISTS uq_notification_sends_token_date
  ON public.notification_sends (token_id, local_date);

-- --------------------------------------------------------------------
-- notifications_reserve_send: reserve per token/date
-- --------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.notifications_reserve_send(
  uuid, date, text
);

CREATE OR REPLACE FUNCTION public.notifications_reserve_send(
  p_user_id    uuid,
  p_token_id   uuid,
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
  IF p_token_id IS NULL THEN
    RAISE EXCEPTION 'TOKEN_REQUIRED';
  END IF;

  INSERT INTO public.notification_sends (
    user_id,
    token_id,
    local_date,
    job_run_id,
    status,
    reserved_at
  )
  VALUES (
    p_user_id,
    p_token_id,
    p_local_date,
    p_job_run_id,
    'reserved',
    now()
  )
  ON CONFLICT (token_id, local_date) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- --------------------------------------------------------------------
-- notifications_sync_client_state: cap active tokens per platform
-- --------------------------------------------------------------------
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
  v_max_active_per_platform integer := 2;
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

    -- Cap active tokens per platform by expiring the oldest seen tokens.
    IF p_platform IS NOT NULL THEN
      WITH ranked AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            ORDER BY last_seen_at DESC, updated_at DESC
          ) AS rn
        FROM public.device_tokens
        WHERE user_id = v_user_id
          AND platform = p_platform
          AND provider = 'fcm'
          AND status = 'active'
      )
      UPDATE public.device_tokens
      SET status = 'expired',
          updated_at = now()
      WHERE id IN (
        SELECT id FROM ranked WHERE rn > v_max_active_per_platform
      );
    END IF;
  END IF;

  RETURN v_current;
END;
$$;

-- --------------------------------------------------------------------
-- Permissions for updated signatures
-- --------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.notifications_reserve_send(
  uuid, uuid, date, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.notifications_reserve_send(
  uuid, uuid, date, text
) TO service_role;

