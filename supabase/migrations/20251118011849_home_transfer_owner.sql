-- ---------------------------------------------------------------------
-- homes.transfer_owner(home_id, new_owner_id) -> jsonb
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.homes_transfer_owner(
  p_home_id     uuid,
  p_new_owner_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user              uuid := auth.uid();
  v_owner_row_ended   integer;
  v_new_owner_ended   integer;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- 1️⃣ Validate new owner input
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    p_new_owner_id IS NOT NULL AND p_new_owner_id <> v_user,
    'INVALID_NEW_OWNER',
    'Please choose a different member to transfer ownership to.',
    '22023',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 2️⃣ Verify caller is current owner of an active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id   = v_user
        AND m.home_id   = p_home_id
        AND m.role      = 'owner'
        AND m.is_current = TRUE
        AND h.is_active = TRUE
    ),
    'FORBIDDEN',
    'Only the current home owner can transfer ownership.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 3️⃣ Verify new owner is an active member of the same home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id    = p_new_owner_id
        AND m.home_id    = p_home_id
        AND m.is_current = TRUE
        AND h.is_active  = TRUE
    ),
    'NEW_OWNER_NOT_MEMBER',
    'The selected user must already be a current member of this household.',
    'P0001',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 4️⃣ (Optional but recommended) serialize with leave/join
  --------------------------------------------------------------------
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  --------------------------------------------------------------------
  -- 5️⃣ End current owner stint (role = owner)
  --     We *do* close the owner stint for history...
  --------------------------------------------------------------------
  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE m.user_id   = v_user
     AND m.home_id   = p_home_id
     AND m.role      = 'owner'
     AND m.is_current = TRUE
  RETURNING 1 INTO v_owner_row_ended;

  PERFORM public.api_assert(
    v_owner_row_ended = 1,
    'STATE_CHANGED_RETRY',
    'Ownership state changed during transfer; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', v_user)
  );

  --------------------------------------------------------------------
  -- 6️⃣ Insert new MEMBER stint for the old owner
  --     👉 This is the bit you were missing.
  --------------------------------------------------------------------
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, p_home_id, 'member', now(), NULL);

  --------------------------------------------------------------------
  -- 7️⃣ End new owner’s current MEMBER stint
  --------------------------------------------------------------------
  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE m.user_id    = p_new_owner_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
  RETURNING 1 INTO v_new_owner_ended;

  PERFORM public.api_assert(
    v_new_owner_ended = 1,
    'STATE_CHANGED_RETRY',
    'New owner membership state changed during transfer; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'new_owner_id', p_new_owner_id)
  );

  --------------------------------------------------------------------
  -- 8️⃣ Insert new OWNER stint for the new owner
  --------------------------------------------------------------------
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (p_new_owner_id, p_home_id, 'owner', now(), NULL);

  --------------------------------------------------------------------
  -- 9️⃣ Return success response
  --------------------------------------------------------------------
  RETURN jsonb_build_object(
    'status',       'success',
    'code',         'ownership_transferred',
    'message',      'Ownership has been successfully transferred.',
    'home_id',      p_home_id,
    'new_owner_id', p_new_owner_id
  );
END;
$$;

