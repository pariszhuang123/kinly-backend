-- 1) Extend enum and counters
DO $$
BEGIN
  BEGIN
    ALTER TYPE public.home_usage_metric
      ADD VALUE 'active_expenses';
  EXCEPTION
    WHEN duplicate_object THEN
      -- Value already exists, so do nothing (idempotent).
      NULL;
  END;
END
$$;
