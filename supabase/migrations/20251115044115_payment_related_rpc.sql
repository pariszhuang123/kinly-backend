ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_subscriptions FROM anon, authenticated;

ALTER TABLE public.home_entitlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.home_entitlements FROM anon, authenticated;

ALTER TABLE public.home_usage_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.home_usage_counters FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- Helpers for attaching subscriptions to homes
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._home_attach_subscription_to_home(
  _user_id uuid,
  _home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Attach the user's live subscription (if any) that is currently unattached
  UPDATE public.user_subscriptions
  SET home_id    = _home_id,
      updated_at = now()
  WHERE user_id = _user_id
    AND home_id IS NULL
    AND status IN ('active', 'cancelled');

  -- We rely on the trigger to call home_entitlements_refresh(_home_id)
END;
$$;

-- Detach subs for this user from this home (make them float again)
CREATE OR REPLACE FUNCTION public._home_detach_subscription_to_home(
  _home_id uuid,
  _user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.user_subscriptions
  SET home_id    = NULL,
      updated_at = now()
  WHERE user_id = _user_id
    AND home_id = _home_id
    AND status IN ('active', 'cancelled');

  -- trigger on user_subscriptions will call home_entitlements_refresh(v_home_id)
END;
$$;


-- ---------------------------------------------------------------------
-- Trigger function: keep home_entitlements in sync with user_subscriptions
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.user_subscriptions_home_entitlements_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- INSERT: new subscription row created
  IF TG_OP = 'INSERT' THEN
    IF NEW.home_id IS NOT NULL THEN
      PERFORM public.home_entitlements_refresh(NEW.home_id);
    END IF;

  -- UPDATE: subscription row changed
  ELSIF TG_OP = 'UPDATE' THEN
    -- Case 1: home_id changed (e.g. detach from one home, attach to another)
    IF NEW.home_id IS DISTINCT FROM OLD.home_id THEN
      -- Old home may have lost funding
      IF OLD.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(OLD.home_id);
      END IF;

      -- New home may have gained funding
      IF NEW.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(NEW.home_id);
      END IF;

    -- Case 2: same home_id, but status/expiry changed
    ELSIF NEW.status IS DISTINCT FROM OLD.status
       OR NEW.current_period_end_at IS DISTINCT FROM OLD.current_period_end_at THEN
      IF NEW.home_id IS NOT NULL THEN
        PERFORM public.home_entitlements_refresh(NEW.home_id);
      END IF;
    END IF;

  -- DELETE: subscription row removed
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.home_id IS NOT NULL THEN
      PERFORM public.home_entitlements_refresh(OLD.home_id);
    END IF;
  END IF;

  -- AFTER trigger: we don't modify the row itself
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- Attach trigger to user_subscriptions
-- ---------------------------------------------------------------------

-- Be idempotent in migrations
DROP TRIGGER IF EXISTS user_subscriptions_home_entitlements_trg
  ON public.user_subscriptions;

CREATE TRIGGER user_subscriptions_home_entitlements_trg
AFTER INSERT OR UPDATE OR DELETE
ON public.user_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.user_subscriptions_home_entitlements_trigger();

-- ---------------------------------------------------------------------
-- Helpers for home entitlements management
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_entitlements_refresh(_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- Whether the home has ANY valid subscription right now
  v_has_valid  boolean;

  -- The maximum expiry across all subscriptions for this home
  v_latest_exp timestamptz;
BEGIN
  -------------------------------------------------------------------------
  -- 1. Aggregate subscription status for this home
  --
  -- We compute:
  --   - v_has_valid: does ANY subscription satisfy "currently premium?"
  --   - v_latest_exp: the furthest current_period_end_at we have on record
  --
  -- NOTE: This uses SELECT ... INTO (PL/pgSQL syntax).
  -------------------------------------------------------------------------
  SELECT
    EXISTS (
      SELECT 1
      FROM public.user_subscriptions us
      WHERE us.home_id = _home_id
        -- Subs we still treat as "funding" the home
        AND us.status IN ('active', 'cancelled')
        -- Valid if end date is in the future OR not provided yet
        AND (us.current_period_end_at IS NULL OR us.current_period_end_at > now())
    ) AS has_valid_subscription,

    -- Latest expiry (can be NULL if no expiry exists)
    MAX(us.current_period_end_at) AS latest_expiry

  INTO v_has_valid, v_latest_exp
  FROM public.user_subscriptions us
  WHERE us.home_id = _home_id;


  -------------------------------------------------------------------------
  -- 2. Upsert into home_entitlements (the source of truth for "is this
  --    home premium or free?")
  --
  -- We insert the newly computed "plan" and "expires_at" values.
  -- If the home already has a row, ON CONFLICT triggers an UPDATE.
  --
  -- IMPORTANT:
  --   - We MUST use EXCLUDED.plan instead of referencing PL/pgSQL vars
  --     inside the UPDATE clause.
  --
  -- WHY?
  --   - PL/pgSQL variables (v_has_valid, v_latest_exp) are NOT visible
  --     inside the SQL UPDATE engine.
  --   - Postgres exposes the pseudo-table EXCLUDED to represent the
  --     values we *attempted* to insert.
  --   - EXCLUDED is the ONLY legal way to access those values inside
  --     ON CONFLICT DO UPDATE.
  -------------------------------------------------------------------------
  INSERT INTO public.home_entitlements AS he (home_id, plan, expires_at)
  VALUES (
    _home_id,

    -- If any valid sub exists → premium, else free
    CASE WHEN v_has_valid THEN 'premium' ELSE 'free' END,

    -- Expiry is only meaningful if premium
    CASE WHEN v_has_valid THEN v_latest_exp ELSE NULL END
  )

  ON CONFLICT (home_id) DO UPDATE
  SET
    -- EXCLUDED.plan = the plan we *intended* to insert
    plan       = EXCLUDED.plan,

    -- EXCLUDED.expires_at = the expiry we *intended* to insert
    expires_at = EXCLUDED.expires_at,

    -- Always update updated_at timestamp
    updated_at = now();

END;
$$;


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

  -- Create home
  INSERT INTO public.homes (name, owner_user_id)
  VALUES (p_name, v_user)
  RETURNING * INTO v_home;

  -- Create owner membership
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  INSERT INTO public.home_entitlements (home_id, plan, expires_at)
  VALUES (v_home.id, 'free', NULL);

  -- Create first invite...
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

  -- 🔹 Attach any existing subscription from this user to this new home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home.id);

  -- Return
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
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- 3️⃣ Check if invite revoked or home inactive
  IF EXISTS (
    SELECT 1
    FROM public.invites i
    JOIN public.homes h ON h.id = i.home_id
    WHERE i.code = p_code::citext
      AND (i.revoked_at IS NOT NULL OR h.is_active = FALSE)
  ) THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- 4️⃣ Already current member of this same home
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

  -- 5️⃣ Already in another active home (only one allowed)
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

  -- 6️⃣ Create new membership
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, v_home_id, 'member', now(), NULL);

  -- 7️⃣ Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::citext;

  -- 8 Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);

  -- 🔟 Success response
  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
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
        jsonb_build_object('homeId', v_home_id, 'otherMembers', v_other_members));
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

  -- 8️⃣ Detach any existing live subscription from the home (if user has one unattached)
  PERFORM public._home_detach_subscription_to_home(p_home_id, v_user);

  -- 🔹 Reassign chores to owner if home still has members (and thus an owner)
  IF NOT v_deactivated THEN
    PERFORM public.chores_reassign_on_member_leave(p_home_id, v_user);
  END IF;


  RETURN jsonb_build_object(
    'ok', true,
    'code', CASE WHEN v_deactivated THEN 'HOME_DEACTIVATED' ELSE 'LEFT_OK' END,
    'message', CASE
                 WHEN v_deactivated THEN 'Left home; no members remain, home deactivated.'
                 ELSE 'Left home.'
               END,
    'data', jsonb_build_object(
      'homeId', v_home_id,
      'roleBefore', v_role_before,
      'membersRemaining', v_members_left,
      'homeDeactivated', v_deactivated
    )
  );
END;
$$;

-- Internal helpers
REVOKE ALL ON FUNCTION public._home_attach_subscription_to_home(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._home_detach_subscription_to_home(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.user_subscriptions_home_entitlements_trigger()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.home_entitlements_refresh(uuid)
  FROM PUBLIC, anon, authenticated;

-- RPCs (reset first)
REVOKE ALL ON FUNCTION public.homes_create_with_invite(text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.homes_join(text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.homes_leave(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.homes_create_with_invite(text)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.homes_join(text)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.homes_leave(uuid)
  TO authenticated;

