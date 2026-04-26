CREATE OR REPLACE FUNCTION public.home_units_list_selectable_expense_units_v2(
  p_home_id uuid
)
RETURNS TABLE (
  unit_id uuid,
  home_id uuid,
  name text,
  unit_type text,
  member_user_ids text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_membership_id uuid;
  v_personal_unit_id uuid;
  v_shared_unit_id uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  SELECT m.id
  INTO v_membership_id
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.user_id = v_user
    AND m.valid_to IS NULL
  LIMIT 1;

  IF v_membership_id IS NULL THEN
    PERFORM public.api_error(
      'not_home_member',
      'Caller is not a current home member.',
      '42501'
    );
  END IF;

  v_personal_unit_id := public._home_units__ensure_personal(
    p_home_id,
    v_membership_id,
    v_user
  );

  SELECT hu.id
  INTO v_shared_unit_id
  FROM public.home_units hu
  JOIN public.home_unit_members hum
    ON hum.unit_id = hu.id
  WHERE hu.home_id = p_home_id
    AND hu.unit_type = 'shared'
    AND hu.archived_at IS NULL
    AND hum.membership_id = v_membership_id
    AND hum.is_active_shared = TRUE
  LIMIT 1;

  RETURN QUERY
  WITH candidate_units AS (
    SELECT
      hu.id,
      hu.home_id,
      hu.name,
      hu.unit_type,
      hu.created_at
    FROM public.home_units hu
    JOIN public.memberships m
      ON m.id = hu.personal_membership_id
    WHERE hu.home_id = p_home_id
      AND hu.unit_type = 'personal'
      AND hu.archived_at IS NULL
      AND m.valid_to IS NULL

    UNION

    SELECT
      hu.id,
      hu.home_id,
      hu.name,
      hu.unit_type,
      hu.created_at
    FROM public.home_units hu
    WHERE hu.id = v_shared_unit_id
  )
  SELECT
    cu.id,
    cu.home_id,
    cu.name,
    cu.unit_type,
    public._home_units__member_user_ids(cu.id)
  FROM candidate_units cu
  ORDER BY
    CASE
      WHEN cu.id = v_shared_unit_id THEN 0
      WHEN cu.id = v_personal_unit_id THEN 1
      ELSE 2
    END,
    lower(cu.name),
    cu.created_at,
    cu.id;
END;
$$;

REVOKE ALL ON FUNCTION public.home_units_list_selectable_expense_units_v2(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.home_units_list_selectable_expense_units_v2(uuid)
TO authenticated;
