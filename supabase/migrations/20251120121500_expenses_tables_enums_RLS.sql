-- =====================================================================
--  Expenses: ENUMS
-- =====================================================================

DO $$
BEGIN
  -- expense_status
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'expense_status'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.expense_status AS ENUM (
      'draft',
      'active',
      'cancelled'
    );
  END IF;

  -- expense_split_type
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'expense_split_type'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.expense_split_type AS ENUM (
      'equal',
      'custom'
    );
  END IF;

  -- expense_share_status
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'expense_share_status'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.expense_share_status AS ENUM (
      'unpaid',
      'paid'
    );
  END IF;
END
$$;


-- =====================================================================
--  Expenses: TABLES
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABLE: public.expenses
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expenses (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id            uuid  NOT NULL REFERENCES public.homes(id)    ON DELETE CASCADE,
  created_by_user_id uuid  NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status             public.expense_status      NOT NULL DEFAULT 'draft',
  split_type         public.expense_split_type,
  amount_cents       bigint NOT NULL,
  description        text   NOT NULL,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CONSTRAINT chk_expenses_amount_positive
    CHECK (amount_cents > 0),

  -- Simplified: rely on NOT NULL for "non-empty"; only enforce upper bound
  CONSTRAINT chk_expenses_description_length
    CHECK (char_length(btrim(description)) <= 280),

  CONSTRAINT chk_expenses_notes_length
    CHECK (notes IS NULL OR char_length(notes) <= 2000),

  -- Only ACTIVE expenses require a split type
  -- draft/cancelled may have NULL split_type
  CONSTRAINT chk_expenses_active_split_required
    CHECK (status <> 'active' OR split_type IS NOT NULL)
);

COMMENT ON TABLE  public.expenses IS 'Top-level shared expense created inside a home.';
COMMENT ON COLUMN public.expenses.home_id            IS 'FK to public.homes.id.';
COMMENT ON COLUMN public.expenses.created_by_user_id IS 'Expense creator / payer.';
COMMENT ON COLUMN public.expenses.status             IS 'draft|active|cancelled.';
COMMENT ON COLUMN public.expenses.split_type         IS 'equal|custom|null (no split).';
COMMENT ON COLUMN public.expenses.amount_cents       IS 'Total amount in integer cents.';
COMMENT ON COLUMN public.expenses.description        IS 'Required description (<=280 chars).';
COMMENT ON COLUMN public.expenses.notes              IS 'Optional notes for creator + viewers.';

CREATE INDEX IF NOT EXISTS idx_expenses_home_status_created_at
  ON public.expenses (home_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_expenses_creator_created_at
  ON public.expenses (created_by_user_id, home_id, created_at DESC);


-- ---------------------------------------------------------------------
-- TABLE: public.expense_splits
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expense_splits (
  expense_id      uuid  NOT NULL REFERENCES public.expenses(id) ON DELETE CASCADE,
  debtor_user_id  uuid  NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount_cents    bigint NOT NULL,
  status          public.expense_share_status NOT NULL DEFAULT 'unpaid',
  marked_paid_at  timestamptz,

  CONSTRAINT pk_expense_splits PRIMARY KEY (expense_id, debtor_user_id),

  CONSTRAINT chk_expense_splits_amount_positive
    CHECK (amount_cents > 0),

  -- Guard: status ↔ marked_paid_at alignment
  CONSTRAINT chk_expense_splits_paid_timestamp_alignment
    CHECK (
      (status = 'unpaid' AND marked_paid_at IS NULL)
      OR
      (status = 'paid'   AND marked_paid_at IS NOT NULL)
    )
);

COMMENT ON TABLE  public.expense_splits IS 'Per-person share of an expense (debtor owes the creator).';
COMMENT ON COLUMN public.expense_splits.debtor_user_id IS 'Member who owes this share.';
COMMENT ON COLUMN public.expense_splits.amount_cents   IS 'Share amount in cents.';
COMMENT ON COLUMN public.expense_splits.status         IS 'unpaid|paid.';
COMMENT ON COLUMN public.expense_splits.marked_paid_at IS 'Timestamp when debtor marked the share paid.';

CREATE INDEX IF NOT EXISTS idx_expense_splits_debtor_status
  ON public.expense_splits (debtor_user_id, status);

CREATE INDEX IF NOT EXISTS idx_expense_splits_expense
  ON public.expense_splits (expense_id);

-- Turn RLS *off* for these tables
ALTER TABLE public.expenses       DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_splits DISABLE ROW LEVEL SECURITY;

-- Keep tables locked to clients
REVOKE ALL ON public.expenses, public.expense_splits
  FROM anon, authenticated;

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
BEGIN
  -- Require authentication
  PERFORM public._assert_authenticated();

  -- Check whether this user is an active/current member of the home
  PERFORM 1
  FROM public.memberships hm
  WHERE hm.home_id   = p_home_id
    AND hm.user_id   = v_user
    AND hm.is_current = TRUE       -- 👈 replace hm.left_at IS NULL
  LIMIT 1;

  IF NOT FOUND THEN
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
