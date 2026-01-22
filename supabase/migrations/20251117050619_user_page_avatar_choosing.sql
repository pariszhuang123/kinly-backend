
CREATE OR REPLACE FUNCTION public._home_effective_plan(p_home_id uuid)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (
      SELECT he.plan
      FROM public.home_entitlements he
      WHERE he.home_id = p_home_id
        AND (he.expires_at IS NULL OR he.expires_at > now())
      ORDER BY he.expires_at NULLS LAST, he.created_at DESC
      LIMIT 1
    ),
    'free'
  );
$$;

REVOKE ALL ON FUNCTION public._home_effective_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._home_effective_plan(uuid) TO authenticated;

-- -------------------------------------------------------------------
-- Current user's profile summary
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.profile_me()
RETURNS TABLE (
  user_id              uuid,
  username             citext,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._assert_authenticated();

  RETURN QUERY
  SELECT
    p.id           AS user_id,
    p.username     AS username,
    a.storage_path AS avatar_storage_path
  FROM public.profiles p
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = auth.uid()
    AND p.deactivated_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_me() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.profile_me() TO authenticated;



-- -------------------------------------------------------------------
-- List available avatars for a home, ordered by created_at ASC
-- (plan-gated + unique within home, except caller's current avatar)
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.avatars_list_for_home(
  p_home_id uuid
)
RETURNS TABLE (
  id           uuid,
  storage_path text,
  category     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan        text;
  v_self_user   uuid;
  v_self_avatar uuid;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);

  v_self_user := auth.uid();

  -- current user's avatar (so we can still show it even if "in use")
  SELECT p.avatar_id
  INTO v_self_avatar
  FROM public.profiles p
  WHERE p.id = v_self_user
    AND p.deactivated_at IS NULL;

  -- ✅ Use shared helper for effective plan
  v_plan := public._home_effective_plan(p_home_id);

  IF v_plan IS NULL THEN
    v_plan := 'free';
  END IF;

  -- Avatars already used by *other* current members in this home
  RETURN QUERY
    WITH used_by_others AS (
      SELECT DISTINCT p.avatar_id
      FROM public.memberships m
      JOIN public.profiles p
        ON p.id = m.user_id
      WHERE m.home_id = p_home_id
        AND m.is_current = TRUE
        AND p.deactivated_at IS NULL
        AND p.id <> v_self_user
    )
    SELECT
      a.id,
      a.storage_path,
      a.category
    FROM public.avatars a
    LEFT JOIN used_by_others u
      ON u.avatar_id = a.id
    WHERE
      (
        -- plan gating
        v_plan <> 'free'
        OR (v_plan = 'free' AND a.category = 'animal')
      )
      AND (
        u.avatar_id IS NULL           -- not used by others
        OR a.id = v_self_avatar       -- always allow my current avatar
      )
    ORDER BY
      a.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.avatars_list_for_home(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.avatars_list_for_home(uuid) TO authenticated;



-- -------------------------------------------------------------------
-- Update current user's username + avatar
-- - Enforces username format
-- - Ensures avatar exists
-- - If user has a current home:
--     * Enforces plan gating (free vs premium) based on home_entitlements
--     * Enforces avatar uniqueness within that home (except self)
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.profile_identity_update(
  p_username  citext,
  p_avatar_id uuid
)
RETURNS TABLE (
  username             citext,
  avatar_id            uuid,
  avatar_storage_path  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- 3–30 chars, start/end alnum, middle may contain . or _
  v_re              text := '^[A-Za-z0-9][A-Za-z0-9._]{1,28}[A-Za-z0-9]$';
  v_user            uuid := auth.uid();
  v_home_id         uuid;
  v_plan            text;
  v_avatar_category text;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- 1. Validate username shape
  --------------------------------------------------------------------
  IF p_username IS NULL OR p_username !~ v_re THEN
    PERFORM public.api_error(
      'INVALID_USERNAME',
      'Username must be 3–30 chars, start/end with letter/number, may contain . or _',
      '22000'
    );
  END IF;

  --------------------------------------------------------------------
  -- 2. Ensure avatar exists + get its category
  --------------------------------------------------------------------
  SELECT a.category
  INTO v_avatar_category
  FROM public.avatars a
  WHERE a.id = p_avatar_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'AVATAR_NOT_FOUND',
      'Selected avatar does not exist.',
      '22000',
      jsonb_build_object('avatar_id', p_avatar_id)
    );
  END IF;

  --------------------------------------------------------------------
  -- 3. Derive current home (if any) and enforce plan + uniqueness
  --------------------------------------------------------------------
  SELECT m.home_id
  INTO v_home_id
  FROM public.memberships m
  WHERE m.user_id = v_user
    AND m.is_current = TRUE
  LIMIT 1;

  IF v_home_id IS NOT NULL THEN
    -- Use shared helper for effective plan (same logic as avatars_list_for_home)
    v_plan := public._home_effective_plan(v_home_id);

    -- Plan gating: free homes can only use 'animal' avatars
    IF v_plan = 'free' AND v_avatar_category <> 'animal' THEN
      PERFORM public.api_error(
        'AVATAR_NOT_ALLOWED_FOR_PLAN',
        'This avatar is not available on the free plan for your home.',
        '22000',
        jsonb_build_object(
          'avatar_id', p_avatar_id,
          'home_id',   v_home_id,
          'plan',      v_plan
        )
      );
    END IF;

    -- Uniqueness within this home: no other current member uses this avatar
    PERFORM 1
    FROM public.memberships m
    JOIN public.profiles  p
      ON p.id = m.user_id
    WHERE m.home_id = v_home_id
      AND m.is_current = TRUE
      AND p.deactivated_at IS NULL
      AND p.avatar_id = p_avatar_id
      AND p.id <> v_user;

    IF FOUND THEN
      PERFORM public.api_error(
        'AVATAR_IN_USE',
        'This avatar is already used by another current member of your home.',
        '22000',
        jsonb_build_object(
          'avatar_id', p_avatar_id,
          'home_id',   v_home_id
        )
      );
    END IF;
  END IF;

  --------------------------------------------------------------------
  -- 4. Perform update, handling "no active profile" + username clash
  --------------------------------------------------------------------
  BEGIN
    UPDATE public.profiles
    SET
      username   = p_username,
      avatar_id  = p_avatar_id,
      updated_at = now()
    WHERE id = v_user
      AND deactivated_at IS NULL;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'PROFILE_NOT_FOUND',
        'Active profile not found for current user.',
        '22000'
      );
    END IF;

  EXCEPTION
    WHEN unique_violation THEN
      -- assumes a unique index on profiles(username)
      PERFORM public.api_error(
        'USERNAME_TAKEN',
        'This username is already in use.',
        '23505'
      );
  END;

  --------------------------------------------------------------------
  -- 5. Return updated identity
  --------------------------------------------------------------------
  RETURN QUERY
  SELECT
    p.username,
    p.avatar_id,
    a.storage_path
  FROM public.profiles p
  JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE p.id = v_user
    AND p.deactivated_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.profile_identity_update(citext, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.profile_identity_update(citext, uuid) TO authenticated;
