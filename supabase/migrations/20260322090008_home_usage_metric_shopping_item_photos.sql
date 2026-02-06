-- Add shopping-list photo quota metric ahead of migrations that use it.
DO $$
BEGIN
  BEGIN
    ALTER TYPE public.home_usage_metric ADD VALUE 'shopping_item_photos';
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;
