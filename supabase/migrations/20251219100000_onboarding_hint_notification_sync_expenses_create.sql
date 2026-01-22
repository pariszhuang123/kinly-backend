-- Fix onboarding hints notification prompt when no prefs row exists
-- Contract: This RPC is only meaningful when the user has a current, active home.
-- If no current home exists, return no prompts.

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

  v_has_notif_pref boolean := FALSE;
  v_has_flatmate_invite_share boolean := FALSE;
  v_has_invite_share boolean := FALSE;

  v_prompt_notifications boolean := FALSE;
  v_prompt_flatmate_invite_share boolean := FALSE;
  v_prompt_invite_share boolean := FALSE;
BEGIN
  PERFORM public._assert_authenticated();

  ------------------------------------------------------------------
  -- Resolve current home (if any)
  ------------------------------------------------------------------
  SELECT m.home_id
  INTO v_home_id
  FROM public.memberships AS m
  WHERE m.user_id   = v_user_id
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

  ------------------------------------------------------------------
  -- Guards: membership + active home
  ------------------------------------------------------------------
  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  ------------------------------------------------------------------
-- Load lifetime user signals (global across homes)
  ------------------------------------------------------------------
  SELECT COUNT(*)
  INTO v_lifetime_authored_chore_count
  FROM public.chores AS c
  WHERE c.created_by_user_id = v_user_id;

  SELECT EXISTS (
    SELECT 1 FROM public.notification_preferences AS np
    WHERE np.user_id = v_user_id
  )
  INTO v_has_notif_pref;

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

  ------------------------------------------------------------------
  -- Ladder (user-authored chore gates)
  ------------------------------------------------------------------
  -- Step 1: notifications only after the user has authored at least 1 chore
  IF NOT v_has_notif_pref
     AND v_lifetime_authored_chore_count >= 1 THEN
    v_prompt_notifications := TRUE;

  -- Step 2: flatmate invite after 2+ user-authored chores
  ELSIF v_lifetime_authored_chore_count >= 2
        AND NOT v_has_flatmate_invite_share THEN
    v_prompt_flatmate_invite_share := TRUE;

  -- Step 3: generic invite after 5+ user-authored chores
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

REVOKE ALL ON FUNCTION public.today_onboarding_hints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.today_onboarding_hints() TO authenticated;


-- --------------------------------------------------------------------
-- Client RPC: sync notification state from app
-- (token + locale/tz + OS permission + optional wants_daily)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notifications_sync_client_state(
  p_token           text,
  p_platform        text,
  p_locale          text,
  p_timezone        text,
  p_os_permission   text,          -- 'allowed' | 'blocked' | 'unknown'
  p_wants_daily     boolean DEFAULT NULL,
  p_preferred_hour  integer DEFAULT NULL
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
  v_should_upsert boolean;
BEGIN
  PERFORM public._assert_authenticated();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  -- Load existing row if any
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

  -- Force off when OS is blocked/unknown so UI toggle matches system
  IF p_os_permission IS DISTINCT FROM 'allowed' THEN
    v_effective_wants_daily := FALSE;
  END IF;

  v_effective_preferred_hour :=
    COALESCE(
      p_preferred_hour,
      v_current.preferred_hour,
      9
    );

  -- Only upsert when we have something explicit or an existing row
  v_should_upsert :=
       v_current.user_id IS NOT NULL
    OR p_wants_daily IS NOT NULL
    OR p_preferred_hour IS NOT NULL
    OR p_token IS NOT NULL
    OR p_os_permission = 'allowed';

  IF NOT v_should_upsert THEN
    -- Return a synthetic row without creating DB state
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
      now()
    )::public.notification_preferences;
  END IF;

  -- Upsert prefs
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
    SET wants_daily     = EXCLUDED.wants_daily,
        preferred_hour  = EXCLUDED.preferred_hour,
        timezone        = EXCLUDED.timezone,
        locale          = EXCLUDED.locale,
        os_permission   = EXCLUDED.os_permission,
        last_os_sync_at = EXCLUDED.last_os_sync_at,
        updated_at      = EXCLUDED.updated_at
  RETURNING * INTO v_current;

  -- Upsert device token if provided
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

-- Allow draft expenses to omit amount_cents while keeping active expenses strict

-- 0) Drop old functions (signature must match EXACTLY)
DROP FUNCTION IF EXISTS public.expenses_create(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb
);

-- 1) Relax column nullability and enforce active rows still require amount
ALTER TABLE public.expenses
  ALTER COLUMN amount_cents DROP NOT NULL;

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_active_amount_required,
  ADD CONSTRAINT chk_expenses_active_amount_required
    CHECK (  status <> 'active' OR amount_cents > 0);

COMMENT ON COLUMN public.expenses.amount_cents IS
  'Total amount in integer cents; null allowed for draft expenses.';

-- 2) Update expenses_create to allow draft creation without amount
CREATE OR REPLACE FUNCTION public.expenses_create(
  p_home_id      uuid,
  p_description  text,
  p_amount_cents bigint DEFAULT NULL,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;
  v_result         public.expenses%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  IF p_split_mode IS NULL THEN
    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;

    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents.', v_amount_cap),
          '22023'
        );
      END IF;
    END IF;
  ELSE
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL
       OR p_amount_cents <= 0
       OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    notes
  )
  VALUES (
    v_home_id,
    v_user,
    v_new_status,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), '')
  )
  RETURNING * INTO v_result;

  IF v_has_splits THEN
    INSERT INTO public.expense_splits (
      expense_id,
      debtor_user_id,
      amount_cents,
      status,
      marked_paid_at
    )
    SELECT v_result.id,
           debtor_user_id,
           amount_cents,
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create(uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create(uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb)
TO authenticated;
