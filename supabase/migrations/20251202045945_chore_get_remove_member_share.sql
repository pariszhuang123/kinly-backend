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
  'id', c.id,
  'home_id', c.home_id,
  'created_by_user_id', c.created_by_user_id,
  'assignee_user_id', c.assignee_user_id,
  'name', c.name,
  'start_date', c.start_date,
  'recurrence', c.recurrence,
  'recurrence_cursor', c.recurrence_cursor,
  'expectation_photo_path', c.expectation_photo_path,
  'how_to_video_url', c.how_to_video_url,
  'notes', c.notes,
  'state', c.state,
  'completed_at', c.completed_at,
  'created_at', c.created_at,
  'updated_at', c.updated_at,
  'assignee',
    CASE WHEN c.assignee_user_id IS NULL THEN NULL
         ELSE jsonb_build_object(
           'id', pa.id,
           'full_name', pa.full_name,
           'avatar_storage_path', a.storage_path)
    END
)
INTO v_chore
FROM public.chores c
LEFT JOIN public.profiles pa ON pa.id = c.assignee_user_id
LEFT JOIN public.avatars a ON a.id = pa.avatar_id
WHERE c.home_id = p_home_id
  AND c.id = p_chore_id;

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


-- ---------------------------------------------------------------------
-- members.kick(home_id, target_user_id) -> removes a member (owner-only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.members_kick(
  p_home_id uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user               uuid := auth.uid();
  v_target_role        text;
  v_rows_updated       integer;
  v_members_remaining  integer;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);

  --------------------------------------------------------------------
  -- 1) Verify caller is the current owner of the active home
  --------------------------------------------------------------------
  PERFORM public.api_assert(
    EXISTS (
      SELECT 1
      FROM public.memberships m
      JOIN public.homes h ON h.id = m.home_id
      WHERE m.user_id    = v_user
        AND m.home_id    = p_home_id
        AND m.role       = 'owner'
        AND m.is_current = TRUE
        AND h.is_active  = TRUE
    ),
    'FORBIDDEN',
    'Only the current owner can remove members.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  --------------------------------------------------------------------
  -- 2) Validate target is a current (non-owner) member
  --------------------------------------------------------------------
  SELECT m.role
    INTO v_target_role
    FROM public.memberships m
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
   LIMIT 1;

  PERFORM public.api_assert(
    v_target_role IS NOT NULL,
    'TARGET_NOT_MEMBER',
    'The selected user is not an active member of this home.',
    'P0002',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  PERFORM public.api_assert(
    v_target_role <> 'owner',
    'CANNOT_KICK_OWNER',
    'Owners cannot be removed.',
    '42501',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 3) Serialize with other membership mutations and close the stint
  --------------------------------------------------------------------
  -- Lock the home row to serialize join/leave/kick operations
  PERFORM 1
  FROM public.homes h
  WHERE h.id = p_home_id
  FOR UPDATE;

  UPDATE public.memberships m
     SET valid_to   = now(),
         is_current = FALSE,
         updated_at = now()
   WHERE m.user_id    = p_target_user_id
     AND m.home_id    = p_home_id
     AND m.is_current = TRUE
  RETURNING 1 INTO v_rows_updated;

  PERFORM public.api_assert(
    v_rows_updated = 1,
    'STATE_CHANGED_RETRY',
    'Membership state changed; please retry.',
    '40001',
    jsonb_build_object('home_id', p_home_id, 'user_id', p_target_user_id)
  );

  --------------------------------------------------------------------
  -- 4) Return success payload
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO v_members_remaining
    FROM public.memberships m
   WHERE m.home_id    = p_home_id
     AND m.is_current = TRUE;

  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'member_removed',
    'message', 'Member removed successfully.',
    'data', jsonb_build_object(
      'home_id',           p_home_id,
      'user_id',           p_target_user_id,
      'members_remaining', v_members_remaining
    )
  );
END;
$$;



-- ====================================================================
-- Kinly: Share Tracking (attempt logging, internal helper only)
-- Using CHECK constraints instead of ENUMs
-- ====================================================================

-- 1) TABLE
create table if not exists public.share_events (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),

  user_id        uuid not null references public.profiles(id),
  home_id        uuid null references public.homes(id),

  feature        text not null,
  channel        text not null
);

comment on table public.share_events is
  'Internal analytics for tracking share attempts (per user, home, feature, channel).';

-- 2) CHECK CONSTRAINTS
alter table public.share_events
  add constraint share_feature_valid
  check (feature in (
    'invite_button',
    'invite_housemate',
    'gratitude_wall_house',
    'gratitude_wall_personal',
    'house_rules_detailed',
    'house_rules_summary',
    'preferences_detailed',
    'preferences_summary',
    'other'
  ));

alter table public.share_events
  add constraint share_channel_valid
  check (channel in (
    'system_share',
    'qr_code',
    'copy_link',
    'other'
  ));

-- 3) RLS
alter table public.share_events enable row level security;

revoke all on table public.share_events from public;
revoke all on table public.share_events from authenticated;

-- 4) INTERNAL HELPER
create or replace function public._share_log_event_internal(
  p_user_id      uuid,
  p_home_id      uuid,
  p_feature      text,
  p_channel      text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  insert into public.share_events (user_id, home_id, feature, channel)
  values (p_user_id, p_home_id, p_feature, p_channel);
end;
$$;

comment on function public._share_log_event_internal(
  uuid, uuid, text, text
) is 'Internal helper for writing share attempts; callers must handle auth/membership.';

-- 5) PUBLIC RPC
create or replace function public.share_log_event(
  p_home_id      uuid,
  p_feature      text,
  p_channel      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  perform public._assert_authenticated();

  if p_home_id is not null then
    perform public._assert_home_member(p_home_id);
    perform public._assert_home_active(p_home_id);
  end if;

  perform public._share_log_event_internal(
    p_user_id      => v_user_id,
    p_home_id      => p_home_id,
    p_feature      => p_feature,
    p_channel      => p_channel
  );
end;
$$;

comment on function public.share_log_event(
  uuid, text, text
) is 'Records a share attempt for the current user with feature and channel.';

revoke all on function public.share_log_event(uuid, text, text) from public;
grant execute on function public.share_log_event(uuid, text, text) to authenticated;
