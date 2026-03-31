BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

/* =====================================================================
   COMPATIBILITY-SAFE ROLLOUT MIGRATION (HARDENED, ADJUSTED)

   Adjustments in this revision:
   - fix finalize quota double-decrement race
   - add compatibility trigger-population for child home_id columns
   - add uniqueness constraints/indexes for split target tables
   - derive child home_id from locked parent rows in persistence helpers
   - keep old public RPCs working as much as possible during rollout
   ===================================================================== */

/* =====================================================================
   0) HOME-SCOPED INTEGRITY + PLAN TERMINATION METADATA
   ===================================================================== */

CREATE UNIQUE INDEX IF NOT EXISTS uq_expenses_id_home_id
  ON public.expenses (id, home_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_plans_id_home_id
  ON public.expense_plans (id, home_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_units_id_home_id
  ON public.home_units (id, home_id);

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS allocation_target_type text;

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_allocation_target_type_valid;

ALTER TABLE public.expenses
  ADD CONSTRAINT chk_expenses_allocation_target_type_valid
  CHECK (
    allocation_target_type IS NULL
    OR allocation_target_type IN ('debtor_based', 'unit_based')
  );

ALTER TABLE public.expense_plans
  ADD COLUMN IF NOT EXISTS allocation_target_type text;

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_allocation_target_type_valid;

ALTER TABLE public.expense_plans
  ADD CONSTRAINT chk_expense_plans_allocation_target_type_valid
  CHECK (
    allocation_target_type IS NULL
    OR allocation_target_type IN ('debtor_based', 'unit_based')
  );

CREATE TABLE IF NOT EXISTS public.expense_plan_units (
  plan_id uuid NOT NULL REFERENCES public.expense_plans(id) ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES public.home_units(id) ON DELETE RESTRICT,
  share_amount_cents bigint NOT NULL,
  home_id uuid,
  CONSTRAINT pk_expense_plan_units PRIMARY KEY (plan_id, unit_id),
  CONSTRAINT chk_expense_plan_units_amount_positive CHECK (share_amount_cents > 0)
);

CREATE TABLE IF NOT EXISTS public.expense_unit_splits (
  expense_id uuid NOT NULL REFERENCES public.expenses(id) ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES public.home_units(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL,
  paid_cents bigint NOT NULL DEFAULT 0,
  fully_paid_at timestamptz,
  home_id uuid,
  CONSTRAINT pk_expense_unit_splits PRIMARY KEY (expense_id, unit_id),
  CONSTRAINT chk_expense_unit_splits_amount_positive CHECK (amount_cents > 0),
  CONSTRAINT chk_expense_unit_splits_paid_bounds CHECK (
    paid_cents >= 0
    AND paid_cents <= amount_cents
  ),
  CONSTRAINT chk_expense_unit_splits_fully_paid_alignment CHECK (
    (paid_cents < amount_cents AND fully_paid_at IS NULL)
    OR (paid_cents = amount_cents AND fully_paid_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.expense_unit_payment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_id uuid NOT NULL REFERENCES public.expenses(id) ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES public.home_units(id) ON DELETE RESTRICT,
  payer_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_expense_unit_payment_events_expense_unit_created_at
  ON public.expense_unit_payment_events (expense_id, unit_id, created_at DESC);

ALTER TABLE public.expense_plan_units DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_unit_splits DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_unit_payment_events DISABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.expense_plan_units, public.expense_unit_splits, public.expense_unit_payment_events
  FROM PUBLIC, anon, authenticated;

ALTER TABLE public.expense_plan_units
  ADD COLUMN IF NOT EXISTS home_id uuid;

UPDATE public.expense_plan_units epu
SET home_id = ep.home_id
FROM public.expense_plans ep
WHERE ep.id = epu.plan_id
  AND epu.home_id IS NULL;

ALTER TABLE public.expense_unit_splits
  ADD COLUMN IF NOT EXISTS home_id uuid;

UPDATE public.expense_unit_splits eus
SET home_id = e.home_id
FROM public.expenses e
WHERE e.id = eus.expense_id
  AND eus.home_id IS NULL;

/*
  Compatibility triggers:
  old writers may omit home_id; derive it from the parent row.
*/

CREATE OR REPLACE FUNCTION public._expense_plan_units_fill_home_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
BEGIN
  IF NEW.plan_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.home_id IS NULL THEN
    SELECT ep.home_id
    INTO v_home_id
    FROM public.expense_plans ep
    WHERE ep.id = NEW.plan_id;

    NEW.home_id := v_home_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plan_units_fill_home_id()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_expense_plan_units_fill_home_id
ON public.expense_plan_units;

CREATE TRIGGER trg_expense_plan_units_fill_home_id
BEFORE INSERT OR UPDATE OF plan_id, home_id
ON public.expense_plan_units
FOR EACH ROW
EXECUTE FUNCTION public._expense_plan_units_fill_home_id();

CREATE OR REPLACE FUNCTION public._expense_unit_splits_fill_home_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
BEGIN
  IF NEW.expense_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.home_id IS NULL THEN
    SELECT e.home_id
    INTO v_home_id
    FROM public.expenses e
    WHERE e.id = NEW.expense_id;

    NEW.home_id := v_home_id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_unit_splits_fill_home_id()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_expense_unit_splits_fill_home_id
ON public.expense_unit_splits;

CREATE TRIGGER trg_expense_unit_splits_fill_home_id
BEFORE INSERT OR UPDATE OF expense_id, home_id
ON public.expense_unit_splits
FOR EACH ROW
EXECUTE FUNCTION public._expense_unit_splits_fill_home_id();

ALTER TABLE public.expense_plan_units
  ALTER COLUMN home_id SET NOT NULL;

ALTER TABLE public.expense_plan_units
  DROP CONSTRAINT IF EXISTS fk_expense_plan_units_plan_home;

ALTER TABLE public.expense_plan_units
  DROP CONSTRAINT IF EXISTS fk_expense_plan_units_unit_home;

ALTER TABLE public.expense_plan_units
  ADD CONSTRAINT fk_expense_plan_units_plan_home
  FOREIGN KEY (plan_id, home_id)
  REFERENCES public.expense_plans (id, home_id)
  ON DELETE RESTRICT;

ALTER TABLE public.expense_plan_units
  ADD CONSTRAINT fk_expense_plan_units_unit_home
  FOREIGN KEY (unit_id, home_id)
  REFERENCES public.home_units (id, home_id)
  ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_expense_plan_units_home_unit
  ON public.expense_plan_units (home_id, unit_id);

ALTER TABLE public.expense_unit_splits
  ALTER COLUMN home_id SET NOT NULL;

ALTER TABLE public.expense_unit_splits
  DROP CONSTRAINT IF EXISTS fk_expense_unit_splits_expense_home;

ALTER TABLE public.expense_unit_splits
  DROP CONSTRAINT IF EXISTS fk_expense_unit_splits_unit_home;

ALTER TABLE public.expense_unit_splits
  ADD CONSTRAINT fk_expense_unit_splits_expense_home
  FOREIGN KEY (expense_id, home_id)
  REFERENCES public.expenses (id, home_id)
  ON DELETE CASCADE;

ALTER TABLE public.expense_unit_splits
  ADD CONSTRAINT fk_expense_unit_splits_unit_home
  FOREIGN KEY (unit_id, home_id)
  REFERENCES public.home_units (id, home_id)
  ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS idx_expense_unit_splits_home_unit_remaining
  ON public.expense_unit_splits (home_id, unit_id, expense_id)
  WHERE paid_cents < amount_cents;

/* table-level duplicate protection */
CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_splits_expense_debtor
  ON public.expense_splits (expense_id, debtor_user_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_unit_splits_expense_unit
  ON public.expense_unit_splits (expense_id, unit_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_plan_debtors_plan_debtor
  ON public.expense_plan_debtors (plan_id, debtor_user_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_plan_units_plan_unit
  ON public.expense_plan_units (plan_id, unit_id);

ALTER TABLE public.expense_plans
  ADD COLUMN IF NOT EXISTS termination_reason text NULL;

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_termination_reason_valid;

ALTER TABLE public.expense_plans
  ADD CONSTRAINT chk_expense_plans_termination_reason_valid
  CHECK (
    termination_reason IS NULL
    OR termination_reason IN (
      'UNIT_TARGET_INVALID',
      'UNIT_TARGET_ARCHIVED',
      'UNIT_TARGET_HOME_MISMATCH',
      'MANUAL',
      'OTHER'
    )
  );

/* =====================================================================
   1) SMALL LOCK / VALIDATION HELPERS
   ===================================================================== */

CREATE OR REPLACE FUNCTION public._expense_lock_home_active(
  p_home_id uuid
)
RETURNS public.homes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home public.homes%ROWTYPE;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_HOME',
      'Home id is required.',
      '22023'
    );
  END IF;

  SELECT *
  INTO v_home
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

  IF v_home.is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  RETURN v_home;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_lock_home_active(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_lock_expense_for_update(
  p_expense_id uuid
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense public.expenses%ROWTYPE;
BEGIN
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

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_lock_expense_for_update(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_lock_plan_for_update(
  p_plan_id uuid
)
RETURNS public.expense_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan public.expense_plans%ROWTYPE;
BEGIN
  IF p_plan_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_PLAN',
      'Plan id is required.',
      '22023'
    );
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

  RETURN v_plan;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_lock_plan_for_update(uuid)
FROM PUBLIC, anon, authenticated;

/*
  Canonical write lock ordering:
  1) lock home row
  2) lock expense/plan row
  3) lock child rows
*/
CREATE OR REPLACE FUNCTION public._expense_lock_expense_with_home_active(
  p_expense_id uuid
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home public.homes%ROWTYPE;
  v_expense public.expenses%ROWTYPE;
BEGIN
  IF p_expense_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EXPENSE',
      'Expense id is required.',
      '22023'
    );
  END IF;

  SELECT h.*
  INTO v_home
  FROM public.homes h
  JOIN public.expenses e
    ON e.home_id = h.id
  WHERE e.id = p_expense_id
  FOR UPDATE OF h;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  IF v_home.is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', v_home.id)
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

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_lock_expense_with_home_active(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_lock_plan_with_home_active(
  p_plan_id uuid
)
RETURNS public.expense_plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home public.homes%ROWTYPE;
  v_plan public.expense_plans%ROWTYPE;
BEGIN
  IF p_plan_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_PLAN',
      'Plan id is required.',
      '22023'
    );
  END IF;

  SELECT h.*
  INTO v_home
  FROM public.homes h
  JOIN public.expense_plans ep
    ON ep.home_id = h.id
  WHERE ep.id = p_plan_id
  FOR UPDATE OF h;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense plan not found.',
      'P0002',
      jsonb_build_object('planId', p_plan_id)
    );
  END IF;

  IF v_home.is_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', v_home.id)
    );
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

  RETURN v_plan;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_lock_plan_with_home_active(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_require_current_membership(
  p_home_id uuid,
  p_user_id uuid
)
RETURNS public.memberships
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_membership public.memberships%ROWTYPE;
BEGIN
  IF p_home_id IS NULL OR p_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_MEMBERSHIP_SCOPE',
      'Home id and user id are required.',
      '22023'
    );
  END IF;

  SELECT *
  INTO v_membership
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = p_user_id
    AND m.valid_to IS NULL
  ORDER BY m.valid_from DESC, m.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_HOME_MEMBER',
      'You are not a current member of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id, 'userId', p_user_id)
    );
  END IF;

  RETURN v_membership;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_require_current_membership(uuid, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_validate_common_fields(
  p_description text,
  p_notes text,
  p_amount_cents bigint,
  p_allow_null_amount boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_desc_max constant integer := 280;
  v_notes_max constant integer := 2000;
  v_amount_cap constant bigint := 900000000000;
BEGIN
  IF btrim(COALESCE(p_description, '')) = '' THEN
    PERFORM public.api_error(
      'INVALID_DESCRIPTION',
      'Description is required.',
      '22023'
    );
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

  IF p_allow_null_amount THEN
    IF p_amount_cents IS NOT NULL AND (p_amount_cents <= 0 OR p_amount_cents > v_amount_cap) THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents when provided.', v_amount_cap),
        '22023',
        jsonb_build_object('amountCents', p_amount_cents)
      );
    END IF;
  ELSE
    IF p_amount_cents IS NULL OR p_amount_cents <= 0 OR p_amount_cents > v_amount_cap THEN
      PERFORM public.api_error(
        'INVALID_AMOUNT',
        format('Amount must be between 1 and %s cents.', v_amount_cap),
        '22023',
        jsonb_build_object('amountCents', p_amount_cents)
      );
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_validate_common_fields(text, text, bigint, boolean)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_validate_recurrence_fields(
  p_recurrence_every integer,
  p_recurrence_unit text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (p_recurrence_every IS NULL) <> (p_recurrence_unit IS NULL) THEN
    PERFORM public.api_error(
      'INVALID_RECURRENCE',
      'Recurrence every and unit must both be set or both be null.',
      '22023'
    );
  END IF;

  IF p_recurrence_every IS NOT NULL THEN
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
END;
$$;

REVOKE ALL ON FUNCTION public._expense_validate_recurrence_fields(integer, text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_validate_start_date_range(
  p_home_id uuid,
  p_user_id uuid,
  p_start_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_membership public.memberships%ROWTYPE;
  v_join_date date;
BEGIN
  IF p_start_date IS NULL THEN
    PERFORM public.api_error(
      'INVALID_START_DATE',
      'Start date is required.',
      '22023'
    );
  END IF;

  v_membership := public._expense_require_current_membership(p_home_id, p_user_id);
  v_join_date := v_membership.valid_from::date;

  IF p_start_date < v_join_date OR p_start_date < (current_date - 90) THEN
    PERFORM public.api_error(
      'INVALID_START_DATE_RANGE',
      'Start date is outside the allowed range.',
      '22023',
      jsonb_build_object(
        'minStartDate', GREATEST(v_join_date, current_date - 90),
        'joinDate', v_join_date,
        'maxBackdateDays', 90,
        'attemptedStartDate', p_start_date
      )
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_validate_start_date_range(uuid, uuid, date)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_validate_evidence_photo_path(
  p_evidence_photo_path text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_path text := NULLIF(btrim(p_evidence_photo_path), '');
BEGIN
  IF v_path IS NOT NULL AND v_path NOT LIKE 'households/%' THEN
    PERFORM public.api_error(
      'INVALID_EVIDENCE_PHOTO_PATH',
      'Evidence photo path must start with households/.',
      '22023',
      jsonb_build_object('field', 'evidencePhotoPath')
    );
  END IF;

  RETURN v_path;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_validate_evidence_photo_path(text)
FROM PUBLIC, anon, authenticated;

/* =====================================================================
   2) PHOTO + QUOTA HELPERS
   ===================================================================== */

CREATE OR REPLACE FUNCTION public._expense_validate_photo_transition(
  p_old_path text,
  p_new_path text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_old_path IS NULL AND p_new_path IS NULL THEN
    RETURN 0;
  ELSIF p_old_path IS NULL AND p_new_path IS NOT NULL THEN
    RETURN 1;
  ELSIF p_old_path IS NOT NULL AND p_new_path IS NOT NULL THEN
    RETURN 0;
  ELSE
    PERFORM public.api_error(
      'PHOTO_DELETE_NOT_ALLOWED',
      'Deleting an evidence photo is not allowed.',
      '22023'
    );
  END IF;

  RETURN 0;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_validate_photo_transition(text, text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_assert_activate_one_off(
  p_home_id uuid,
  p_photo_delta integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', COALESCE(p_photo_delta, 0)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_assert_activate_one_off(uuid, integer)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_apply_activate_one_off(
  p_home_id uuid,
  p_photo_delta integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', COALESCE(p_photo_delta, 0)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_apply_activate_one_off(uuid, integer)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_assert_activate_plan_with_first_cycle(
  p_home_id uuid,
  p_photo_delta integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', COALESCE(p_photo_delta, 0)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_assert_activate_plan_with_first_cycle(uuid, integer)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_apply_activate_plan_with_first_cycle(
  p_home_id uuid,
  p_photo_delta integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_build_object(
      'active_expenses', 1,
      'expense_photos', COALESCE(p_photo_delta, 0)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_apply_activate_plan_with_first_cycle(uuid, integer)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_assert_generate_cycle(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_assert_quota(
    p_home_id,
    jsonb_build_object('active_expenses', 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_assert_generate_cycle(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_apply_generate_cycle(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_build_object('active_expenses', 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_apply_generate_cycle(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_quota_apply_finalize_expense(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._home_usage_apply_delta(
    p_home_id,
    jsonb_build_object('active_expenses', -1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_quota_apply_finalize_expense(uuid)
FROM PUBLIC, anon, authenticated;

/* =====================================================================
   3) ROW-RETURNING SPLIT BUILDERS
   ===================================================================== */

CREATE OR REPLACE FUNCTION public._expense_build_debtor_splits(
  p_home_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL
)
RETURNS TABLE (
  debtor_user_id uuid,
  amount_cents bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_member_count integer := 0;
  v_equal_share bigint := 0;
  v_remainder bigint := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_creator_user_id IS NULL THEN
    PERFORM public.api_error('INVALID_CREATOR', 'Creator id is required.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLIT', 'Split mode is required.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error('INVALID_AMOUNT', 'Amount must be positive.', '22023');
  END IF;

  IF p_split_mode = 'equal' THEN
    IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
    END IF;

    WITH candidates AS (
      SELECT DISTINCT ON (m.user_id)
             m.user_id AS debtor_user_id,
             raw.ord_position
      FROM unnest(p_member_ids) WITH ORDINALITY AS raw(member_id, ord_position)
      JOIN public.memberships m
        ON m.id = raw.member_id
       AND m.home_id = p_home_id
       AND m.valid_to IS NULL
      ORDER BY m.user_id, raw.ord_position
    )
    SELECT COUNT(*)::int
    INTO v_member_count
    FROM candidates;

    IF v_member_count < 1 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
    END IF;

    v_equal_share := p_amount_cents / v_member_count;
    v_remainder := p_amount_cents % v_member_count;

    RETURN QUERY
    WITH ordered AS (
      SELECT
        c.debtor_user_id,
        row_number() OVER (ORDER BY c.ord_position, c.debtor_user_id) AS rn
      FROM (
        SELECT DISTINCT ON (m.user_id)
               m.user_id AS debtor_user_id,
               raw.ord_position
        FROM unnest(p_member_ids) WITH ORDINALITY AS raw(member_id, ord_position)
        JOIN public.memberships m
          ON m.id = raw.member_id
         AND m.home_id = p_home_id
         AND m.valid_to IS NULL
        ORDER BY m.user_id, raw.ord_position
      ) c
    )
    SELECT
      o.debtor_user_id,
      v_equal_share + CASE WHEN o.rn = v_member_count THEN v_remainder ELSE 0 END AS amount_cents
    FROM ordered o
    ORDER BY o.rn;

    RETURN;
  ELSIF p_split_mode = 'custom' THEN
    IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
      PERFORM public.api_error('INVALID_SPLIT', 'p_splits must be a JSON array.', '22023');
    END IF;

    SELECT COUNT(*)::int
    INTO v_member_count
    FROM (
      SELECT DISTINCT ON (m.user_id)
             m.user_id
      FROM jsonb_to_recordset(p_splits) WITH ORDINALITY AS x(member_id uuid, amount_cents bigint, ordinality bigint)
      JOIN public.memberships m
        ON m.id = x.member_id
       AND m.home_id = p_home_id
       AND m.valid_to IS NULL
      ORDER BY m.user_id, x.ordinality
    ) deduped;

    IF v_member_count < 1 THEN
      PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
    END IF;

    RETURN QUERY
    WITH raw AS (
      SELECT x.member_id, x.amount_cents, x.ordinality
      FROM jsonb_to_recordset(p_splits) WITH ORDINALITY AS x(member_id uuid, amount_cents bigint, ordinality bigint)
    ), normalized AS (
      SELECT DISTINCT ON (m.user_id)
             m.user_id AS debtor_user_id,
             raw.amount_cents,
             raw.ordinality
      FROM raw
      JOIN public.memberships m
        ON m.id = raw.member_id
       AND m.home_id = p_home_id
       AND m.valid_to IS NULL
      ORDER BY m.user_id, raw.ordinality
    )
    SELECT n.debtor_user_id, n.amount_cents
    FROM normalized n
    ORDER BY n.ordinality, n.debtor_user_id;

    RETURN;
  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_build_debtor_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_get_validated_debtor_splits(
  p_home_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL
)
RETURNS TABLE (
  debtor_user_id uuid,
  amount_cents bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_built jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_sum bigint := 0;
  v_min bigint := 0;
  v_distinct_count integer := 0;
BEGIN
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'ord', built.ord,
               'debtor_user_id', built.debtor_user_id,
               'amount_cents', built.amount_cents
             )
             ORDER BY built.ord
           ),
           '[]'::jsonb
         )
  INTO v_built
  FROM (
    SELECT
      row_number() OVER () AS ord,
      s.debtor_user_id,
      s.amount_cents
    FROM public._expense_build_debtor_splits(
      p_home_id,
      p_creator_user_id,
      p_amount_cents,
      p_split_mode,
      p_member_ids,
      p_splits
    ) s
  ) built;

  SELECT
    COUNT(*)::int,
    COALESCE(SUM(x.amount_cents), 0),
    COALESCE(MIN(x.amount_cents), 0),
    COUNT(DISTINCT x.debtor_user_id)::int
  INTO
    v_count,
    v_sum,
    v_min,
    v_distinct_count
  FROM jsonb_to_recordset(v_built) AS x(ord integer, debtor_user_id uuid, amount_cents bigint);

  IF v_count < 1 THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'At least one debtor is required.', '22023');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_built) AS x(ord integer, debtor_user_id uuid, amount_cents bigint)
    WHERE x.debtor_user_id IS NULL
       OR x.amount_cents IS NULL
  ) THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Each debtor split requires a debtor and amount.', '22023');
  END IF;

  IF v_min <= 0 THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Split amounts must be positive.', '22023');
  END IF;

  IF v_distinct_count <> v_count THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Each debtor may appear only once.', '22023');
  END IF;

  IF v_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'INVALID_SPLITS_SUM',
      'Split amounts must sum to the expense amount.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_sum)
    );
  END IF;

  RETURN QUERY
  SELECT x.debtor_user_id, x.amount_cents
  FROM jsonb_to_recordset(v_built) AS x(ord integer, debtor_user_id uuid, amount_cents bigint)
  ORDER BY x.ord;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_get_validated_debtor_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_build_unit_splits(
  p_home_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL
)
RETURNS TABLE (
  unit_id uuid,
  amount_cents bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total_count integer := 0;
  v_equal_share bigint := 0;
  v_remainder bigint := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_creator_user_id IS NULL THEN
    PERFORM public.api_error('INVALID_CREATOR', 'Creator id is required.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLIT', 'Split mode is required to build unit splits.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      'Amount must be a positive integer.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents)
    );
  END IF;

  IF p_split_mode = 'equal' THEN
    IF p_unit_ids IS NULL OR array_length(p_unit_ids, 1) IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_UNITS_REQUIRED',
        'Provide at least one unit for an equal split.',
        '22023'
      );
    END IF;

    WITH ordered AS (
      SELECT
        deduped.unit_id,
        row_number() OVER (ORDER BY deduped.ord_position) AS rn,
        count(*) OVER () AS total_count
      FROM (
        SELECT DISTINCT ON (raw.unit_id)
               raw.unit_id,
               raw.ord_position
        FROM unnest(p_unit_ids)
          WITH ORDINALITY AS raw(unit_id, ord_position)
        WHERE raw.unit_id IS NOT NULL
        ORDER BY raw.unit_id, raw.ord_position
      ) deduped
    )
    SELECT COALESCE(MAX(total_count), 0)
    INTO v_total_count
    FROM ordered;

    IF v_total_count < 1 THEN
      PERFORM public.api_error(
        'SPLIT_UNITS_REQUIRED',
        'Include at least one unit in the split.',
        '22023'
      );
    END IF;

    v_equal_share := p_amount_cents / v_total_count;
    v_remainder := p_amount_cents % v_total_count;

    RETURN QUERY
    WITH ordered AS (
      SELECT
        deduped.unit_id,
        row_number() OVER (ORDER BY deduped.ord_position) AS rn
      FROM (
        SELECT DISTINCT ON (raw.unit_id)
               raw.unit_id,
               raw.ord_position
        FROM unnest(p_unit_ids)
          WITH ORDINALITY AS raw(unit_id, ord_position)
        WHERE raw.unit_id IS NOT NULL
        ORDER BY raw.unit_id, raw.ord_position
      ) deduped
    )
    SELECT
      ordered.unit_id,
      v_equal_share + CASE WHEN ordered.rn = v_total_count THEN v_remainder ELSE 0 END
    FROM ordered
    ORDER BY ordered.rn;

    RETURN;
  ELSIF p_split_mode = 'custom' THEN
    IF p_unit_splits IS NULL OR jsonb_typeof(p_unit_splits) <> 'array' THEN
      PERFORM public.api_error('INVALID_SPLIT', 'p_unit_splits must be a JSON array.', '22023');
    END IF;

    RETURN QUERY
    SELECT x.unit_id, x.amount_cents
    FROM jsonb_to_recordset(p_unit_splits) AS x(unit_id uuid, amount_cents bigint);

    RETURN;
  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_build_unit_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_get_validated_unit_splits(
  p_home_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL
)
RETURNS TABLE (
  unit_id uuid,
  amount_cents bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_built jsonb := '[]'::jsonb;
  v_split_count integer := 0;
  v_split_sum bigint := 0;
  v_distinct_count integer := 0;
  v_unit_match_count integer := 0;
  v_only_unit_id uuid;
  v_creator_personal_unit_id uuid;
BEGIN
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'ord', built.ord,
               'unit_id', built.unit_id,
               'amount_cents', built.amount_cents
             )
             ORDER BY built.ord
           ),
           '[]'::jsonb
         )
  INTO v_built
  FROM (
    SELECT
      row_number() OVER () AS ord,
      s.unit_id,
      s.amount_cents
    FROM public._expense_build_unit_splits(
      p_home_id,
      p_creator_user_id,
      p_amount_cents,
      p_split_mode,
      p_unit_ids,
      p_unit_splits
    ) s
  ) built;

  SELECT
    COUNT(*)::int,
    COALESCE(SUM(x.amount_cents), 0),
    COUNT(DISTINCT x.unit_id)::int
  INTO
    v_split_count,
    v_split_sum,
    v_distinct_count
  FROM jsonb_to_recordset(v_built) AS x(ord integer, unit_id uuid, amount_cents bigint);

  IF v_split_count = 1 THEN
    SELECT x.unit_id
    INTO v_only_unit_id
    FROM jsonb_to_recordset(v_built) AS x(ord integer, unit_id uuid, amount_cents bigint)
    ORDER BY x.ord
    LIMIT 1;
  ELSE
    v_only_unit_id := NULL;
  END IF;

  IF v_split_count < 1 THEN
    PERFORM public.api_error('SPLIT_UNITS_REQUIRED', 'Include at least one unit in the split.', '22023');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_built) AS x(ord integer, unit_id uuid, amount_cents bigint)
    WHERE x.unit_id IS NULL
       OR x.amount_cents IS NULL
       OR x.amount_cents <= 0
  ) THEN
    PERFORM public.api_error('INVALID_UNIT_TARGET', 'Each unit split requires a unit and a positive amount.', '22023');
  END IF;

  IF v_distinct_count <> v_split_count THEN
    PERFORM public.api_error('INVALID_UNIT_TARGET', 'Each unit must appear only once.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'INVALID_SPLITS_SUM',
      'Split amounts must sum to the expense amount.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  SELECT COUNT(*)::int
  INTO v_unit_match_count
  FROM jsonb_to_recordset(v_built) AS x(ord integer, unit_id uuid, amount_cents bigint)
  JOIN public.home_units hu
    ON hu.id = x.unit_id
   AND hu.home_id = p_home_id
   AND hu.archived_at IS NULL;

  IF v_unit_match_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_UNIT_TARGET',
      'All units must be active units in this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  SELECT hu.id
  INTO v_creator_personal_unit_id
  FROM public.memberships m
  JOIN public.home_units hu
    ON hu.personal_membership_id = m.id
   AND hu.unit_type = 'personal'
   AND hu.archived_at IS NULL
  WHERE m.home_id = p_home_id
    AND m.user_id = p_creator_user_id
    AND m.valid_to IS NULL
  ORDER BY m.valid_from DESC, m.id DESC
  LIMIT 1;

  IF v_split_count = 1
     AND v_creator_personal_unit_id IS NOT NULL
     AND v_only_unit_id = v_creator_personal_unit_id THEN
    PERFORM public.api_error(
      'SPLIT_UNITS_REQUIRED',
      'Unit-based allocation must include a debtor beyond the creator personal unit.',
      '22023'
    );
  END IF;

  RETURN QUERY
  SELECT x.unit_id, x.amount_cents
  FROM jsonb_to_recordset(v_built) AS x(ord integer, unit_id uuid, amount_cents bigint)
  ORDER BY x.ord;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_get_validated_unit_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

/* =====================================================================
   4) SPLIT PERSISTENCE HELPERS
   Adjusted: derive home_id from locked parent, do not trust caller p_home_id.
   ===================================================================== */

CREATE OR REPLACE FUNCTION public._expense_persist_debtor_splits(
  p_expense_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense public.expenses%ROWTYPE;
BEGIN
  v_expense := public._expense_lock_expense_for_update(p_expense_id);

  INSERT INTO public.expense_splits (expense_id, debtor_user_id, amount_cents, status, marked_paid_at)
  SELECT
    p_expense_id,
    s.debtor_user_id,
    s.amount_cents,
    CASE
      WHEN s.debtor_user_id = p_creator_user_id
        THEN 'paid'::public.expense_share_status
      ELSE 'unpaid'::public.expense_share_status
    END,
    CASE
      WHEN s.debtor_user_id = p_creator_user_id
        THEN now()
      ELSE NULL
    END
  FROM public._expense_get_validated_debtor_splits(
    v_expense.home_id,
    p_creator_user_id,
    p_amount_cents,
    p_split_mode,
    p_member_ids,
    p_splits
  ) s
  ON CONFLICT (expense_id, debtor_user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_persist_debtor_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_persist_unit_splits(
  p_expense_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense public.expenses%ROWTYPE;
BEGIN
  v_expense := public._expense_lock_expense_for_update(p_expense_id);

  INSERT INTO public.expense_unit_splits (
    expense_id,
    home_id,
    unit_id,
    amount_cents,
    paid_cents,
    fully_paid_at
  )
  SELECT
    p_expense_id,
    v_expense.home_id,
    s.unit_id,
    s.amount_cents,
    0,
    NULL
  FROM public._expense_get_validated_unit_splits(
    v_expense.home_id,
    p_creator_user_id,
    p_amount_cents,
    p_split_mode,
    p_unit_ids,
    p_unit_splits
  ) s
  ON CONFLICT (expense_id, unit_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_persist_unit_splits(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_persist_plan_debtor_targets(
  p_plan_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan public.expense_plans%ROWTYPE;
BEGIN
  v_plan := public._expense_lock_plan_for_update(p_plan_id);

  INSERT INTO public.expense_plan_debtors (plan_id, debtor_user_id, share_amount_cents)
  SELECT
    p_plan_id,
    s.debtor_user_id,
    s.amount_cents
  FROM public._expense_get_validated_debtor_splits(
    v_plan.home_id,
    p_creator_user_id,
    p_amount_cents,
    p_split_mode,
    p_member_ids,
    p_splits
  ) s
  ON CONFLICT (plan_id, debtor_user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_persist_plan_debtor_targets(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_persist_plan_unit_targets(
  p_plan_id uuid,
  p_creator_user_id uuid,
  p_amount_cents bigint,
  p_split_mode public.expense_split_type,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan public.expense_plans%ROWTYPE;
BEGIN
  v_plan := public._expense_lock_plan_for_update(p_plan_id);

  INSERT INTO public.expense_plan_units (plan_id, home_id, unit_id, share_amount_cents)
  SELECT
    p_plan_id,
    v_plan.home_id,
    s.unit_id,
    s.amount_cents
  FROM public._expense_get_validated_unit_splits(
    v_plan.home_id,
    p_creator_user_id,
    p_amount_cents,
    p_split_mode,
    p_unit_ids,
    p_unit_splits
  ) s
  ON CONFLICT (plan_id, unit_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_persist_plan_unit_targets(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb)
FROM PUBLIC, anon, authenticated;

/* =====================================================================
   5) EDITABILITY + FINALIZATION + CYCLE GENERATION HELPERS
   ===================================================================== */

CREATE OR REPLACE FUNCTION public._expense_get_editability(
  p_expense_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense public.expenses%ROWTYPE;
  v_plan_status public.expense_plan_status;
  v_can_edit boolean := FALSE;
  v_reason text := NULL;
BEGIN
  IF p_expense_id IS NULL OR p_user_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_EDITABILITY_SCOPE',
      'Expense id and user id are required.',
      '22023'
    );
  END IF;

  SELECT e.*
  INTO v_expense
  FROM public.expenses e
  WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Expense not found.',
      'P0002',
      jsonb_build_object('expenseId', p_expense_id)
    );
  END IF;

  PERFORM public._assert_home_active(v_expense.home_id);
  PERFORM public._expense_require_current_membership(v_expense.home_id, p_user_id);

  IF v_expense.created_by_user_id <> p_user_id THEN
    RETURN jsonb_build_object(
      'canEdit', false,
      'reason', 'NOT_CREATOR'
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
        v_reason := 'CONVERTED_TO_PLAN';
      ELSE
        v_reason := 'RECURRING_CYCLE_IMMUTABLE';
      END IF;
    ELSE
      CASE v_expense.status
        WHEN 'active'::public.expense_status THEN v_reason := 'ACTIVE_IMMUTABLE';
        WHEN 'converted'::public.expense_status THEN v_reason := 'CONVERTED_TO_PLAN';
        ELSE v_reason := 'NOT_EDITABLE';
      END CASE;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'canEdit', v_can_edit,
    'reason', v_reason,
    'planStatus', v_plan_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_get_editability(uuid, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_finalize_if_fully_paid_v2(
  p_expense_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense public.expenses%ROWTYPE;
  v_has_unpaid boolean := TRUE;
  v_rows integer := 0;
BEGIN
  v_expense := public._expense_lock_expense_with_home_active(p_expense_id);

  IF v_expense.fully_paid_at IS NOT NULL THEN
    RETURN TRUE;
  END IF;

  IF COALESCE(v_expense.allocation_target_type, 'debtor_based') = 'unit_based' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.expense_unit_splits s
      WHERE s.expense_id = p_expense_id
        AND s.paid_cents < s.amount_cents
    )
    INTO v_has_unpaid;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.expense_splits s
      WHERE s.expense_id = p_expense_id
        AND s.status = 'unpaid'
    )
    INTO v_has_unpaid;
  END IF;

  IF v_has_unpaid THEN
    RETURN FALSE;
  END IF;

  UPDATE public.expenses
  SET fully_paid_at = now()
  WHERE id = p_expense_id
    AND fully_paid_at IS NULL;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 1 THEN
    PERFORM public._expense_quota_apply_finalize_expense(v_expense.home_id);
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_finalize_if_fully_paid_v2(uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._expense_plan_generate_cycle_v3(
  p_plan_id uuid,
  p_cycle_date date,
  p_apply_quota boolean DEFAULT TRUE
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan public.expense_plans%ROWTYPE;
  v_expense public.expenses%ROWTYPE;
  v_invalid_reason text := NULL;
BEGIN
  IF p_plan_id IS NULL OR p_cycle_date IS NULL THEN
    PERFORM public.api_error('INVALID_PLAN', 'Plan id and cycle date are required.', '22023');
  END IF;

  v_plan := public._expense_lock_plan_with_home_active(p_plan_id);

  IF v_plan.status <> 'active' THEN
    PERFORM public.api_error(
      'PLAN_NOT_ACTIVE',
      'Cannot generate cycles for a terminated plan.',
      'P0004',
      jsonb_build_object('planId', p_plan_id, 'status', v_plan.status)
    );
  END IF;

  IF p_apply_quota THEN
    PERFORM public._expense_quota_assert_generate_cycle(v_plan.home_id);
  END IF;

  IF COALESCE(v_plan.allocation_target_type, 'debtor_based') = 'unit_based' THEN
    IF EXISTS (
      SELECT 1
      FROM public.expense_plan_units u
      WHERE u.plan_id = v_plan.id
        AND u.home_id <> v_plan.home_id
    ) THEN
      v_invalid_reason := 'UNIT_TARGET_HOME_MISMATCH';
    ELSIF EXISTS (
      SELECT 1
      FROM public.expense_plan_units u
      LEFT JOIN public.home_units hu
        ON hu.id = u.unit_id
       AND hu.home_id = u.home_id
      WHERE u.plan_id = v_plan.id
        AND hu.id IS NULL
    ) THEN
      v_invalid_reason := 'UNIT_TARGET_INVALID';
    ELSIF EXISTS (
      SELECT 1
      FROM public.expense_plan_units u
      JOIN public.home_units hu
        ON hu.id = u.unit_id
       AND hu.home_id = u.home_id
      WHERE u.plan_id = v_plan.id
        AND hu.archived_at IS NOT NULL
    ) THEN
      v_invalid_reason := 'UNIT_TARGET_ARCHIVED';
    END IF;

    IF v_invalid_reason IS NOT NULL THEN
      UPDATE public.expense_plans
      SET status = 'terminated',
          termination_reason = v_invalid_reason,
          updated_at = now()
      WHERE id = v_plan.id;

      PERFORM public.api_error(
        'PLAN_TERMINATED_INVALID_TARGETS',
        'Recurring plan terminated because unit targets are no longer valid.',
        'P0004',
        jsonb_build_object('planId', v_plan.id, 'reason', v_invalid_reason)
      );
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      allocation_target_type,
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
      COALESCE(v_plan.allocation_target_type, 'debtor_based'),
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
  EXCEPTION
    WHEN unique_violation THEN
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

  IF COALESCE(v_plan.allocation_target_type, 'debtor_based') = 'unit_based' THEN
    INSERT INTO public.expense_unit_splits (
      expense_id,
      home_id,
      unit_id,
      amount_cents,
      paid_cents,
      fully_paid_at
    )
    SELECT
      v_expense.id,
      u.home_id,
      u.unit_id,
      u.share_amount_cents,
      0,
      NULL
    FROM public.expense_plan_units u
    WHERE u.plan_id = v_plan.id
    ON CONFLICT (expense_id, unit_id) DO NOTHING;
  ELSE
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
        WHEN d.debtor_user_id = v_plan.created_by_user_id THEN 'paid'::public.expense_share_status
        ELSE 'unpaid'::public.expense_share_status
      END,
      CASE
        WHEN d.debtor_user_id = v_plan.created_by_user_id THEN now()
        ELSE NULL
      END
    FROM public.expense_plan_debtors d
    WHERE d.plan_id = v_plan.id
    ON CONFLICT (expense_id, debtor_user_id) DO NOTHING;
  END IF;

  IF p_apply_quota THEN
    PERFORM public._expense_quota_apply_generate_cycle(v_plan.home_id);
  END IF;

  RETURN v_expense;
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plan_generate_cycle_v3(uuid, date, boolean)
FROM PUBLIC, anon, authenticated;

/* =====================================================================
   6) NEW PUBLIC RPCS FOR ROLLOUT
   ===================================================================== */

CREATE OR REPLACE FUNCTION public.expenses_create_v5(
  p_home_id uuid,
  p_description text,
  p_amount_cents bigint DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_allocation_target_type text DEFAULT NULL,
  p_split_mode public.expense_split_type DEFAULT NULL,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit text DEFAULT NULL,
  p_start_date date DEFAULT current_date,
  p_evidence_photo_path text DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_photo_path text;
  v_photo_delta integer := 0;
  v_is_recurring boolean := FALSE;
  v_result public.expenses%ROWTYPE;
  v_plan public.expense_plans%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._expense_lock_home_active(p_home_id);
  PERFORM public._expense_require_current_membership(p_home_id, v_user);

  v_photo_path := public._expense_validate_evidence_photo_path(p_evidence_photo_path);
  v_photo_delta := public._expense_validate_photo_transition(NULL, v_photo_path);
  PERFORM public._expense_validate_recurrence_fields(p_recurrence_every, p_recurrence_unit);
  v_is_recurring := p_recurrence_every IS NOT NULL;

  IF p_split_mode IS NULL THEN
    IF p_allocation_target_type IS NOT NULL THEN
      PERFORM public.api_error(
        'INVALID_ALLOCATION_TARGET',
        'Draft expenses must not set allocation target type.',
        '22023'
      );
    END IF;

    IF v_is_recurring THEN
      PERFORM public.api_error(
        'INVALID_RECURRENCE_DRAFT',
        'Recurring expenses must be activated with splits; drafts cannot be recurring.',
        '22023'
      );
    END IF;

    PERFORM public._expense_validate_common_fields(p_description, p_notes, p_amount_cents, TRUE);
    PERFORM public._expense_validate_start_date_range(p_home_id, v_user, p_start_date);

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      allocation_target_type,
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
      p_home_id,
      v_user,
      'draft',
      NULL,
      NULL,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_photo_path,
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    RETURN v_result;
  END IF;

  IF p_allocation_target_type IS NULL THEN
    PERFORM public.api_error(
      'INVALID_ALLOCATION_TARGET',
      'Active expense creation requires an allocation target type.',
      '22023'
    );
  END IF;

  IF p_allocation_target_type NOT IN ('debtor_based', 'unit_based') THEN
    PERFORM public.api_error(
      'INVALID_ALLOCATION_TARGET',
      'Unknown allocation target type.',
      '22023'
    );
  END IF;

  IF p_allocation_target_type = 'debtor_based' AND (p_unit_ids IS NOT NULL OR p_unit_splits IS NOT NULL) THEN
    PERFORM public.api_error(
      'INVALID_ALLOCATION_TARGET',
      'Debtor-based expenses must not include unit split payloads.',
      '22023'
    );
  END IF;

  IF p_allocation_target_type = 'unit_based' AND (p_member_ids IS NOT NULL OR p_splits IS NOT NULL) THEN
    PERFORM public.api_error(
      'INVALID_ALLOCATION_TARGET',
      'Unit-based expenses must not include debtor-based split payloads.',
      '22023'
    );
  END IF;

  PERFORM public._expense_validate_common_fields(p_description, p_notes, p_amount_cents, FALSE);
  PERFORM public._expense_validate_start_date_range(p_home_id, v_user, p_start_date);

  IF NOT v_is_recurring THEN
    PERFORM public._expense_quota_assert_activate_one_off(p_home_id, v_photo_delta);

    INSERT INTO public.expenses (
      home_id,
      created_by_user_id,
      status,
      allocation_target_type,
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
      p_home_id,
      v_user,
      'active',
      p_allocation_target_type,
      p_split_mode,
      p_amount_cents,
      btrim(p_description),
      NULLIF(btrim(p_notes), ''),
      v_photo_path,
      NULL,
      NULL,
      p_start_date
    )
    RETURNING * INTO v_result;

    IF p_allocation_target_type = 'debtor_based' THEN
      PERFORM public._expense_persist_debtor_splits(
        v_result.id,
        v_user,
        p_amount_cents,
        p_split_mode,
        p_member_ids,
        p_splits
      );
    ELSE
      PERFORM public._expense_persist_unit_splits(
        v_result.id,
        v_user,
        p_amount_cents,
        p_split_mode,
        p_unit_ids,
        p_unit_splits
      );
    END IF;

    PERFORM public._expense_quota_apply_activate_one_off(p_home_id, v_photo_delta);
    RETURN v_result;
  END IF;

  PERFORM public._expense_quota_assert_activate_plan_with_first_cycle(p_home_id, v_photo_delta);

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    allocation_target_type,
    split_type,
    amount_cents,
    description,
    notes,
    evidence_photo_path,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status,
    termination_reason
  )
  VALUES (
    p_home_id,
    v_user,
    p_allocation_target_type,
    p_split_mode,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    v_photo_path,
    p_recurrence_every,
    p_recurrence_unit,
    p_start_date,
    public._expense_plan_next_cycle_date_v2(p_recurrence_every, p_recurrence_unit, p_start_date),
    'active',
    NULL
  )
  RETURNING * INTO v_plan;

  IF p_allocation_target_type = 'debtor_based' THEN
    PERFORM public._expense_persist_plan_debtor_targets(
      v_plan.id,
      v_user,
      p_amount_cents,
      p_split_mode,
      p_member_ids,
      p_splits
    );
  ELSE
    PERFORM public._expense_persist_plan_unit_targets(
      v_plan.id,
      v_user,
      p_amount_cents,
      p_split_mode,
      p_unit_ids,
      p_unit_splits
    );
  END IF;

  v_result := public._expense_plan_generate_cycle_v3(v_plan.id, p_start_date, FALSE);
  PERFORM public._expense_quota_apply_activate_plan_with_first_cycle(p_home_id, v_photo_delta);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_create_v5(uuid, text, bigint, text, text, public.expense_split_type, uuid[], jsonb, uuid[], jsonb, integer, text, date, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_create_v5(uuid, text, bigint, text, text, public.expense_split_type, uuid[], jsonb, uuid[], jsonb, integer, text, date, text)
TO authenticated;

CREATE OR REPLACE FUNCTION public.expenses_edit_v5(
  p_expense_id uuid,
  p_amount_cents bigint,
  p_description text,
  p_notes text DEFAULT NULL,
  p_allocation_target_type text DEFAULT NULL,
  p_split_mode public.expense_split_type DEFAULT NULL,
  p_member_ids uuid[] DEFAULT NULL,
  p_splits jsonb DEFAULT NULL,
  p_unit_ids uuid[] DEFAULT NULL,
  p_unit_splits jsonb DEFAULT NULL,
  p_recurrence_every integer DEFAULT NULL,
  p_recurrence_unit text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_evidence_photo_path text DEFAULT NULL
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_existing public.expenses%ROWTYPE;
  v_target_start date;
  v_target_photo_path text;
  v_photo_delta integer := 0;
  v_has_evidence_arg boolean := p_evidence_photo_path IS NOT NULL;
  v_is_recurring boolean := FALSE;
  v_plan public.expense_plans%ROWTYPE;
  v_result public.expenses%ROWTYPE;
  v_editability jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  v_existing := public._expense_lock_expense_with_home_active(p_expense_id);
  PERFORM public._expense_require_current_membership(v_existing.home_id, v_user);

  v_editability := public._expense_get_editability(p_expense_id, v_user);

  IF COALESCE((v_editability ->> 'canEdit')::boolean, FALSE) IS NOT TRUE THEN
    PERFORM public.api_error(
      'EDIT_NOT_ALLOWED',
      'This expense cannot be edited.',
      '42501',
      jsonb_build_object(
        'expenseId', p_expense_id,
        'reason', v_editability ->> 'reason'
      )
    );
  END IF;

  IF v_existing.status = 'active' THEN
    IF p_amount_cents IS DISTINCT FROM v_existing.amount_cents THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Amount is immutable for active expenses.', '42501', jsonb_build_object('field', 'amountCents', 'expenseId', v_existing.id));
    END IF;

    IF p_allocation_target_type IS NOT NULL AND p_allocation_target_type IS DISTINCT FROM v_existing.allocation_target_type THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Allocation target type is immutable for active expenses.', '42501', jsonb_build_object('field', 'allocationTargetType', 'expenseId', v_existing.id));
    END IF;

    IF p_split_mode IS NOT NULL AND p_split_mode IS DISTINCT FROM v_existing.split_type THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Split mode is immutable for active expenses.', '42501', jsonb_build_object('field', 'splitMode', 'expenseId', v_existing.id));
    END IF;

    IF p_member_ids IS NOT NULL OR p_splits IS NOT NULL OR p_unit_ids IS NOT NULL OR p_unit_splits IS NOT NULL THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Splits are immutable for active expenses.', '42501', jsonb_build_object('field', 'splits', 'expenseId', v_existing.id));
    END IF;

    IF p_recurrence_every IS NOT NULL OR p_recurrence_unit IS NOT NULL THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Recurrence is immutable for active expenses.', '42501', jsonb_build_object('field', 'recurrence', 'expenseId', v_existing.id));
    END IF;

    IF p_start_date IS NOT NULL AND p_start_date IS DISTINCT FROM v_existing.start_date THEN
      PERFORM public.api_error('EDIT_NOT_ALLOWED', 'Start date is immutable for active expenses.', '42501', jsonb_build_object('field', 'startDate', 'expenseId', v_existing.id));
    END IF;

    PERFORM public._expense_validate_common_fields(p_description, p_notes, v_existing.amount_cents, FALSE);

    IF v_has_evidence_arg THEN
      v_target_photo_path := public._expense_validate_evidence_photo_path(p_evidence_photo_path);
    ELSE
      v_target_photo_path := v_existing.evidence_photo_path;
    END IF;

    v_photo_delta := public._expense_validate_photo_transition(v_existing.evidence_photo_path, v_target_photo_path);

    IF v_photo_delta = 1 THEN
      PERFORM public._home_assert_quota(
        v_existing.home_id,
        jsonb_build_object('expense_photos', 1)
      );
    END IF;

    UPDATE public.expenses
    SET description = btrim(p_description),
        notes = NULLIF(btrim(p_notes), ''),
        evidence_photo_path = v_target_photo_path,
        updated_at = now()
    WHERE id = v_existing.id
    RETURNING * INTO v_result;

    IF v_photo_delta = 1 THEN
      PERFORM public._home_usage_apply_delta(
        v_existing.home_id,
        jsonb_build_object('expense_photos', 1)
      );
    END IF;

    RETURN v_result;
  END IF;

  IF p_allocation_target_type IS NULL THEN
    PERFORM public.api_error('INVALID_ALLOCATION_TARGET', 'Editing a draft to active requires allocation target type.', '22023');
  END IF;

  IF p_allocation_target_type NOT IN ('debtor_based', 'unit_based') THEN
    PERFORM public.api_error('INVALID_ALLOCATION_TARGET', 'Unknown allocation target type.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLITS', 'Splits are required. Editing an expense always activates it.', '22023');
  END IF;

  IF p_allocation_target_type = 'debtor_based' AND (p_unit_ids IS NOT NULL OR p_unit_splits IS NOT NULL) THEN
    PERFORM public.api_error('INVALID_ALLOCATION_TARGET', 'Debtor-based expenses must not include unit split payloads.', '22023');
  END IF;

  IF p_allocation_target_type = 'unit_based' AND (p_member_ids IS NOT NULL OR p_splits IS NOT NULL) THEN
    PERFORM public.api_error('INVALID_ALLOCATION_TARGET', 'Unit-based expenses must not include debtor-based split payloads.', '22023');
  END IF;

  PERFORM public._expense_validate_common_fields(p_description, p_notes, p_amount_cents, FALSE);
  PERFORM public._expense_validate_recurrence_fields(p_recurrence_every, p_recurrence_unit);
  v_target_start := COALESCE(p_start_date, v_existing.start_date);
  PERFORM public._expense_validate_start_date_range(v_existing.home_id, v_user, v_target_start);

  IF v_has_evidence_arg THEN
    v_target_photo_path := public._expense_validate_evidence_photo_path(p_evidence_photo_path);
  ELSE
    v_target_photo_path := v_existing.evidence_photo_path;
  END IF;

  v_photo_delta := public._expense_validate_photo_transition(v_existing.evidence_photo_path, v_target_photo_path);
  v_is_recurring := p_recurrence_every IS NOT NULL;

  IF NOT v_is_recurring THEN
    PERFORM public._expense_quota_assert_activate_one_off(v_existing.home_id, v_photo_delta);

    UPDATE public.expenses
    SET status = 'active',
        allocation_target_type = p_allocation_target_type,
        split_type = p_split_mode,
        amount_cents = p_amount_cents,
        description = btrim(p_description),
        notes = NULLIF(btrim(p_notes), ''),
        evidence_photo_path = v_target_photo_path,
        recurrence_every = NULL,
        recurrence_unit = NULL,
        start_date = v_target_start,
        updated_at = now()
    WHERE id = v_existing.id
    RETURNING * INTO v_result;

    IF p_allocation_target_type = 'debtor_based' THEN
      PERFORM public._expense_persist_debtor_splits(
        v_result.id,
        v_user,
        p_amount_cents,
        p_split_mode,
        p_member_ids,
        p_splits
      );
    ELSE
      PERFORM public._expense_persist_unit_splits(
        v_result.id,
        v_user,
        p_amount_cents,
        p_split_mode,
        p_unit_ids,
        p_unit_splits
      );
    END IF;

    PERFORM public._expense_quota_apply_activate_one_off(v_existing.home_id, v_photo_delta);
    RETURN v_result;
  END IF;

  PERFORM public._expense_quota_assert_activate_plan_with_first_cycle(v_existing.home_id, v_photo_delta);

  INSERT INTO public.expense_plans (
    home_id,
    created_by_user_id,
    allocation_target_type,
    split_type,
    amount_cents,
    description,
    notes,
    evidence_photo_path,
    recurrence_every,
    recurrence_unit,
    start_date,
    next_cycle_date,
    status,
    termination_reason
  )
  VALUES (
    v_existing.home_id,
    v_user,
    p_allocation_target_type,
    p_split_mode,
    p_amount_cents,
    btrim(p_description),
    NULLIF(btrim(p_notes), ''),
    v_target_photo_path,
    p_recurrence_every,
    p_recurrence_unit,
    v_target_start,
    public._expense_plan_next_cycle_date_v2(p_recurrence_every, p_recurrence_unit, v_target_start),
    'active',
    NULL
  )
  RETURNING * INTO v_plan;

  IF p_allocation_target_type = 'debtor_based' THEN
    PERFORM public._expense_persist_plan_debtor_targets(
      v_plan.id,
      v_user,
      p_amount_cents,
      p_split_mode,
      p_member_ids,
      p_splits
    );
  ELSE
    PERFORM public._expense_persist_plan_unit_targets(
      v_plan.id,
      v_user,
      p_amount_cents,
      p_split_mode,
      p_unit_ids,
      p_unit_splits
    );
  END IF;

  UPDATE public.expenses
  SET status = 'converted',
      plan_id = v_plan.id,
      allocation_target_type = p_allocation_target_type,
      recurrence_every = p_recurrence_every,
      recurrence_unit = p_recurrence_unit,
      evidence_photo_path = v_target_photo_path,
      start_date = v_target_start,
      updated_at = now()
  WHERE id = v_existing.id;

  v_result := public._expense_plan_generate_cycle_v3(v_plan.id, v_target_start, FALSE);
  PERFORM public._expense_quota_apply_activate_plan_with_first_cycle(v_existing.home_id, v_photo_delta);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_edit_v5(uuid, bigint, text, text, text, public.expense_split_type, uuid[], jsonb, uuid[], jsonb, integer, text, date, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_edit_v5(uuid, bigint, text, text, text, public.expense_split_type, uuid[], jsonb, uuid[], jsonb, integer, text, date, text)
TO authenticated;

CREATE OR REPLACE FUNCTION public.expenses_get_for_edit_v3(
  p_expense_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_expense public.expenses%ROWTYPE;
  v_plan_status public.expense_plan_status;
  v_splits jsonb := '[]'::jsonb;
  v_unit_splits jsonb := '[]'::jsonb;
  v_editability jsonb;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id is required.', '22023');
  END IF;

  SELECT e.*
  INTO v_expense
  FROM public.expenses e
  WHERE e.id = p_expense_id;

  IF NOT FOUND THEN
    PERFORM public.api_error('NOT_FOUND', 'Expense not found.', 'P0002', jsonb_build_object('expenseId', p_expense_id));
  END IF;

  PERFORM public._assert_home_active(v_expense.home_id);
  PERFORM public._expense_require_current_membership(v_expense.home_id, v_user);

  IF v_expense.created_by_user_id <> v_user THEN
    PERFORM public.api_error('NOT_CREATOR', 'Only the creator can edit this expense.', '42501', jsonb_build_object('expenseId', p_expense_id, 'userId', v_user));
  END IF;

  v_editability := public._expense_get_editability(p_expense_id, v_user);
  v_plan_status := NULLIF(v_editability ->> 'planStatus', '')::public.expense_plan_status;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId', s.expense_id,
               'debtorUserId', s.debtor_user_id,
               'amountCents', s.amount_cents,
               'status', s.status,
               'markedPaidAt', s.marked_paid_at
             )
             ORDER BY s.debtor_user_id
           ),
           '[]'::jsonb
         )
  INTO v_splits
  FROM public.expense_splits s
  WHERE s.expense_id = v_expense.id;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'expenseId', s.expense_id,
               'unitId', s.unit_id,
               'unitName', hu.name,
               'unitType', hu.unit_type,
               'amountCents', s.amount_cents,
               'paidCents', s.paid_cents,
               'remainingCents', s.amount_cents - s.paid_cents,
               'fullyPaidAt', s.fully_paid_at
             )
             ORDER BY hu.name, s.unit_id
           ),
           '[]'::jsonb
         )
  INTO v_unit_splits
  FROM public.expense_unit_splits s
  JOIN public.home_units hu
    ON hu.id = s.unit_id
   AND hu.home_id = s.home_id
  WHERE s.expense_id = v_expense.id;

  RETURN jsonb_build_object(
    'expenseId', v_expense.id,
    'homeId', v_expense.home_id,
    'createdByUserId', v_expense.created_by_user_id,
    'status', v_expense.status,
    'allocationTargetType', v_expense.allocation_target_type,
    'splitType', v_expense.split_type,
    'amountCents', v_expense.amount_cents,
    'description', v_expense.description,
    'notes', v_expense.notes,
    'evidencePhotoPath', v_expense.evidence_photo_path,
    'createdAt', v_expense.created_at,
    'updatedAt', v_expense.updated_at,
    'planId', v_expense.plan_id,
    'planStatus', v_plan_status,
    'recurrenceEvery', v_expense.recurrence_every,
    'recurrenceUnit', v_expense.recurrence_unit,
    'startDate', v_expense.start_date,
    'canEdit', COALESCE((v_editability ->> 'canEdit')::boolean, FALSE),
    'editDisabledReason', v_editability ->> 'reason',
    'splits', v_splits,
    'unitSplits', v_unit_splits
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_for_edit_v3(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_get_for_edit_v3(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.expenses_get_current_owed_v3(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
  v_result jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'payerUserId', payer_user_id,
               'payerDisplay', payer_display,
               'payerAvatarUrl', payer_avatar_url,
               'totalOwedCents', total_owed_cents,
               'containsSharedUnitBalance', contains_shared_unit_balance,
               'items', items
             )
             ORDER BY payer_display NULLS LAST, payer_user_id
           ),
           '[]'::jsonb
         )
  INTO v_result
  FROM (
    SELECT
      payer_user_id,
      payer_display,
      payer_avatar_url,
      SUM(remaining_cents) AS total_owed_cents,
      BOOL_OR(contains_shared_unit_balance) AS contains_shared_unit_balance,
      jsonb_agg(item ORDER BY created_at DESC, expense_id) AS items
    FROM (
      SELECT
        e.created_by_user_id AS payer_user_id,
        COALESCE(p.username, p.full_name, p.email) AS payer_display,
        a.storage_path AS payer_avatar_url,
        e.created_at,
        e.id AS expense_id,
        s.amount_cents AS remaining_cents,
        FALSE AS contains_shared_unit_balance,
        jsonb_build_object(
          'expenseId', e.id,
          'allocationTargetType', 'debtor_based',
          'liabilityKind', 'personal',
          'liabilityScope', 'user',
          'displayMode', 'personal_balance',
          'description', e.description,
          'amountCents', s.amount_cents,
          'paidCents', 0,
          'remainingCents', s.amount_cents,
          'notes', e.notes,
          'evidencePhotoPath', e.evidence_photo_path,
          'recurrenceEvery', e.recurrence_every,
          'recurrenceUnit', e.recurrence_unit,
          'startDate', e.start_date
        ) AS item
      FROM public.expense_splits s
      JOIN public.expenses e
        ON e.id = s.expense_id
      JOIN public.profiles p
        ON p.id = e.created_by_user_id
      LEFT JOIN public.avatars a
        ON a.id = p.avatar_id
      WHERE e.home_id = p_home_id
        AND e.status = 'active'
        AND COALESCE(e.allocation_target_type, 'debtor_based') = 'debtor_based'
        AND s.debtor_user_id = v_user
        AND s.status = 'unpaid'

      UNION ALL

      SELECT
        e.created_by_user_id AS payer_user_id,
        COALESCE(p.username, p.full_name, p.email) AS payer_display,
        a.storage_path AS payer_avatar_url,
        e.created_at,
        e.id AS expense_id,
        (s.amount_cents - s.paid_cents) AS remaining_cents,
        (hu.unit_type = 'shared') AS contains_shared_unit_balance,
        jsonb_build_object(
          'expenseId', e.id,
          'allocationTargetType', 'unit_based',
          'liabilityKind', CASE WHEN hu.unit_type = 'shared' THEN 'shared' ELSE 'personal' END,
          'liabilityScope', 'unit',
          'displayMode', CASE WHEN hu.unit_type = 'shared' THEN 'shared_unit_balance' ELSE 'unit_balance' END,
          'unitId', s.unit_id,
          'unitName', hu.name,
          'description', e.description,
          'amountCents', s.amount_cents,
          'paidCents', s.paid_cents,
          'remainingCents', (s.amount_cents - s.paid_cents),
          'notes', e.notes,
          'evidencePhotoPath', e.evidence_photo_path,
          'recurrenceEvery', e.recurrence_every,
          'recurrenceUnit', e.recurrence_unit,
          'startDate', e.start_date
        ) AS item
      FROM public.expense_unit_splits s
      JOIN public.expenses e
        ON e.id = s.expense_id
      JOIN public.home_units hu
        ON hu.id = s.unit_id
       AND hu.home_id = s.home_id
      JOIN public.profiles p
        ON p.id = e.created_by_user_id
      LEFT JOIN public.avatars a
        ON a.id = p.avatar_id
      WHERE e.home_id = p_home_id
        AND e.status = 'active'
        AND e.allocation_target_type = 'unit_based'
        AND s.paid_cents < s.amount_cents
        AND EXISTS (
          SELECT 1
          FROM public.home_unit_members hum
          JOIN public.memberships m
            ON m.id = hum.membership_id
          WHERE hum.unit_id = s.unit_id
            AND m.user_id = v_user
            AND m.home_id = p_home_id
            AND m.valid_to IS NULL
        )
    ) unioned
    GROUP BY payer_user_id, payer_display, payer_avatar_url
  ) grouped;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_get_current_owed_v3(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_get_current_owed_v3(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.expenses_pay_unit_due_v2(
  p_expense_id uuid,
  p_unit_id uuid,
  p_amount_cents bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_remaining bigint;
  v_new_paid bigint;
  v_expense public.expenses%ROWTYPE;
  v_is_current_member boolean := FALSE;
  v_fully_paid boolean := FALSE;
BEGIN
  PERFORM public._assert_authenticated();

  IF p_expense_id IS NULL OR p_unit_id IS NULL THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense id and unit id are required.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error('INVALID_PAYMENT_AMOUNT', 'Payment amount must be positive.', '22023');
  END IF;

  v_expense := public._expense_lock_expense_with_home_active(p_expense_id);

  SELECT TRUE
  INTO v_is_current_member
  FROM public.memberships m
  JOIN public.home_unit_members hum
    ON hum.membership_id = m.id
   AND hum.unit_id = p_unit_id
  WHERE m.home_id = v_expense.home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF COALESCE(v_is_current_member, FALSE) IS NOT TRUE THEN
    PERFORM public.api_error(
      'INVALID_UNIT_SCOPE',
      'Caller is not a current member of the debtor unit.',
      '42501',
      jsonb_build_object('expenseId', p_expense_id, 'unitId', p_unit_id)
    );
  END IF;

  IF v_expense.status <> 'active' OR v_expense.allocation_target_type IS DISTINCT FROM 'unit_based' THEN
    PERFORM public.api_error('INVALID_EXPENSE', 'Expense is not an active unit-based expense.', '22023');
  END IF;

  SELECT (s.amount_cents - s.paid_cents)
  INTO v_remaining
  FROM public.expense_unit_splits s
  WHERE s.expense_id = p_expense_id
    AND s.unit_id = p_unit_id
  FOR UPDATE;

  IF v_remaining IS NULL THEN
    PERFORM public.api_error('INVALID_UNIT_TARGET', 'Unit split not found for this expense.', 'P0002');
  END IF;

  IF p_amount_cents > v_remaining THEN
    PERFORM public.api_error(
      'INVALID_PAYMENT_AMOUNT',
      'Payment exceeds remaining unit balance.',
      '22023',
      jsonb_build_object('remainingCents', v_remaining, 'attemptedAmountCents', p_amount_cents)
    );
  END IF;

  UPDATE public.expense_unit_splits s
  SET paid_cents = s.paid_cents + p_amount_cents,
      fully_paid_at = CASE
        WHEN s.paid_cents + p_amount_cents = s.amount_cents THEN now()
        ELSE NULL
      END
  WHERE s.expense_id = p_expense_id
    AND s.unit_id = p_unit_id
  RETURNING paid_cents INTO v_new_paid;

  INSERT INTO public.expense_unit_payment_events (
    expense_id,
    unit_id,
    payer_user_id,
    amount_cents
  )
  VALUES (
    p_expense_id,
    p_unit_id,
    v_user,
    p_amount_cents
  );

  v_fully_paid := public._expense_finalize_if_fully_paid_v2(p_expense_id);

  RETURN jsonb_build_object(
    'expenseId', p_expense_id,
    'unitId', p_unit_id,
    'payerUserId', v_user,
    'amountPaidCents', p_amount_cents,
    'paidCents', v_new_paid,
    'remainingCents', GREATEST(0, v_remaining - p_amount_cents),
    'expenseFullyPaid', v_fully_paid
  );
END;
$$;

REVOKE ALL ON FUNCTION public.expenses_pay_unit_due_v2(uuid, uuid, bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_pay_unit_due_v2(uuid, uuid, bigint)
TO authenticated;

/* =====================================================================
   7) NO CLEANUP YET
   ===================================================================== */

COMMIT;
