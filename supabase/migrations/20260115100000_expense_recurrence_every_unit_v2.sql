-- Recurrence refactor v2: add recurrence_every/unit, backfill, constraints, and v2 RPCs.

-- =====================================================================
-- Schema: new recurrence columns
-- =====================================================================
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS recurrence_every integer,
  ADD COLUMN IF NOT EXISTS recurrence_unit text;

ALTER TABLE public.expense_plans
  ADD COLUMN IF NOT EXISTS recurrence_every integer,
  ADD COLUMN IF NOT EXISTS recurrence_unit text;

-- =====================================================================
-- Backfill from legacy recurrence_interval
-- =====================================================================
UPDATE public.expense_plans
   SET recurrence_every = CASE recurrence_interval
                            WHEN 'weekly' THEN 1
                            WHEN 'every_2_weeks' THEN 2
                            WHEN 'monthly' THEN 1
                            WHEN 'every_2_months' THEN 2
                            WHEN 'annual' THEN 1
                            ELSE recurrence_every
                          END,
       recurrence_unit  = CASE recurrence_interval
                            WHEN 'weekly' THEN 'week'
                            WHEN 'every_2_weeks' THEN 'week'
                            WHEN 'monthly' THEN 'month'
                            WHEN 'every_2_months' THEN 'month'
                            WHEN 'annual' THEN 'year'
                            ELSE recurrence_unit
                          END
 WHERE recurrence_every IS NULL
   AND recurrence_unit IS NULL;

UPDATE public.expenses
   SET recurrence_every = CASE recurrence_interval
                            WHEN 'weekly' THEN 1
                            WHEN 'every_2_weeks' THEN 2
                            WHEN 'monthly' THEN 1
                            WHEN 'every_2_months' THEN 2
                            WHEN 'annual' THEN 1
                            ELSE recurrence_every
                          END,
       recurrence_unit  = CASE recurrence_interval
                            WHEN 'weekly' THEN 'week'
                            WHEN 'every_2_weeks' THEN 'week'
                            WHEN 'monthly' THEN 'month'
                            WHEN 'every_2_months' THEN 'month'
                            WHEN 'annual' THEN 'year'
                            ELSE recurrence_unit
                          END
 WHERE recurrence_interval <> 'none'
   AND recurrence_every IS NULL
   AND recurrence_unit IS NULL;

-- =====================================================================
-- Legacy column loosening (prepare for drop)
-- =====================================================================
ALTER TABLE public.expenses
  ALTER COLUMN recurrence_interval DROP NOT NULL,
  ALTER COLUMN recurrence_interval DROP DEFAULT;

ALTER TABLE public.expense_plans
  ALTER COLUMN recurrence_interval DROP NOT NULL;
-- =====================================================================
-- Constraints: expenses (paired nullability + units)
-- =====================================================================
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_recurrence_pair,
  ADD CONSTRAINT chk_expenses_recurrence_pair
    CHECK (
      (recurrence_every IS NULL AND recurrence_unit IS NULL)
      OR (recurrence_every IS NOT NULL AND recurrence_unit IS NOT NULL)
    );

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_recurrence_every_min,
  ADD CONSTRAINT chk_expenses_recurrence_every_min
    CHECK (recurrence_every IS NULL OR recurrence_every >= 1);

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_recurrence_unit_allowed,
  ADD CONSTRAINT chk_expenses_recurrence_unit_allowed
    CHECK (recurrence_unit IS NULL OR recurrence_unit IN ('day', 'week', 'month', 'year'));

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_plan_alignment,
  ADD CONSTRAINT chk_expenses_plan_alignment
    CHECK (
      (recurrence_every IS NULL AND recurrence_unit IS NULL AND plan_id IS NULL)
      OR (recurrence_every IS NOT NULL AND recurrence_unit IS NOT NULL AND plan_id IS NOT NULL)
    );

-- =====================================================================
-- Constraints: expense_plans (non-null recurrence + allowed units)
-- =====================================================================
ALTER TABLE public.expense_plans
  ALTER COLUMN recurrence_every SET NOT NULL,
  ALTER COLUMN recurrence_unit SET NOT NULL;

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_recurrence_non_none,
  DROP CONSTRAINT IF EXISTS chk_expense_plans_recurrence_every_min,
  ADD CONSTRAINT chk_expense_plans_recurrence_every_min
    CHECK (recurrence_every >= 1);

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_recurrence_unit_allowed,
  ADD CONSTRAINT chk_expense_plans_recurrence_unit_allowed
    CHECK (recurrence_unit IN ('day', 'week', 'month', 'year'));

COMMENT ON COLUMN public.expenses.recurrence_every IS
  'Recurring interval count; NULL for one-off expenses.';
COMMENT ON COLUMN public.expenses.recurrence_unit IS
  'Recurring interval unit (day|week|month|year); NULL for one-off expenses.';
COMMENT ON COLUMN public.expense_plans.recurrence_every IS
  'Recurring interval count (>= 1).';
COMMENT ON COLUMN public.expense_plans.recurrence_unit IS
  'Recurring interval unit (day|week|month|year).';

-- =====================================================================
-- Helper: next cycle date for v2 recurrence
-- =====================================================================
CREATE OR REPLACE FUNCTION public._expense_plan_next_cycle_date_v2(
  p_every int,
  p_unit  text,
  p_from  date
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = ''
AS $$
BEGIN
  IF p_every IS NULL OR p_unit IS NULL THEN
    RAISE EXCEPTION
      'Recurrence every/unit is required for expense plans.'
      USING ERRCODE = '22023';
  END IF;

  IF p_every < 1 THEN
    RAISE EXCEPTION
      'Recurrence every must be >= 1.'
      USING ERRCODE = '22023';
  END IF;

  CASE p_unit
    WHEN 'day' THEN
      RETURN (p_from + p_every)::date;
    WHEN 'week' THEN
      RETURN (p_from + (p_every * 7))::date;
    WHEN 'month' THEN
      RETURN (p_from + make_interval(months => p_every))::date;
    WHEN 'year' THEN
      RETURN (p_from + make_interval(years => p_every))::date;
    ELSE
      RAISE EXCEPTION
        'Recurrence unit % not supported for expense plans.',
        p_unit
        USING ERRCODE = '22023';
  END CASE;
END;
$$;
-- =====================================================================
-- Helper: generate a single cycle expense for a plan (idempotent)
-- =====================================================================
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

  -- Read w/o lock for faster "not found", but do not trust it
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

  -- Lock home FIRST (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_active
    FROM public.homes h
   WHERE h.id = v_plan_unsafe.home_id
   FOR UPDATE;

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- Lock plan row
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

  -- Idempotent insert (unique on (plan_id, start_date))
  BEGIN
    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
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

  -- Create splits for this cycle.
  -- If payer included as participant, mark their share paid immediately.
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

  -- Usage increments happen here for recurring cycles (including first cycle)
  PERFORM public._home_usage_apply_delta(
    v_plan.home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_expense;
END;
$$;

-- =====================================================================
-- Cron: generate all due cycles (safe to call repeatedly) - RETURNS void
-- =====================================================================
DROP FUNCTION IF EXISTS public.expense_plans_generate_due_cycles();

CREATE OR REPLACE FUNCTION public.expense_plans_generate_due_cycles()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan        public.expense_plans%ROWTYPE;
  v_cycle_date  date;
  v_next_date   date;

  v_cycles_done integer;
  v_cap constant integer := 31;   -- max cycles per plan per run

  v_total_cycles_done integer := 0;
  v_total_cap constant integer := 500; -- global max cycles per run
BEGIN
  FOR v_plan IN
    SELECT *
      FROM public.expense_plans
     WHERE status = 'active'
       AND next_cycle_date <= current_date
     FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_total_cycles_done >= v_total_cap;

    v_cycle_date := v_plan.next_cycle_date;
    v_next_date := v_plan.next_cycle_date;

    v_cycles_done := 0;

    WHILE v_cycle_date <= current_date AND v_cycles_done < v_cap LOOP
      EXIT WHEN v_total_cycles_done >= v_total_cap;

      PERFORM public._expense_plan_generate_cycle(v_plan.id, v_cycle_date);

      v_next_date := public._expense_plan_next_cycle_date_v2(
        v_plan.recurrence_every,
        v_plan.recurrence_unit,
        v_cycle_date
      );

      v_cycle_date  := v_next_date;
      v_cycles_done := v_cycles_done + 1;
      v_total_cycles_done := v_total_cycles_done + 1;
    END LOOP;

    UPDATE public.expense_plans
       SET next_cycle_date = v_next_date,
           updated_at      = now()
     WHERE id = v_plan.id;
  END LOOP;

  RETURN;
END;
$$;
-- =====================================================================
-- expenses_create (v1) - now writes recurrence_every/unit
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_create(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
);

CREATE OR REPLACE FUNCTION public.expenses_create(
  p_home_id      uuid,
  p_description  text,
  p_amount_cents bigint DEFAULT NULL,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL,
  p_recurrence   public.recurrence_interval DEFAULT 'none',
  p_start_date   date DEFAULT current_date
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

  v_recur_every    integer := NULL;
  v_recur_unit     text := NULL;

  v_split_count    integer := 0;
  v_split_sum      bigint  := 0;
  v_split_min      bigint  := 0;

  v_join_date      date;

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

  IF p_recurrence IS NULL THEN
    PERFORM public.api_error('INVALID_RECURRENCE', 'Recurrence is required.', '22023');
  END IF;

  v_is_recurring := p_recurrence <> 'none';

  IF v_is_recurring AND p_recurrence NOT IN ('weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'annual') THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence interval must be weekly, every_2_weeks, monthly, every_2_months, or annual.',
      '22023'
    );
  END IF;

  IF v_is_recurring THEN
    CASE p_recurrence
      WHEN 'weekly' THEN
        v_recur_every := 1;
        v_recur_unit := 'week';
      WHEN 'every_2_weeks' THEN
        v_recur_every := 2;
        v_recur_unit := 'week';
      WHEN 'monthly' THEN
        v_recur_every := 1;
        v_recur_unit := 'month';
      WHEN 'every_2_months' THEN
        v_recur_every := 2;
        v_recur_unit := 'month';
      WHEN 'annual' THEN
        v_recur_every := 1;
        v_recur_unit := 'year';
      ELSE
        PERFORM public.api_error(
          'INVALID_RECURRENCE',
          'Recurrence interval is not supported.',
          '22023'
        );
    END CASE;
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

  -- Draft vs active based on splits presence (p_split_mode)
  IF p_split_mode IS NULL THEN
    -- Draft
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    -- UPDATED: draft may optionally include amount, but if present must be valid.
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
    -- Activating (one-off active) OR recurring activation (plan + first cycle)
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

  -- Membership join date for start_date validation
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

  -- Lock home (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- If activating (splits present), build/validate split buffer (also validates members + sums)
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

    IF v_split_count < 2 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
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
  -- One-off path (non-recurring)
  IF NOT v_is_recurring THEN
    -- Paywall only if we are creating an ACTIVE expense (splits present)
    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_interval,
      recurrence_every,
      recurrence_unit,
      start_date
    )
    VALUES (
      v_home_id,
      v_user,
      v_new_status,
      v_target_split,
      p_amount_cents,                 -- may be NULL (draft) or >0
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      'none',
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    -- Create splits only for active
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

    -- Usage only for active
    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    RETURN v_result;
  END IF;

  -- Recurring activation path (user-generated): enforce quota for FIRST cycle intent
  -- (cron later ignores quota by design)
  PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
    recurrence_interval,
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
    p_recurrence,
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

  -- First cycle creation increments usage inside _expense_plan_generate_cycle (canonical)
  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
) TO authenticated;
-- =====================================================================
-- expenses_edit (v1) - now writes recurrence_every/unit
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_edit(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
);

CREATE OR REPLACE FUNCTION public.expenses_edit(
  p_expense_id   uuid,
  p_amount_cents bigint,
  p_description  text,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL,
  p_recurrence   public.recurrence_interval DEFAULT NULL,
  p_start_date   date DEFAULT NULL
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

  v_target_split    public.expense_split_type;
  v_target_recur    public.recurrence_interval;
  v_target_recur_every integer;
  v_target_recur_unit  text;
  v_target_start    date;
  v_is_recurring    boolean := FALSE;

  v_split_count     integer := 0;
  v_split_sum       bigint  := 0;
  v_split_min       bigint  := 0;

  v_join_date       date;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  -- Activation requires amount
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

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  -- Lock home first (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  -- Lock expense row next (homes -> expenses)
  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
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
    PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Active expenses cannot be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  v_target_split := p_split_mode;
  v_target_recur := COALESCE(p_recurrence, 'none');
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

  v_is_recurring := v_target_recur <> 'none';

  IF v_is_recurring AND v_target_recur NOT IN ('weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'annual') THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence interval must be weekly, every_2_weeks, monthly, every_2_months, or annual.',
      '22023'
    );
  END IF;

  IF v_is_recurring THEN
    CASE v_target_recur
      WHEN 'weekly' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'week';
      WHEN 'every_2_weeks' THEN
        v_target_recur_every := 2;
        v_target_recur_unit := 'week';
      WHEN 'monthly' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'month';
      WHEN 'every_2_months' THEN
        v_target_recur_every := 2;
        v_target_recur_unit := 'month';
      WHEN 'annual' THEN
        v_target_recur_every := 1;
        v_target_recur_unit := 'year';
      ELSE
        PERFORM public.api_error(
          'INVALID_RECURRENCE',
          'Recurrence interval is not supported.',
          '22023'
        );
    END CASE;
  ELSE
    v_target_recur_every := NULL;
    v_target_recur_unit := NULL;
  END IF;

  -- Build splits (this truncates pg_temp buffer itself)
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

  IF v_split_count < 2 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  -- Lock order convention: expense already locked; now safe to mutate splits
  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;
  IF v_is_recurring THEN
    -- User-generated recurring activation consumes quota for the first cycle intent
    PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
      recurrence_interval,
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
      v_target_recur,
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

    -- Mark original draft as converted; do NOT increment usage here
    UPDATE public.expenses
       SET status              = 'converted',
           plan_id             = v_plan.id,
           recurrence_interval = v_target_recur,
           recurrence_every    = v_target_recur_every,
           recurrence_unit     = v_target_recur_unit,
           start_date          = v_target_start,
           updated_at          = now()
     WHERE id = v_existing.id;

    -- First cycle creation increments usage inside _expense_plan_generate_cycle
    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  -- One-off activation path
  PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  UPDATE public.expenses
     SET status              = 'active',
         split_type          = v_target_split,
         amount_cents        = p_amount_cents,
         description         = btrim(p_description),
         notes               = NULLIF(btrim(p_notes), ''),
         recurrence_interval = 'none',
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

  PERFORM public._home_usage_apply_delta(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_edit(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_edit(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, public.recurrence_interval, date
) TO authenticated;
-- =====================================================================
-- expenses_create_v2
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_create_v2(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date
);

CREATE OR REPLACE FUNCTION public.expenses_create_v2(
  p_home_id          uuid,
  p_description      text,
  p_amount_cents     bigint DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT current_date
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

  -- Draft vs active based on splits presence (p_split_mode)
  IF p_split_mode IS NULL THEN
    -- Draft
    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    -- Draft may optionally include amount, but if present must be valid.
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
    -- Activating (one-off active) OR recurring activation (plan + first cycle)
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

  -- Membership join date for start_date validation
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

  -- Lock home (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004');
  END IF;

  -- If activating (splits present), build/validate split buffer (also validates members + sums)
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

    IF v_split_count < 2 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
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
  -- One-off path (non-recurring)
  IF NOT v_is_recurring THEN
    -- Paywall only if we are creating an ACTIVE expense (splits present)
    IF v_new_status = 'active' THEN
      PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      split_type,
      amount_cents,
      description,
      notes,
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
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    -- Create splits only for active
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

    -- Usage only for active
    IF v_new_status = 'active' THEN
      PERFORM public._home_usage_apply_delta(v_home_id, jsonb_build_object('active_expenses', 1));
    END IF;

    RETURN v_result;
  END IF;

  -- Recurring activation path (user-generated): enforce quota for FIRST cycle intent
  -- (cron later ignores quota by design)
  PERFORM public._home_assert_quota(v_home_id, jsonb_build_object('active_expenses', 1));

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    split_type,
    amount_cents,
    description,
    notes,
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

  -- First cycle creation increments usage inside _expense_plan_generate_cycle (canonical)
  v_result := public._expense_plan_generate_cycle(v_plan.id, p_start_date);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create_v2(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create_v2(
  uuid, text, bigint, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) TO authenticated;
-- =====================================================================
-- expenses_edit_v2
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
);

CREATE OR REPLACE FUNCTION public.expenses_edit_v2(
  p_expense_id       uuid,
  p_amount_cents     bigint,
  p_description      text,
  p_notes            text DEFAULT NULL,
  p_split_mode       public.expense_split_type DEFAULT NULL,
  p_member_ids       uuid[] DEFAULT NULL,
  p_splits           jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit  text DEFAULT NULL,
  p_start_date       date DEFAULT NULL
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

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  -- Activation requires amount
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

  v_target_split := p_split_mode;
  v_target_recur_every := p_recurrence_every;
  v_target_recur_unit := p_recurrence_unit;
  v_target_start := COALESCE(p_start_date, NULL);

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

  SELECT *
    INTO v_existing_unsafe
    FROM public.expenses e
   WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  -- Lock home first (global order: homes -> ...)
  SELECT h.is_active
    INTO v_home_is_active
    FROM public.homes h
   WHERE h.id = v_existing_unsafe.home_id
   FOR UPDATE;

  IF v_home_is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error('HOME_INACTIVE', 'This home is no longer active.', 'P0004', jsonb_build_object('homeId', v_existing_unsafe.home_id));
  END IF;

  -- Lock expense row next (homes -> expenses)
  SELECT *
    INTO v_existing
    FROM public.expenses e
   WHERE e.id = p_expense_id
   FOR UPDATE;

  IF v_existing.home_id <> v_existing_unsafe.home_id THEN
    PERFORM public.api_error('CONCURRENT_MODIFICATION', 'Expense changed while editing. Please retry.', '40001', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  IF v_existing.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can modify this expense.', '42501');
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
    PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Active expenses cannot be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
  END IF;

  IF v_existing.status <> 'draft' THEN
    PERFORM public.api_error('INVALID_STATE', 'Only draft expenses can be edited.', '42501',
      jsonb_build_object('expenseId', v_existing.id, 'status', v_existing.status)
    );
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

  -- Build splits (this truncates pg_temp buffer itself)
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

  IF v_split_count < 2 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least two debtors are required.', '22023');
  END IF;

  IF v_split_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error('INVALID_SPLITS_SUM', 'Split amounts must sum to the expense amount.', '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  -- Lock order convention: expense already locked; now safe to mutate splits
  DELETE FROM public.expense_splits s
   WHERE s.expense_id = v_existing.id;
  IF v_is_recurring THEN
    -- User-generated recurring activation consumes quota for the first cycle intent
    PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

    INSERT INTO public.expense_plans (
      home_id,
      created_by_user_id,
      split_type,
      amount_cents,
      description,
      notes,
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

    -- Mark original draft as converted; do NOT increment usage here
    UPDATE public.expenses
       SET status           = 'converted',
           plan_id          = v_plan.id,
           recurrence_every = v_target_recur_every,
           recurrence_unit  = v_target_recur_unit,
           start_date       = v_target_start,
           updated_at       = now()
     WHERE id = v_existing.id;

    -- First cycle creation increments usage inside _expense_plan_generate_cycle
    v_result := public._expense_plan_generate_cycle(v_plan.id, v_target_start);
    RETURN v_result;
  END IF;

  -- One-off activation path
  PERFORM public._home_assert_quota(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  UPDATE public.expenses
     SET status           = 'active',
         split_type       = v_target_split,
         amount_cents     = p_amount_cents,
         description      = btrim(p_description),
         notes            = NULLIF(btrim(p_notes), ''),
         recurrence_every = NULL,
         recurrence_unit  = NULL,
         start_date       = v_target_start,
         updated_at       = now()
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

  PERFORM public._home_usage_apply_delta(v_existing.home_id, jsonb_build_object('active_expenses', 1));

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_edit_v2(
  uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb, integer, text, date
) TO authenticated;
-- =====================================================================
-- expenses_get_for_edit: include recurrence_every/unit
-- =====================================================================
DROP FUNCTION IF EXISTS public.expenses_get_for_edit(uuid);

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
-- =====================================================================
-- expenses_get_current_owed: include recurrence_every/unit
-- =====================================================================
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
          'expenseId',       e.id,
          'description',     e.description,
          'amountCents',     s.amount_cents,
          'notes',           e.notes,
          'recurrenceEvery', e.recurrence_every,
          'recurrenceUnit',  e.recurrence_unit,
          'startDate',       e.start_date
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

-- =====================================================================
-- expenses_get_current_paid_to_me_by_debtor_details: include recurrence_every/unit
-- =====================================================================
CREATE OR REPLACE FUNCTION public.expenses_get_current_paid_to_me_by_debtor_details(
  p_home_id uuid,
  p_debtor_user_id uuid
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

  IF p_debtor_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'Debtor id is required.',
      '22023'
    );
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',       expense_id,
               'description',     description,
               'notes',           notes,
               'amountCents',     amount_cents,
               'markedPaidAt',    marked_paid_at,
               'debtorUsername',  debtor_username,
               'debtorAvatarUrl', debtor_avatar_url,
               'isOwner',         debtor_is_owner,
               'recurrenceEvery', recurrence_every,
               'recurrenceUnit',  recurrence_unit,
               'startDate',       start_date
             )
             ORDER BY marked_paid_at DESC, expense_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      e.id                                      AS expense_id,
      e.description                             AS description,
      e.notes                                   AS notes,
      s.amount_cents                            AS amount_cents,
      s.marked_paid_at                          AS marked_paid_at,
      p.username                                AS debtor_username,
      a.storage_path                            AS debtor_avatar_url,
      (h.owner_user_id = s.debtor_user_id)      AS debtor_is_owner,
      e.recurrence_every                        AS recurrence_every,
      e.recurrence_unit                         AS recurrence_unit,
      e.start_date                              AS start_date
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    JOIN public.homes h
      ON h.id = e.home_id
    JOIN public.profiles p
      ON p.id = s.debtor_user_id
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE e.home_id            = p_home_id
      AND e.created_by_user_id = v_user
      AND s.debtor_user_id     = p_debtor_user_id
      AND s.status             = 'paid'
      AND s.marked_paid_at     IS NOT NULL
      AND s.recipient_viewed_at IS NULL
      AND s.debtor_user_id    <> e.created_by_user_id
  ) details;

  RETURN v_result;
END;
$$;
-- =====================================================================
-- expenses_get_created_by_me: include recurrence_every/unit
-- =====================================================================
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

  -- Caller must be a current member of this home
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

  -- Home is fully frozen when inactive
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

  /*
    Build list of live expenses created by the current user.
  */
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId',        e.id,
               'homeId',           e.home_id,
               'createdByUserId',  e.created_by_user_id,
               'description',      e.description,
               'amountCents',      e.amount_cents,
               'status',           e.status,
               'splitType',        e.split_type,
               'createdAt',        e.created_at,
               'recurrenceEvery',  e.recurrence_every,
               'recurrenceUnit',   e.recurrence_unit,
               'startDate',        e.start_date,
               'totalShares',      COALESCE(stats.total_shares, 0)::int,
               'paidShares',       COALESCE(stats.paid_shares, 0)::int,
               'paidAmountCents',  COALESCE(stats.paid_amount_cents, 0),
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
