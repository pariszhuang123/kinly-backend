CREATE OR REPLACE FUNCTION public.shopping_list_update_item_v2(
  p_item_id uuid,
  p_name text DEFAULT NULL,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_is_completed boolean DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL,
  p_replace_photo boolean DEFAULT FALSE,
  p_scope_type text DEFAULT NULL,
  p_unit_id uuid DEFAULT NULL
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._shopping_list__update_item_core(
    p_item_id,
    p_name,
    p_quantity,
    p_details,
    p_is_completed,
    p_reference_photo_path,
    p_replace_photo,
    p_scope_type,
    p_unit_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.members_list_active_by_home_v2(
  p_home_id uuid,
  p_exclude_self boolean DEFAULT true
)
RETURNS TABLE (
  membership_id   uuid,
  user_id         uuid,
  username        citext,
  role            text,
  valid_from      timestamptz,
  avatar_url      text,
  can_transfer_to boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    m.id AS membership_id,
    m.user_id,
    p.username,
    m.role,
    m.valid_from,
    a.storage_path AS avatar_url,
    (m.role <> 'owner') AS can_transfer_to
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
    AND (p_exclude_self IS FALSE OR m.user_id <> auth.uid())
  ORDER BY
    CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END,
    p.username;
$$;

