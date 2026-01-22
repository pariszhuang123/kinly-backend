----------------------------------------------------------------------
-- ENUM: usage metrics managed by quotas
----------------------------------------------------------------------
CREATE TYPE public.home_usage_metric AS ENUM (
  'active_chores',
  'chore_photos',
  'active_members'
);

----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.home_plan_limits (
  plan       text                     NOT NULL,
  metric     public.home_usage_metric NOT NULL,
  max_value  integer                  NOT NULL CHECK (max_value >= 0),

  PRIMARY KEY (plan, metric),
  CONSTRAINT home_plan_limits_plan_not_blank
    CHECK (btrim(plan) <> '')
);

COMMENT ON TABLE public.home_plan_limits IS
  'Per-plan limits for home usage metrics (e.g. free vs premium).';

COMMENT ON COLUMN public.home_plan_limits.plan IS
  'Logical plan name (e.g. free, premium).';

COMMENT ON COLUMN public.home_plan_limits.metric IS
  'Usage metric being limited (active_chores, chore_photos, active_members).';

COMMENT ON COLUMN public.home_plan_limits.max_value IS
  'Maximum allowed value for this metric on this plan.';

INSERT INTO public.home_plan_limits (plan, metric, max_value)
VALUES
  -- Free tier defaults (keep in sync with docs/tests)
  ('free', 'active_chores', 20),
  ('free', 'chore_photos', 15),
  ('free', 'active_members', 4)
ON CONFLICT (plan, metric)
DO UPDATE SET max_value = EXCLUDED.max_value;

----------------------------------------------------------------------
-- home_plan_limits: lock it down
----------------------------------------------------------------------
ALTER TABLE public.home_plan_limits ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.home_plan_limits
FROM PUBLIC, anon, authenticated;

-- Optional, if you ever need direct access from a service_key client:
-- GRANT SELECT, INSERT, UPDATE, DELETE ON public.home_plan_limits TO service_role;

----------------------------------------------------------------------
-- COUNTERS: add active_members
----------------------------------------------------------------------
ALTER TABLE public.home_usage_counters
  ADD COLUMN IF NOT EXISTS active_members integer NOT NULL DEFAULT 0 CHECK (active_members >= 0);

COMMENT ON COLUMN public.home_usage_counters.active_members IS
  'Number of current/active members in the home (owner + members).';

----------------------------------------------------------------------
-- INTERNAL HELPERS
----------------------------------------------------------------------

DROP FUNCTION IF EXISTS public._home_usage_increment(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public._home_usage_apply_delta(
  p_home_id uuid,
  p_deltas  jsonb   -- e.g. {"active_chores": 1, "active_members": -1}
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row                 public.home_usage_counters;
  v_active_chores_delta integer := 0;
  v_chore_photos_delta  integer := 0;
  v_active_members_delta integer := 0;
BEGIN
  --------------------------------------------------------------------
  -- Ensure a row exists
  --------------------------------------------------------------------
  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

  --------------------------------------------------------------------
  -- Extract numeric deltas robustly (ignore non-numeric)
  --------------------------------------------------------------------
  IF p_deltas IS NOT NULL AND jsonb_typeof(p_deltas) = 'object' THEN
    IF jsonb_typeof(p_deltas->'active_chores') = 'number' THEN
      v_active_chores_delta := (p_deltas->>'active_chores')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'chore_photos') = 'number' THEN
      v_chore_photos_delta := (p_deltas->>'chore_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'active_members') = 'number' THEN
      v_active_members_delta := (p_deltas->>'active_members')::integer;
    END IF;
  END IF;

  --------------------------------------------------------------------
  -- Apply each metric delta (extend as you add features)
  --------------------------------------------------------------------
  UPDATE public.home_usage_counters h
  SET
    active_chores = GREATEST(
      0,
      COALESCE(h.active_chores, 0) + v_active_chores_delta
    ),
    chore_photos = GREATEST(
      0,
      COALESCE(h.chore_photos, 0) + v_chore_photos_delta
    ),
    active_members = GREATEST(
      0,
      COALESCE(h.active_members, 0) + v_active_members_delta
    ),
    -- Add new quota metrics later, e.g.:
    -- polls_created = GREATEST(0, COALESCE(h.polls_created, 0) + v_polls_created_delta),
    -- ai_tasks_used = GREATEST(0, COALESCE(h.ai_tasks_used, 0) + v_ai_tasks_used_delta),
    updated_at = now()
  WHERE h.home_id = p_home_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._home_usage_apply_delta(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

----------------------------------------------------------------------
-- Quota enforcement helper (kept separate from apply_delta)
----------------------------------------------------------------------

DROP FUNCTION IF EXISTS public._home_assert_within_free_limits(uuid, integer, integer);
DROP FUNCTION IF EXISTS public._home_assert_quota(uuid, jsonb);

CREATE OR REPLACE FUNCTION public._home_assert_quota(
  p_home_id uuid,
  p_deltas  jsonb   -- e.g. {"active_members": 1, "active_chores": 1}
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan         text;
  v_is_premium   boolean;
  v_counters     public.home_usage_counters%ROWTYPE;

  v_metric_key   text;
  v_metric_enum  public.home_usage_metric;
  v_raw_value    jsonb;
  v_delta        integer;
  v_current      integer;
  v_new          integer;
  v_max          integer;
BEGIN
  --------------------------------------------------------------------
  -- 1) Determine plan (defaults to 'free' if missing)
  --------------------------------------------------------------------
  v_plan := public._home_effective_plan(p_home_id);

  --------------------------------------------------------------------
  -- 2) Premium homes skip all quota checks
  --------------------------------------------------------------------
  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  --------------------------------------------------------------------
  -- 3) No deltas → nothing to check
  --------------------------------------------------------------------
  IF p_deltas IS NULL OR jsonb_typeof(p_deltas) <> 'object' THEN
    RETURN;
  END IF;

  --------------------------------------------------------------------
  -- 4) Load counters row (may be NULL if not created yet)
  --------------------------------------------------------------------
  SELECT *
  INTO v_counters
  FROM public.home_usage_counters
  WHERE home_id = p_home_id;

  IF NOT FOUND THEN
    v_counters.active_chores  := 0;
    v_counters.chore_photos   := 0;
    v_counters.active_members := 0;
  END IF;

  --------------------------------------------------------------------
  -- 5) For each key:value in p_deltas, perform plan checks
  --------------------------------------------------------------------
  FOR v_metric_key, v_raw_value IN
    SELECT key, value
    FROM jsonb_each(p_deltas)
  LOOP
    ------------------------------------------------------------------
    -- 5a) Map JSON key → enum, ignore unknown metrics
    ------------------------------------------------------------------
    BEGIN
      v_metric_enum := v_metric_key::public.home_usage_metric;
    EXCEPTION WHEN invalid_text_representation THEN
      CONTINUE; -- unknown metric, ignore for quota
    END;

    ------------------------------------------------------------------
    -- 5b) Ensure numeric delta
    ------------------------------------------------------------------
    IF jsonb_typeof(v_raw_value) <> 'number' THEN
      PERFORM public.api_error(
        'INVALID_QUOTA_DELTA',
        'Quota delta must be numeric.',
        '22023',
        jsonb_build_object('metric', v_metric_key, 'value', v_raw_value)
      );
    END IF;

    v_delta := (v_raw_value #>> '{}')::integer;

    -- Ignore zero or negative deltas (quota only cares about increases)
    IF COALESCE(v_delta, 0) <= 0 THEN
      CONTINUE;
    END IF;

    ------------------------------------------------------------------
    -- 5c) Look up per-plan limit. Missing → unlimited
    ------------------------------------------------------------------
    SELECT max_value
    INTO v_max
    FROM public.home_plan_limits
    WHERE plan   = v_plan
      AND metric = v_metric_enum;

    IF v_max IS NULL THEN
      CONTINUE;  -- unlimited for this metric on this plan
    END IF;

    ------------------------------------------------------------------
    -- 5d) Map metric → current counter
    ------------------------------------------------------------------
    v_current := CASE v_metric_enum
      WHEN 'active_chores'  THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'   THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members' THEN COALESCE(v_counters.active_members, 0)
    END;

    v_new := GREATEST(0, v_current + v_delta);

    ------------------------------------------------------------------
    -- 5e) Enforce limit
    ------------------------------------------------------------------
    IF v_new > v_max THEN
      PERFORM public.api_error(
        'PAYWALL_LIMIT_' || upper(v_metric_key),
        format(
          'Free plan allows up to %s %s per home.',
          v_max,
          v_metric_key
        ),
        'P0001',
        jsonb_build_object(
          'limit_type', v_metric_key,
          'plan',       v_plan,
          'max',        v_max,
          'current',    v_current,
          'projected',  v_new
        )
      );
    END IF;
  END LOOP;

END;
$$;

COMMENT ON FUNCTION public._home_assert_quota(uuid, jsonb) IS
  'Generic quota enforcement: checks deltas against per-plan limits in home_plan_limits and raises api_error when exceeding quotas.';

REVOKE ALL ON FUNCTION public._home_assert_quota(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

----------------------------------------------------------------------
-- CHORES: create
----------------------------------------------------------------------

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
  v_usage_delta  integer := 1;  -- every new chore counts as +1
  v_photo_delta  integer := 0;  -- will be 1 if we create with a photo
  v_row          public.chores;
BEGIN
  PERFORM public._assert_authenticated();

  -- Ensure caller actually belongs to this home (and is_current)
  PERFORM public._assert_home_member(p_home_id);

  -- Validate required name
  IF COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Chore name is required.',
      '22023',
      jsonb_build_object('field', 'name')
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

----------------------------------------------------------------------
-- CHORES: update
----------------------------------------------------------------------

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

  -- Enforce that assignee is provided
  IF p_assignee_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Assignee is required when updating a chore.',
      '22023',
      jsonb_build_object('field', 'assignee_user_id')
    );
  END IF;

  -- Validate name
  IF COALESCE(btrim(p_name), '') = '' THEN
    PERFORM public.api_error(
      'INVALID_INPUT',
      'Chore name is required.',
      '22023',
      jsonb_build_object('field', 'name')
    );
  END IF;

  -- Load existing chore (and lock it)
  SELECT *
  INTO v_existing
  FROM public.chores
  WHERE id = p_chore_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found.',
      'P0002',
      jsonb_build_object('chore_id', p_chore_id)
    );
  END IF;

  -- Ensure caller is an active member of this home
  PERFORM public._assert_home_member(v_existing.home_id);

  -- Enforce "only creator or assignee can edit"
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

  -- Compute photo delta (per-chore slot semantics)
  IF v_existing.expectation_photo_path IS NULL AND v_new_path IS NOT NULL THEN
    v_photo_delta := 1;   -- adding first photo to this chore
  ELSIF v_existing.expectation_photo_path IS NOT NULL AND v_new_path IS NULL THEN
    v_photo_delta := -1;  -- removing the only photo from this chore
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

  -- Update chore
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

----------------------------------------------------------------------
-- CHORES: cancel
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chores_cancel(p_chore_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user  uuid := auth.uid();
  v_chore public.chores;
BEGIN
  PERFORM public._assert_authenticated();

  -- Lock the chore row
  SELECT *
    INTO v_chore
    FROM public.chores
   WHERE id = p_chore_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found.',
      'P0002',
      jsonb_build_object('chore_id', p_chore_id)
    );
  END IF;

  -- Must belong to this home
  PERFORM public._assert_home_member(v_chore.home_id);

  -- Only creator or current assignee can cancel
  PERFORM public.api_assert(
    v_chore.created_by_user_id = v_user
    OR v_chore.assignee_user_id = v_user,
    'FORBIDDEN',
    'Only the chore creator or current assignee can cancel.',
    '42501',
    jsonb_build_object('chore_id', p_chore_id)
  );

  -- Only draft/active chores can be cancelled
  PERFORM public.api_assert(
    v_chore.state IN ('draft', 'active'),
    'ALREADY_FINALIZED',
    'Only draft/active chores can be cancelled.',
    '22023'
  );

  -- Transition to cancelled
  UPDATE public.chores
     SET state            = 'cancelled',
         next_occurrence  = NULL,
         recurrence       = 'none',
         recurrence_cursor= NULL,
         updated_at       = now()
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

----------------------------------------------------------------------
-- CHORES: complete
----------------------------------------------------------------------

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
      'P0002',
      jsonb_build_object('chore_id', _chore_id)
    );
  END IF;

  -- Must belong to the same home (and user must be is_current)
  PERFORM public._assert_home_member(v_chore.home_id);

  -- Only current assignee can complete
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
    UPDATE public.chores
    SET
      state           = 'completed',
      completed_at    = COALESCE(v_chore.completed_at, now()),
      next_occurrence = NULL,
      updated_at      = now()
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
  -- Case 2: recurring chore → advance to first date AFTER today
  -------------------------------------------------------------------
  v_new_next_date := COALESCE(v_chore.next_occurrence, v_chore.start_date);
  v_new_cursor    := COALESCE(v_chore.recurrence_cursor, v_new_next_date::timestamptz);

  WHILE v_new_next_date <= current_date LOOP
    CASE v_chore.recurrence
      WHEN 'daily'          THEN v_new_next_date := v_new_next_date + INTERVAL '1 day';
      WHEN 'weekly'         THEN v_new_next_date := v_new_next_date + INTERVAL '7 days';
      WHEN 'every_2_weeks'  THEN v_new_next_date := v_new_next_date + INTERVAL '14 days';
      WHEN 'monthly'        THEN v_new_next_date := (v_new_next_date + INTERVAL '1 month')::date;
      WHEN 'every_2_months' THEN v_new_next_date := (v_new_next_date + INTERVAL '2 months')::date;
      WHEN 'annual'         THEN v_new_next_date := (v_new_next_date + INTERVAL '1 year')::date;
      ELSE
        EXIT;
    END CASE;

    v_new_cursor     := v_new_next_date::timestamptz;
    v_steps_advanced := v_steps_advanced + 1;
  END LOOP;

  -- If nothing moved forward, next_occurrence was already in the future
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
    recurrence_cursor = v_new_cursor,
    next_occurrence   = v_new_next_date,
    completed_at      = now(),
    updated_at        = now()
  WHERE id = _chore_id;

  RETURN jsonb_build_object(
    'status',                   'recurring_completed',
    'chore_id',                 _chore_id,
    'home_id',                  v_chore.home_id,
    'recurrence',               v_chore.recurrence,
    'state',                    v_chore.state,
    'previous_next_occurrence', v_prev_next,
    'new_next_occurrence',      v_new_next_date,
    'steps_advanced',           v_steps_advanced
  );
END;
$$;

----------------------------------------------------------------------
-- HOMES: join(code)
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.homes_join(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid := auth.uid();
  v_home_id uuid;
  v_revoked boolean;
  v_active  boolean;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- Combined lookup: home_id + invite state
  --------------------------------------------------------------------
  SELECT
    i.home_id,
    (i.revoked_at IS NOT NULL) AS revoked,
    h.is_active
  INTO
    v_home_id,
    v_revoked,
    v_active
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::public.citext
  LIMIT 1;

  -- Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- Already current member of this same home
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

  -- Already in another active home (only one allowed)
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

  --------------------------------------------------------------------
  -- Paywall: enforce active_members limit on this home
  --------------------------------------------------------------------
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, v_home_id, 'member', now(), NULL);

  -- Increment cached active_members
  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::public.citext;

  -- Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;

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

  -- 5) Create first invite
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT ON CONSTRAINT uq_invites_active_one_per_home DO NOTHING
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

DROP FUNCTION IF EXISTS public.homes_create_with_invite(text);

REVOKE ALL ON FUNCTION public.homes_create_with_invite()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.homes_create_with_invite()
TO authenticated;

----------------------------------------------------------------------
-- HOMES: leave(home_id)
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.homes_leave(p_home_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user            uuid := auth.uid();
  v_is_owner        boolean;
  v_other_members   integer;
  v_left_rows       integer;
  v_deactivated     boolean := false;
  v_role_before     text;
  v_members_left    integer;

  v_current_members integer;
  v_delta_members   integer;
BEGIN
  PERFORM public._assert_authenticated();

  -- Serialize with transfers/joins
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  -- Must be a current member
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      WHERE m.user_id = v_user
        AND m.home_id = p_home_id
        AND m.is_current
    ),
    'NOT_MEMBER',
    'You are not a current member of this home.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

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
    SELECT 1
    FROM public.memberships m
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
      PERFORM public.api_error(
        'OWNER_MUST_TRANSFER_FIRST',
        'Owner must transfer ownership before leaving.',
        '42501',
        jsonb_build_object(
          'home_id',       p_home_id,
          'other_members', v_other_members
        )
      );
    END IF;
  END IF;

  -- End the stint
  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
   WHERE user_id = v_user
     AND home_id = p_home_id
     AND m.is_current
  RETURNING 1 INTO v_left_rows;

  IF v_left_rows IS NULL THEN
    PERFORM public.api_error(
      'STATE_CHANGED_RETRY',
      'Membership state changed; retry.',
      '40001'
    );
  END IF;

  -- Check remaining members (ground truth)
  SELECT COUNT(*) INTO v_members_left
    FROM public.memberships m
   WHERE m.home_id = p_home_id
     AND m.is_current;

  -- Keep usage counter in sync with ground truth
  SELECT COALESCE(active_members, 0)
    INTO v_current_members
    FROM public.home_usage_counters
   WHERE home_id = p_home_id;

  v_delta_members := v_members_left - v_current_members;

  IF v_delta_members <> 0 THEN
    PERFORM public._home_usage_apply_delta(
      p_home_id,
      jsonb_build_object('active_members', v_delta_members)
    );
  END IF;

  -- Deactivate home if no members remain
  IF v_members_left = 0 THEN
    UPDATE public.homes
       SET is_active      = FALSE,
           deactivated_at = now(),
           updated_at     = now()
     WHERE id = p_home_id;

    v_deactivated := true;
  END IF;

  -- Detach any existing live subscription from the home
  PERFORM public._home_detach_subscription_to_home(p_home_id, v_user);

  -- Reassign chores to owner if home still has members
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
      'home_id',          p_home_id,
      'role_before',      v_role_before,
      'members_remaining', v_members_left,
      'home_deactivated', v_deactivated
    )
  );
END;
$$;