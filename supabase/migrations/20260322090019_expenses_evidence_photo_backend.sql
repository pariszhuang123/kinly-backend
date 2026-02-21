-- =====================================================================
-- Expenses evidence photos v2
-- - Adds optional evidence_photo_path on expenses and expense_plans.
-- - Adds expense_photos to paywall counters/quotas.
-- - Wires create/edit/cancel/pay/terminate + plan cycle copy semantics.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Quota system extensions: counter + free plan limit
-- ---------------------------------------------------------------------
ALTER TABLE public.home_usage_counters
ADD COLUMN IF NOT EXISTS expense_photos integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  BEGIN
    ALTER TABLE public.home_usage_counters
      ADD CONSTRAINT home_usage_counters_expense_photos_check
      CHECK (expense_photos >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

INSERT INTO public.home_plan_limits (plan, metric, max_value)
VALUES ('free', 'expense_photos', 10)
ON CONFLICT (plan, metric) DO UPDATE
SET max_value = EXCLUDED.max_value;

-- ---------------------------------------------------------------------
-- 1) Expenses + plans schema: optional evidence photo path
-- ---------------------------------------------------------------------
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS evidence_photo_path text;

ALTER TABLE public.expense_plans
  ADD COLUMN IF NOT EXISTS evidence_photo_path text;

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_evidence_photo_path,
  ADD CONSTRAINT chk_expenses_evidence_photo_path
    CHECK (
      evidence_photo_path IS NULL
      OR evidence_photo_path LIKE 'households/%'
    );

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_evidence_photo_path,
  ADD CONSTRAINT chk_expense_plans_evidence_photo_path
    CHECK (
      evidence_photo_path IS NULL
      OR evidence_photo_path LIKE 'households/%'
    );

COMMENT ON COLUMN public.expenses.evidence_photo_path IS
  'Optional evidence image path for the bill. Must start with households/ when present.';

COMMENT ON COLUMN public.expense_plans.evidence_photo_path IS
  'Optional default evidence image path copied to generated recurring cycle expenses.';

-- ---------------------------------------------------------------------
-- 2) Quota helpers: add expense_photos support
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._home_assert_quota(
  p_home_id uuid,
  p_deltas  jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan       text;
  v_is_premium boolean;
  v_counters   public.home_usage_counters%ROWTYPE;

  v_metric_key   text;
  v_metric_enum  public.home_usage_metric;
  v_raw_value    jsonb;
  v_delta        integer;
  v_current      integer;
  v_new          integer;
  v_max          integer;
BEGIN
  v_plan := public._home_effective_plan(p_home_id);

  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  IF p_deltas IS NULL OR jsonb_typeof(p_deltas) <> 'object' THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_counters
  FROM public.home_usage_counters
  WHERE home_id = p_home_id;

  IF NOT FOUND THEN
    v_counters.active_chores        := 0;
    v_counters.chore_photos         := 0;
    v_counters.active_members       := 0;
    v_counters.active_expenses      := 0;
    v_counters.shopping_item_photos := 0;
    v_counters.expense_photos       := 0;
  END IF;

  FOR v_metric_key, v_raw_value IN
    SELECT key, value FROM jsonb_each(p_deltas)
  LOOP
    BEGIN
      v_metric_enum := v_metric_key::public.home_usage_metric;
    EXCEPTION WHEN invalid_text_representation THEN
      CONTINUE;
    END;

    IF jsonb_typeof(v_raw_value) <> 'number' THEN
      PERFORM public.api_error(
        'INVALID_QUOTA_DELTA',
        'Quota delta must be numeric.',
        '22023',
        jsonb_build_object('metric', v_metric_key, 'value', v_raw_value)
      );
    END IF;

    v_delta := (v_raw_value #>> '{}')::integer;
    IF COALESCE(v_delta, 0) <= 0 THEN
      CONTINUE;
    END IF;

    SELECT max_value
    INTO v_max
    FROM public.home_plan_limits
    WHERE plan = v_plan
      AND metric = v_metric_enum;

    IF v_max IS NULL THEN
      CONTINUE;
    END IF;

    v_current := CASE v_metric_enum
      WHEN 'active_chores'        THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'         THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members'       THEN COALESCE(v_counters.active_members, 0)
      WHEN 'active_expenses'      THEN COALESCE(v_counters.active_expenses, 0)
      WHEN 'shopping_item_photos' THEN COALESCE(v_counters.shopping_item_photos, 0)
      WHEN 'expense_photos'       THEN COALESCE(v_counters.expense_photos, 0)
    END;

    v_new := GREATEST(0, v_current + v_delta);

    IF v_new > v_max THEN
      PERFORM public.api_error(
        'PAYWALL_LIMIT_' || upper(v_metric_key),
        format('Free plan allows up to %s %s per home.', v_max, v_metric_key),
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

REVOKE ALL ON FUNCTION public._home_assert_quota(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._home_usage_apply_delta(
  p_home_id uuid,
  p_deltas  jsonb
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row                         public.home_usage_counters;
  v_home_active                 boolean;

  v_active_chores_delta         integer := 0;
  v_chore_photos_delta          integer := 0;
  v_active_members_delta        integer := 0;
  v_active_expenses_delta       integer := 0;
  v_shopping_item_photos_delta  integer := 0;
  v_expense_photos_delta        integer := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Home not found.',
      'P0002',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

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

    IF jsonb_typeof(p_deltas->'active_expenses') = 'number' THEN
      v_active_expenses_delta := (p_deltas->>'active_expenses')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'shopping_item_photos') = 'number' THEN
      v_shopping_item_photos_delta := (p_deltas->>'shopping_item_photos')::integer;
    END IF;

    IF jsonb_typeof(p_deltas->'expense_photos') = 'number' THEN
      v_expense_photos_delta := (p_deltas->>'expense_photos')::integer;
    END IF;
  END IF;

  UPDATE public.home_usage_counters h
     SET active_chores        = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
         chore_photos         = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
         active_members       = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
         active_expenses      = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
         shopping_item_photos = GREATEST(0, COALESCE(h.shopping_item_photos, 0) + v_shopping_item_photos_delta),
         expense_photos       = GREATEST(0, COALESCE(h.expense_photos, 0) + v_expense_photos_delta),
         updated_at           = now()
   WHERE h.home_id = p_home_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._home_usage_apply_delta(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Membership-change plan termination: decrement expense_photos once
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._expense_plans_terminate_for_member_change(
  p_home_id uuid,
  p_affected_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    WITH terminated AS (
      UPDATE public.expense_plans ep
         SET status = 'terminated',
             terminated_at = now(),
             updated_at = now()
       WHERE ep.home_id = p_home_id
         AND ep.status = 'active'
         AND (
           ep.created_by_user_id = p_affected_user_id
           OR EXISTS (
             SELECT 1
               FROM public.expense_plan_debtors d
              WHERE d.plan_id = ep.id
                AND d.debtor_user_id = p_affected_user_id
           )
         )
      RETURNING ep.home_id, ep.evidence_photo_path
    )
    SELECT
      t.home_id,
      COUNT(*) FILTER (WHERE t.evidence_photo_path IS NOT NULL)::int AS dec_expense_photos
    FROM terminated t
    GROUP BY t.home_id
  LOOP
    IF COALESCE(r.dec_expense_photos, 0) > 0 THEN
      PERFORM public._home_usage_apply_delta(
        r.home_id,
        jsonb_build_object('expense_photos', -r.dec_expense_photos)
      );
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plans_terminate_for_member_change(uuid, uuid)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) Cycle generation: copy plan evidence photo to cycle expense
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._expense_plan_generate_cycle(
  p_plan_id    uuid,
  p_cycle_date date
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan_unsafe  public.expense_plans%ROWTYPE;
  v_plan         public.expense_plans%ROWTYPE;
  v_home_active  boolean;
  v_expense      public.expenses%ROWTYPE;
BEGIN
  IF p_plan_id IS NULL OR p_cycle_date IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id and cycle date are required.', '22023');
  END IF;

  SELECT *
    INTO v_plan_unsafe
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = v_plan_unsafe.home_id
   FOR UPDATE;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  SELECT *
    INTO v_plan
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id
   FOR UPDATE;

  IF v_plan.home_id <> v_plan_unsafe.home_id THEN
    PERFORM public.api_error(
      'CONCURRENT_MODIFICATION',
      'Plan changed while generating cycle; retry.',
      '40001',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_plan.status <> 'active' THEN
    PERFORM public.api_error(
      'PLAN_NOT_ACTIVE',
      'Cannot generate cycles for a terminated plan.',
      'P0004',
      jsonb_build_object('planId', p_plan_id, 'status', v_plan.status)
    );
  END IF;

  BEGIN
    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      evidence_photo_path,
      plan_id,
      recurrence_interval,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_plan.home_id,
      v_plan.created_by_user_id,
      'active',
      v_plan.split_type,
      v_plan.amount_cents,
      v_plan.description,
      v_plan.notes,
      v_plan.evidence_photo_path,
      v_plan.id,
      v_plan.recurrence_interval,
      v_plan.recurrence_every,
      v_plan.recurrence_unit,
      p_cycle_date
    )
    RETURNING * INTO v_expense;

  EXCEPTION WHEN unique_violation THEN
    SELECT *
      INTO v_expense
      FROM public.expenses e
     WHERE e.plan_id = v_plan.id
       AND e.start_date = p_cycle_date
     LIMIT 1;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'STATE_CHANGED_RETRY',
        'Cycle already exists but could not be read; retry.',
        '40001',
        jsonb_build_object('planId', v_plan.id, 'cycleDate', p_cycle_date)
      );
    END IF;

    RETURN v_expense;
  END;

  INSERT INTO public.expense_splits (
    expense_id,
    debtor_user_id,
    amount_cents,
    status,
    marked_paid_at
  )
  SELECT
    v_expense.id,
    d.debtor_user_id,
    d.share_amount_cents,
    CASE
      WHEN d.debtor_user_id = v_plan.created_by_user_id
        THEN 'paid'::public.expense_share_status
      ELSE 'unpaid'::public.expense_share_status
    END,
    CASE
      WHEN d.debtor_user_id = v_plan.created_by_user_id
        THEN now()
      ELSE NULL
    END
  FROM public.expense_plan_debtors d
  WHERE d.plan_id = v_plan.id;

  PERFORM public._home_usage_apply_delta(
    v_plan.home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plan_generate_cycle(uuid, date)
FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) expenses_create_v3: add p_evidence_photo_path + quota semantics
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.expenses_create_v3(
  p_home_id          uuid,
  p_description      text,
  p_amount_cents     bigint DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT current_date,
  p_evidence_photo_path text DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_home_id        uuid := p_home_id;
  v_home_is_active boolean;

  v_result         public.expenses%ROWTYPE;
  v_plan           public.expense_plans%ROWTYPE;

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;
  v_is_recurring   boolean := FALSE;

  v_recur_every    integer := p_recurrence_every;
  v_recur_unit     text := p_recurrence_unit;

  v_split_count    integer := 0;
  v_split_sum      bigint  := 0;
  v_split_min      bigint  := 0;

  v_join_date      date;

  v_evidence_photo_path text := NULLIF(btrim(p_evidence_photo_path), '');
  v_photo_delta integer := 0;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_start_date IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF v_evidence_photo_path IS NOT NULL
     AND v_evidence_photo_path NOT LIKE 'households/%' THEN
    PERFORM public.api_error(
      'INVALID_EVIDENCE_PHOTO_PATH',
      'Evidence photo path must start with households/.',
      '22023',
      jsonb_build_object('field', 'evidencePhotoPath')
    );
  END IF;

  v_is_recurring := p_recurrence_every IS NOT NULL;

  IF v_is_recurring THEN
    IF p_recurrence_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF p_recurrence_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      format('Description must be %s characters or fewer.', v_desc_max),
      '22023'
    );
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error(
      'INVALID_NOTES',
      format('Notes must be %s characters or fewer.', v_notes_max),
      '22023'
    );
  END IF;

  IF p_split_mode IS NULL THEN
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    IF p_amount_cents IS NOT NULL THEN
      IF p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
        PERFORM public.api_error(
          'INVALID_AMOUNT',
          format('Amount must be between 1 and %s cents when provided.', v_amount_cap),
          '22023',
          jsonb_build_object('amountCents', p_amount_cents)
        );
      END IF;
    END IF;

    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;

    IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023'
      );
    END IF;
  END IF;

  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id, 'userId', v_user)
    );
  END IF;

  IF p_start_date < v_join_date OR p_start_date < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  p_start_date
      )
    );
  END IF;

  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );

    SELECT COUNT(*)::int,
           COALESCE(SUM(amount_cents), 0),
           COALESCE(MIN(amount_cents), 0)
      INTO v_split_count, v_split_sum, v_split_min
      FROM pg_temp.expense_split_buffer;

    IF v_split_count < 1 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
    END IF;

    IF v_split_min <= 0 THEN
      PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
    END IF;

    IF v_split_sum <> p_amount_cents THEN
      PERFORM public.api_error(
        'INVALID_SPLITS_SUM',
        'Split amounts must sum to the expense amount.',
        '22023',
        jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
      );
    END IF;
  END IF;

  IF NOT v_is_recurring THEN
    v_photo_delta := CASE
      WHEN v_new_status = 'active' AND v_evidence_photo_path IS NOT NULL THEN 1
      ELSE 0
    END;

    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(
        v_home_id,
        jsonb_build_object(
          'active_expenses', 1,
          'expense_photos', v_photo_delta
        )
      );
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      evidence_photo_path,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_home_id,
      v_user,
      v_new_status,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_evidence_photo_path,
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    IF v_has_splits THEN
      INSERT INTO public.expense_splits (
        expense_id,
        debtor_user_id,
        amount_cents,
        status,
        marked_paid_at
      )
      SELECT v_result.id,
             debtor_user_id,
             amount_cents,
             CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
                  ELSE 'unpaid'::public.expense_share_status
             END,
             CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
        FROM pg_temp.expense_split_buffer;
    END IF;

    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(
        v_home_id,
        jsonb_build_object(
          'active_expenses', 1,
          'expense_photos', v_photo_delta
        )
      );
    END IF;

    RETURN v_result;
  END IF;

  v_photo_delta := CASE WHEN v_evidence_photo_path IS NOT NULL THEN 1 ELSE 0 END;

  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', v_photo_delta
    )
  );

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
    evidence_photo_path,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status
  )
  VALUES (
    v_home_id,
    v_user,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    v_evidence_photo_path,
    v_recur_every,
    v_recur_unit,
    p_start_date,
    public._expense_plan_next_cycle_date_v2(v_recur_every, v_recur_unit, p_start_date),
    'active'
  )
  RETURNING * INTO v_plan;

  INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
  SELECT v_plan.id, debtor_user_id, amount_cents
    FROM pg_temp.expense_split_buffer;

  IF v_photo_delta > 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_home_id,
      jsonb_build_object('expense_photos', 1)
    );
  END IF;

  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create_v3(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create_v3(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date, text
) TO authenticated;

-- ---------------------------------------------------------------------
-- 6) expenses_edit_v3: evidence photo flow + quota semantics
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.expenses_edit_v3(
  p_expense_id       uuid,
  p_amount_cents     bigint,
  p_description      text,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT NULL,
  p_evidence_photo_path text DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user            uuid := auth.uid();

  v_existing_unsafe public.expenses%ROWTYPE;
  v_existing        public.expenses%ROWTYPE;

  v_result          public.expenses%ROWTYPE;
  v_plan            public.expense_plans%ROWTYPE;

  v_home_is_active  boolean;

  v_target_split       public.expense_split_type;
  v_target_recur_every integer;
  v_target_recur_unit  text;
  v_target_start       date;
  v_is_recurring       boolean := FALSE;

  v_split_count     integer := 0;
  v_split_sum       bigint  := 0;
  v_split_min       bigint  := 0;

  v_join_date       date;

  v_has_evidence_arg boolean := p_evidence_photo_path IS NOT NULL;
  v_requested_evidence_path text := NULLIF(btrim(p_evidence_photo_path), '');
  v_target_evidence_path text;
  v_photo_delta integer := 0;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  IF v_requested_evidence_path IS NOT NULL
     AND v_requested_evidence_path NOT LIKE 'households/%' THEN
    PERFORM public.api_error(
      'INVALID_EVIDENCE_PHOTO_PATH',
      'Evidence photo path must start with households/.',
      '22023',
      jsonb_build_object('field', 'evidencePhotoPath')
    );
  END IF;

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  SELECT m.valid_from::date
    INTO v_join_date
    FROM public.memberships m
   WHERE m.home_id    = v_existing.home_id
     AND m.user_id    = v_user
     AND m.is_current = TRUE
     AND m.valid_to IS NULL
   LIMIT 1;

  IF v_join_date IS NULL THEN
    PERFORM public.api_error('NOT_HOME_MEMBER', 'You are not a current member of this home.', '42501',
      jsonb_build_object('homeId', v_existing.home_id, 'userId', v_user)
    );
  END IF;

  IF v_existing.plan_id IS NOT NULL THEN
    PERFORM public.api_error('IMMUTABLE_CYCLE', 'Expenses generated from a recurring plan cannot be edited.', '42501');
  END IF;

  IF v_existing.status = 'active' THEN
    IF v_existing.created_by_user_id <> v_user THEN
      PERFORM public.api_error(
        'NOT_CREATOR',
        'Only the creator can edit this active expense.',
        '42501'
      );
    END IF;

    IF p_amount_cents IS DISTINCT FROM v_existing.amount_cents THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Amount is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'amountCents', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_split_mode IS NOT NULL AND p_split_mode IS DISTINCT FROM v_existing.split_type THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Split mode is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'splitMode', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_member_ids IS NOT NULL OR p_splits IS NOT NULL THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Splits are immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'splits', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_recurrence_every IS NOT NULL OR p_recurrence_unit IS NOT NULL THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Recurrence is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'recurrence', 'expenseId', v_existing.id)
      );
    END IF;

    IF p_start_date IS NOT NULL AND p_start_date IS DISTINCT FROM v_existing.start_date THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Start date is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'startDate', 'expenseId', v_existing.id)
      );
    END IF;

    IF v_has_evidence_arg
       AND v_requested_evidence_path IS DISTINCT FROM v_existing.evidence_photo_path THEN
      PERFORM public.api_error(
        'EDIT_NOT_ALLOWED',
        'Evidence photo is immutable for active expenses.',
        '42501',
        jsonb_build_object('field', 'evidencePhotoPath', 'expenseId', v_existing.id)
      );
    END IF;

    IF btrim(COALESCE(p_description, '')) = '' THEN
      PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
    END IF;

    IF char_length(btrim(p_description)) > v_desc_max THEN
      PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
    END IF;

    IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
      PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
    END IF;

    UPDATE public.expenses
       SET description = btrim(p_description),
           notes = NULLIF(btrim(p_notes), ''),
           updated_at = now()
     WHERE id = v_existing.id
     RETURNING * INTO v_result;

    RETURN v_result;
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error('INVALID_AMOUNT', format('Amount must be between 1 and %s cents.', v_amount_cap), '22023');
  END IF;

  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', 'Description is required.', '22023');
  END IF;

  IF char_length(btrim(p_description)) > v_desc_max THEN
    PERFORM public.api_error('INVALID_DESCRIPTION', format('Description must be %s characters or fewer.', v_desc_max), '22023');
  END IF;

  IF p_notes IS NOT NULL AND char_length(p_notes) > v_notes_max THEN
    PERFORM public.api_error('INVALID_NOTES', format('Notes must be %s characters or fewer.', v_notes_max), '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Splits are required. Editing an expense always activates it.', '22023');
  END IF;

  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF v_has_evidence_arg THEN
    v_target_evidence_path := v_requested_evidence_path;
  ELSE
    v_target_evidence_path := v_existing.evidence_photo_path;
  END IF;

  v_target_split := p_split_mode;
  v_target_recur_every := p_recurrence_every;
  v_target_recur_unit := p_recurrence_unit;
  v_is_recurring := v_target_recur_every IS NOT NULL;

  IF v_is_recurring THEN
    IF v_target_recur_every < 1 THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence every must be >= 1.',
        '22023'
      );
    END IF;

    IF v_target_recur_unit NOT IN ('day', 'week', 'month', 'year') THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE',
        'Recurrence unit must be day, week, month, or year.',
        '22023'
      );
    END IF;
  END IF;

  v_target_start := COALESCE(p_start_date, v_existing.start_date);

  IF v_target_start IS NULL THEN
    PERFORM public.api_error('INVALID_START_DATE', 'Start date is required.', '22023');
  END IF;

  IF v_target_start < v_join_date OR v_target_start < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate',        GREATEST(v_join_date, current_date - 90),
        'joinDate',            v_join_date,
        'maxBackdateDays',     90,
        'attemptedStartDate',  v_target_start
      )
    );
  END IF;

  PERFORM public._expenses_prepare_split_buffer(
    v_existing.home_id,
    v_user,
    p_amount_cents,
    v_target_split,
    p_member_ids,
    p_splits
  );

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COALESCE(MIN(amount_cents), 0)
    INTO v_split_count, v_split_sum, v_split_min
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 1 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;

  IF v_is_recurring THEN
    v_photo_delta := CASE WHEN v_target_evidence_path IS NOT NULL THEN 1 ELSE 0 END;

    PERFORM public._home_assert_quota(
      v_existing.home_id,
      jsonb_build_object(
        'active_expenses', 1,
        'expense_photos', v_photo_delta
      )
    );

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
      evidence_photo_path,
      recurrence_every,
      recurrence_unit,
      start_date,
      next_cycle_date,
      status
    )
    VALUES (
      v_existing.home_id,
      v_user,
      v_target_split,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_target_evidence_path,
      v_target_recur_every,
      v_target_recur_unit,
      v_target_start,
      public._expense_plan_next_cycle_date_v2(v_target_recur_every, v_target_recur_unit, v_target_start),
      'active'
    )
    RETURNING * INTO v_plan;

    INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
    SELECT v_plan.id, debtor_user_id, amount_cents
      FROM pg_temp.expense_split_buffer;

    UPDATE public.expenses
       SET status              = 'converted',
           plan_id             = v_plan.id,
           recurrence_every    = v_target_recur_every,
           recurrence_unit     = v_target_recur_unit,
           evidence_photo_path = v_target_evidence_path,
           start_date          = v_target_start,
           updated_at          = now()
     WHERE id = v_existing.id;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_usage_apply_delta(
        v_existing.home_id,
        jsonb_build_object('expense_photos', 1)
      );
    END IF;

    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  v_photo_delta := CASE WHEN v_target_evidence_path IS NOT NULL THEN 1 ELSE 0 END;

  PERFORM public._home_assert_quota(
    v_existing.home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', v_photo_delta
    )
  );

  UPDATE public.expenses
     SET status              = 'active',
         split_type          = v_target_split,
         amount_cents        = p_amount_cents,
         description         = btrim(p_description),
         notes               = NULLIF(btrim(p_notes), ''),
         evidence_photo_path = v_target_evidence_path,
         recurrence_every    = NULL,
         recurrence_unit     = NULL,
         start_date          = v_target_start,
         updated_at          = now()
   WHERE id = v_existing.id
   RETURNING * INTO v_result;

  INSERT INTO public.expense_splits (
    expense_id,
    debtor_user_id,
    amount_cents,
    status,
    marked_paid_at
  )
  SELECT v_result.id,
         debtor_user_id,
         amount_cents,
         CASE WHEN debtor_user_id = v_user THEN 'paid'::public.expense_share_status
              ELSE 'unpaid'::public.expense_share_status
         END,
         CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;

  PERFORM public._home_usage_apply_delta(
    v_existing.home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', v_photo_delta
    )
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_edit_v3(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_edit_v3(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date, text
) TO authenticated;

-- ---------------------------------------------------------------------
-- 7) expenses_get_for_edit: include evidencePhotoPath
-- ---------------------------------------------------------------------
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
  v_plan_status        public.expense_plan_status;
  v_splits             jsonb := '[]'::jsonb;
  v_can_edit           boolean := FALSE;
  v_edit_disabled      text := NULL;
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

  v_can_edit := (
    v_expense.status = 'draft'::public.expense_status
    OR (
      v_expense.status = 'active'::public.expense_status
      AND v_expense.plan_id IS NULL
    )
  );

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
    'evidencePhotoPath',  v_expense.evidence_photo_path,
    'createdAt',          v_expense.created_at,
    'updatedAt',          v_expense.updated_at,
    'planId',             v_expense.plan_id,
    'planStatus',         v_plan_status,
    'recurrenceEvery',    v_expense.recurrence_every,
    'recurrenceUnit',     v_expense.recurrence_unit,
    'startDate',          v_expense.start_date,
    'canEdit',            v_can_edit,
    'editDisabledReason', v_edit_disabled,
    'splits',             v_splits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_for_edit(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_get_for_edit(uuid)
TO authenticated;

-- ---------------------------------------------------------------------
-- 8) Expense payloads: surface evidencePhotoPath
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_get_current_owed(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user   uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'payerUserId',     payer_user_id,
               'payerDisplay',    payer_display,
               'payerAvatarUrl',  payer_avatar_url,
               'totalOwedCents',  total_owed_cents,
               'items',           items
             )
             ORDER BY payer_display NULLS LAST, payer_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.created_by_user_id                          AS payer_user_id,
      COALESCE(p.username, p.full_name, p.email)    AS payer_display,
      a.storage_path                                AS payer_avatar_url,
      SUM(s.amount_cents)                           AS total_owed_cents,
      jsonb_agg(
        jsonb_build_object(
          'expenseId',         e.id,
          'description',       e.description,
          'amountCents',       s.amount_cents,
          'notes',             e.notes,
          'evidencePhotoPath', e.evidence_photo_path,
          'recurrenceEvery',   e.recurrence_every,
          'recurrenceUnit',    e.recurrence_unit,
          'startDate',         e.start_date
        )
        ORDER BY e.created_at DESC, e.id
      ) AS items
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.profiles p
      ON p.id = e.created_by_user_id
    JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE e.home_id        = p_home_id
      AND e.status         = 'active'
      AND s.debtor_user_id = v_user
      AND s.status         = 'unpaid'
    GROUP BY e.created_by_user_id, payer_display, payer_avatar_url
  ) owed;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.expenses_get_created_by_me(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_result         jsonb;
  v_home_is_active boolean;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = p_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id, 'userId', v_user)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = p_home_id;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',         e.id,
               'homeId',            e.home_id,
               'createdByUserId',   e.created_by_user_id,
               'description',       e.description,
               'amountCents',       e.amount_cents,
               'status',            e.status,
               'splitType',         e.split_type,
               'evidencePhotoPath', e.evidence_photo_path,
               'createdAt',         e.created_at,
               'recurrenceEvery',   e.recurrence_every,
               'recurrenceUnit',    e.recurrence_unit,
               'startDate',         e.start_date,
               'totalShares',       COALESCE(stats.total_shares, 0)::int,
               'paidShares',        COALESCE(stats.paid_shares, 0)::int,
               'paidAmountCents',   COALESCE(stats.paid_amount_cents, 0),
               'allPaid',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN FALSE
                   ELSE COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                 END,
               'fullyPaidAt',
                 CASE
                   WHEN COALESCE(stats.total_shares, 0) = 0 THEN NULL
                   WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                     THEN stats.max_paid_at
                   ELSE NULL
                 END
             )
             ORDER BY
               CASE
                 WHEN COALESCE(stats.total_shares, 0) = 0 THEN 0
                 WHEN COALESCE(stats.paid_shares, 0) = 0 THEN 0
                 WHEN COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
                   THEN 2
                 ELSE 1
               END,
               e.created_at DESC,
               e.id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM public.expenses e
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) AS total_shares,
        COUNT(*) FILTER (WHERE s.status = 'paid') AS paid_shares,
        COALESCE(
          SUM(s.amount_cents) FILTER (WHERE s.status = 'paid'),
          0
        ) AS paid_amount_cents,
        MAX(s.marked_paid_at) FILTER (WHERE s.status = 'paid') AS max_paid_at
      FROM public.expense_splits s
      WHERE s.expense_id = e.id
    ) stats ON TRUE
  WHERE e.home_id            = p_home_id
    AND e.created_by_user_id = v_user
    AND e.status IN ('draft', 'active')
    AND NOT (
      COALESCE(stats.total_shares, 0) > 0
      AND COALESCE(stats.total_shares, 0) = COALESCE(stats.paid_shares, 0)
      AND e.created_at < (CURRENT_TIMESTAMP - INTERVAL '14 days')
    );

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------
-- 9) pay-my-due: decrement one-off expense_photos on first fully-paid
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_pay_my_due(
  p_recipient_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user                 uuid := auth.uid();
  v_split_count          integer := 0;
  v_expense_count        integer := 0;
  v_newly_fully_paid_cnt integer := 0;
  v_touched_count        integer := 0;
  v_newly_photo_cnt      integer := 0;
  r                      record;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_recipient_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_RECIPIENT',
      'Recipient (expense creator) is required.',
      '22023'
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_touched (
    expense_id uuid PRIMARY KEY
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_touched;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expenses_newly_paid (
    home_id uuid NOT NULL,
    expense_photo_dec integer NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE TABLE pg_temp.expenses_newly_paid;

  WITH target_expenses AS (
    SELECT DISTINCT e.id, e.home_id
      FROM public.expense_splits s
      JOIN public.expenses e ON e.id = s.expense_id
      JOIN public.homes h ON h.id = e.home_id
      JOIN public.memberships m
        ON m.home_id    = e.home_id
       AND m.user_id    = v_user
       AND m.is_current = TRUE
       AND m.valid_to IS NULL
     WHERE s.debtor_user_id = v_user
       AND s.status = 'unpaid'
       AND e.status = 'active'
       AND e.created_by_user_id = p_recipient_user_id
       AND h.is_active = TRUE
  ),
  locked_homes AS (
    SELECT h.id
      FROM public.homes h
     WHERE h.id IN (SELECT home_id FROM target_expenses)
     ORDER BY h.id
     FOR UPDATE
  ),
  locked_expenses AS (
    SELECT e.id, e.home_id
      FROM public.expenses e
      JOIN locked_homes lh ON lh.id = e.home_id
      JOIN public.homes h ON h.id = e.home_id
     WHERE e.id IN (SELECT id FROM target_expenses)
       AND e.status = 'active'
       AND h.is_active = TRUE
     ORDER BY e.id
     FOR UPDATE
  ),
  updated AS (
    UPDATE public.expense_splits s
       SET status              = 'paid',
           marked_paid_at      = now(),
           recipient_viewed_at = NULL
     WHERE s.debtor_user_id = v_user
       AND s.expense_id IN (SELECT id FROM locked_expenses)
       AND s.status = 'unpaid'
    RETURNING s.expense_id
  ),
  aggregates AS (
    SELECT
      COUNT(*)::int AS split_count,
      COUNT(DISTINCT expense_id)::int AS expense_count
    FROM updated
  ),
  inserted AS (
    INSERT INTO pg_temp.expenses_touched (expense_id)
    SELECT DISTINCT expense_id FROM updated
    RETURNING 1
  )
  SELECT
    COALESCE(a.split_count, 0),
    COALESCE(a.expense_count, 0),
    COALESCE((SELECT COUNT(*) FROM inserted), 0)
  INTO
    v_split_count,
    v_expense_count,
    v_touched_count
  FROM aggregates a;

  WITH newly_paid AS (
    UPDATE public.expenses e
       SET fully_paid_at = now()
     WHERE e.id IN (SELECT expense_id FROM pg_temp.expenses_touched)
       AND e.fully_paid_at IS NULL
       AND NOT EXISTS (
         SELECT 1
           FROM public.expense_splits s
          WHERE s.expense_id = e.id
            AND s.status = 'unpaid'
       )
    RETURNING
      e.home_id,
      CASE
        WHEN e.plan_id IS NULL AND e.evidence_photo_path IS NOT NULL THEN 1
        ELSE 0
      END AS expense_photo_dec
  )
  INSERT INTO pg_temp.expenses_newly_paid (home_id, expense_photo_dec)
  SELECT home_id, expense_photo_dec FROM newly_paid;

  SELECT
    COUNT(*)::int,
    COALESCE(SUM(expense_photo_dec), 0)::int
    INTO v_newly_fully_paid_cnt, v_newly_photo_cnt
    FROM pg_temp.expenses_newly_paid;

  FOR r IN
    SELECT
      home_id,
      COUNT(*)::int AS dec_count,
      COALESCE(SUM(expense_photo_dec), 0)::int AS dec_expense_photo_count
    FROM pg_temp.expenses_newly_paid
    GROUP BY home_id
  LOOP
    PERFORM public._home_usage_apply_delta(
      r.home_id,
      jsonb_build_object(
        'active_expenses', -r.dec_count,
        'expense_photos',  -r.dec_expense_photo_count
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'recipientUserId',          p_recipient_user_id,
    'splitsPaid',               v_split_count,
    'expensesTouched',          v_expense_count,
    'expensesNewlyFullyPaid',   v_newly_fully_paid_cnt,
    'expensePhotosFreed',       v_newly_photo_cnt
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_pay_my_due(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_pay_my_due(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 10) plan terminate: decrement expense_photos once on first transition
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expense_plans_terminate(
  p_plan_id uuid
)
RETURNS public.expense_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user  uuid := auth.uid();
  v_plan  public.expense_plans%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_plan_id IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id is required.', '22023');
  END IF;

  SELECT *
    INTO v_plan
    FROM public.expense_plans ep
   WHERE ep.id = p_plan_id
   FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_plan.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the plan creator can terminate this plan.',
      '42501'
    );
  END IF;

  PERFORM public._assert_home_member(v_plan.home_id);
  PERFORM public._assert_home_active(v_plan.home_id);

  IF v_plan.status = 'terminated' THEN
    RETURN v_plan;
  END IF;

  UPDATE public.expense_plans
     SET status        = 'terminated',
         terminated_at = now(),
         updated_at    = now()
   WHERE id = p_plan_id
  RETURNING * INTO v_plan;

  IF v_plan.evidence_photo_path IS NOT NULL THEN
    PERFORM public._home_usage_apply_delta(
      v_plan.home_id,
      jsonb_build_object('expense_photos', -1)
    );
  END IF;

  RETURN v_plan;
END;
$$;

REVOKE ALL ON FUNCTION public.expense_plans_terminate(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expense_plans_terminate(uuid)
TO authenticated;

-- ---------------------------------------------------------------------
-- 11) cancel: free active_expenses only for active rows + one-off photo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_cancel(
  p_expense_id uuid
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_expense        public.expenses%ROWTYPE;
  v_home_is_active boolean;
  v_has_paid       boolean := FALSE;
  v_was_active     boolean := FALSE;
  v_photo_delta    integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  SELECT *
  INTO v_expense
  FROM public.expenses e
  WHERE e.id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error(
      'NOT_CREATOR',
      'Only the creator can cancel this expense.',
      '42501',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_expense.status = 'cancelled' THEN
    RETURN v_expense;
  END IF;

  IF v_expense.status NOT IN ('draft', 'active') THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Only draft or active expenses can be cancelled.',
      'P0003'
    );
  END IF;

  v_was_active := (v_expense.status = 'active');

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_expense.home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_expense.home_id)
    );
  END IF;

  SELECT h.is_active
  INTO v_home_is_active
  FROM public.homes h
  WHERE h.id = v_expense.home_id
  FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004'
    );
  END IF;

  PERFORM 1
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id
  FOR UPDATE;

  SELECT EXISTS (
    SELECT 1
    FROM public.expense_splits s
    WHERE s.expense_id = v_expense.id
      AND s.status     = 'paid'
      AND s.debtor_user_id <> v_expense.created_by_user_id
  )
  INTO v_has_paid;

  IF v_has_paid THEN
    PERFORM public.api_error(
      'EXPENSE_LOCKED_AFTER_PAYMENT',
      'Expenses with paid shares cannot be cancelled.',
      'P0004',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  UPDATE public.expenses
  SET status     = 'cancelled',
      updated_at = now()
  WHERE id = v_expense.id
  RETURNING * INTO v_expense;

  IF v_was_active THEN
    IF v_expense.plan_id IS NULL
       AND v_expense.evidence_photo_path IS NOT NULL
       AND v_expense.fully_paid_at IS NULL THEN
      v_photo_delta := -1;
    END IF;

    PERFORM public._home_usage_apply_delta(
      v_expense.home_id,
      jsonb_build_object(
        'active_expenses', -1,
        'expense_photos', v_photo_delta
      )
    );
  END IF;

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_cancel(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_cancel(uuid)
TO authenticated;
