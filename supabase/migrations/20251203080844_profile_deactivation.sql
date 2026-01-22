CREATE OR REPLACE FUNCTION public.profiles_request_deactivation()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid := auth.uid();
  v_home_id        uuid;
  v_deactivated_at timestamptz;
BEGIN
  PERFORM public._assert_authenticated();

  -- Find the caller's current home (at most one is allowed today)
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user
     AND m.is_current
   LIMIT 1;

  -- Leave the home first; bubbles OWNER_MUST_TRANSFER_FIRST if needed
  IF v_home_id IS NOT NULL THEN
    PERFORM public.homes_leave(v_home_id);
  END IF;

  -- Mark profile as deactivated (idempotent)
  UPDATE public.profiles p
     SET deactivated_at = COALESCE(p.deactivated_at, now()),
         updated_at     = now()
   WHERE p.id = v_user
  RETURNING deactivated_at INTO v_deactivated_at;

  IF v_deactivated_at IS NULL THEN
    PERFORM public.api_error(
      'PROFILE_NOT_FOUND',
      'Profile not found for current user.',
      'P0002',
      jsonb_build_object('user_id', v_user)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', 'DEACTIVATION_REQUESTED',
    'data', jsonb_build_object(
      'deactivated_at', v_deactivated_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.profiles_request_deactivation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.profiles_request_deactivation() TO authenticated;


-- ---------------------------------------------------------------------
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
        is_current = FALSE,
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

