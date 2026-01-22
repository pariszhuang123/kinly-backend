CREATE OR REPLACE FUNCTION public.chores_list_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id                          uuid,
  home_id                     uuid,
  assignee_user_id            uuid,
  name                        text,
  start_date                  date,
  assignee_full_name          text,
  assignee_avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.assignee_user_id,
    c.name,
    c.start_date,
    pa.full_name AS assignee_full_name,
    a.storage_path AS assignee_avatar_storage_path
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id
    AND c.state IN ('draft', 'active')
  ORDER BY 
    c.start_date DESC,
    c.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.today_flow_list(
  p_home_id uuid,
  p_state   public.chore_state
)
RETURNS TABLE (
  id         uuid,
  home_id    uuid,
  name       text,
  start_date date,
  state      public.chore_state
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid(); -- 👈 auto-resolve the assignee
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  RETURN QUERY
  SELECT
    c.id,
    c.home_id,
    c.name,
    c.start_date,
    c.state
  FROM public.chores AS c
  WHERE
    c.home_id = p_home_id
    AND c.state = p_state
    AND (
        -- If it's draft, no assignee filter
        p_state = 'draft'::public.chore_state
        -- If it's active, only return chores assigned to *this user*
        OR (p_state = 'active'::public.chore_state AND c.assignee_user_id = v_user)
    )
  ORDER BY
    c.start_date ASC,
    c.created_at ASC;
END;
$$;
