-- 20251224XX_chore_dates_back_to_date.sql
-- Contract: chores start_date/recurrence_cursor are date-only (no time-of-day).

-- 1) Schema: convert timestamptz back to date
ALTER TABLE public.chores
  ALTER COLUMN start_date TYPE date USING (timezone('UTC', start_date))::date,
  ALTER COLUMN start_date SET DEFAULT current_date,
  ALTER COLUMN start_date SET NOT NULL,
  ALTER COLUMN recurrence_cursor TYPE date USING (timezone('UTC', recurrence_cursor))::date;

COMMENT ON COLUMN public.chores.start_date        IS 'Initial due date.';
COMMENT ON COLUMN public.chores.recurrence_cursor IS 'Anchor date for recurrence (next due).';

DROP INDEX IF EXISTS idx_chores_home_due_cursor;
CREATE INDEX IF NOT EXISTS idx_chores_home_due_cursor
  ON public.chores (home_id, recurrence_cursor NULLS LAST, created_at DESC);

-- 2) Replace RPCs/views with date contract
DROP FUNCTION IF EXISTS public.chores_create(
  uuid,
  text,
  uuid,
  timestamptz,
  public.recurrence_interval,
  text,
  text,
  text
);

DROP FUNCTION IF EXISTS public.chores_update(
  uuid,
  text,
  uuid,
  timestamptz,
  public.recurrence_interval,
  text,
  text,
  text
);

DROP FUNCTION IF EXISTS public._chores_base_for_home(uuid);
DROP FUNCTION IF EXISTS public.chores_list_for_home(uuid);
DROP FUNCTION IF EXISTS public.today_flow_list(uuid, public.chore_state);

-- Base view for chores (date current due)
CREATE OR REPLACE FUNCTION public._chores_base_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                           uuid,
  home_id                      uuid,
  assignee_user_id             uuid,
  created_by_user_id           uuid,
  name                         text,
  state                        public.chore_state,
  current_due_on               date,
  created_at                   timestamptz,
  assignee_full_name           text,
  assignee_avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.created_by_user_id,
    c.name,
    c.state,
    CASE
      WHEN c.completed_at IS NULL THEN c.start_date
      ELSE c.recurrence_cursor
    END AS current_due_on,
    c.created_at,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id;
END;
$$;

-- Lists (return date current due)
CREATE OR REPLACE FUNCTION public.chores_list_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                            uuid,
  home_id                       uuid,
  assignee_user_id              uuid,
  name                          text,
  start_date                    date, -- current due date
  assignee_full_name            text,
  assignee_avatar_storage_path  text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    id,
    home_id,
    assignee_user_id,
    name,
    current_due_on AS start_date,
    assignee_full_name,
    assignee_avatar_storage_path
  FROM public._chores_base_for_home(p_home_id)
  WHERE state IN ('draft', 'active')
    AND (
      state = 'active'::public.chore_state
      OR (state = 'draft'::public.chore_state AND created_by_user_id = auth.uid())
    )
  ORDER BY current_due_on DESC, created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.today_flow_list(
  p_home_id uuid,
  p_state   public.chore_state
)
RETURNS TABLE (
  id         uuid,
  home_id    uuid,
  name       text,
  start_date date,
  state      public.chore_state
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    id,
    home_id,
    name,
    current_due_on AS start_date,
    state
  FROM public._chores_base_for_home(p_home_id)
  WHERE state = p_state
    AND current_due_on <= current_date  -- due now or overdue
    AND (
      (p_state = 'draft'::public.chore_state AND created_by_user_id = auth.uid())
      OR (p_state = 'active'::public.chore_state AND assignee_user_id = auth.uid())
    )
  ORDER BY current_due_on ASC, created_at ASC;
$$;

-- Mutations (date-based)
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
  v_user_id     uuid := auth.uid();
  v_state       public.chore_state;
  v_usage_delta integer := 1;
  v_photo_delta integer := 0;
  v_row         public.chores;
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

-- Completion: advance date cursor
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

  -------------------------------------------------------------------
  -- Case 1: non-recurring chore — mark completed once and for all
  -------------------------------------------------------------------
  IF v_chore.recurrence = 'none' THEN
    UPDATE public.chores
    SET state             = 'completed',
        completed_at      = COALESCE(v_chore.completed_at, now()),
        recurrence_cursor = NULL,
        updated_at        = now()
    WHERE id = _chore_id;

    -- Decrement active counter
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
  -- Case 2: recurring chore — advance to first date AFTER today
  -------------------------------------------------------------------
  WHILE v_current_due <= current_date LOOP
    CASE v_chore.recurrence
      WHEN 'daily'          THEN v_current_due := v_current_due + 1;
      WHEN 'weekly'         THEN v_current_due := v_current_due + 7;
      WHEN 'every_2_weeks'  THEN v_current_due := v_current_due + 14;
      WHEN 'monthly'        THEN v_current_due := (v_current_due + INTERVAL '1 month')::date;
      WHEN 'every_2_months' THEN v_current_due := (v_current_due + INTERVAL '2 months')::date;
      WHEN 'annual'         THEN v_current_due := (v_current_due + INTERVAL '1 year')::date;
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
    'status',         'recurring_completed',
    'chore_id',       _chore_id,
    'home_id',        v_chore.home_id,
    'recurrence',     v_chore.recurrence,
    'state',          v_chore.state,
    'cursor_after',   v_current_due,
    'steps_advanced', v_steps_advanced
  );
END;
$$;

-- Cancel: keep cursor null
CREATE OR REPLACE FUNCTION public.chores_cancel(p_chore_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore public.chores%ROWTYPE;
  v_user  uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  SELECT * INTO v_chore
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Chore not found.', '22023', jsonb_build_object('chore_id', p_chore_id));
  END IF;

  PERFORM public._assert_home_member(v_chore.home_id);
  PERFORM public.api_assert(
    v_chore.created_by_user_id = v_user OR v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the chore creator or current assignee can cancel.',
    '42501',
    jsonb_build_object('choreId', p_chore_id)
  );
  PERFORM public.api_assert(
    v_chore.state IN ('draft', 'active'),
    'ALREADY_FINALIZED',
    'Only draft/active chores can be cancelled.',
    '22023'
  );

  UPDATE public.chores
  SET state             = 'cancelled',
      recurrence        = 'none',
      recurrence_cursor = NULL,
      updated_at        = now()
  WHERE id = p_chore_id
  RETURNING * INTO v_chore;

  -- Decrement active_chores by 1 (clamped at 0 in the helper)
  PERFORM public._home_usage_apply_delta(
    v_chore.home_id,
    jsonb_build_object('active_chores', -1)
  );

  RETURN jsonb_build_object('chore', to_jsonb(v_chore));
END;
$$;

-- Events trigger (date cursor)
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
      'name',              NEW.name,
      'recurrence',        NEW.recurrence,
      'recurrence_cursor', NEW.recurrence_cursor,
      'assignee_user_id',  NEW.assignee_user_id
    );
    INSERT INTO public.chore_events (
      chore_id, home_id, actor_user_id, event_type, from_state, to_state, payload
    ) VALUES (NEW.id, NEW.home_id, v_actor, v_event_type, NULL, v_to_state, v_payload);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.assignee_user_id      IS NOT DISTINCT FROM NEW.assignee_user_id
       AND OLD.recurrence        IS NOT DISTINCT FROM NEW.recurrence
       AND OLD.recurrence_cursor IS NOT DISTINCT FROM NEW.recurrence_cursor
       AND OLD.state             IS NOT DISTINCT FROM NEW.state THEN
      RETURN NEW;
    END IF;

    v_from_state := OLD.state;
    v_to_state   := NEW.state;

    -- Priority order documented in previous version; preserved here.
    IF NEW.recurrence <> 'none'
       AND OLD.recurrence_cursor IS NOT NULL
       AND NEW.recurrence_cursor IS NOT NULL
       AND NEW.recurrence_cursor > OLD.recurrence_cursor THEN
      v_event_type := 'complete';
      v_payload := jsonb_build_object(
        'recurrence',    NEW.recurrence,
        'cursor_before', OLD.recurrence_cursor,
        'cursor_after',  NEW.recurrence_cursor
      );

    ELSIF OLD.state <> 'completed'
          AND NEW.state = 'completed'
          AND NEW.recurrence = 'none' THEN
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

    ELSIF OLD.recurrence IS DISTINCT FROM NEW.recurrence THEN
      v_event_type := 'update';
      v_payload := jsonb_build_object(
        'recurrence_from', OLD.recurrence,
        'recurrence_to',   NEW.recurrence
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

-- Revoke/Grant (date signatures)
REVOKE ALL ON FUNCTION public._chores_base_for_home(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chores_list_for_home(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.today_flow_list(uuid, public.chore_state) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chores_create(uuid, text, uuid, date, public.recurrence_interval, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chores_update(uuid, text, uuid, date, public.recurrence_interval, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chores_cancel(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chore_complete(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chores_events_trigger() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._chores_base_for_home(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chores_list_for_home(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.today_flow_list(uuid, public.chore_state) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chores_create(uuid, text, uuid, date, public.recurrence_interval, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chores_update(uuid, text, uuid, date, public.recurrence_interval, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chores_cancel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chore_complete(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chores_events_trigger() TO authenticated;

CREATE OR REPLACE FUNCTION public.expenses_get_for_edit(
  p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_expense            public.expenses%ROWTYPE;
  v_home_is_active     boolean;
  v_splits             jsonb := '[]'::jsonb;
  v_can_edit           boolean := FALSE;
  v_edit_disabled      text := NULL;
  v_plan_status        text := NULL;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  SELECT e.*
    INTO v_expense
    FROM public.expenses e
   WHERE e.id = p_expense_id
     AND EXISTS (
       SELECT 1
         FROM public.memberships m
        WHERE m.home_id    = e.home_id
          AND m.user_id    = v_user
          AND m.is_current = TRUE
          AND m.valid_to IS NULL
     );

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_expense.home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_expense.home_id));
  END IF;

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can edit this expense.', '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.plan_id IS NOT NULL THEN
    SELECT ep.status
      INTO v_plan_status
      FROM public.expense_plans ep
     WHERE ep.id = v_expense.plan_id
     LIMIT 1;
  END IF;

  v_can_edit := (v_expense.status = 'draft'::public.expense_status);

  IF NOT v_can_edit THEN
    IF v_expense.plan_id IS NOT NULL THEN
      IF v_expense.status = 'converted'::public.expense_status THEN
        v_edit_disabled := 'CONVERTED_TO_PLAN';
      ELSE
        v_edit_disabled := 'RECURRING_CYCLE_IMMUTABLE';
      END IF;
    ELSE
      CASE v_expense.status
        WHEN 'active'::public.expense_status THEN v_edit_disabled := 'ACTIVE_IMMUTABLE';
        WHEN 'converted'::public.expense_status THEN v_edit_disabled := 'CONVERTED_TO_PLAN';
        ELSE v_edit_disabled := 'NOT_EDITABLE';
      END CASE;
    END IF;
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',    s.expense_id,
               'debtorUserId', s.debtor_user_id,
               'amountCents',  s.amount_cents,
               'status',       s.status,
               'markedPaidAt', s.marked_paid_at
             )
             ORDER BY s.debtor_user_id
           ),
           '[]'::jsonb
         )
    INTO v_splits
    FROM public.expense_splits s
   WHERE s.expense_id = v_expense.id;

  RETURN jsonb_build_object(
    'expenseId',          v_expense.id,
    'homeId',             v_expense.home_id,
    'createdByUserId',    v_expense.created_by_user_id,
    'status',             v_expense.status,
    'splitType',          v_expense.split_type,
    'amountCents',        v_expense.amount_cents,
    'description',        v_expense.description,
    'notes',              v_expense.notes,
    'createdAt',          v_expense.created_at,
    'updatedAt',          v_expense.updated_at,
    'planId',             v_expense.plan_id,
    'planStatus',         v_plan_status,
    'recurrenceInterval', v_expense.recurrence_interval,
    'startDate',          v_expense.start_date,
    'canEdit',            v_can_edit,
    'editDisabledReason', v_edit_disabled,
    'splits',             v_splits
  );
END;
$$;


-- Client-facing paywall status RPC: returns plan, usage, and limits.

CREATE OR REPLACE FUNCTION public.paywall_status_get(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan           text;
  v_now            timestamptz := now();
BEGIN
  PERFORM public._assert_home_member(p_home_id);

  SELECT COALESCE(he.plan, 'free')
    INTO v_plan
    FROM public.home_entitlements he
   WHERE he.home_id = p_home_id;

  RETURN jsonb_build_object(
    'plan', v_plan,
    'is_premium', (v_plan <> 'free'),
    'has_ai',     (v_plan = 'premium_ai'),
    'usage', COALESCE((
      SELECT jsonb_build_object(
        'active_chores',   c.active_chores,
        'chore_photos',    c.chore_photos,
        'active_members',  c.active_members,
        'active_expenses', c.active_expenses,
        'updated_at',      c.updated_at
      )
      FROM public.home_usage_counters c
      WHERE c.home_id = p_home_id
    ), jsonb_build_object(
      'active_chores', 0,
      'chore_photos', 0,
      'active_members', 0,
      'active_expenses', 0,
      'updated_at', v_now
    )),

    'limits', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'metric',    x.metric::text,
          'max_value', x.max_value
        )
        ORDER BY x.metric::text
      )
      FROM (
        SELECT l.metric, l.max_value
        FROM public.home_plan_limits l
        WHERE l.plan = v_plan
      ) x
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.paywall_status_get(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.paywall_status_get(uuid)
  TO authenticated, service_role;
