-- =====================================================================
-- ENUM: expense_status add 'converted' (Option A)
-- - Fix: DO-block uses direct ALTER TYPE (no nested $$ / EXECUTE)
-- - Idempotent: checks enum + value existence
-- =====================================================================
DO $$
BEGIN
  -- Ensure enum exists
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'expense_status'
  ) THEN
    RAISE EXCEPTION 'public.expense_status enum does not exist';
  END IF;

  -- Add value if missing
  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'expense_status'
      AND e.enumlabel = 'converted'
  ) THEN
    ALTER TYPE public.expense_status ADD VALUE 'converted';
  END IF;
END
$$;

-- =====================================================================
-- ENUM: expense_plan_status create if missing
-- =====================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'expense_plan_status'
  ) THEN
    CREATE TYPE public.expense_plan_status AS ENUM ('active', 'terminated');
  END IF;
END
$$;
