-- ---------------------------------------------------------------------
-- RPCs for Homes/Memberships/Invites (RLS remains locked; RPC-only)
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Helper: current auth user
CREATE OR REPLACE FUNCTION public._current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.api_error(
  p_code text,
  p_msg text,
  p_sqlstate text DEFAULT 'P0001',
  p_details jsonb DEFAULT NULL,
  p_hint text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  RAISE EXCEPTION USING
    MESSAGE = json_build_object('code', p_code, 'message', p_msg, 'details', p_details)::text,
    ERRCODE = p_sqlstate,
    DETAIL  = p_details::text,
    HINT    = p_hint;
END;
$$;

CREATE OR REPLACE FUNCTION public.api_assert(
  p_condition boolean,
  p_code text,
  p_msg text,
  p_sqlstate text DEFAULT 'P0001',
  p_details jsonb DEFAULT NULL,
  p_hint text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF NOT coalesce(p_condition, false) THEN
    PERFORM public.api_error(p_code, p_msg, p_sqlstate, p_details, p_hint);
  END IF;
END;
$$;


-- Helper: assert caller is authenticated
CREATE OR REPLACE FUNCTION public._assert_authenticated()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM public.api_error('UNAUTHORIZED', 'Authentication required', '28000');
  END IF;
END;
$$;

-- Helper: generate a 6-char Crockford Base32 code (no I/O/0/1)
CREATE OR REPLACE FUNCTION public._gen_invite_code()
RETURNS citext
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  out_code text := '';
  i int;
  idx int;
BEGIN
  FOR i IN 1..6 LOOP
    idx := 1 + floor(random() * length(alphabet))::int;
    out_code := out_code || substr(alphabet, idx, 1);
  END LOOP;
  RETURN out_code::citext;
END;
$$;


-- 1) One-active-invite-per-home safety (run once)
CREATE UNIQUE INDEX IF NOT EXISTS uq_invites_active_one_per_home
  ON public.invites (home_id)
  WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------
-- homes.create() -> returns the created home row
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_create_with_invite(p_name text)
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

  -- Create home (add other NOT NULL cols as needed)
  INSERT INTO public.homes (name, owner_user_id)
  VALUES (p_name, v_user)
  RETURNING * INTO v_home;

  -- Create owner membership (current)
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  -- Create first (active) invite. If one somehow exists, don’t rotate it.
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT ON CONSTRAINT uq_invites_active_one_per_home DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT * INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  -- Return a stable API shape
  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id,
      'name',          v_home.name,
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

-- ---------------------------------------------------------------------
-- invites.revoke(home_id) -> returns the revoked row (if any)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invites_revoke(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();

  -- 1️⃣ Must be the current owner
  PERFORM public.api_assert(EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = p_home_id
      AND m.role = 'owner'
      AND m.is_current = TRUE
  ), 'FORBIDDEN', 'Only the current owner can revoke an invite.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- 2️⃣ Revoke any active invite(s)
  UPDATE public.invites i
     SET revoked_at = now()
   WHERE i.home_id = p_home_id
     AND i.revoked_at IS NULL
  RETURNING * INTO v_inv;

  -- 3️⃣ If no active invite existed, return a soft info response
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status',  'info',
      'code',    'no_active_invite',
      'message', 'No active invite was found to revoke.'
    );
  END IF;

  -- 4️⃣ Return structured success payload
  RETURN jsonb_build_object(
    'status',      'success',
    'code',        'invite_revoked',
    'message',     'The active invite has been revoked successfully.',
    'invite_id',   v_inv.id,
    'home_id',     v_inv.home_id,
    'revoked_at',  v_inv.revoked_at
  );
END;
$$;

-- ---------------------------------------------------------------------
-- invites.rotate(home_id) -> returns the new active invite
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invites_rotate(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_new  public.invites;
BEGIN
  PERFORM public._assert_authenticated();

  -- ensure caller is the current owner of an active home
  PERFORM public.api_assert(EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.homes h ON h.id = m.home_id
    WHERE m.user_id    = v_user
      AND m.home_id    = p_home_id
      AND m.role       = 'owner'
      AND m.is_current = TRUE
      AND h.is_active  = TRUE
  ), 'FORBIDDEN', 'Only the current owner of an active household can rotate invites.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- revoke existing active invites
  UPDATE public.invites
     SET revoked_at = now()
   WHERE home_id    = p_home_id
     AND revoked_at IS NULL;

  -- create a new invite; unique partial index enforces 1 active per home
  INSERT INTO public.invites (home_id, code)
  VALUES (p_home_id, public._gen_invite_code())
  ON CONFLICT ON CONSTRAINT uq_invites_active_one_per_home DO NOTHING
  RETURNING * INTO v_new;

  -- race-safe fallback if another txn inserted first
  IF v_new.id IS NULL THEN
    SELECT *
      INTO v_new
      FROM public.invites
     WHERE home_id = p_home_id
       AND revoked_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'code','invite_rotated',
    'message','A new invite code has been generated successfully.',
    'invite_id',   v_new.id,
    'invite_code', v_new.code
  );
END;
$$;

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
BEGIN
  PERFORM public._assert_authenticated();

  -- 1️⃣ Look up invite code (case-insensitive)
  SELECT i.home_id
    INTO v_home_id
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::citext
  LIMIT 1;

  -- 2️⃣ Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_CODE', 'Invite code not found. Please check and try again.', '22023',
      jsonb_build_object('code', p_code));
  END IF;

  -- 3️⃣ Check if invite revoked or home inactive
  IF EXISTS (
    SELECT 1 FROM public.invites i
    JOIN public.homes h ON h.id = i.home_id
    WHERE i.code = p_code::citext
      AND (i.revoked_at IS NOT NULL OR h.is_active = FALSE)
  ) THEN
    PERFORM public.api_error('INACTIVE_INVITE', 'This invite or household is no longer active.', 'P0001',
      jsonb_build_object('code', p_code));
  END IF;

  -- 4️⃣ Already current member of this same home
  IF EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = v_home_id
      AND m.is_current = TRUE
  ) THEN
    RETURN jsonb_build_object(
      'status', 'success',
      'code', 'already_member',
      'message', 'You are already part of this household.',
      'home_id', v_home_id
    );
  END IF;

  -- 5️⃣ Already in another active home (only one allowed)
  IF EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.is_current = TRUE
      AND m.home_id <> v_home_id
  ) THEN
    PERFORM public.api_error('ALREADY_IN_OTHER_HOME', 'You are already a member of another household. Leave it first before joining a new one.', '42501');
  END IF;

  -- 6️⃣ Create new membership
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, v_home_id, 'member', now(), NULL);

  -- 7️⃣ Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::citext;

  -- 8️⃣ Success response
  RETURN jsonb_build_object(
    'status', 'success',
    'code', 'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;

-- ---------------------------------------------------------------------
-- homes.transfer_owner(home_id, new_owner_id) -> void
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_transfer_owner(
  p_home_id uuid,
  p_new_owner_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  -- 1️⃣ Validate new owner input
  PERFORM public.api_assert(p_new_owner_id IS NOT NULL AND p_new_owner_id <> v_user,
    'INVALID_NEW_OWNER', 'Please choose a different member to transfer ownership to.', '22023',
    jsonb_build_object('homeId', p_home_id, 'newOwnerId', p_new_owner_id));

  -- 2️⃣ Verify caller is current owner of an active home
  PERFORM public.api_assert(EXISTS (
    SELECT 1 FROM public.memberships m
    JOIN public.homes h ON h.id = m.home_id
    WHERE m.user_id = v_user
      AND m.home_id = p_home_id
      AND m.role = 'owner'
      AND m.is_current = TRUE
      AND h.is_active = TRUE
  ), 'FORBIDDEN', 'Only the current home owner can transfer ownership.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- 3️⃣ Verify new owner is an active member of the same home
  PERFORM public.api_assert(EXISTS (
    SELECT 1 FROM public.memberships m
    JOIN public.homes h ON h.id = m.home_id
    WHERE m.user_id = p_new_owner_id
      AND m.home_id = p_home_id
      AND m.is_current = TRUE
      AND h.is_active = TRUE
  ), 'NEW_OWNER_NOT_MEMBER', 'The selected user must already be a current member of this household.', 'P0001',
     jsonb_build_object('homeId', p_home_id, 'newOwnerId', p_new_owner_id));

  -- 4️⃣ End current owner stint
  UPDATE public.memberships
     SET valid_to = now(), updated_at = now()
   WHERE user_id = v_user
     AND home_id = p_home_id
     AND role = 'owner'
     AND is_current = TRUE;

  -- 5️⃣ End new owner’s current member stint
  UPDATE public.memberships
     SET valid_to = now(), updated_at = now()
   WHERE user_id = p_new_owner_id
     AND home_id = p_home_id
     AND is_current = TRUE;

  -- 6️⃣ Insert new ownership stint
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (p_new_owner_id, p_home_id, 'owner', now(), NULL);

  -- 7️⃣ Return success response
  RETURN jsonb_build_object(
    'status', 'success',
    'code', 'ownership_transferred',
    'message', 'Ownership has been successfully transferred.',
    'home_id', p_home_id,
    'new_owner_id', p_new_owner_id
  );
END;
$$;
-- ---------------------------------------------------------------------
-- homes.leave(home_id) 
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_leave(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''   -- fully-qualify everything
AS $$
DECLARE
  v_user            uuid := auth.uid();
  v_is_owner        boolean;
  v_other_members   integer;
  v_left_rows       integer;
  v_deactivated     boolean := false;
  v_role_before     text;
  v_members_left    integer;
BEGIN
  PERFORM public._assert_authenticated();

  -- Serialize with transfers/joins
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  -- Must be a current member
  PERFORM public.api_assert(EXISTS (
    SELECT 1 FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = p_home_id
       AND m.is_current
  ), 'NOT_MEMBER', 'You are not a current member of this home.', '42501',
     jsonb_build_object('homeId', p_home_id));

  -- Capture role (for response)
  SELECT m.role
    INTO v_role_before
    FROM public.memberships m
   WHERE m.user_id = v_user
     AND m.home_id = p_home_id
     AND m.is_current
   LIMIT 1;

  -- If owner, only leave if last member
  SELECT EXISTS (
    SELECT 1 FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = p_home_id
       AND m.is_current
       AND m.role = 'owner'
  ) INTO v_is_owner;

  IF v_is_owner THEN
    SELECT COUNT(*) INTO v_other_members
      FROM public.memberships m
     WHERE m.home_id = p_home_id
       AND m.is_current
       AND m.user_id <> v_user;

    IF v_other_members > 0 THEN
      PERFORM public.api_error('OWNER_MUST_TRANSFER_FIRST', 'Owner must transfer ownership before leaving.', '42501',
        jsonb_build_object('homeId', p_home_id, 'otherMembers', v_other_members));
    END IF;
  END IF;

  -- End the stint
  UPDATE public.memberships
     SET valid_to  = now(),
         updated_at = now()
   WHERE user_id = v_user
     AND home_id = p_home_id
     AND is_current
  RETURNING 1 INTO v_left_rows;

  IF v_left_rows IS NULL THEN
    PERFORM public.api_error('STATE_CHANGED_RETRY', 'Membership state changed; retry.', '40001');
  END IF;

  -- Check remaining members
  SELECT COUNT(*) INTO v_members_left
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current;

  IF v_members_left = 0 THEN
    UPDATE public.homes
       SET is_active = FALSE,
           deactivated_at = now(),
           updated_at = now()
     WHERE id = p_home_id;
    v_deactivated := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', CASE WHEN v_deactivated THEN 'HOME_DEACTIVATED' ELSE 'LEFT_OK' END,
    'message', CASE
                 WHEN v_deactivated THEN 'Left home; no members remain, home deactivated.'
                 ELSE 'Left home.'
               END,
    'data', jsonb_build_object(
      'homeId', p_home_id,
      'roleBefore', v_role_before,
      'membersRemaining', v_members_left,
      'homeDeactivated', v_deactivated
    )
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Listing helpers (RPC-only views over memberships)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.members_list_active_by_home(
  p_home_id uuid,
  p_exclude_self boolean DEFAULT true
)
RETURNS TABLE (
  user_id         uuid,
  username        citext,
  role            text,
  valid_from      timestamptz,
  avatar_url      text,
  can_transfer_to boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT 
    m.user_id,
    p.username,
    m.role,
    m.valid_from,
    a.storage_path AS avatar_url,
    (m.role <> 'owner') AS can_transfer_to
  FROM public.memberships m
  JOIN public.profiles p ON p.id = m.user_id
  JOIN public.avatars  a ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
    AND (p_exclude_self IS FALSE OR m.user_id <> auth.uid())
  ORDER BY 
    CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END,
    p.username;
$$;


-- ---------------------------------------------------------------------
-- Grants: expose only to authenticated
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Start clean: remove PUBLIC’s implicit execute on all funcs in public
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Explicitly block helpers
REVOKE ALL ON FUNCTION public._current_user_id()         FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._assert_authenticated()    FROM anon, authenticated;
REVOKE ALL ON FUNCTION public._gen_invite_code()         FROM anon, authenticated;

-- Grant only the RPCs your app should call
GRANT EXECUTE ON FUNCTION public.homes_create_with_invite(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.invites_revoke(uuid)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.invites_rotate(uuid)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.homes_join(text)               TO authenticated;
GRANT EXECUTE ON FUNCTION public.homes_transfer_owner(uuid,uuid)TO authenticated;
GRANT EXECUTE ON FUNCTION public.homes_leave(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.members_list_active_by_home(uuid, boolean) TO authenticated;
