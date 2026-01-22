CREATE OR REPLACE FUNCTION public.expenses_get_created_by_me(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_result         jsonb;
  v_home_is_active boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  -- Caller must be a current member of this home
  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = p_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id, 'userId', v_user)
    );
  END IF;

  -- Home is fully frozen when inactive
  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  /*
    Build list of live expenses created by the current user.

    Rules:
    - Include creator in the split stats so paidAmountCents / amountCents
      reflects:
        * 25/60 when only the creator has paid
        * 60/60 when everyone has paid.
    - Exclude expenses that:
        * are fully paid (all shares paid), AND
        * were created more than 14 days ago.
    - Sort by:
        1) payment status: unpaid -> partial -> fully paid
        2) createdAt: newest first
  */
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',        e.id,
               'homeId',           e.home_id,
               'createdByUserId',  e.created_by_user_id,
               'description',      e.description,
               'amountCents',      e.amount_cents,
               'status',           e.status,
               'splitType',        e.split_type,
               'createdAt',        e.created_at,
               'recurrenceInterval', e.recurrence_interval,
               'startDate',        e.start_date,
               'totalShares',      COALESCE(stats.total_shares, 0)::int,
               'paidShares',       COALESCE(stats.paid_shares, 0)::int,
               'paidAmountCents',  COALESCE(stats.paid_amount_cents, 0),
               'allPaid',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN FALSE
                   ELSE COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                 END,
               'fullyPaidAt',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN NULL
                   WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                     THEN stats.max_paid_at
                   ELSE NULL
                 END
             )
             ORDER BY
               -- payment status rank: 0 = unpaid, 1 = partial, 2 = fully paid
               CASE
                 WHEN COALESCE(stats.total_shares, 0) = 0 THEN 0                             -- treat as unpaid
                 WHEN COALESCE(stats.paid_shares, 0) = 0 THEN 0                             -- unpaid
                 WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                   THEN 2                                                                   -- fully paid
                 ELSE 1                                                                     -- partially paid
               END,
               e.created_at DESC,
               e.id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM public.expenses e
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) AS total_shares,
        COUNT(*) FILTER (WHERE s.status = 'paid') AS paid_shares,
        COALESCE(
          SUM(s.amount_cents) FILTER (WHERE s.status = 'paid'),
          0
        ) AS paid_amount_cents,
        MAX(s.marked_paid_at) FILTER (WHERE s.status = 'paid') AS max_paid_at
      FROM public.expense_splits s
      WHERE s.expense_id = e.id
      -- creator is included here now
    ) stats ON TRUE
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND e.status IN ('draft', 'active')
    -- Filter out fully-paid expenses older than 14 days
    AND NOT (
      COALESCE(stats.total_shares, 0) > 0
      AND COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
      AND e.created_at < (CURRENT_TIMESTAMP - INTERVAL '14 days')
    );

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------
-- Member cap resolution notifications (one-time per request)
-- ---------------------------------------------------------------------
ALTER TABLE public.member_cap_join_requests
  ADD COLUMN IF NOT EXISTS resolution_notified_at timestamptz;

COMMENT ON COLUMN public.member_cap_join_requests.resolution_notified_at IS
  'Set when the owner has been notified about the resolved join request.';

-- ---------------------------------------------------------------------
-- today_onboarding_hints(): include one-time resolution payload
-- ---------------------------------------------------------------------
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

    v_notif_os_permission text := 'unknown';
    v_notif_wants_daily boolean := FALSE;

    v_has_flatmate_invite_share boolean := FALSE;
    v_has_invite_share boolean := FALSE;

    v_prompt_notifications boolean := FALSE;
    v_prompt_flatmate_invite_share boolean := FALSE;
    v_prompt_invite_share boolean := FALSE;

    v_member_cap_payload jsonb := NULL;
    v_member_cap_resolution jsonb := NULL;
    v_resolution_request_id uuid := NULL;
    v_home_plan text;
    v_is_owner boolean := FALSE;
  BEGIN
    PERFORM public._assert_authenticated();

    SELECT m.home_id, (m.role = 'owner')
      INTO v_home_id, v_is_owner
      FROM public.memberships AS m
     WHERE m.user_id    = v_user_id
       AND m.is_current = TRUE
     LIMIT 1;

    IF v_home_id IS NULL THEN
      RETURN jsonb_build_object(
        'userAuthoredChoreCountLifetime', 0,
        'shouldPromptNotifications', FALSE,
        'shouldPromptFlatmateInviteShare', FALSE,
        'shouldPromptInviteShare', FALSE,
        'memberCapJoinRequests', 'null'::jsonb,
        'memberCapJoinResolution', 'null'::jsonb
      );
    END IF;

    PERFORM public._assert_home_member(v_home_id);
    PERFORM public._assert_home_active(v_home_id);

    SELECT plan
      INTO v_home_plan
      FROM public.home_entitlements
     WHERE home_id = v_home_id;

    SELECT COUNT(*)
      INTO v_lifetime_authored_chore_count
      FROM public.chores AS c
     WHERE c.created_by_user_id = v_user_id;

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

    IF v_is_owner IS TRUE AND v_home_plan = 'free' THEN
      SELECT jsonb_build_object(
        'homeId', v_home_id,
        'pendingCount', COUNT(*),
        'joinerNames', COALESCE(
          jsonb_agg(p.username ORDER BY r.created_at ASC)
            FILTER (WHERE p.username IS NOT NULL),
          '[]'::jsonb
        ),
        'requestIds', COALESCE(
          jsonb_agg(r.id ORDER BY r.created_at ASC),
          '[]'::jsonb
        )
      )
      INTO v_member_cap_payload
      FROM public.member_cap_join_requests r
      LEFT JOIN public.profiles p ON p.id = r.joiner_user_id
      WHERE r.home_id = v_home_id
        AND r.resolved_at IS NULL;
    END IF;

    IF v_is_owner IS TRUE AND v_home_plan = 'premium' THEN
      SELECT jsonb_build_object(
        'requestId', r.id,
        'joinerName', COALESCE(p.username, ''),
        'resolvedReason', r.resolved_reason
      )
      INTO v_member_cap_resolution
      FROM public.member_cap_join_requests r
      LEFT JOIN public.profiles p ON p.id = r.joiner_user_id
      WHERE r.home_id = v_home_id
        AND r.resolved_at IS NOT NULL
        AND r.resolved_reason IN ('joined', 'joiner_superseded')
        AND r.resolution_notified_at IS NULL
      ORDER BY r.resolved_at DESC
      LIMIT 1;
    END IF;

    IF v_member_cap_resolution IS NOT NULL THEN
      v_resolution_request_id :=
        (v_member_cap_resolution->>'requestId')::uuid;
    END IF;

    IF v_resolution_request_id IS NOT NULL THEN
      UPDATE public.member_cap_join_requests
         SET resolution_notified_at = now()
       WHERE id = v_resolution_request_id
         AND resolution_notified_at IS NULL;
    END IF;

    RETURN jsonb_build_object(
      'userAuthoredChoreCountLifetime', v_lifetime_authored_chore_count,
      'shouldPromptNotifications', v_prompt_notifications,
      'shouldPromptFlatmateInviteShare', v_prompt_flatmate_invite_share,
      'shouldPromptInviteShare', v_prompt_invite_share,
      'memberCapJoinRequests', COALESCE(v_member_cap_payload, 'null'::jsonb),
      'memberCapJoinResolution', COALESCE(v_member_cap_resolution, 'null'::jsonb)
    );
  END;
$$;

REVOKE ALL ON FUNCTION public.today_onboarding_hints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.today_onboarding_hints() TO authenticated;
