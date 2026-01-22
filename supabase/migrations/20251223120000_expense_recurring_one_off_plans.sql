-- Fold recurring plan activation into expenses_create/edit, add bulk pay, surface recurrence fields, and wire cron
-- ADJUSTMENTS (FINAL, UPDATED + Option A):
-- A) remove main_payer_user_id (payer = created_by_user_id everywhere)
-- B) Draft creation does NOT consume quota and does NOT increment active_expenses.
--    Quota + usage delta happen ONLY when an ACTIVE expense is created:
--      - expenses_create with splits (one-off active)
--      - expenses_edit when draft -> active (one-off activation)
--      - recurring cycle creation increments inside _expense_plan_generate_cycle (including first cycle)
-- C) Strategy: Fold recurring activation into create/edit (no separate plan activation RPC assumed)
-- D) Uses _expenses_prepare_split_buffer (function owns CREATE TEMP + TRUNCATE)
-- E) start_date is DATE and is never timezone-converted
-- F) Drafts can ONLY be created via expenses_create. Drafts MAY store start_date.
--    UPDATED: Drafts MAY optionally store amount_cents (NULL or >0), but amount is REQUIRED to activate (splits present).
--    expenses_edit ALWAYS activates a draft and WILL NOT keep draft status.
-- G) Bulk pay decrement is idempotent and canonical via expenses.fully_paid_at (set once).
-- H) _home_assert_quota paths are serialized via FOR UPDATE lock on homes.
-- I) Convention enforced: any split update must lock the parent expense row first,
--    with global lock order: homes -> expenses -> splits (homes sorted if multiple).
-- J) pg_cron schedule is upsert-like (safe to re-run migration).
-- K) Once an expense is ACTIVE, it is immutable (no edit, no cancel).
-- L) Option A: introduce expense_status = 'converted' for draft->plan conversion (distinct from 'cancelled').
--
-- NEW (this version):
-- M) expenses_pay_my_due is recipient-scoped bulk pay: expenses_pay_my_due(p_recipient_user_id uuid)
--    Debtor is auth.uid(); Recipient is expenses.created_by_user_id. Summary-only return.
-- N) expenses_mark_share_paid wrapper dropped (redundant).
--
-- ALSO FIXED:
-- O) Potential constraint break: amount_cents constraint now allows NULL OR >0 (drafts can carry amount or not).

-- =====================================================================
-- Expenses table: canonical fully-paid timestamp (also idempotency guard)
-- =====================================================================
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS fully_paid_at timestamptz;

-- =====================================================================
-- Expenses table: recurrence + plan linkage + start_date (date)
-- (safe if already applied; re-runnable)
-- =====================================================================
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS plan_id uuid,
  ADD COLUMN IF NOT EXISTS recurrence_interval public.recurrence_interval NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS start_date date;

-- Backfill start_date for any legacy rows
UPDATE public.expenses e
   SET start_date = COALESCE(e.start_date, (timezone('UTC', e.created_at))::date)
 WHERE e.start_date IS NULL;

ALTER TABLE public.expenses
  ALTER COLUMN start_date SET NOT NULL;

-- =====================================================================
-- Expenses table constraints (DB-level invariants)
-- Your requested constraints + FIX for amount_cents allowing NULL or >0
-- =====================================================================

-- Description and notes length (keep your exact limits)
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_description_length,
  ADD CONSTRAINT chk_expenses_description_length
    CHECK (char_length(btrim(description)) <= 280);

ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_notes_length,
  ADD CONSTRAINT chk_expenses_notes_length
    CHECK (notes IS NULL OR char_length(notes) <= 2000);

-- Active requires amount_cents present + >0
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_active_amount_required,
  ADD CONSTRAINT chk_expenses_active_amount_required
    CHECK (
      (status <> 'active'::public.expense_status)
      OR (amount_cents IS NOT NULL AND amount_cents > 0)
    );

-- Active requires split_type present
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_active_split_required,
  ADD CONSTRAINT chk_expenses_active_split_required
    CHECK (
      (status <> 'active'::public.expense_status)
      OR (split_type IS NOT NULL)
    );

-- FIX: amount_cents may be NULL (drafts), otherwise must be > 0
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_amount_positive,
  ADD CONSTRAINT chk_expenses_amount_positive
    CHECK (amount_cents IS NULL OR amount_cents > 0);

-- Plan alignment: plan_id required only when recurrence is set
ALTER TABLE public.expenses
  DROP CONSTRAINT IF EXISTS chk_expenses_plan_alignment,
  ADD CONSTRAINT chk_expenses_plan_alignment
    CHECK (
      (recurrence_interval = 'none' AND plan_id IS NULL)
      OR (recurrence_interval <> 'none' AND plan_id IS NOT NULL)
    );

COMMENT ON COLUMN public.expenses.plan_id IS
  'Nullable for one-off expenses; set for cycle expenses generated from a plan.';
COMMENT ON COLUMN public.expenses.recurrence_interval IS
  'none for one-off; copied from plan for recurring cycles.';
COMMENT ON COLUMN public.expenses.start_date IS
  'Cycle start date (or one-off effective date).';
COMMENT ON COLUMN public.expenses.fully_paid_at IS
  'Canonical fully-paid timestamp; set once. Used as idempotency guard for usage decrements.';

-- =====================================================================
-- Indexes
-- =====================================================================

-- If you had an old name, drop it safely
DROP INDEX IF EXISTS public.expenses_fully_paid_at_idx;

-- Active unpaid expenses per home
CREATE INDEX IF NOT EXISTS idx_expenses_active_unpaid
ON public.expenses (home_id, created_at DESC)
WHERE status = 'active'::public.expense_status
  AND fully_paid_at IS NULL;

-- Helpful index for "unpaid exists?" checks
CREATE INDEX IF NOT EXISTS idx_expense_splits_expense_status
ON public.expense_splits (expense_id, status);

-- Existing useful indexes (safe to keep/create)
CREATE INDEX IF NOT EXISTS idx_expenses_home_status_created_at
  ON public.expenses (home_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_expenses_creator_created_at
  ON public.expenses (created_by_user_id, home_id, created_at DESC);

-- plan_id index + unique cycle guard
CREATE INDEX IF NOT EXISTS idx_expenses_plan_id
  ON public.expenses (plan_id);

DROP INDEX IF EXISTS public.ux_expenses_plan_cycle_unique;

CREATE UNIQUE INDEX IF NOT EXISTS ux_expenses_plan_cycle_unique
ON public.expenses (plan_id, start_date)
WHERE plan_id IS NOT NULL
  AND status = 'active'::public.expense_status;

-- =====================================================================
-- Helper: _home_usage_apply_delta
-- Enforce deterministic lock order: homes -> counters
-- =====================================================================
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
  v_row                    public.home_usage_counters;
  v_home_active            boolean;

  v_active_chores_delta    integer := 0;
  v_chore_photos_delta     integer := 0;
  v_active_members_delta   integer := 0;
  v_active_expenses_delta  integer := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  -- Lock home FIRST to match global lock order (homes -> ...)
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
  END IF;

  UPDATE public.home_usage_counters h
     SET active_chores   = GREATEST(0, COALESCE(h.active_chores, 0) + v_active_chores_delta),
         chore_photos    = GREATEST(0, COALESCE(h.chore_photos, 0) + v_chore_photos_delta),
         active_members  = GREATEST(0, COALESCE(h.active_members, 0) + v_active_members_delta),
         active_expenses = GREATEST(0, COALESCE(h.active_expenses, 0) + v_active_expenses_delta),
         updated_at      = now()
   WHERE h.home_id = p_home_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- =====================================================================
-- Helper: _home_assert_quota
-- Serialized with other home mutations via homes FOR UPDATE (homes -> counters)
-- NOTE: cron-driven recurring generation ignores quota by design (does not call this).
-- =====================================================================
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
  v_plan          text;
  v_is_premium    boolean;

  v_home_active   boolean;
  v_counters      public.home_usage_counters%ROWTYPE;

  v_metric_key    text;
  v_metric_enum   public.home_usage_metric;
  v_raw_value     jsonb;
  v_delta         integer;
  v_current       integer;
  v_new           integer;
  v_max           integer;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  -- Lock home FIRST (global order: homes -> ...)
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

  IF v_home_active IS DISTINCT FROM TRUE THEN
    PERFORM public.api_error(
      'HOME_INACTIVE',
      'This home is no longer active.',
      'P0004',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;

  v_is_premium := public._home_is_premium(p_home_id);
  IF v_is_premium THEN
    RETURN;
  END IF;

  IF p_deltas IS NULL OR jsonb_typeof(p_deltas) <> 'object' THEN
    RETURN;
  END IF;

  v_plan := public._home_effective_plan(p_home_id);

  INSERT INTO public.home_usage_counters (home_id)
  VALUES (p_home_id)
  ON CONFLICT (home_id) DO NOTHING;

  SELECT *
    INTO v_counters
    FROM public.home_usage_counters
   WHERE home_id = p_home_id
   FOR UPDATE;

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

-- =====================================================================
-- Helper: _expenses_prepare_split_buffer (as you provided)
-- =====================================================================
-- Fix _expenses_prepare_split_buffer equal-split scope (no orphaned CTE) and
-- harden expenses_pay_my_due home locking.

-- Recreate split buffer helper with self-contained ordered subqueries
CREATE OR REPLACE FUNCTION public._expenses_prepare_split_buffer(
  p_home_id      uuid,
  p_creator_id   uuid,
  p_amount_cents bigint,
  p_split_mode   public.expense_split_type,
  p_member_ids   uuid[] DEFAULT NULL,
  p_splits       jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_split_count         integer := 0;
  v_split_sum           bigint  := 0;
  v_distinct_count      integer := 0;
  v_non_creator_members integer := 0;
  v_member_match_count  integer := 0;

  v_total_count         integer := 0;
  v_equal_share         bigint  := 0;
  v_remainder           bigint  := 0;
BEGIN
  IF p_home_id IS NULL THEN
    PERFORM public.api_error('INVALID_HOME', 'Home id is required.', '22023');
  END IF;

  IF p_creator_id IS NULL THEN
    PERFORM public.api_error('INVALID_CREATOR', 'Creator id is required.', '22023');
  END IF;

  IF p_split_mode IS NULL THEN
    PERFORM public.api_error('INVALID_SPLIT', 'Split mode is required to build splits.', '22023');
  END IF;

  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM public.api_error(
      'INVALID_AMOUNT',
      'Amount must be a positive integer.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents)
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.expense_split_buffer (
    debtor_user_id uuid NOT NULL,
    amount_cents   bigint NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE TABLE pg_temp.expense_split_buffer;

  IF p_split_mode = 'equal' THEN
    IF p_member_ids IS NULL OR array_length(p_member_ids, 1) IS NULL THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Provide at least two members for an equal split.',
        '22023'
      );
    END IF;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn,
        COUNT(*) OVER () AS total_count
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    SELECT COALESCE(MAX(total_count), 0)
      INTO v_total_count
      FROM ordered;

    IF v_total_count < 2 THEN
      PERFORM public.api_error(
        'SPLIT_MEMBERS_REQUIRED',
        'Include at least two members in the split.',
        '22023'
      );
    END IF;

    v_equal_share := p_amount_cents / v_total_count;
    v_remainder   := p_amount_cents % v_total_count;

    WITH ordered AS (
      SELECT
        member_id,
        ROW_NUMBER() OVER (ORDER BY ord_position) AS rn
      FROM (
        SELECT DISTINCT ON (raw.member_id)
               raw.member_id,
               raw.ord_position
        FROM unnest(p_member_ids)
          WITH ORDINALITY AS raw(member_id, ord_position)
        WHERE raw.member_id IS NOT NULL
        ORDER BY raw.member_id, raw.ord_position
      ) deduped
    )
    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT
      member_id,
      v_equal_share + CASE WHEN rn = v_total_count THEN v_remainder ELSE 0 END
    FROM ordered
    ORDER BY rn;

  ELSIF p_split_mode = 'custom' THEN
    IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
      PERFORM public.api_error('INVALID_SPLIT', 'p_splits must be a JSON array.', '22023');
    END IF;

    INSERT INTO pg_temp.expense_split_buffer (debtor_user_id, amount_cents)
    SELECT x.user_id, x.amount_cents
    FROM jsonb_to_recordset(p_splits) AS x(user_id uuid, amount_cents bigint);

  ELSE
    PERFORM public.api_error('INVALID_SPLIT', 'Unknown split type.', '22023');
  END IF;

  SELECT COUNT(*)::int,
         COALESCE(SUM(amount_cents), 0),
         COUNT(DISTINCT debtor_user_id)::int
    INTO v_split_count, v_split_sum, v_distinct_count
    FROM pg_temp.expense_split_buffer;

  IF v_split_count < 2 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least two members in the split.', '22023');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.expense_split_buffer
    WHERE debtor_user_id IS NULL
       OR amount_cents   IS NULL
       OR amount_cents  <= 0
  ) THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each split requires a member and a positive amount.', '22023');
  END IF;

  IF v_distinct_count <> v_split_count THEN
    PERFORM public.api_error('INVALID_DEBTOR', 'Each debtor must appear only once.', '22023');
  END IF;

  IF v_split_sum <> p_amount_cents THEN
    PERFORM public.api_error(
      'SPLIT_SUM_MISMATCH',
      'Split amounts must add up to the total amount.',
      '22023',
      jsonb_build_object('amountCents', p_amount_cents, 'splitSumCents', v_split_sum)
    );
  END IF;

  SELECT COUNT(*)::int
    INTO v_non_creator_members
    FROM pg_temp.expense_split_buffer
   WHERE debtor_user_id <> p_creator_id;

  IF v_non_creator_members = 0 THEN
    PERFORM public.api_error('SPLIT_MEMBERS_REQUIRED', 'Include at least one other member in the split.', '22023');
  END IF;

  SELECT COUNT(*)::int
    INTO v_member_match_count
    FROM pg_temp.expense_split_buffer s
    JOIN public.memberships m
      ON m.home_id    = p_home_id
     AND m.user_id    = s.debtor_user_id
     AND m.is_current = TRUE
     AND m.valid_to IS NULL;

  IF v_member_match_count <> v_split_count THEN
    PERFORM public.api_error(
      'INVALID_DEBTOR',
      'All debtors must be current members of this home.',
      '42501',
      jsonb_build_object('homeId', p_home_id)
    );
  END IF;
END;
$$;


-- =====================================================================
-- Recurring plan tables (expense_plans, expense_plan_debtors) + RLS
-- (Kept from your earlier recurring code; included here for completeness)
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.expense_plans (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id             uuid NOT NULL REFERENCES public.homes(id)    ON DELETE RESTRICT,
  created_by_user_id  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,

  split_type          public.expense_split_type NOT NULL,
  amount_cents        bigint NOT NULL,
  description         text NOT NULL,
  notes               text,
  recurrence_interval public.recurrence_interval NOT NULL,
  start_date          date NOT NULL,
  next_cycle_date     date NOT NULL,
  status              public.expense_plan_status NOT NULL DEFAULT 'active',
  terminated_at       timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_expense_plans_amount_positive
    CHECK (amount_cents > 0),
  CONSTRAINT chk_expense_plans_description_length
    CHECK (char_length(btrim(description)) <= 280),
  CONSTRAINT chk_expense_plans_notes_length
    CHECK (notes IS NULL OR char_length(notes) <= 2000),
  CONSTRAINT chk_expense_plans_status_timestamp
    CHECK (
      (status = 'terminated' AND terminated_at IS NOT NULL)
      OR (status = 'active' AND terminated_at IS NULL)
    ),
  CONSTRAINT chk_expense_plans_recurrence_non_none
    CHECK (recurrence_interval <> 'none')
);

CREATE TABLE IF NOT EXISTS public.expense_plan_debtors (
  plan_id            uuid NOT NULL REFERENCES public.expense_plans(id) ON DELETE RESTRICT,
  debtor_user_id     uuid NOT NULL REFERENCES public.profiles(id)      ON DELETE RESTRICT,
  share_amount_cents bigint NOT NULL,

  CONSTRAINT pk_expense_plan_debtors PRIMARY KEY (plan_id, debtor_user_id),
  CONSTRAINT chk_expense_plan_debtors_amount_positive
    CHECK (share_amount_cents > 0)
);

ALTER TABLE public.expense_plans
  DROP COLUMN IF EXISTS main_payer_user_id;

ALTER TABLE public.expense_plans
  DROP CONSTRAINT IF EXISTS chk_expense_plans_next_cycle_not_before_start,
  ADD CONSTRAINT chk_expense_plans_next_cycle_not_before_start
  CHECK (next_cycle_date >= start_date);

ALTER TABLE public.expense_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_plan_debtors ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.expense_plans FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.expense_plan_debtors FROM PUBLIC, anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_expense_plans_home_status_next_date
  ON public.expense_plans (home_id, status, next_cycle_date);

CREATE INDEX IF NOT EXISTS idx_expense_plans_home_created_at
  ON public.expense_plans (home_id, created_at DESC);

-- Ensure expenses.plan_id FK exists with ON DELETE RESTRICT
DO $$
DECLARE
  v_fk_name text;
BEGIN
  SELECT c.conname INTO v_fk_name
    FROM pg_constraint c
    JOIN pg_attribute a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY (c.conkey)
   WHERE c.conrelid = 'public.expenses'::regclass
     AND c.contype = 'f'
     AND a.attname = 'plan_id'
   LIMIT 1;

  IF v_fk_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.expenses DROP CONSTRAINT %I', v_fk_name);
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'fk_expenses_plan_id_restrict'
       AND conrelid = 'public.expenses'::regclass
  ) THEN
    ALTER TABLE public.expenses
      ADD CONSTRAINT fk_expenses_plan_id_restrict
      FOREIGN KEY (plan_id)
      REFERENCES public.expense_plans(id)
      ON DELETE RESTRICT;
  END IF;
END$$;

-- =====================================================================
-- Helper: next cycle date calculator (IMMUTABLE + explicit date math)
-- =====================================================================
CREATE OR REPLACE FUNCTION public._expense_plan_next_cycle_date(
  p_interval public.recurrence_interval,
  p_from     date
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
BEGIN
  CASE p_interval
    WHEN 'weekly' THEN
      RETURN (p_from + 7)::date;
    WHEN 'every_2_weeks' THEN
      RETURN (p_from + 14)::date;
    WHEN 'monthly' THEN
      RETURN (p_from + INTERVAL '1 month')::date;
    WHEN 'every_2_months' THEN
      RETURN (p_from + INTERVAL '2 months')::date;
    WHEN 'annual' THEN
      RETURN (p_from + INTERVAL '1 year')::date;
    ELSE
      RAISE EXCEPTION
        'Recurrence interval % not supported for expense plans.',
        p_interval
        USING ERRCODE = '22023';
  END CASE;
END;
$$;

-- =====================================================================
-- Helper: terminate plans impacted by membership change
-- =====================================================================
CREATE OR REPLACE FUNCTION public._expense_plans_terminate_for_member_change(
  p_home_id uuid,
  p_affected_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
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
     );
END;
$$;

REVOKE ALL ON FUNCTION public._expense_plans_terminate_for_member_change(uuid, uuid)
FROM PUBLIC, anon, authenticated;

-- =====================================================================
-- Helper: generate a single cycle expense for a plan (idempotent)
-- NOTE: cron-driven generation does NOT call _home_assert_quota (quota ignored for cron).
-- Lock order inside: homes -> plan row -> insert expense -> insert splits -> usage delta
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

REVOKE ALL ON FUNCTION public._expense_plan_generate_cycle(uuid, date)
FROM PUBLIC, anon, authenticated;

-- =====================================================================
-- Cron: generate all due cycles (safe to call repeatedly) - RETURNS void
-- CAPPED per plan + global cap
-- NOTE: Ignores quota/paywall by design (cron-only).
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
    v_next_date  := v_plan.next_cycle_date;
    v_cycles_done := 0;

    WHILE v_cycle_date <= current_date LOOP
      EXIT WHEN v_cycles_done >= v_cap;
      EXIT WHEN v_total_cycles_done >= v_total_cap;

      PERFORM public._expense_plan_generate_cycle(v_plan.id, v_cycle_date);

      v_cycle_date := public._expense_plan_next_cycle_date(v_plan.recurrence_interval, v_cycle_date);
      v_next_date  := v_cycle_date;

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

REVOKE ALL ON FUNCTION public.expense_plans_generate_due_cycles()
FROM PUBLIC, anon, authenticated;

-- =====================================================================
-- expenses_create (UPDATED: drafts may optionally include amount_cents; still no quota unless activating)
-- Draft rules:
-- - if p_split_mode IS NULL => draft
--   - p_recurrence must be 'none'
--   - p_amount_cents may be NULL OR >0 (optional)
-- - if p_split_mode IS NOT NULL => active (or plan + first cycle)
--   - amount REQUIRED and >0 (and splits sum check enforced)
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
    p_start_date,
    public._expense_plan_next_cycle_date(p_recurrence, p_start_date),
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
-- expenses_edit (unchanged activation semantics: ALWAYS activates draft)
-- NOTE: Because expenses_edit activates, amount is still REQUIRED here.
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
      v_target_start,
      public._expense_plan_next_cycle_date(v_target_recur, v_target_start),
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
-- expenses_get_for_edit (unchanged)
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
    'recurrenceInterval', v_expense.recurrence_interval,
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
-- Bulk pay: expenses_pay_my_due (recipient-scoped) - idempotent usage decrement via fully_paid_at
-- Lock order: homes(sorted) -> expenses(sorted) -> splits update
-- =====================================================================

DROP FUNCTION IF EXISTS public.expenses_pay_my_due(uuid);
DROP FUNCTION IF EXISTS public.expenses_pay_my_due(uuid, uuid);

-- Harden pay-my-due home locking (avoid uuid = uuid[] ANY issues)
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
    home_id uuid NOT NULL
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
    RETURNING e.home_id
  )
  INSERT INTO pg_temp.expenses_newly_paid (home_id)
  SELECT home_id FROM newly_paid;

  SELECT COUNT(*)::int
    INTO v_newly_fully_paid_cnt
    FROM pg_temp.expenses_newly_paid;

  FOR r IN
    SELECT home_id, COUNT(*)::int AS dec_count
      FROM pg_temp.expenses_newly_paid
     GROUP BY home_id
  LOOP
    PERFORM public._home_usage_apply_delta(
      r.home_id,
      jsonb_build_object('active_expenses', -r.dec_count)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'recipientUserId',          p_recipient_user_id,
    'splitsPaid',               v_split_count,
    'expensesTouched',          v_expense_count,
    'expensesNewlyFullyPaid',   v_newly_fully_paid_cnt
  );
END;
$$;

REVOKE ALL ON FUNCTION public._expenses_prepare_split_buffer(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.expenses_pay_my_due(uuid) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._expenses_prepare_split_buffer(uuid, uuid, bigint, public.expense_split_type, uuid[], jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expenses_pay_my_due(uuid) TO authenticated;

-- Redundant wrapper removed
DROP FUNCTION IF EXISTS public.expenses_mark_share_paid(uuid);

-- ---------------------------------------------------------------------
-- RPC: terminate a plan (stop future cycles)
-- Only creator/payer can terminate (created_by_user_id)
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.expense_plans_terminate(uuid);

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

  RETURN v_plan;
END;
$$;

REVOKE ALL ON FUNCTION public.expense_plans_terminate(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.expense_plans_terminate(uuid)
TO authenticated;

-- Embed membership-change termination into homes_leave and members_kick
-- ---------------------------------------------------------------------

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
     SET valid_to = now(),
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

  -- Terminate impacted recurring plans for this member
  PERFORM public._expense_plans_terminate_for_member_change(p_home_id, v_user);

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
      'home_id',            p_home_id,
      'role_before',        v_role_before,
      'members_remaining',  v_members_left,
      'home_deactivated',   v_deactivated
    )
  );
END;
$$;

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
  PERFORM 1
    FROM public.homes h
   WHERE h.id = p_home_id
   FOR UPDATE;

  UPDATE public.memberships m
     SET valid_to   = now(),
         updated_at = now()
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

  -- Terminate impacted recurring plans for the kicked member
  PERFORM public._expense_plans_terminate_for_member_change(p_home_id, p_target_user_id);

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


-- =====================================================================
-- Cron: schedule daily cycle generation (03:00 UTC) with upsert-like behavior
-- =====================================================================
DO $$
DECLARE
  v_job_id integer;
BEGIN
  BEGIN
    SELECT j.jobid
      INTO v_job_id
      FROM cron.job j
     WHERE j.jobname = 'expense_plans_generate_daily'
     LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
      'expense_plans_generate_daily',
      '0 3 * * *',
      $cmd$SELECT public.expense_plans_generate_due_cycles();$cmd$
    );
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE NOTICE 'Skipping pg_cron schedule: cron.job unavailable or insufficient privileges.';
  END;
END
$$;
