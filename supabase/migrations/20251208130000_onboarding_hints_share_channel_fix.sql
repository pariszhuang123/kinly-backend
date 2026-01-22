-- Fix onboarding hints notification prompt when no prefs row exists
CREATE OR REPLACE FUNCTION public.today_onboarding_hints()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_home_id uuid;
  v_active_chores int := 0;

  v_has_notif_pref boolean := FALSE;
  v_has_flatmate_invite_share boolean := FALSE;
  v_has_invite_share boolean := FALSE;

  v_prompt_notifications boolean := FALSE;
  v_prompt_flatmate_invite_share boolean := FALSE;
  v_prompt_invite_share boolean := FALSE;
BEGIN
  ------------------------------------------------------------------
  -- 0) Require authenticated user up front
  ------------------------------------------------------------------
  PERFORM public._assert_authenticated();

  ------------------------------------------------------------------
  -- 1) Resolve current home
  ------------------------------------------------------------------
  SELECT m.home_id
  INTO v_home_id
  FROM public.memberships AS m
  WHERE m.user_id   = v_user_id
    AND m.is_current = TRUE
  LIMIT 1;

  -- No current home -> nothing to show
  IF v_home_id IS NULL THEN
    RETURN jsonb_build_object(
      'activeChoreCount', 0,
      'shouldPromptNotifications', FALSE,
      'shouldPromptFlatmateInviteShare', FALSE,
      'shouldPromptInviteShare', FALSE
    );
  END IF;

  ------------------------------------------------------------------
  -- 2) Guards: membership + home active
  ------------------------------------------------------------------
  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  ------------------------------------------------------------------
  -- 3) Active chores
  ------------------------------------------------------------------
  SELECT COALESCE(huc.active_chores, 0)
  INTO v_active_chores
  FROM public.home_usage_counters AS huc
  WHERE huc.home_id = v_home_id;

  IF NOT FOUND THEN
    v_active_chores := 0;
  END IF;

  ------------------------------------------------------------------
  -- 4) Hints pre-conditions
  ------------------------------------------------------------------

  -- Has any notification preference row yet?
  SELECT EXISTS (
    SELECT 1
    FROM public.notification_preferences AS np
    WHERE np.user_id = v_user_id
  )
  INTO v_has_notif_pref;

  -- Has user ever shared a housemate/flatmate invite?
  SELECT EXISTS (
    SELECT 1
    FROM public.share_events AS se
    WHERE se.user_id = v_user_id
      AND se.feature = 'invite_housemate'
      AND se.channel IS NOT NULL
  )
  INTO v_has_flatmate_invite_share;

  -- Has user ever shared a generic invite?
  SELECT EXISTS (
    SELECT 1
    FROM public.share_events AS se
    WHERE se.user_id = v_user_id
      AND se.feature = 'invite_button'
      AND se.channel IS NOT NULL
  )
  INTO v_has_invite_share;

  ------------------------------------------------------------------
  -- 5) One-at-a-time onboarding logic (priority ladder)
  ------------------------------------------------------------------

  -- Step 1: daily notifications
  IF v_active_chores >= 1
     AND NOT v_has_notif_pref THEN
    v_prompt_notifications := TRUE;

  -- Step 2: flatmate/housemate invite share
  ELSIF v_active_chores >= 2
        AND NOT v_has_flatmate_invite_share THEN
    v_prompt_flatmate_invite_share := TRUE;

  -- Step 3: generic invite share
  ELSIF v_active_chores >= 5
        AND NOT v_has_invite_share THEN
    v_prompt_invite_share := TRUE;
  END IF;

  ------------------------------------------------------------------
  -- 6) Response
  ------------------------------------------------------------------
  RETURN jsonb_build_object(
    'activeChoreCount', v_active_chores,
    'shouldPromptNotifications', v_prompt_notifications,
    'shouldPromptFlatmateInviteShare', v_prompt_flatmate_invite_share,
    'shouldPromptInviteShare', v_prompt_invite_share
  );
END;
$$;

REVOKE ALL ON FUNCTION public.today_onboarding_hints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.today_onboarding_hints() TO authenticated;
