CREATE OR REPLACE FUNCTION public.shopping_list_archive_item(
  p_item_id uuid
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_existing public.shopping_list_items;
  v_updated public.shopping_list_items;
BEGIN
  PERFORM public._assert_authenticated();

  SELECT i.*
  INTO v_existing
  FROM public.shopping_list_items i
  JOIN public.memberships m
    ON m.home_id = i.home_id
   AND m.user_id = v_user
   AND m.is_current = TRUE
  WHERE i.id = p_item_id
    AND i.archived_at IS NULL
  FOR UPDATE;

  IF v_existing.id IS NULL THEN
    PERFORM public.api_error(
      'item_not_found',
      'Shopping list item not found.',
      'P0002',
      jsonb_build_object('item_id', p_item_id)
    );
  END IF;

  UPDATE public.shopping_list_items
  SET
    archived_at = now(),
    archived_by_user_id = v_user
  WHERE id = p_item_id
  RETURNING * INTO v_updated;

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.shopping_list_archive_item(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopping_list_archive_item(uuid)
TO authenticated;
