-- Chores recurrence v2: add recurrence_every/unit, backfill, constraints, and v2 RPCs.

-- Schema: new recurrence columns
ALTER TABLE public.chores
  ADD COLUMN IF NOT EXISTS recurrence_every integer,
  ADD COLUMN IF NOT EXISTS recurrence_unit text;

ALTER TABLE public.chores DISABLE TRIGGER chores_events_trigger;
-- Backfill from legacy recurrence interval
UPDATE public.chores
   SET recurrence_every = CASE recurrence
                             WHEN 'daily' THEN 1
                             WHEN 'weekly' THEN 1
                             WHEN 'every_2_weeks' THEN 2
                             WHEN 'monthly' THEN 1
                             WHEN 'every_2_months' THEN 2
                             WHEN 'annual' THEN 1
                             ELSE recurrence_every
                           END,
       recurrence_unit  = CASE recurrence
                             WHEN 'daily' THEN 'day'
                             WHEN 'weekly' THEN 'week'
                             WHEN 'every_2_weeks' THEN 'week'
                             WHEN 'monthly' THEN 'month'
                             WHEN 'every_2_months' THEN 'month'
                             WHEN 'annual' THEN 'year'
                             ELSE recurrence_unit
                           END
 WHERE recurrence <> 'none'
   AND recurrence_every IS NULL
   AND recurrence_unit IS NULL;

UPDATE public.chores
   SET recurrence_every = NULL,
       recurrence_unit  = NULL
 WHERE recurrence = 'none'
   AND recurrence_every IS NULL
   AND recurrence_unit IS NULL;

ALTER TABLE public.chores ENABLE TRIGGER chores_events_trigger;

-- Constraints: chores recurrence pair + allowed units
ALTER TABLE public.chores
  DROP CONSTRAINT IF EXISTS chk_chores_recurrence_pair,
  ADD CONSTRAINT chk_chores_recurrence_pair
    CHECK (
      (recurrence_every IS NULL AND recurrence_unit IS NULL)
      OR (recurrence_every IS NOT NULL AND recurrence_unit IS NOT NULL)
    ),
  DROP CONSTRAINT IF EXISTS chk_chores_recurrence_every_min,
  ADD CONSTRAINT chk_chores_recurrence_every_min
    CHECK (recurrence_every IS NULL OR recurrence_every >= 1),
  DROP CONSTRAINT IF EXISTS chk_chores_recurrence_unit_allowed,
  ADD CONSTRAINT chk_chores_recurrence_unit_allowed
    CHECK (recurrence_unit IS NULL OR recurrence_unit IN ('day', 'week', 'month', 'year'));

COMMENT ON COLUMN public.chores.recurrence_every IS 'NULL for one-off; >=1 for recurring cadence.';
COMMENT ON COLUMN public.chores.recurrence_unit IS 'Allowed units: day|week|month|year. NULL for one-off.';

-- Helper: map legacy recurrence interval to every/unit
CREATE OR REPLACE FUNCTION public._chore_recurrence_to_every_unit(
  p_recurrence public.recurrence_interval
)
RETURNS TABLE (
  recurrence_every integer,
  recurrence_unit text
)
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = ''
AS $$
BEGIN
  CASE p_recurrence
    WHEN 'daily' THEN
      recurrence_every := 1;
      recurrence_unit := 'day';
    WHEN 'weekly' THEN
      recurrence_every := 1;
      recurrence_unit := 'week';
    WHEN 'every_2_weeks' THEN
      recurrence_every := 2;
      recurrence_unit := 'week';
    WHEN 'monthly' THEN
      recurrence_every := 1;
      recurrence_unit := 'month';
    WHEN 'every_2_months' THEN
      recurrence_every := 2;
      recurrence_unit := 'month';
    WHEN 'annual' THEN
      recurrence_every := 1;
      recurrence_unit := 'year';
    ELSE
      recurrence_every := NULL;
      recurrence_unit := NULL;
  END CASE;

  RETURN NEXT;
END;
$$;

-- Update v1 RPCs to keep recurrence_every/unit in sync.
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
  v_usage_delta  integer := 1;
  v_photo_delta  integer := 0;
  v_row          public.chores;
  v_recur_every  integer;
  v_recur_unit   text;
BEGIN
  PERFORM public._assert_authenticated();

  -- Ensure caller actually belongs to this home (and is_current)
  PERFORM public._assert_home_member(p_home_id);

  -- Validate required name
  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  -- If assignee is provided, enforce they are a current member of this home
  IF p_assignee_user_id IS NOT NULL THEN
    PERFORM public.api_assert(
      EXISTS (
        SELECT 1
        FROM public.memberships m
        WHERE m.home_id = p_home_id
          AND m.user_id = p_assignee_user_id
          AND m.is_current
      ),
      'ASSIGNEE_NOT_CURRENT_MEMBER',
      'Assignee must be a current member of this home.',
      '42501',
      jsonb_build_object(
        'home_id',   p_home_id,
        'assignee',  p_assignee_user_id
      )
    );
    v_state := 'active';
  ELSE
    v_state := 'draft';
  END IF;

  SELECT * INTO v_recur_every, v_recur_unit
  FROM public._chore_recurrence_to_every_unit(COALESCE(p_recurrence, 'none'));

  -- Compute photo delta: only if we are creating with a photo
  IF p_expectation_photo_path IS NOT NULL THEN
    v_photo_delta := 1;
  END IF;

  -- Paywall check at SAVE time (quota helper)
  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,  -- +1 chore
        'chore_photos',  v_photo_delta   -- +1 photo if present
      )
    )
  );

  -- Insert chore
  INSERT INTO public.chores (
    home_id,
    created_by_user_id,
    assignee_user_id,
    name,
    start_date,
    recurrence,
    recurrence_every,
    recurrence_unit,
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
    v_recur_every,
    v_recur_unit,
    p_how_to_video_url,
    p_notes,
    p_expectation_photo_path,
    v_state
  )
  RETURNING * INTO v_row;

  -- Update usage counters via JSON-based helper
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.chores_update(
  p_chore_id               uuid,
  p_name                   text,
  p_assignee_user_id       uuid,
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
  v_target_recur public.recurrence_interval;
  v_target_every integer;
  v_target_unit  text;
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

  v_target_recur := COALESCE(p_recurrence, v_existing.recurrence);
  v_target_every := v_existing.recurrence_every;
  v_target_unit := v_existing.recurrence_unit;

  IF p_recurrence IS NOT NULL THEN
    SELECT * INTO v_target_every, v_target_unit
    FROM public._chore_recurrence_to_every_unit(p_recurrence);
  END IF;

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
    recurrence             = v_target_recur,
    recurrence_every       = v_target_every,
    recurrence_unit        = v_target_unit,
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

-- v2 RPCs: flexible recurrence every/unit.
CREATE OR REPLACE FUNCTION public.chores_create_v2(
  p_home_id                uuid,
  p_name                   text,
  p_assignee_user_id       uuid DEFAULT NULL,
  p_start_date             date DEFAULT current_date,
  p_recurrence_every       integer DEFAULT NULL,
  p_recurrence_unit        text DEFAULT NULL,
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
  v_usage_delta  integer := 1;
  v_photo_delta  integer := 0;
  v_row          public.chores;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  PERFORM public.api_assert(
    coalesce(btrim(p_name), '') <> '',
    'INVALID_INPUT',
    'Chore name is required.',
    '22023',
    jsonb_build_object('field', 'name')
  );

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery and recurrenceUnit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF p_recurrence_every IS NOT NULL AND p_recurrence_every < 1 THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery must be >= 1.',
      '22023',
      jsonb_build_object('field', 'recurrenceEvery')
    );
  END IF;

  IF p_recurrence_unit IS NOT NULL
     AND p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceUnit must be one of day|week|month|year.',
      '22023',
      jsonb_build_object('field', 'recurrenceUnit')
    );
  END IF;

  -- If assignee is provided, enforce they are a current member of this home
  IF p_assignee_user_id IS NOT NULL THEN
    PERFORM public.api_assert(
      EXISTS (
        SELECT 1
        FROM public.memberships m
        WHERE m.home_id = p_home_id
          AND m.user_id = p_assignee_user_id
          AND m.is_current
      ),
      'ASSIGNEE_NOT_CURRENT_MEMBER',
      'Assignee must be a current member of this home.',
      '42501',
      jsonb_build_object(
        'home_id',   p_home_id,
        'assignee',  p_assignee_user_id
      )
    );
    v_state := 'active';
  ELSE
    v_state := 'draft';
  END IF;

  IF p_expectation_photo_path IS NOT NULL THEN
    v_photo_delta := 1;
  END IF;

  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  INSERT INTO public.chores (
    home_id,
    created_by_user_id,
    assignee_user_id,
    name,
    start_date,
    recurrence_every,
    recurrence_unit,
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
    p_recurrence_every,
    p_recurrence_unit,
    p_how_to_video_url,
    p_notes,
    p_expectation_photo_path,
    v_state
  )
  RETURNING * INTO v_row;

  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'active_chores', v_usage_delta,
        'chore_photos',  v_photo_delta
      )
    )
  );

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.chores_update_v2(
  p_chore_id               uuid,
  p_name                   text,
  p_assignee_user_id       uuid,
  p_start_date             date DEFAULT NULL,
  p_recurrence_every       integer DEFAULT NULL,
  p_recurrence_unit        text DEFAULT NULL,
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

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery and recurrenceUnit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF p_recurrence_every IS NOT NULL AND p_recurrence_every < 1 THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceEvery must be >= 1.',
      '22023',
      jsonb_build_object('field', 'recurrenceEvery')
    );
  END IF;

  IF p_recurrence_unit IS NOT NULL
     AND p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'recurrenceUnit must be one of day|week|month|year.',
      '22023',
      jsonb_build_object('field', 'recurrenceUnit')
    );
  END IF;

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


  v_new_path := COALESCE(p_expectation_photo_path, v_existing.expectation_photo_path);
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;
  ELSE
    v_photo_delta := 0;
  END IF;

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
    start_date             = COALESCE(p_start_date, v_existing.start_date),
    recurrence_every       = p_recurrence_every,
    recurrence_unit        = p_recurrence_unit,
    expectation_photo_path = v_new_path,
    how_to_video_url       = COALESCE(p_how_to_video_url, v_existing.how_to_video_url),
    notes                  = COALESCE(p_notes, v_existing.notes),
    state                  = 'active',
    updated_at             = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_new;

  IF v_photo_delta <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_new.home_id,
      jsonb_build_object('chore_photos', v_photo_delta)
    );
  END IF;

  RETURN v_new;
END;
$$;

-- Update chore completion to use recurrence_every/unit when present.
CREATE OR REPLACE FUNCTION public.chore_complete(_chore_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore          public.chores%ROWTYPE;
  v_current_due    date;
  v_steps_advanced integer := 0;
  v_user           uuid := auth.uid();
  v_every          integer;
  v_unit           text;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_chore
  FROM public.chores
  WHERE id = _chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('CHORE_NOT_FOUND', 'Chore not found or not accessible.', '22023', jsonb_build_object('chore_id', _chore_id));
  END IF;

  PERFORM public._assert_home_member(v_chore.home_id);
  PERFORM public.api_assert(
    v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the current assignee can complete this chore.',
    '42501',
    jsonb_build_object('chore_id', _chore_id)
  );
  PERFORM public.api_assert(
    v_chore.state = 'active',
    'INVALID_STATE',
    'Only active chores can be completed.',
    '22023',
    jsonb_build_object('chore_id', _chore_id, 'state', v_chore.state)
  );

  v_current_due := COALESCE(v_chore.recurrence_cursor, v_chore.start_date);

  v_every := v_chore.recurrence_every;
  v_unit := v_chore.recurrence_unit;

  IF v_every IS NULL AND v_unit IS NULL THEN
    SELECT * INTO v_every, v_unit
    FROM public._chore_recurrence_to_every_unit(v_chore.recurrence);
  END IF;

  -------------------------------------------------------------------
  -- Case 1: non-recurring chore -> mark completed once and for all
  -------------------------------------------------------------------
  IF v_every IS NULL OR v_unit IS NULL THEN
    UPDATE public.chores
    SET state             = 'completed',
        completed_at      = COALESCE(v_chore.completed_at, now()),
        recurrence_cursor = NULL,
        updated_at        = now()
    WHERE id = _chore_id;

    PERFORM public._home_usage_apply_delta(
      v_chore.home_id,
      jsonb_build_object('active_chores', -1)
    );

    RETURN jsonb_build_object(
      'status',   'non_recurring_completed',
      'chore_id', _chore_id,
      'home_id',  v_chore.home_id,
      'state',    'completed'
    );
  END IF;

  -------------------------------------------------------------------
  -- Case 2: recurring chore -> advance to first date AFTER today
  -------------------------------------------------------------------
  WHILE v_current_due <= current_date LOOP
    CASE v_unit
      WHEN 'day' THEN v_current_due := v_current_due + v_every;
      WHEN 'week' THEN v_current_due := v_current_due + (v_every * 7);
      WHEN 'month' THEN v_current_due := (v_current_due + (v_every || ' months')::interval)::date;
      WHEN 'year' THEN v_current_due := (v_current_due + (v_every || ' years')::interval)::date;
      ELSE EXIT;
    END CASE;
    v_steps_advanced := v_steps_advanced + 1;
  END LOOP;

  IF v_steps_advanced = 0 THEN
    RETURN jsonb_build_object(
      'status',   'already_completed_for_cycle',
      'chore_id', _chore_id,
      'home_id',  v_chore.home_id,
      'state',    v_chore.state
    );
  END IF;

  UPDATE public.chores
  SET
    recurrence_cursor = v_current_due,
    completed_at      = now(),
    updated_at        = now()
  WHERE id = _chore_id;

  RETURN jsonb_build_object(
    'status',          'recurring_completed',
    'chore_id',        _chore_id,
    'home_id',         v_chore.home_id,
    'recurrenceEvery', v_every,
    'recurrenceUnit',  v_unit,
    'state',           v_chore.state,
    'cursor_after',    v_current_due,
    'steps_advanced',  v_steps_advanced
  );
END;
$$;

-- Update chore payloads to include recurrence_every/unit.
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

  SELECT jsonb_build_object(
           'id',                    base.id,
           'home_id',               base.home_id,
           'created_by_user_id',    base.created_by_user_id,
           'assignee_user_id',      base.assignee_user_id,
           'name',                  base.name,
           'start_date',            base.current_due_on,
           'recurrence',            c.recurrence,
           'recurrence_every',      c.recurrence_every,
           'recurrence_unit',       c.recurrence_unit,
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

-- Events trigger: include recurrence_every/unit changes.
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
  PERFORM public._assert_authenticated();

  IF TG_OP = 'INSERT' THEN
    v_event_type := 'create';
    v_to_state   := NEW.state;
    v_payload := jsonb_build_object(
      'name',               NEW.name,
      'recurrence',         NEW.recurrence,
      'recurrence_every',   NEW.recurrence_every,
      'recurrence_unit',    NEW.recurrence_unit,
      'recurrence_cursor',  NEW.recurrence_cursor,
      'assignee_user_id',   NEW.assignee_user_id
    );
    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (NEW.id, NEW.home_id, v_actor, v_event_type, NULL, v_to_state, v_payload);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.assignee_user_id      IS NOT DISTINCT FROM NEW.assignee_user_id
       AND OLD.recurrence        IS NOT DISTINCT FROM NEW.recurrence
       AND OLD.recurrence_every  IS NOT DISTINCT FROM NEW.recurrence_every
       AND OLD.recurrence_unit   IS NOT DISTINCT FROM NEW.recurrence_unit
       AND OLD.recurrence_cursor IS NOT DISTINCT FROM NEW.recurrence_cursor
       AND OLD.state             IS NOT DISTINCT FROM NEW.state THEN
      RETURN NEW;
    END IF;

    v_from_state := OLD.state;
    v_to_state   := NEW.state;

    IF NEW.recurrence_cursor IS NOT NULL
       AND OLD.recurrence_cursor IS NOT NULL
       AND NEW.recurrence_cursor > OLD.recurrence_cursor THEN
      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'recurrence_every', NEW.recurrence_every,
        'recurrence_unit',  NEW.recurrence_unit,
        'cursor_before',    OLD.recurrence_cursor,
        'cursor_after',     NEW.recurrence_cursor
      );

    ELSIF OLD.state <> 'completed'
          AND NEW.state = 'completed' THEN
      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'completed_state_from', OLD.state,
        'completed_state_to',   NEW.state
      );

    ELSIF OLD.state IN ('draft', 'active')
          AND NEW.state = 'cancelled' THEN
      v_event_type := 'cancel';
      v_payload := jsonb_build_object(
        'state_from',        OLD.state,
        'state_to',          NEW.state,
        'recurrence_before', OLD.recurrence,
        'recurrence_every',  OLD.recurrence_every,
        'recurrence_unit',   OLD.recurrence_unit,
        'cursor_before',     OLD.recurrence_cursor,
        'assignee_user_id',  OLD.assignee_user_id
      );

    ELSIF OLD.state = 'draft'
          AND NEW.state = 'active' THEN
      v_event_type := 'activate';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    ELSIF OLD.assignee_user_id IS DISTINCT FROM NEW.assignee_user_id THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'change_type',   'assignee',
        'assignee_event',
          CASE
            WHEN OLD.assignee_user_id IS NULL AND NEW.assignee_user_id IS NOT NULL THEN 'assign'
            WHEN OLD.assignee_user_id IS NOT NULL AND NEW.assignee_user_id IS NULL THEN 'unassign'
            ELSE 'reassign'
          END,
        'assignee_from', OLD.assignee_user_id,
        'assignee_to',   NEW.assignee_user_id
      );

    ELSIF OLD.recurrence_every IS DISTINCT FROM NEW.recurrence_every
          OR OLD.recurrence_unit IS DISTINCT FROM NEW.recurrence_unit THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'recurrence_every_from', OLD.recurrence_every,
        'recurrence_every_to',   NEW.recurrence_every,
        'recurrence_unit_from',  OLD.recurrence_unit,
        'recurrence_unit_to',    NEW.recurrence_unit
      );

    ELSIF OLD.state IS DISTINCT FROM NEW.state THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'state_from', OLD.state,
        'state_to',   NEW.state
      );

    ELSE
      RETURN NEW;
    END IF;

    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (NEW.id, NEW.home_id, v_actor, v_event_type, v_from_state, v_to_state, v_payload);
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    v_event_type := 'cancel';
    v_from_state := OLD.state;
    v_payload := jsonb_build_object('reason', 'deleted', 'state', OLD.state);
    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (OLD.id, OLD.home_id, v_actor, v_event_type, v_from_state, NULL, v_payload);
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS chores_events_trigger ON public.chores;
CREATE TRIGGER chores_events_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.chores
FOR EACH ROW EXECUTE FUNCTION public.chores_events_trigger();

-- Revoke/Grant v2 RPCs
REVOKE ALL ON FUNCTION public.chores_create_v2(
  uuid, text, uuid, date, integer, text, text, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.chores_update_v2(
  uuid, text, uuid, date, integer, text, text, text, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.chores_create_v2(
  uuid, text, uuid, date, integer, text, text, text, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.chores_update_v2(
  uuid, text, uuid, date, integer, text, text, text, text
) TO authenticated;
