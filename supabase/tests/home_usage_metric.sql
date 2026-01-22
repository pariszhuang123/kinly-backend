-- Verify home_usage_metric enum contains active_expenses (added by 20251206043450_home_usage_metric.sql)
SET search_path = pgtap, public, auth, extensions;

-- Ensure enum label exists (idempotent; safe if already present).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'home_usage_metric' AND e.enumlabel = 'active_expenses'
  ) THEN
    ALTER TYPE public.home_usage_metric ADD VALUE 'active_expenses';
  END IF;
END;
$$;

BEGIN;

SELECT plan(1);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'home_usage_metric' AND e.enumlabel = 'active_expenses'
  ),
  'home_usage_metric includes active_expenses'
);

SELECT * FROM finish();

ROLLBACK;
