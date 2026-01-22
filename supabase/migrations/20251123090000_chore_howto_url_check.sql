-- Enforce http/https scheme for how_to_video_url.
alter table public.chores
  add constraint chores_how_to_video_url_scheme
  check (how_to_video_url is null or how_to_video_url ~* '^https?://');


-- Allow authenticated users to upload/update expectation photos into the
-- public `households` bucket under flow/expectations/*.
-- Storage still enforces RLS even for public buckets on write.

do $$
begin
  if not exists (
    select 1 from pg_policies
    where policyname = 'households_expectations_insert'
      and tablename = 'objects'
      and schemaname = 'storage'
  ) then
    create policy "households_expectations_insert"
      on storage.objects
      for insert
      to authenticated
      with check (
        bucket_id = 'households'
        and position('flow/expectations/' in name) = 1
      );
  end if;

  if not exists (
    select 1 from pg_policies
    where policyname = 'households_expectations_update'
      and tablename = 'objects'
      and schemaname = 'storage'
  ) then
    create policy "households_expectations_update"
      on storage.objects
      for update
      to authenticated
      using (
        bucket_id = 'households'
        and position('flow/expectations/' in name) = 1
      )
      with check (
        bucket_id = 'households'
        and position('flow/expectations/' in name) = 1
      );
  end if;
end
$$;

-- Avatar uniqueness helper for home joins
-- Ensures current user's avatar is unique within the target home, plan-gated

CREATE OR REPLACE FUNCTION public._ensure_unique_avatar_for_home(
  p_home_id uuid,
  p_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_avatar_before uuid;
  v_new_avatar uuid;
  v_plan text;
BEGIN
  PERFORM public._assert_authenticated();

  -- Lock profile row for this user
  SELECT p.avatar_id
    INTO v_avatar_before
  FROM public.profiles p
  WHERE p.id = p_user_id
    AND p.deactivated_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'PROFILE_NOT_FOUND',
      'Active profile not found for current user.',
      '22000',
      jsonb_build_object('user_id', p_user_id)
    );
  END IF;

  -- Default plan to free if none found
  v_plan := public._home_effective_plan(p_home_id);
  IF v_plan IS NULL THEN
    v_plan := 'free';
  END IF;

  -- If current avatar is unique in this home, keep it
  IF v_avatar_before IS NOT NULL THEN
    PERFORM 1
    FROM public.memberships m
    JOIN public.profiles pr
      ON pr.id = m.user_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
      AND pr.deactivated_at IS NULL
      AND pr.avatar_id = v_avatar_before
      AND pr.id <> p_user_id;

    IF NOT FOUND THEN
      RETURN v_avatar_before;
    END IF;
  END IF;

  -- Pick the first available avatar respecting plan and excluding other members
  WITH used_by_others AS (
    SELECT DISTINCT pr.avatar_id
    FROM public.memberships m
    JOIN public.profiles pr
      ON pr.id = m.user_id
    WHERE m.home_id = p_home_id
      AND m.is_current = TRUE
      AND pr.deactivated_at IS NULL
      AND pr.id <> p_user_id
  )
  SELECT a.id
    INTO v_new_avatar
  FROM public.avatars a
  LEFT JOIN used_by_others u
    ON u.avatar_id = a.id
  WHERE u.avatar_id IS NULL
    AND (v_plan <> 'free' OR a.category = 'animal')
  ORDER BY a.created_at ASC
  LIMIT 1;

  IF v_new_avatar IS NULL THEN
    PERFORM public.api_error(
      'NO_AVAILABLE_AVATAR',
      'No available avatars for this home.',
      'P0001',
      jsonb_build_object('home_id', p_home_id, 'plan', v_plan)
    );
  END IF;

  UPDATE public.profiles
     SET avatar_id = v_new_avatar,
         updated_at = now()
   WHERE id = p_user_id
     AND deactivated_at IS NULL;

  RETURN v_new_avatar;
END;
$$;

REVOKE ALL ON FUNCTION public._ensure_unique_avatar_for_home(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._ensure_unique_avatar_for_home(uuid, uuid) TO authenticated;


----------------------------------------------------------------------
-- HOMES: join(code)
----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.homes_join(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid := auth.uid();
  v_home_id uuid;
  v_revoked boolean;
  v_active  boolean;
BEGIN
  PERFORM public._assert_authenticated();

  --------------------------------------------------------------------
  -- Combined lookup: home_id + invite state
  --------------------------------------------------------------------
  SELECT
    i.home_id,
    (i.revoked_at IS NOT NULL) AS revoked,
    h.is_active
  INTO
    v_home_id,
    v_revoked,
    v_active
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::public.citext
  LIMIT 1;

  -- Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object('code', p_code)
    );
  END IF;

  -- Already current member of this same home
  IF EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = v_home_id
      AND m.is_current = TRUE
  ) THEN
    RETURN jsonb_build_object(
      'status',  'success',
      'code',    'already_member',
      'message', 'You are already part of this household.',
      'home_id', v_home_id
    );
  END IF;

  -- Already in another active home (only one allowed)
  IF EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.is_current = TRUE
      AND m.home_id <> v_home_id
  ) THEN
    PERFORM public.api_error(
      'ALREADY_IN_OTHER_HOME',
      'You are already a member of another household. Leave it first before joining a new one.',
      '42501'
    );
  END IF;

  --------------------------------------------------------------------
  -- Paywall: enforce active_members limit on this home
  --------------------------------------------------------------------
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership
  INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
  VALUES (v_user, v_home_id, 'member', now(), NULL);

  -- Increment cached active_members
  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::public.citext;

  -- Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);
  -- Ensure caller has a unique avatar within this home (plan-gated)
  PERFORM public._ensure_unique_avatar_for_home(v_home_id, v_user);

  -- Success response

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;
