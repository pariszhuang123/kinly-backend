-- Add expense-photo quota metric ahead of migrations that use it.
DO $$
BEGIN
  BEGIN
    ALTER TYPE public.home_usage_metric ADD VALUE 'expense_photos';
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;
