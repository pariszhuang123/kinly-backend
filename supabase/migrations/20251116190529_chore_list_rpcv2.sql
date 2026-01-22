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

-- Lock down today_flow_list
REVOKE ALL ON FUNCTION public.today_flow_list(p_home_id uuid, p_state public.chore_state) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.today_flow_list(p_home_id uuid, p_state public.chore_state) TO authenticated;

CREATE OR REPLACE FUNCTION public._assert_home_member(
  p_home_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user   uuid := auth.uid();
  v_exists boolean;
BEGIN
  -- Require authentication
  PERFORM public._assert_authenticated();

  -- Check whether this user is an active/current member of the home
  SELECT TRUE
    INTO v_exists
  FROM public.memberships hm
  WHERE hm.home_id   = p_home_id
    AND hm.user_id   = v_user
    AND hm.is_current = TRUE       -- 👈 replace hm.left_at IS NULL
  LIMIT 1;

  IF NOT v_exists THEN
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

CREATE OR REPLACE FUNCTION public.home_assignees_list(
  p_home_id uuid
)
RETURNS TABLE (
  user_id              uuid,
  full_name            text,
  email                text,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 1️⃣ Require auth
  PERFORM public._assert_authenticated();

  -- 2️⃣ Ensure caller actually belongs to this home
  PERFORM public._assert_home_member(p_home_id);

  -- 3️⃣ Return all *active* members of this home as potential assignees
  RETURN QUERY
  SELECT
    m.user_id,
    p.full_name,
    p.email,
    a.storage_path
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE        -- or your "still in house" condition
  ORDER BY COALESCE(p.full_name, p.email);
END;
$$;

CREATE OR REPLACE FUNCTION public.chores_get_for_home(
  p_home_id  uuid,
  p_chore_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_chore      jsonb;
  v_assignees  jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  -- 1️⃣ Chore + current assignee (if any)
  SELECT jsonb_build_object(
           'id',                      c.id,
           'home_id',                 c.home_id,
           'created_by_user_id',      c.created_by_user_id,
           'assignee_user_id',        c.assignee_user_id,
           'name',                    c.name,
           'start_date',              c.start_date,
           'recurrence',              c.recurrence,
           'expectation_photo_path',  c.expectation_photo_path,
           'how_to_video_url',        c.how_to_video_url,
           'notes',                   c.notes,
           'assignee', CASE
             WHEN c.assignee_user_id IS NULL THEN NULL
             ELSE jsonb_build_object(
               'id',                   pa.id,
               'full_name',            pa.full_name,
               'avatar_storage_path',  a.storage_path
             )
           END
         )
  INTO v_chore
  FROM public.chores c
  LEFT JOIN public.profiles pa
    ON pa.id = c.assignee_user_id      -- ✅ safe when NULL
  LEFT JOIN public.avatars a
    ON a.id = pa.avatar_id
  WHERE c.home_id = p_home_id
    AND c.id      = p_chore_id;

  IF v_chore IS NULL THEN
    PERFORM public.api_error(
      'NOT_FOUND',
      'Chore not found for this home.',
      '22023',
      jsonb_build_object('home_id', p_home_id, 'chore_id', p_chore_id)
    );
  END IF;

  -- 2️⃣ All potential assignees in this home (these *should* have avatars)
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'user_id',             m.user_id,
               'full_name',           p.full_name,
               'avatar_storage_path', a.storage_path
             )
             ORDER BY p.full_name
           ),
           '[]'::jsonb
         )
  INTO v_assignees
  FROM public.memberships m            
  JOIN public.profiles p
    ON p.id = m.user_id
  JOIN public.avatars a
    ON a.id = p.avatar_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE;                -- or your "active" condition

  RETURN jsonb_build_object(
    'chore',     v_chore,
    'assignees', v_assignees
  );
END;
$$;
