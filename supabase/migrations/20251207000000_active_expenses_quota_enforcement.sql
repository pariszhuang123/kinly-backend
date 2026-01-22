-- Add active_expenses quota metric and enforce for expenses

ALTER TABLE public.home_usage_counters
  ADD COLUMN IF NOT EXISTS active_expenses integer NOT NULL DEFAULT 0 CHECK (active_expenses >= 0);

COMMENT ON COLUMN public.home_usage_counters.active_expenses IS
  'Number of draft/active expenses that still count toward the plan quota (freed when cancelled or fully paid).';

-- 2) Seed free-tier limit (premium bypasses _home_assert_quota)
INSERT INTO public.home_plan_limits (plan, metric, max_value)
VALUES ('free', 'active_expenses', 10)
ON CONFLICT (plan, metric) DO UPDATE SET max_value = EXCLUDED.max_value;

-- 3) Recreate helpers to include active_expenses
DROP FUNCTION IF EXISTS public._home_usage_apply_delta(uuid, jsonb);

CREATE OR REPLACE FUNCTION public._home_usage_apply_delta(
  p_home_id uuid,
  p_deltas  jsonb   -- e.g. {"active_expenses": 1}
)
RETURNS public.home_usage_counters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row                   public.home_usage_counters;
  v_active_chores_delta   integer := 0;
  v_chore_photos_delta    integer := 0;
  v_active_members_delta  integer := 0;
  v_active_expenses_delta integer := 0;
BEGIN
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
  END IF;

  UPDATE public.home_usage_counters h
  SET
    active_chores = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
    chore_photos  = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
    active_members = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
    active_expenses = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
    updated_at = now()
  WHERE h.home_id = p_home_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public._home_usage_apply_delta(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public._home_assert_quota(uuid, jsonb);

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
    v_counters.active_chores    := 0;
    v_counters.chore_photos     := 0;
    v_counters.active_members   := 0;
    v_counters.active_expenses  := 0;
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
      WHEN 'active_chores'    THEN COALESCE(v_counters.active_chores, 0)
      WHEN 'chore_photos'     THEN COALESCE(v_counters.chore_photos, 0)
      WHEN 'active_members'   THEN COALESCE(v_counters.active_members, 0)
      WHEN 'active_expenses'  THEN COALESCE(v_counters.active_expenses, 0)
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

COMMENT ON FUNCTION public._home_assert_quota(uuid, jsonb) IS
  'Generic quota enforcement: checks deltas against per-plan limits in home_plan_limits and raises api_error when exceeding quotas.';

REVOKE ALL ON FUNCTION public._home_assert_quota(uuid, jsonb)
FROM PUBLIC, anon, authenticated;

-- Enforce active_expenses quota in expenses RPCs

CREATE OR REPLACE FUNCTION public.expenses_create(
  p_home_id      uuid,
  p_amount_cents bigint,
  p_description  text,
  p_notes        text DEFAULT NULL,
  p_split_mode   public.expense_split_type DEFAULT NULL,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
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

  v_new_status     public.expense_status;
  v_target_split   public.expense_split_type;
  v_has_splits     boolean := FALSE;

  v_amount_cap constant bigint  := 900000000000;
  v_desc_max   constant integer := 280;
  v_notes_max  constant integer := 2000;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF v_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_amount_cents IS NULL
     OR p_amount_cents <= 0
     OR p_amount_cents > v_amount_cap THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      format('Amount must be between 1 and %s cents.', v_amount_cap),
      '22023'
    );
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
    v_new_status   := 'draft';
    v_target_split := NULL;
    v_has_splits   := FALSE;
  ELSE
    v_new_status   := 'active';
    v_target_split := p_split_mode;
    v_has_splits   := TRUE;
  END IF;

  PERFORM 1
  FROM public.memberships m
  WHERE m.home_id    = v_home_id
    AND m.user_id    = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a member of this home.',
      '42501',
      jsonb_build_object('homeId', v_home_id)
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

  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  IF v_has_splits THEN
    PERFORM public._expenses_prepare_split_buffer(
      v_home_id,
      v_user,
      p_amount_cents,
      v_target_split,
      p_member_ids,
      p_splits
    );
  END IF;

  INSERT INTO public.expenses (
    home_id,
    created_by_user_id,
    status,
    split_type,
    amount_cents,
    description,
    notes
  )
  VALUES (
    v_home_id,
    v_user,
    v_new_status,
    v_target_split,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), '')
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
           CASE
             WHEN debtor_user_id = v_user
               THEN 'paid'::public.expense_share_status
             ELSE 'unpaid'::public.expense_share_status
           END,
           CASE WHEN debtor_user_id = v_user THEN now() ELSE NULL END
    FROM pg_temp.expense_split_buffer;
  END IF;

  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_expenses', 1)
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create(uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_create(uuid, bigint, text, text, public.expense_split_type, uuid[], jsonb)
TO authenticated;

---------------------------------------------------------------------
-- expenses.markSharePaid: free quota slot when fully paid
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expenses_mark_share_paid(
  p_expense_id uuid
)
RETURNS public.expense_splits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user           uuid;
  v_expense        public.expenses%ROWTYPE;
  v_split          public.expense_splits%ROWTYPE;
  v_home_is_active boolean;
  v_unpaid_count   integer;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
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

  IF v_expense.status <> 'active' THEN
    PERFORM public.api_error(
      'INVALID_STATE',
      'Only active expenses can be paid.',
      'P0003'
    );
  END IF;

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

  SELECT *
  INTO v_split
  FROM public.expense_splits s
  WHERE s.expense_id     = v_expense.id
    AND s.debtor_user_id = v_user
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'You do not have a share on this expense.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id, 'userId', v_user)
    );
  END IF;

  IF v_split.status = 'paid' THEN
    RETURN v_split;
  END IF;

  UPDATE public.expense_splits
  SET status         = 'paid',
      marked_paid_at = now()
  WHERE expense_id     = v_expense.id
    AND debtor_user_id = v_user
  RETURNING * INTO v_split;

  SELECT COUNT(*)
  INTO v_unpaid_count
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id
    AND s.status     = 'unpaid';

  IF v_unpaid_count = 0 THEN
    PERFORM public._home_usage_apply_delta(
      v_expense.home_id,
      jsonb_build_object('active_expenses', -1)
    );
  END IF;

  RETURN v_split;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_mark_share_paid(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_mark_share_paid(uuid)
TO authenticated;

---------------------------------------------------------------------
-- expenses.cancel: free quota slot
---------------------------------------------------------------------
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

  PERFORM public._home_usage_apply_delta(
    v_expense.home_id,
    jsonb_build_object('active_expenses', -1)
  );

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_cancel(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expenses_cancel(uuid)
TO authenticated;
