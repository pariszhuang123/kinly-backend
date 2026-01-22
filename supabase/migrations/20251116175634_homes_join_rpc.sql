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
  WHERE i.code = p_code::public.citext   -- 👈 qualified
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
    WHERE i.code = p_code::public.citext   -- 👈 qualified
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
     AND code = p_code::public.citext;    -- 👈 qualified

  -- 8️⃣ Attach Subscription to home
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

