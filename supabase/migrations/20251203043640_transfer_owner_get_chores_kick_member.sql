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
  -- 9️⃣ Update homes.owner_user_id
  --------------------------------------------------------------------
  UPDATE public.homes h
     SET owner_user_id = p_new_owner_id,
         updated_at    = now()
   WHERE h.id           = p_home_id;

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

-- chores_update: timestamptz inputs; optionally reset cursor
CREATE OR REPLACE FUNCTION public.chores_update(
  p_chore_id               uuid,
  p_name                   text,
  p_assignee_user_id       uuid,
  p_start_date             timestamptz,
  p_recurrence             public.recurrence_interval DEFAULT 'none',
  p_expectation_photo_path text DEFAULT NULL,
  p_how_to_video_url       text DEFAULT NULL,
  p_notes                  text DEFAULT NULL
)
RETURNS public.chores
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_existing     public.chores;
  v_new          public.chores;
  v_new_path     text;
  v_photo_delta  integer := 0;
BEGIN
  PERFORM public._assert_authenticated();

  PERFORM public.api_assert(
    p_assignee_user_id IS NOT NULL,
    'INVALID_INPUT',
    'Assignee is required when updating a chore.',
    '22023',
    jsonb_build_object('field', 'assignee_user_id')
  );
  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  SELECT * INTO v_existing
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', '22023', jsonb_build_object('chore_id', p_chore_id));
  END IF;

PERFORM public._assert_home_member(v_existing.home_id);

PERFORM public.api_assert(
  v_existing.created_by_user_id = v_user_id
  OR v_existing.assignee_user_id = v_user_id,
  'FORBIDDEN',
  'Only the chore creator or current assignee can update this chore.',
  '42501',
  jsonb_build_object('chore_id', p_chore_id, 'home_id', v_existing.home_id)
);

-- Assignee must be a current member of this home
PERFORM public.api_assert(
  EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.home_id = v_existing.home_id
      AND m.user_id = p_assignee_user_id
      AND m.is_current
  ),
  'ASSIGNEE_NOT_CURRENT_MEMBER',
  'Assignee must be a current member of this home.',
  '42501',
  jsonb_build_object(
    'home_id',  v_existing.home_id,
    'assignee', p_assignee_user_id
  )
);
  -- Work out what the *new* path will be after COALESCE

  v_new_path := COALESCE(p_expectation_photo_path, v_existing.expectation_photo_path);
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;
  ELSE
    v_photo_delta := 0;   -- no slot change
  END IF;

  -- Paywall check if we're *adding* a photo slot
  IF v_photo_delta > 0 THEN
    PERFORM public._home_assert_quota(
      v_existing.home_id,
      jsonb_build_object(
        'chore_photos', v_photo_delta
      )
    );
  END IF;

  UPDATE public.chores
  SET
    name                   = p_name,
    assignee_user_id       = p_assignee_user_id,
    start_date             = p_start_date,
    recurrence             = COALESCE(p_recurrence, v_existing.recurrence),
    expectation_photo_path = v_new_path,
    how_to_video_url       = COALESCE(p_how_to_video_url, v_existing.how_to_video_url),
    notes                  = COALESCE(p_notes, v_existing.notes),
    state                  = 'active',
    updated_at             = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_new;

  -- Update usage counters if the slot changed
  IF v_photo_delta <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_new.home_id,
      jsonb_build_object('chore_photos', v_photo_delta)
    );
  END IF;

  RETURN v_new;
END;
$$;


CREATE OR REPLACE FUNCTION public.chores_get_for_home(
  p_home_id  uuid,
  p_chore_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore     jsonb;
  v_assignees jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  -- _chores_base_for_home already checks membership + home_active

  -- 1️⃣ Chore + current assignee (if any), using helper for current_due_at
  SELECT jsonb_build_object(
           'id',                    base.id,
           'home_id',               base.home_id,
           'created_by_user_id',    base.created_by_user_id,
           'assignee_user_id',      base.assignee_user_id,
           'name',                  base.name,

           -- 🔎 This is where we send the computed “start date”
           -- Option A: keep key name `start_date` but change semantics:
           'start_date',            base.current_due_at,

           -- Option B (cleaner, if you can update the client): 
           -- 'current_due_at',       base.current_due_at,

           'recurrence',            c.recurrence,
           'recurrence_cursor',     c.recurrence_cursor,
           'expectation_photo_path',c.expectation_photo_path,
           'how_to_video_url',      c.how_to_video_url,
           'notes',                 c.notes,
           'state',                 base.state,
           'completed_at',          c.completed_at,
           'created_at',            base.created_at,
           'updated_at',            c.updated_at,
           'assignee',
             CASE
               WHEN base.assignee_user_id IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'id',                 base.assignee_user_id,
                 'full_name',          base.assignee_full_name,
                 'avatar_storage_path',base.assignee_avatar_storage_path
               )
             END
         )
    INTO v_chore
    FROM public._chores_base_for_home(p_home_id) AS base
    JOIN public.chores c
      ON c.id = base.id
   WHERE base.id = p_chore_id;

  IF v_chore IS NULL THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found for this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'chore_id', p_chore_id)
    );
  END IF;

  -- 2️⃣ All potential assignees in this home (unchanged)
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'user_id',             m.user_id,
               'full_name',           p.full_name,
               'avatar_storage_path', a.storage_path
             )
             ORDER BY p.full_name
           ),
           '[]'::jsonb
         )
    INTO v_assignees
    FROM public.memberships m
    JOIN public.profiles p
      ON p.id = m.user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id
   WHERE m.home_id   = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'chore',     v_chore,
    'assignees', v_assignees
  );
END;
$$;


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
     SET m.valid_to   = now(),
         m.is_current = FALSE,
         m.updated_at = now()
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

