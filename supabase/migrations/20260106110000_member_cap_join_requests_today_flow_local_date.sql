-- Member cap: pending join queue, owner surfacing, and auto-resolution after upgrade.
-- Up-to-date version (not deployed yet): live joiner names via profiles.username, lock-order aligned,
-- unique-violation safe joins, consistent JSON payloads.

-- ---------------------------------------------------------------------
-- TABLE: member_cap_join_requests
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.member_cap_join_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id          uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  joiner_user_id   uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at      timestamptz,
  resolved_reason  text CHECK (resolved_reason IN (
    'joined',
    'joiner_superseded',
    'home_inactive',
    'invite_missing',
    'owner_dismissed'
  )),
  resolved_payload jsonb
);

COMMENT ON TABLE public.member_cap_join_requests IS
  'Queue of join attempts blocked by member cap; resolved on owner upgrade/dismiss. Joiner names are read live from profiles.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_cap_requests_home_joiner_open
  ON public.member_cap_join_requests (home_id, joiner_user_id)
  WHERE resolved_at IS NULL;

ALTER TABLE public.member_cap_join_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.member_cap_join_requests FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- Helper: ensure caller is home owner
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_home_owner(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();

  IF NOT public.is_home_owner(p_home_id, auth.uid()) THEN
    PERFORM public.api_error(
      'NOT_HOME_OWNER',
      'Only the home owner can perform this action.',
      '42501',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._assert_home_owner(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._assert_home_owner(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- Helper: enqueue a blocked join request (idempotent per home+joiner)
-- NOTE: Joiner display name is read live from profiles.username when surfaced.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._member_cap_enqueue_request(
  p_home_id uuid,
  p_joiner_user_id uuid
) RETURNS public.member_cap_join_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.member_cap_join_requests;
BEGIN
  IF p_home_id IS NULL OR p_joiner_user_id IS NULL THEN
    PERFORM public.api_error('INVALID_INPUT', 'home_id and joiner_user_id are required.', '22023');
  END IF;

  INSERT INTO public.member_cap_join_requests (home_id, joiner_user_id)
  VALUES (p_home_id, p_joiner_user_id)
  ON CONFLICT (home_id, joiner_user_id) WHERE resolved_at IS NULL DO UPDATE
    SET home_id = EXCLUDED.home_id  -- no-op; keeps RETURNING working
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._member_cap_enqueue_request(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._member_cap_enqueue_request(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._member_cap_resolve_requests(
  p_home_id uuid,
  p_reason text,
  p_request_ids uuid[] DEFAULT NULL,
  p_payload jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_INPUT', 'home_id is required.', '22023');
  END IF;

  IF p_reason IS NULL THEN
    PERFORM public.api_error('INVALID_REASON', 'resolved_reason is required.', '22023');
  END IF;

  UPDATE public.member_cap_join_requests
     SET resolved_at      = now(),
         resolved_reason  = p_reason,
         resolved_payload = p_payload
   WHERE home_id = p_home_id
     AND resolved_at IS NULL
     AND (p_request_ids IS NULL OR id = ANY(p_request_ids));
END;
$$;

REVOKE ALL ON FUNCTION public._member_cap_resolve_requests(uuid, text, uuid[], jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._member_cap_resolve_requests(uuid, text, uuid[], jsonb) TO service_role;

-- ---------------------------------------------------------------------
-- Owner dismiss: clear pending requests for a home
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.member_cap_owner_dismiss(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_owner(p_home_id);

  PERFORM public._member_cap_resolve_requests(
    p_home_id,
    'owner_dismissed',
    NULL,
    jsonb_build_object('by', v_user)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.member_cap_owner_dismiss(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.member_cap_owner_dismiss(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- Auto-resolution after upgrade to premium
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.member_cap_process_pending(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv public.invites;
  v_row public.member_cap_join_requests%ROWTYPE;
  v_home_active boolean;
BEGIN
  IF p_home_id IS NULL THEN
    RETURN;
  END IF;

  -- Only process when premium
  IF NOT public._home_is_premium(p_home_id) THEN
    RETURN;
  END IF;

  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    RETURN;
  END IF;

  -- Ensure invite exists (one active per home)
  SELECT *
    INTO v_inv
    FROM public.invites
   WHERE home_id = p_home_id
     AND revoked_at IS NULL
   ORDER BY created_at DESC, id DESC
   LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.invites (home_id, code)
    VALUES (p_home_id, public._gen_invite_code())
    ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING;

    SELECT *
      INTO v_inv
      FROM public.invites
     WHERE home_id = p_home_id
       AND revoked_at IS NULL
     ORDER BY created_at DESC, id DESC
     LIMIT 1;
  END IF;

  FOR v_row IN
    SELECT *
      FROM public.member_cap_join_requests
     WHERE home_id = p_home_id
       AND resolved_at IS NULL
     ORDER BY created_at ASC, id ASC
  LOOP
    -- home inactive (defensive)
    IF v_home_active IS DISTINCT FROM TRUE THEN
      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'home_inactive',
        ARRAY[v_row.id],
        NULL
      );
      CONTINUE;
    END IF;

    -- no invite (defensive)
    IF v_inv.id IS NULL THEN
      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'invite_missing',
        ARRAY[v_row.id],
        NULL
      );
      CONTINUE;
    END IF;

    -- attempt to join; handle races safely via unique constraint on memberships(user_id) WHERE is_current
    BEGIN
      INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
      VALUES (v_row.joiner_user_id, p_home_id, 'member', now(), NULL);

      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('active_members', 1)
      );

      UPDATE public.invites
         SET used_count = used_count + 1
       WHERE id = v_inv.id;

      PERFORM public._home_attach_subscription_to_home(v_row.joiner_user_id, p_home_id);

      PERFORM public._member_cap_resolve_requests(
        p_home_id,
        'joined',
        ARRAY[v_row.id],
        jsonb_build_object('invite_id', v_inv.id, 'invite_code', v_inv.code)
      );

    EXCEPTION
      WHEN unique_violation THEN
        -- joiner got a current membership elsewhere (or already joined) between checks and insert
        PERFORM public._member_cap_resolve_requests(
          p_home_id,
          'joiner_superseded',
          ARRAY[v_row.id],
          NULL
        );
        CONTINUE;

      WHEN OTHERS THEN
        -- Do NOT RAISE: one bad request should not stall the entire queue.
        -- Leaving unresolved allows future retries after transient issues.
        CONTINUE;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.member_cap_process_pending(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.member_cap_process_pending(uuid) TO service_role;

-- ---------------------------------------------------------------------
-- homes.join(code): add member-cap pending request path
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_join(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid := auth.uid();
  v_home_id uuid;
  v_revoked boolean;
  v_active  boolean;

  v_plan    text;
  v_cap     integer;
  v_current_members integer := 0;

  v_req public.member_cap_join_requests;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- Combined lookup: home_id + invite state
  SELECT
    i.home_id,
    (i.revoked_at IS NOT NULL) AS revoked,
    h.is_active
  INTO
    v_home_id,
    v_revoked,
    v_active
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::public.citext
  LIMIT 1;

  -- Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'code_not_found'
      )
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'revoked_or_home_inactive'
      )
    );
  END IF;

  -- Ensure caller has a unique avatar within this home (plan-gated)
  PERFORM public._ensure_unique_avatar_for_home(v_home_id, v_user);

  -- Already current member of this same home
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = v_home_id
       AND m.is_current = TRUE
  ) THEN
    RETURN jsonb_build_object(
      'status',  'success',
      'code',    'already_member',
      'message', 'You are already part of this household.',
      'home_id', v_home_id
    );
  END IF;

  -- Already in another active home (only one allowed)
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.is_current = TRUE
       AND m.home_id <> v_home_id
  ) THEN
    PERFORM public.api_error(
      'ALREADY_IN_OTHER_HOME',
      'You are already a member of another household. Leave it first before joining a new one.',
      '42501',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'single_home_rule'
      )
    );
  END IF;

  -- Member-cap precheck (free-only): block + enqueue instead of raising paywall
  v_plan := public._home_effective_plan(v_home_id);

  IF v_plan = 'free' THEN
    -- Align lock order explicitly (homes -> home_usage_counters ...)
    PERFORM 1
      FROM public.homes h
     WHERE h.id = v_home_id
     FOR UPDATE;

    -- Ensure counters row exists and lock it
    PERFORM public._home_usage_apply_delta(v_home_id, '{}'::jsonb);

    SELECT COALESCE(active_members, 0)
      INTO v_current_members
      FROM public.home_usage_counters
     WHERE home_id = v_home_id
     FOR UPDATE;

    SELECT max_value
      INTO v_cap
      FROM public.home_plan_limits
     WHERE plan = v_plan
       AND metric = 'active_members';

    IF v_cap IS NOT NULL AND (v_current_members + 1) > v_cap THEN
      v_req := public._member_cap_enqueue_request(v_home_id, v_user);

      RETURN jsonb_build_object(
        'status',     'blocked',
        'code',       'member_cap',
        'message',    'Home is not accepting new members right now. We notified the owner.',
        'home_id',    v_home_id,
        'request_id', v_req.id
      );
    END IF;
  END IF;

  -- Paywall: enforce active_members limit on this home (raises on free over-limit)
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership (race-safe)
  BEGIN
    INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
    VALUES (v_user, v_home_id, 'member', now(), NULL);
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_error(
        'ALREADY_IN_OTHER_HOME',
        'You are already a member of another household. Leave it first before joining a new one.',
        '42501',
        jsonb_build_object(
          'context', 'homes_join',
          'reason', 'unique_violation_memberships'
        )
      );
  END;

  -- Increment cached active_members
  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::public.citext;

  -- Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);

  -- Success response
  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.homes_join(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.homes_join(text) TO authenticated;

-- ---------------------------------------------------------------------
-- today_onboarding_hints(): surface pending member-cap requests for owner
-- NOTE: joiner names are read live from profiles.username
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
      'memberCapJoinRequests', 'null'::jsonb
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

  RETURN jsonb_build_object(
    'userAuthoredChoreCountLifetime', v_lifetime_authored_chore_count,
    'shouldPromptNotifications', v_prompt_notifications,
    'shouldPromptFlatmateInviteShare', v_prompt_flatmate_invite_share,
    'shouldPromptInviteShare', v_prompt_invite_share,
    'memberCapJoinRequests', COALESCE(v_member_cap_payload, 'null'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.today_onboarding_hints() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.today_onboarding_hints() TO authenticated;

-- ---------------------------------------------------------------------
-- home_entitlements_refresh: invoke member-cap resolver on upgrade
-- NOTE: As per your grants: only service_role/postgres should have EXECUTE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.home_entitlements_refresh(_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_has_valid  boolean;
  v_latest_exp timestamptz;
BEGIN
  SELECT
    EXISTS (
      SELECT 1
        FROM public.user_subscriptions us
       WHERE us.home_id = _home_id
         AND us.status IN ('active', 'cancelled')
         AND (us.current_period_end_at IS NULL OR us.current_period_end_at > now())
    ) AS has_valid_subscription,
    MAX(us.current_period_end_at) AS latest_expiry
  INTO v_has_valid, v_latest_exp
  FROM public.user_subscriptions us
  WHERE us.home_id = _home_id;

  INSERT INTO public.home_entitlements AS he (home_id, plan, expires_at)
  VALUES (
    _home_id,
    CASE WHEN v_has_valid THEN 'premium' ELSE 'free' END,
    CASE WHEN v_has_valid THEN v_latest_exp ELSE NULL END
  )
  ON CONFLICT (home_id) DO UPDATE
  SET
    plan       = EXCLUDED.plan,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();

  -- If upgraded to premium, attempt to process pending member-cap joins
  IF v_has_valid THEN
    PERFORM public.member_cap_process_pending(_home_id);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.home_entitlements_refresh(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_entitlements_refresh(uuid) TO service_role;
-- (postgres retains implicit rights; keep if you explicitly grant in your environment)

-- Align today_flow_list with client-provided local date to avoid UTC drift.
-- Adds an optional p_local_date (defaults to current_date) so the client can
-- pass its local day; callers can keep using the existing signature unchanged.

DROP FUNCTION IF EXISTS public.today_flow_list(uuid, public.chore_state);

CREATE OR REPLACE FUNCTION public.today_flow_list(
  p_home_id    uuid,
  p_state      public.chore_state,
  p_local_date date DEFAULT current_date
)
RETURNS TABLE (
  id         uuid,
  home_id    uuid,
  name       text,
  start_date date,
  state      public.chore_state
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    id,
    home_id,
    name,
    current_due_on AS start_date,
    state
  FROM public._chores_base_for_home(p_home_id)
  WHERE state = p_state
    AND current_due_on <= p_local_date  -- client-local day boundary
    AND (
      (p_state = 'draft'::public.chore_state AND created_by_user_id = auth.uid())
      OR (p_state = 'active'::public.chore_state AND assignee_user_id = auth.uid())
    )
  ORDER BY current_due_on ASC, created_at ASC;
$$;

REVOKE ALL ON FUNCTION public.today_flow_list(uuid, public.chore_state, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.today_flow_list(uuid, public.chore_state, date) TO authenticated;
