CREATE OR REPLACE FUNCTION public._home_usage_increment(
  p_home_id uuid,
  p_active_delta integer DEFAULT 0,
  p_photo_delta integer DEFAULT 0
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.home_usage_counters;
BEGIN
  INSERT INTO public.home_usage_counters (home_id, active_chores, chore_photos)
  VALUES (
    p_home_id,
    GREATEST(0, COALESCE(p_active_delta, 0)),
    GREATEST(0, COALESCE(p_photo_delta, 0))
  )
  ON CONFLICT (home_id) DO UPDATE
    SET active_chores = GREATEST(0, public.home_usage_counters.active_chores + COALESCE(p_active_delta, 0)),
        chore_photos  = GREATEST(0, public.home_usage_counters.chore_photos + COALESCE(p_photo_delta, 0)),
        updated_at    = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_home_owner(
  p_home_id uuid,
  p_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.home_id = p_home_id
      AND m.user_id = COALESCE(p_user_id, auth.uid())
      AND m.is_current = TRUE
      AND m.role = 'owner'
  );
$$;

CREATE OR REPLACE FUNCTION public._home_is_premium(p_home_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (
      SELECT plan = 'premium'
             AND (expires_at IS NULL OR expires_at > now())
      FROM public.home_entitlements
      WHERE home_id = p_home_id
    ),
    FALSE
  );
$$;

CREATE OR REPLACE FUNCTION public._assert_home_member(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_exists boolean;
BEGIN
  -- Require authentication
  PERFORM public._assert_authenticated();

  -- Check whether this user is a member of the home
  SELECT TRUE
  INTO v_exists
  FROM public.memberships hm
  WHERE hm.home_id = p_home_id
    AND hm.user_id = v_user
    AND hm.left_at IS NULL    -- active membership (depends on your schema)
  LIMIT 1;

  IF NOT v_exists THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  RETURN;
END;
$$;

-- =====================================================================
--  Helper: _home_assert_within_free_limits
--  - Enforces free-plan quotas at SAVE time.
--  - For premium homes, it's a no-op.
--  - For free homes, it uses home_usage_counters + deltas.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._home_assert_within_free_limits(
  p_home_id      uuid,
  p_active_delta integer DEFAULT 0,  -- how many active chores you're about to add
  p_photo_delta  integer DEFAULT 0   -- how many chore photos you're about to add
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_premium     boolean;
  v_active_current integer := 0;
  v_photos_current integer := 0;
  v_active_new     integer;
  v_photos_new     integer;

  -- 🔧 Free plan limits (you can change these later)
  v_max_free_active constant integer := 20;
  v_max_free_photos constant integer := 15;
BEGIN
  -- Premium homes skip checks
  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  -- Nothing to add? Then nothing to check.
  IF COALESCE(p_active_delta, 0) <= 0
     AND COALESCE(p_photo_delta, 0) <= 0 THEN
    RETURN;
  END IF;

  -- Load current counters (default to 0 if row doesn't exist yet)
  SELECT
    COALESCE(active_chores, 0),
    COALESCE(chore_photos, 0)
  INTO v_active_current, v_photos_current
  FROM public.home_usage_counters
  WHERE home_id = p_home_id;

  v_active_new := GREATEST(0, v_active_current + COALESCE(p_active_delta, 0));
  v_photos_new := GREATEST(0, v_photos_current + COALESCE(p_photo_delta, 0));

  -- Active chores paywall
  IF v_active_new > v_max_free_active THEN
    PERFORM public.api_error(
      'PAYWALL_LIMIT_ACTIVE_CHORES',
      format('Free plan allows up to %s active chores per home.', v_max_free_active),
      'P0001',
      jsonb_build_object(
        'limit_type', 'active_chores',
        'max', v_max_free_active,
        'current', v_active_current,
        'projected', v_active_new
      )
    );
  END IF;

  -- Chore photos paywall
  IF v_photos_new > v_max_free_photos THEN
    PERFORM public.api_error(
      'PAYWALL_LIMIT_CHORE_PHOTOS',
      format('Free plan allows up to %s chore photos per home.', v_max_free_photos),
      'P0001',
      jsonb_build_object(
        'limit_type', 'chore_photos',
        'max', v_max_free_photos,
        'current', v_photos_current,
        'projected', v_photos_new
      )
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.chores_list_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                          uuid,
  home_id                     uuid,
  assignee_user_id            uuid,
  name                        text,
  start_date                  date,
  assignee_full_name          text,
  assignee_avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.name,
    c.start_date,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id
    AND c.state IN ('draft', 'active')
  ORDER BY c.created_at ASC;
END;
$$;


-- Example: adjust table/column names to your real membership table
-- memberships(home_id uuid, user_id uuid, joined_at, left_at, ...)

CREATE OR REPLACE FUNCTION public.home_assignees_list(
  p_home_id uuid
)
RETURNS TABLE (
  user_id              uuid,
  full_name            text,
  email                text,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 1️⃣ Require auth
  PERFORM public._assert_authenticated();

  -- 2️⃣ Ensure caller actually belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- 3️⃣ Return all *active* members of this home as potential assignees
  RETURN QUERY
  SELECT
    m.user_id,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.left_at IS NULL          -- or your "still in house" condition
  ORDER BY COALESCE(p.full_name, p.email);
END;
$$;

-- =====================================================================
--  RPC: chores_create
--  - Creates a chore for a home
--  - Enforces:
--      * name is required
--      * state = 'draft'  when assignee_user_id IS NULL
--      * state = 'active' when assignee_user_id IS NOT NULL
--  - Updates home_usage_counters:
--      * every new chore (draft or active) counts as 1 slot
--      * photo slot counted if expectation_photo_path is set at creation--  - Paywall:
--      * For free homes, adding an active chore beyond limit is blocked.
--      * Checks free-plan limits, then writes + increments usage counters.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.chores_create(
  p_home_id                uuid,
  p_name                   text,
  p_assignee_user_id       uuid DEFAULT NULL,
  p_start_date             date DEFAULT current_date,
  p_recurrence             public.recurrence_interval DEFAULT 'none',
  p_how_to_video_url       text DEFAULT NULL,
  p_notes                  text DEFAULT NULL,
  p_expectation_photo_path text DEFAULT NULL

)
RETURNS public.chores
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_state        public.chore_state;
  v_usage_delta  integer := 1;  -- 🟢 every new chore counts as +1
  v_photo_delta  integer := 0;  -- will be 1 if we create with a photo
  v_row          public.chores;
BEGIN
  PERFORM public._assert_authenticated();
  -- 2️⃣ Ensure caller actually belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- 1️⃣ Validate required name
  IF coalesce(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Chore name is required.',
      '22023',
      jsonb_build_object('field', 'name')
    );
  END IF;

  -- 2️⃣ Derive state from assignee_user_id
  IF p_assignee_user_id IS NULL THEN
    v_state := 'draft';
  ELSE
    v_state := 'active';
  END IF;

  -- 3️⃣ Compute photo delta: only if we are creating with a photo
  IF p_expectation_photo_path IS NOT NULL THEN
    v_photo_delta := 1;
  END IF;

  -- 4️⃣ Paywall check at SAVE time
  --    Draft and active both consume quota, photo may also consume.
  PERFORM public._home_assert_within_free_limits(
    p_home_id,
    v_usage_delta,  -- +1 chore
    v_photo_delta   -- +1 photo if present
  );

  -- 4️⃣ Insert chore (no expectation_photo_path yet)
  INSERT INTO public.chores (
    home_id,
    created_by_user_id,
    assignee_user_id,
    name,
    start_date,
    recurrence,
    how_to_video_url,
    notes,
    expectation_photo_path,
    state
  )
  VALUES (
    p_home_id,
    v_user_id,
    p_assignee_user_id,
    p_name,
    COALESCE(p_start_date, current_date),
    COALESCE(p_recurrence, 'none'),
    p_how_to_video_url,
    p_notes,
    p_expectation_photo_path, 
    v_state
  )
  RETURNING * INTO v_row;

  -- 5️⃣ Update usage counters
  PERFORM public._home_usage_increment(
    p_home_id,
    v_usage_delta,  -- +1 chore (draft or active)
    v_photo_delta
  );

  RETURN v_row;
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
  v_chore      jsonb;
  v_assignees  jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  -- 1️⃣ Chore + current assignee (if any)
  SELECT jsonb_build_object(
           'id',                      c.id,
           'home_id',                 c.home_id,
           'created_by_user_id',      c.created_by_user_id,
           'assignee_user_id',        c.assignee_user_id,
           'name',                    c.name,
           'start_date',              c.start_date,
           'recurrence',              c.recurrence,
           'expectation_photo_path',  c.expectation_photo_path,
           'how_to_video_url',        c.how_to_video_url,
           'notes',                   c.notes,
           'assignee', CASE
             WHEN c.assignee_user_id IS NULL THEN NULL
             ELSE jsonb_build_object(
               'id',                   pa.id,
               'full_name',            pa.full_name,
               'avatar_storage_path',  a.storage_path
             )
           END
         )
  INTO v_chore
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id      -- ✅ safe when NULL
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id
    AND c.id      = p_chore_id;

  IF v_chore IS NULL THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found for this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'chore_id', p_chore_id)
    );
  END IF;

  -- 2️⃣ All potential assignees in this home (these *should* have avatars)
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
  WHERE m.home_id = p_home_id
    AND m.left_at IS NULL;                  -- or your "active" condition

  RETURN jsonb_build_object(
    'chore',     v_chore,
    'assignees', v_assignees
  );
END;
$$;

-- =====================================================================
--  RPC: chores_update
--  - Updates an existing chore
--  - Enforces:
--      * p_name MUST NOT be NULL
--      * p_assignee_user_id MUST NOT be NULL
--      * p_start_date MUST NOT be NULL

--      * state is always set to 'active'
--      * all other fields are kept (only changed if a non-NULL value given)
--  - DOES NOT modify home_usage_counters (no _home_usage_increment)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.chores_update(
  p_chore_id               uuid,
  p_name                   text,
  p_assignee_user_id       uuid,  -- required: must not be NULL
  p_start_date             date,
  p_recurrence             public.recurrence_interval DEFAULT NULL,
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

  -- 1️⃣ Enforce that assignee is provided
  IF p_assignee_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Assignee is required when updating a chore.',
      '22023',
      jsonb_build_object('field', 'assignee_user_id')
    );
  END IF;

  -- 2️⃣ Validate name
  IF coalesce(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Chore name is required.',
      '22023',
      jsonb_build_object('field', 'name')
    );
  END IF;

  -- 3️⃣ Load existing chore (and lock it to avoid concurrent edits)
  SELECT *
  INTO v_existing
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found.',
      '22023',
      jsonb_build_object('chore_id', p_chore_id)
    );
  END IF;

  -- 3️⃣.b Ensure caller is an active member of this home
  PERFORM public._assert_home_member(v_existing.home_id);

  -- 3️⃣.c Enforce "only creator or assignee can edit"
  -- Assumes chores has created_by_user_id and assignee_user_id columns.
  IF v_existing.created_by_user_id IS DISTINCT FROM v_user_id
     AND (
       v_existing.assignee_user_id IS NULL
       OR v_existing.assignee_user_id IS DISTINCT FROM v_user_id
     )
  THEN
    PERFORM public.api_error(
      'FORBIDDEN',
      'Only the chore creator or current assignee can update this chore.',
      '42501',
      jsonb_build_object(
        'chore_id', p_chore_id,
        'home_id',  v_existing.home_id
      )
    );
  END IF;

  -- 4️⃣ Work out what the *new* path will be after COALESCE
  v_new_path := COALESCE(p_expectation_photo_path, v_existing.expectation_photo_path);

  -- 5️⃣ Compute photo delta (per-chore slot semantics)
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;   -- adding first photo to this chore
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;  -- removing the only photo from this chore
  ELSE
    v_photo_delta := 0;   -- no slot change (either none→none or replace photo)
  END IF;

  -- 6️⃣ Paywall check if we're *adding* a photo slot
  IF v_photo_delta > 0 THEN
    PERFORM public._home_assert_within_free_limits(
      v_existing.home_id,
      0,              -- chore count unchanged
      v_photo_delta   -- +1 photo slot if we are adding
    );
  END IF;

  -- 7️⃣ Update chore
  UPDATE public.chores
  SET
    name                   = p_name,
    assignee_user_id       = p_assignee_user_id,
    start_date             = p_start_date,
    recurrence             = COALESCE(p_recurrence, v_existing.recurrence),
    expectation_photo_path = v_new_path,
    how_to_video_url       = COALESCE(p_how_to_video_url, v_existing.how_to_video_url),
    notes                  = COALESCE(p_notes, v_existing.notes),

    -- 🔒 On update, chore is always active
    state                  = 'active',

    updated_at             = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_new;

  -- 8️⃣ Update usage counters if the slot changed
  IF v_photo_delta <> 0 THEN
    PERFORM public._home_usage_increment(
      v_new.home_id,
      0,              -- chore count unchanged
      v_photo_delta   -- +1 or -1 photo slot
    );
  END IF;

  RETURN v_new;
END;
$$;

-- ---------------------------------------------------------------------
-- RPC: chores.cancel
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chores_cancel(p_chore_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_chore public.chores;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_chore
    FROM public.chores
   WHERE id = p_chore_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', 'P0002', jsonb_build_object('choreId', p_chore_id));
  END IF;

  PERFORM public._assert_home_member(v_chore.home_id);

PERFORM public.api_assert(
  v_chore.created_by_user_id = v_user
  OR v_chore.assignee_user_id = v_user,
  'FORBIDDEN',
  'Only the chore creator or current assignee can cancel.',
  '42501',
  jsonb_build_object('choreId', p_chore_id)
);

  PERFORM public.api_assert(v_chore.state IN ('draft', 'active'),
    'ALREADY_FINALIZED', 'Only draft/active chores can be cancelled.', '22023');

  UPDATE public.chores
     SET state = 'cancelled',
        next_occurrence   = NULL,
        recurrence        = 'none',      -- or NULL, depending on your enum rules
        recurrence_cursor = NULL,
        updated_at        = now()
   WHERE id = p_chore_id
   RETURNING * INTO v_chore;

  PERFORM public._home_usage_increment(v_chore.home_id, -1, 0);

  RETURN jsonb_build_object('chore', to_jsonb(v_chore));
END;
$$;


CREATE OR REPLACE FUNCTION public.chore_complete(_chore_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore          public.chores%ROWTYPE;
  v_new_next_date  date;
  v_new_cursor     timestamptz;
  v_prev_next      date;
  v_steps_advanced integer := 0;
  v_user           uuid := auth.uid();  
BEGIN
  -- Ensure caller is authenticated
  PERFORM public._assert_authenticated();

  -- Lock the chore row so two clients can't complete at once
  SELECT *
  INTO v_chore
  FROM public.chores
  WHERE id = _chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'CHORE_NOT_FOUND',
      'Chore not found or not accessible.',
      '22023',
      jsonb_build_object('chore_id', _chore_id)
    );
  END IF;

  -- Must belong to the same home
  PERFORM public._assert_home_member(v_chore.home_id);

  -- 🔐 Only current assignee can complete
  PERFORM public.api_assert(
    v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the current assignee can complete this chore.',
    '42501',
    jsonb_build_object('chore_id', _chore_id)
  );

  -- Optional: sanity guard on state
  PERFORM public.api_assert(
    v_chore.state = 'active',
    'INVALID_STATE',
    'Only active chores can be completed.',
    '22023',
    jsonb_build_object('chore_id', _chore_id, 'state', v_chore.state)
  );

  v_prev_next := v_chore.next_occurrence;

  -------------------------------------------------------------------
  -- Case 1: non-recurring chore → mark completed once and for all
  -------------------------------------------------------------------
  IF v_chore.recurrence = 'none' THEN
    -- At this point we already asserted state = 'active', so this is
    -- the first (and only) valid completion for this chore.

    UPDATE public.chores
    SET
      state           = 'completed',
      completed_at    = COALESCE(v_chore.completed_at, now()),
      next_occurrence = NULL,          -- 🔴 contract: clear nextOccurrence
      updated_at      = now()
    WHERE id = _chore_id;

    -- 🔴 contract: decrement active counter
    PERFORM public._home_usage_increment(v_chore.home_id, -1, 0);

    RETURN jsonb_build_object(
      'status',   'non_recurring_completed',
      'chore_id', _chore_id,
      'home_id',  v_chore.home_id,
      'state',    'completed'
    );
  END IF;

  -------------------------------------------------------------------
  -- Case 2: recurring chore → advance to first date AFTER today
  --
  -- We keep state as-is (e.g. 'active') but move the schedule forward.
  -- chores_events_trigger will see next_occurrence jump and log
  -- a 'complete' event for the old occurrence.
  -------------------------------------------------------------------
  v_new_next_date := COALESCE(v_chore.next_occurrence, v_chore.start_date);
  v_new_cursor    := COALESCE(v_chore.recurrence_cursor, v_new_next_date::timestamptz);

  -- Advance until we find the first date strictly after today
  WHILE v_new_next_date <= current_date LOOP
    CASE v_chore.recurrence
      WHEN 'daily'          THEN v_new_next_date := v_new_next_date + INTERVAL '1 day';
      WHEN 'weekly'         THEN v_new_next_date := v_new_next_date + INTERVAL '7 days';
      WHEN 'every_2_weeks'  THEN v_new_next_date := v_new_next_date + INTERVAL '14 days';
      WHEN 'monthly'        THEN v_new_next_date := (v_new_next_date + INTERVAL '1 month')::date;
      WHEN 'every_2_months' THEN v_new_next_date := (v_new_next_date + INTERVAL '2 months')::date;
      WHEN 'annual'         THEN v_new_next_date := (v_new_next_date + INTERVAL '1 year')::date;
      ELSE
        -- Unknown recurrence; bail out safely
        EXIT;
    END CASE;

    v_new_cursor     := v_new_next_date::timestamptz;
    v_steps_advanced := v_steps_advanced + 1;
  END LOOP;

  -- If nothing moved forward, it means next_occurrence was already in the future
  -- → treat as idempotent "already completed for current cycle".
  IF v_steps_advanced = 0 THEN
    RETURN jsonb_build_object(
      'status',                  'already_completed_for_cycle',
      'chore_id',                _chore_id,
      'home_id',                 v_chore.home_id,
      'state',                   v_chore.state
    );
  END IF;

  UPDATE public.chores
  SET
    recurrence_cursor = v_new_cursor,
    next_occurrence   = v_new_next_date,
    completed_at      = now(),
    updated_at        = now()
  WHERE id = _chore_id;

  -- chores_events_trigger will detect next_occurrence moving forward
  -- for a recurring chore and log a 'complete' event for the previous date.

  RETURN jsonb_build_object(
    'status',                  'recurring completed',
    'chore_id',                _chore_id,
    'home_id',                 v_chore.home_id,
    'recurrence',              v_chore.recurrence,
    'state',                   v_chore.state,
    'previous_next_occurrence', v_prev_next,
    'new_next_occurrence',     v_new_next_date,
    'steps_advanced',          v_steps_advanced
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.chores_reassign_on_member_leave(
  v_home_id uuid,
  v_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_owner_user_id uuid;
BEGIN
  -- Find current owner of the home
  SELECT m.user_id
    INTO v_owner_user_id
  FROM public.memberships m
  WHERE m.home_id = v_home_id
    AND m.role = 'owner'
    AND m.is_current = TRUE
  LIMIT 1;

  -- If no owner (e.g., home deactivated), do nothing
  IF v_owner_user_id IS NULL THEN
    RETURN;
  END IF;

  -- Reassign active chores from leaving member to owner
  UPDATE public.chores c
     SET assignee_user_id = v_owner_user_id,
         updated_at       = now()
   WHERE c.home_id = v_home_id
     AND c.assignee_user_id = v_user_id
     AND c.state IN ('draft', 'active');

END;
$$;

CREATE OR REPLACE FUNCTION public.chores_events_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor       uuid := auth.uid();
  v_event_type  public.chore_event_type;
  v_from_state  public.chore_state;
  v_to_state    public.chore_state;
  v_payload     jsonb := '{}'::jsonb;
BEGIN
  -- Require auth (or relax this if you have backend jobs without auth)
  PERFORM public._assert_authenticated();

  IF TG_OP = 'INSERT' THEN
    -- New chore created
    v_event_type := 'create';
    v_to_state   := NEW.state;

    v_payload := jsonb_build_object(
      'name',              NEW.name,
      'recurrence',        NEW.recurrence,
      'next_occurrence',   NEW.next_occurrence,
      'assignee_user_id',  NEW.assignee_user_id
    );

    INSERT INTO public.chore_events (
      chore_id,
      home_id,
      actor_user_id,
      event_type,
      from_state,
      to_state,
      payload
    )
    VALUES (
      NEW.id,
      NEW.home_id,
      v_actor,
      v_event_type,
      NULL,
      v_to_state,
      v_payload
    );

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Short-circuit if nothing interesting changed
    IF OLD.assignee_user_id      IS NOT DISTINCT FROM NEW.assignee_user_id
       AND OLD.recurrence        IS NOT DISTINCT FROM NEW.recurrence
       AND OLD.recurrence_cursor IS NOT DISTINCT FROM NEW.recurrence_cursor
       AND OLD.next_occurrence   IS NOT DISTINCT FROM NEW.next_occurrence
       AND OLD.state             IS NOT DISTINCT FROM NEW.state THEN
      RETURN NEW;
    END IF;

    v_from_state := OLD.state;
    v_to_state   := NEW.state;

    ----------------------------------------------------------------
    -- Priority:
    -- 1) Recurring completion inferred from next_occurrence moving
    -- 2) Non-recurring completion via state change
    -- 3) Cancel (draft/active -> cancelled)
    -- 4) Activate (draft -> active)
    -- 5) Assignee change (update with assignee payload)
    -- 6) Recurrence config change (update)
    -- 7) Generic state change update
    ----------------------------------------------------------------

    -- 1️⃣ Recurring completion inferred from next_occurrence advancing
    IF NEW.recurrence <> 'none'
       AND OLD.next_occurrence IS NOT NULL
       AND NEW.next_occurrence IS NOT NULL
       AND NEW.next_occurrence > OLD.next_occurrence THEN

      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'recurrence',             NEW.recurrence,
        'completed_date',         OLD.next_occurrence,
        'next_occurrence_before', OLD.next_occurrence,
        'next_occurrence_after',  NEW.next_occurrence,
        'cursor_before',          OLD.recurrence_cursor,
        'cursor_after',           NEW.recurrence_cursor
      );

    -- 2️⃣ Non-recurring completion: state -> completed, recurrence = none
    ELSIF OLD.state <> 'completed'
          AND NEW.state = 'completed'
          AND NEW.recurrence = 'none' THEN

      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'completed_state_from', OLD.state,
        'completed_state_to',   NEW.state
      );

    -- 3️⃣ Cancel: draft/active -> cancelled
    ELSIF OLD.state IN ('draft', 'active')
          AND NEW.state = 'cancelled' THEN

      v_event_type := 'cancel';
      v_payload := jsonb_build_object(
        'state_from',             OLD.state,
        'state_to',               NEW.state,
        'reason',                 'cancelled',
        -- capture schedule so RPC is free to clear it
        'recurrence_before',      OLD.recurrence,
        'next_occurrence_before', OLD.next_occurrence,
        'cursor_before',          OLD.recurrence_cursor,
        'assignee_user_id',       OLD.assignee_user_id
      );

    -- 4️⃣ Activate: draft -> active
    ELSIF OLD.state = 'draft'
          AND NEW.state = 'active' THEN

      v_event_type := 'activate';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    -- 5️⃣ Assignee changes (still event_type = 'update')
    ELSIF OLD.assignee_user_id IS DISTINCT FROM NEW.assignee_user_id THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'change_type', 'assignee',
        'assignee_event',
          CASE
            WHEN OLD.assignee_user_id IS NULL AND NEW.assignee_user_id IS NOT NULL THEN 'assign'
            WHEN OLD.assignee_user_id IS NOT NULL AND NEW.assignee_user_id IS NULL THEN 'unassign'
            ELSE 'reassign'
          END,
        'assignee_from', OLD.assignee_user_id,
        'assignee_to',   NEW.assignee_user_id
      );

    -- 6️⃣ Recurrence config changed (e.g. weekly → every_2_weeks)
    ELSIF OLD.recurrence IS DISTINCT FROM NEW.recurrence THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'recurrence_from', OLD.recurrence,
        'recurrence_to',   NEW.recurrence
      );

    -- 7️⃣ Fallback: some other meaningful state change
    ELSIF OLD.state IS DISTINCT FROM NEW.state THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    ELSE
      -- If we got here, something changed we don't currently care to log
      RETURN NEW;
    END IF;

    INSERT INTO public.chore_events (
      chore_id,
      home_id,
      actor_user_id,
      event_type,
      from_state,
      to_state,
      payload
    )
    VALUES (
      NEW.id,
      NEW.home_id,
      v_actor,
      v_event_type,
      v_from_state,
      v_to_state,
      v_payload
    );

    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    -- Physical delete: treat as cancel with reason=deleted
    v_event_type := 'cancel';
    v_from_state := OLD.state;

    v_payload := jsonb_build_object(
      'reason', 'deleted',
      'state',  OLD.state
    );

    INSERT INTO public.chore_events (
      chore_id,
      home_id,
      actor_user_id,
      event_type,
      from_state,
      to_state,
      payload
    )
    VALUES (
      OLD.id,
      OLD.home_id,
      v_actor,
      v_event_type,
      v_from_state,
      NULL,
      v_payload
    );

    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;


DROP TRIGGER IF EXISTS chores_events_trigger ON public.chores;

CREATE TRIGGER chores_events_trigger
AFTER INSERT OR UPDATE OR DELETE
ON public.chores
FOR EACH ROW
EXECUTE FUNCTION public.chores_events_trigger();

-- INTERNAL HELPERS: revoke from everyone except owner
REVOKE ALL ON FUNCTION public._home_usage_increment(uuid, integer, integer)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.is_home_owner(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._home_is_premium(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._assert_home_member(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public._home_assert_within_free_limits(uuid, integer, integer)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_reassign_on_member_leave(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_events_trigger()
  FROM PUBLIC, anon, authenticated;

-- RPC FUNCTIONS: also start by revoking
REVOKE ALL ON FUNCTION public.chores_list_for_home(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.home_assignees_list(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_create(
  uuid, text, uuid, date, public.recurrence_interval, text, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_get_for_home(uuid, uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_update(
  uuid, text, uuid, date, public.recurrence_interval, text, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_cancel(uuid)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chore_complete(uuid)
  FROM PUBLIC, anon, authenticated;

-- RPCs callable by logged-in app users
GRANT EXECUTE ON FUNCTION public.chores_list_for_home(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.home_assignees_list(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.chores_create(
  uuid, text, uuid, date, public.recurrence_interval, text, text, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.chores_get_for_home(uuid, uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.chores_update(
  uuid, text, uuid, date, public.recurrence_interval, text, text, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.chores_cancel(uuid)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.chore_complete(uuid)
  TO authenticated;