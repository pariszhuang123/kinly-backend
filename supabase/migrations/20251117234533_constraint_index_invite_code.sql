-- Ensure the partial unique index exists
CREATE UNIQUE INDEX IF NOT EXISTS uq_invites_active_one_per_home
  ON public.invites (home_id)
  WHERE revoked_at IS NULL;


----------------------------------------------------------------------
-- HOMES: create_with_invite()
----------------------------------------------------------------------

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

  -- create a new invite; partial unique index enforces 1 active per home
  INSERT INTO public.invites (home_id, code)
  VALUES (p_home_id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
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
