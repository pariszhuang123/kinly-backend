drop policy if exists "households_expectations_insert" on storage.objects;
drop policy if exists "households_expectations_update" on storage.objects;
-- plus any other old storage.objects policies you no longer want

-- Allow authenticated users to do anything on objects in the `households` bucket
create policy "households_bucket_all"
  on storage.objects
  for all               -- select, insert, update, delete
  to authenticated
  using (bucket_id = 'households')
  with check (bucket_id = 'households');

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

  --------------------------------------------------------------------
  -- Ensure caller has a unique avatar within this home (plan-gated)
  -- This now runs even if they are already a member of the home.
  --------------------------------------------------------------------
  PERFORM public._ensure_unique_avatar_for_home(v_home_id, v_user);

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

  -- Success response
  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;
