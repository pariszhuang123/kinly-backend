-- Guard homes.create/join for deactivated profiles
-- Adds _assert_active_profile() and calls it from both RPCs.

CREATE OR REPLACE FUNCTION public._assert_active_profile()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.deactivated_at IS NULL
    ),
    'PROFILE_DEACTIVATED',
    'Your profile is deactivated. Reactivate it to continue.',
    '42501'
  );
END;
$$;

REVOKE ALL ON FUNCTION public._assert_active_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._assert_active_profile() TO authenticated;

-- ---------------------------------------------------------------------
-- homes.join(code) -> returns joined home_id
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
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  --------------------------------------------------------------------
  -- Combined lookup: home_id + invite state
  --------------------------------------------------------------------
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
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object('code', p_code)
    );
  END IF;

  --------------------------------------------------------------------
  -- Ensure caller has a unique avatar within this home (plan-gated)
  -- This now runs even if they are already a member of the home.
  --------------------------------------------------------------------
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
      '42501'
    );
  END IF;

  --------------------------------------------------------------------
  -- Paywall: enforce active_members limit on this home
  --------------------------------------------------------------------
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, v_home_id, 'member', now(), NULL);

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
-- homes.create_with_invite() -> returns the created home row
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_create_with_invite()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home public.homes;
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- 1) Create home
  INSERT INTO public.homes (owner_user_id)
  VALUES (v_user)
  RETURNING * INTO v_home;

  -- 2) Create owner membership (first active member)
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  -- 3) Increment usage counters: active_members +1
  PERFORM public._home_usage_apply_delta(
    v_home.id,
    jsonb_build_object('active_members', 1)
  );

  -- 4) Set entitlements (default: free)
  INSERT INTO public.home_entitlements (home_id, plan, expires_at)
  VALUES (v_home.id, 'free', NULL);

  -- 5) Create first invite (one active per home enforced by partial index)
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT *
    INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id
      AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  -- 6) Attach existing subscription to this home (if any)
  PERFORM public._home_attach_subscription_to_home(v_user, v_home.id);

  -- 7) Return result
  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id,
      'owner_user_id', v_home.owner_user_id,
      'created_at',    v_home.created_at
    ),
    'invite', jsonb_build_object(
      'id',         v_inv.id,
      'home_id',    v_inv.home_id,
      'code',       v_inv.code,
      'created_at', v_inv.created_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.homes_create_with_invite() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.homes_create_with_invite() TO authenticated;
