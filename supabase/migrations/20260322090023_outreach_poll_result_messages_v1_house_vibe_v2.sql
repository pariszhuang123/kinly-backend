-- =====================================================================
-- Outreach poll result messages v1.1 (adjusted)
-- Goals:
-- - Keep business-copy correctness (FKs, lengths, uniqueness).
-- - Make targeting robust against URL casing/whitespace.
-- - Ensure updated_at is touched on update.
-- - Public can read ACTIVE rows only; only service_role can write.
-- =====================================================================

create table if not exists public.outreach_poll_result_messages (
  id                 uuid primary key default gen_random_uuid(),

  poll_id            uuid not null
    references public.outreach_polls(id) on delete cascade,

  option_id          uuid not null
    references public.outreach_poll_options(id) on delete cascade,

  primary_message    text not null,
  cta_label          text not null,

  -- Optional targeting:
  -- - If NULL => "default" message variant (applies to all sources/campaigns)
  source_id_resolved text
    references public.outreach_sources(source_id),

  -- Campaign is optional; if provided it must be paired with a source
  utm_campaign       text,

  active             boolean not null default true,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- Ensure option belongs to poll
  constraint fk_outreach_poll_result_messages_poll_option
    foreign key (poll_id, option_id)
    references public.outreach_poll_options(poll_id, id) on delete cascade,

  -- Copy guardrails
  constraint chk_outreach_poll_result_messages_primary_message_len
    check (char_length(trim(primary_message)) between 1 and 280),

  constraint chk_outreach_poll_result_messages_cta_label_len
    check (char_length(trim(cta_label)) between 1 and 60),

  -- If campaign is present, enforce reasonable length after trimming
  constraint chk_outreach_poll_result_messages_campaign_len
    check (
      utm_campaign is null
      or char_length(trim(utm_campaign)) between 1 and 128
    ),

  -- Pairing rule: campaign targeting requires a source targeting
  constraint chk_outreach_poll_result_messages_target_pairing
    check (
      utm_campaign is null
      or source_id_resolved is not null
    ),

  -- (Optional but recommended) prevent whitespace-only campaign strings
  constraint chk_outreach_poll_result_messages_campaign_not_blank
    check (
      utm_campaign is null
      or trim(utm_campaign) <> ''
    )
);

-- Uniqueness across the targeting tuple.
-- NOTE: if you want campaign matching to be case-insensitive, consider storing
-- utm_campaign normalized (e.g., lower(trim())) via trigger or using CITEXT.
create unique index if not exists uq_outreach_poll_result_messages_target_tuple
  on public.outreach_poll_result_messages
  (poll_id, option_id, source_id_resolved, utm_campaign)
  nulls not distinct;

-- Fast lookup for "find best matching message"
create index if not exists idx_outreach_poll_result_messages_lookup
  on public.outreach_poll_result_messages
  (poll_id, option_id, active, source_id_resolved, utm_campaign);

comment on table public.outreach_poll_result_messages is
  'Result message variants for outreach polls, with optional source/campaign targeting.';

-- Touch updated_at automatically
drop trigger if exists trg_outreach_poll_result_messages_touch_updated_at
  on public.outreach_poll_result_messages;

create trigger trg_outreach_poll_result_messages_touch_updated_at
before update on public.outreach_poll_result_messages
for each row execute function public._touch_updated_at();

-- RLS + permissions
alter table public.outreach_poll_result_messages enable row level security;

revoke all on table public.outreach_poll_result_messages
  from public, anon, authenticated;

grant select on table public.outreach_poll_result_messages
  to anon, authenticated, service_role;

grant insert, update, delete on table public.outreach_poll_result_messages
  to service_role;

-- Policies (idempotent)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'outreach_poll_result_messages'
      and policyname = 'public_read_active_outreach_poll_result_messages'
  ) then
    execute $p$
      create policy "public_read_active_outreach_poll_result_messages"
      on public.outreach_poll_result_messages
      for select
      to anon, authenticated
      using (active = true)
    $p$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'outreach_poll_result_messages'
      and policyname = 'service_role_all_outreach_poll_result_messages'
  ) then
    execute $p$
      create policy "service_role_all_outreach_poll_result_messages"
      on public.outreach_poll_result_messages
      for all
      to service_role
      using (true)
      with check (true)
    $p$;
  end if;
end $$;


-- =====================================================================
-- Seed DEFAULT result messages (no targeting)
-- - One row per (poll_id, option_key)
-- - source_id_resolved = NULL, utm_campaign = NULL
-- - Upsert-safe
-- =====================================================================

with seed as (
  select *
  from (values
    -- ---------------------------------------------------------------
    -- poll_toilet_paper_v1 : "Who replaces the toilet paper in your flat?"
    -- poll_id = 041630e6-190f-48d8-860e-880e60ddeff7
    -- options: me, notice, not_notice
    -- ---------------------------------------------------------------
    ('041630e6-190f-48d8-860e-880e60ddeff7'::uuid, 'me'::text,
      'If it’s always you, that’s a silent job no one agreed to. Kinly makes shared standards visible and helps rotate responsibilities so it doesn’t default to one person.',
      'Share the load'
    ),
    ('041630e6-190f-48d8-860e-880e60ddeff7'::uuid, 'notice'::text,
      'You notice first — which usually means you end up reminding people. Kinly helps your flat agree on “the rule” once, then keeps it visible so you don’t have to repeat yourself.',
      'Agree once. Relax after.'
    ),
    ('041630e6-190f-48d8-860e-880e60ddeff7'::uuid, 'not_notice'::text,
      'If you don’t notice, it’s easy to accidentally annoy someone. Kinly makes expectations visible so you don’t have to guess — fewer awkward moments, more smooth living.',
      'Make it less awkward'
    ),

    -- ---------------------------------------------------------------
    -- poll_rent_reminder_v1 : "Who reminds everyone about rent?"
    -- poll_id = 6da03d6f-3a12-473b-ae67-40c77ede8a70
    -- options: system, person_reminder, landlord_chase
    -- ---------------------------------------------------------------
    ('6da03d6f-3a12-473b-ae67-40c77ede8a70'::uuid, 'system'::text,
      'Nice — you already have a system. Kinly keeps it running with less manual chasing, so reminders and expectations don’t rely on one person’s memory.',
      'Upgrade your system'
    ),
    ('6da03d6f-3a12-473b-ae67-40c77ede8a70'::uuid, 'person_reminder'::text,
      'When “someone reminds the group,” that person carries the mental load. Kinly automates reminders and makes responsibilities clear so it’s fairer — and less personal.',
      'Share the load'
    ),
    ('6da03d6f-3a12-473b-ae67-40c77ede8a70'::uuid, 'landlord_chase'::text,
      'If the landlord is the chaser, things can get tense fast. Kinly helps set expectations upfront and keep everyone aligned, so reminders feel neutral instead of confrontational.',
      'Share the load'
    ),

    -- ---------------------------------------------------------------
    -- poll_milk_v1 : "Your milk disappears. What’s the rule?"
    -- poll_id = 85ee1b79-3642-4e05-abb0-ea3aadcfaaa1
    -- options: chaos, share, individual
    -- ---------------------------------------------------------------
    ('85ee1b79-3642-4e05-abb0-ea3aadcfaaa1'::uuid, 'chaos'::text,
      '“It’s fair game” works… until someone’s had a long day. Kinly adds light structure so small stuff doesn’t become big drama.',
      'Make it less awkward'
    ),
    ('85ee1b79-3642-4e05-abb0-ea3aadcfaaa1'::uuid, 'share'::text,
      'Replace-what-you-use is fair, but it only works when everyone remembers. Kinly makes the rule explicit and reduces the need for “Hey… who took my milk?” moments.',
      'Agree once. Relax after.'
    ),
    ('85ee1b79-3642-4e05-abb0-ea3aadcfaaa1'::uuid, 'individual'::text,
      'If everyone keeps their own stuff separate, it’s simpler — but only if the boundary is clear. Kinly helps agree what’s shared vs personal so nobody feels taken advantage of.',
      'Agree once. Relax after.'
    )
  ) as v(poll_id, option_key, primary_message, cta_label)
),
resolved as (
  select
    s.poll_id,
    o.id as option_id,
    s.primary_message,
    s.cta_label
  from seed s
  join public.outreach_poll_options o
    on o.poll_id = s.poll_id
   and o.option_key = s.option_key
)
insert into public.outreach_poll_result_messages
  (poll_id, option_id, primary_message, cta_label, source_id_resolved, utm_campaign, active)
select
  poll_id,
  option_id,
  primary_message,
  cta_label,
  null::text as source_id_resolved,
  null::text as utm_campaign,
  true
from resolved
on conflict (poll_id, option_id, source_id_resolved, utm_campaign)
do update set
  primary_message = excluded.primary_message,
  cta_label       = excluded.cta_label,
  active          = excluded.active,
  updated_at      = now();

CREATE OR REPLACE FUNCTION public.homes_create_with_invite()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_home public.homes;
  v_inv  public.invites;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- 1) Create home
  INSERT INTO public.homes (owner_user_id)
  VALUES (v_user)
  RETURNING * INTO v_home;

  -- 2) Create owner membership (first active member)
  INSERT INTO public.memberships (user_id, home_id, role)
  VALUES (v_user, v_home.id, 'owner');

  -- 3) Increment usage counters: active_members +1
  PERFORM public._home_usage_apply_delta(
    v_home.id,
    jsonb_build_object('active_members', 1)
  );

  -- 4) Set entitlements (default: free)
  INSERT INTO public.home_entitlements (home_id, plan, expires_at)
  VALUES (v_home.id, 'free', NULL);

  -- 5) Seed starter draft chores for quick household setup (weekly recurrence)
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_assignee_user_id => v_user,
    p_name => 'Take out trash',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week',
    p_how_to_video_url => 'https://www.youtube.com/shorts/tF_smwdwzMk',
    p_expectation_photo_path => 'flow/expectations/1771359335379-pc7yvv_template.jpg',
    p_notes => 'Don''t forget to throw the rubbish, or else need to wait for a month!!'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Clean kitchen',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Clean bathroom',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  PERFORM public.chores_create_v2(
    p_home_id => v_home.id,
    p_name => 'Vacuum common area',
    p_recurrence_every => 1,
    p_recurrence_unit => 'week'
  );
  -- 6) Seed starter draft bill templates
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Internet bill'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Electric bill'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Water bill'
  );
  PERFORM public.expenses_create_v3(
    p_home_id => v_home.id,
    p_description => 'Rent'
  );
  PERFORM public.shopping_list_add_item(
    p_home_id => v_home.id,
    p_name => 'Toilet paper',
    p_quantity => '1',
    p_details => 'Get the 3-ply one for extra comfort!', 
    p_reference_photo_path => 'households/shopping/item/1771297308238-ecgval_template.jpg'
  );

  -- 7) Create first invite (one active per home enforced by partial index)
  INSERT INTO public.invites (home_id, code)
  VALUES (v_home.id, public._gen_invite_code())
  ON CONFLICT (home_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING * INTO v_inv;

  IF NOT FOUND THEN
    SELECT *
    INTO v_inv
    FROM public.invites
    WHERE home_id = v_home.id
      AND revoked_at IS NULL
    LIMIT 1;
  END IF;

  -- 8) Attach existing subscription to this home (if any)
  PERFORM public._home_attach_subscription_to_home(v_user, v_home.id);

  -- 9) Return result
  RETURN jsonb_build_object(
    'home', jsonb_build_object(
      'id',            v_home.id,
      'owner_user_id', v_home.owner_user_id,
      'created_at',    v_home.created_at
    ),
    'invite', jsonb_build_object(
      'id',         v_inv.id,
      'home_id',    v_inv.home_id,
      'code',       v_inv.code,
      'created_at', v_inv.created_at
    )
  );
END;
$$;


-- House vibe v2 cutover
-- - Activate v2 with stricter mixed threshold for large homes
-- - Keep small-home sensitivity unchanged
-- - Ensure invalidation is mapping-version safe
-- - Backfill v2 house_vibes rows for existing homes

-- Ensure only one active mapping version can exist.
CREATE UNIQUE INDEX IF NOT EXISTS house_vibe_versions_one_active_idx
ON public.house_vibe_versions ((status))
WHERE status = 'active';

-- Create v2 version row if missing.
INSERT INTO public.house_vibe_versions (
  mapping_version,
  min_side_count_small,
  min_side_count_large,
  status
)
VALUES (
  'v2',
  1,
  3,
  'draft'
)
ON CONFLICT (mapping_version) DO UPDATE
SET
  min_side_count_small = EXCLUDED.min_side_count_small,
  min_side_count_large = EXCLUDED.min_side_count_large;

-- Clone label registry from v1 to v2 (unchanged content).
INSERT INTO public.house_vibe_labels (
  label_id,
  mapping_version,
  title_key,
  summary_key,
  image_key,
  ui,
  is_active,
  updated_at
)
SELECT
  l.label_id,
  'v2',
  l.title_key,
  l.summary_key,
  l.image_key,
  l.ui,
  l.is_active,
  now()
FROM public.house_vibe_labels l
WHERE l.mapping_version = 'v1'
ON CONFLICT (mapping_version, label_id) DO UPDATE
SET
  title_key = EXCLUDED.title_key,
  summary_key = EXCLUDED.summary_key,
  image_key = EXCLUDED.image_key,
  ui = EXCLUDED.ui,
  is_active = EXCLUDED.is_active,
  updated_at = now();

-- Clone mapping effects from v1 to v2 (unchanged semantics; only version thresholds differ).
INSERT INTO public.house_vibe_mapping_effects (
  mapping_version,
  preference_id,
  option_index,
  axis,
  delta,
  weight
)
SELECT
  'v2',
  me.preference_id,
  me.option_index,
  me.axis,
  me.delta,
  me.weight
FROM public.house_vibe_mapping_effects me
WHERE me.mapping_version = 'v1'
ON CONFLICT (mapping_version, preference_id, option_index, axis) DO UPDATE
SET
  delta = EXCLUDED.delta,
  weight = EXCLUDED.weight;

-- Flip active mapping from v1 to v2.
UPDATE public.house_vibe_versions
SET status = CASE WHEN mapping_version = 'v2' THEN 'active' ELSE 'draft' END
WHERE mapping_version IN ('v1', 'v2');

-- Keep invalidation version-safe: invalidate all existing rows for home,
-- and ensure an active-version placeholder exists.
CREATE OR REPLACE FUNCTION public._house_vibes_mark_out_of_date(p_home_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total int;
  v_active_mapping_version text;
BEGIN
  SELECT COUNT(*)
    INTO v_total
  FROM public.memberships m
  WHERE m.home_id = p_home_id
    AND m.is_current = true;

  SELECT hv.mapping_version
    INTO v_active_mapping_version
  FROM public.house_vibe_versions hv
  WHERE hv.status = 'active'
  ORDER BY hv.created_at DESC
  LIMIT 1;

  IF v_active_mapping_version IS NULL THEN
    v_active_mapping_version := 'v1';
  END IF;

  UPDATE public.house_vibes
  SET
    out_of_date = true,
    invalidated_at = now(),
    computed_at = now(),
    coverage_total = COALESCE(v_total, 0)
  WHERE home_id = p_home_id;

  INSERT INTO public.house_vibes (
    home_id,
    mapping_version,
    label_id,
    confidence,
    coverage_answered,
    coverage_total,
    axes,
    computed_at,
    out_of_date,
    invalidated_at
  )
  VALUES (
    p_home_id,
    v_active_mapping_version,
    'insufficient_data',
    0,
    0,
    COALESCE(v_total, 0),
    '{}'::jsonb,
    now(),
    true,
    now()
  )
  ON CONFLICT (home_id, mapping_version) DO UPDATE
    SET out_of_date       = true,
        label_id          = EXCLUDED.label_id,
        confidence        = EXCLUDED.confidence,
        coverage_answered = EXCLUDED.coverage_answered,
        coverage_total    = EXCLUDED.coverage_total,
        axes              = EXCLUDED.axes,
        computed_at       = EXCLUDED.computed_at,
        invalidated_at    = EXCLUDED.invalidated_at;
END;
$$;

-- Eagerly seed v2 snapshots for current homes so all homes are immediately on v2 paths.
INSERT INTO public.house_vibes (
  home_id,
  mapping_version,
  label_id,
  confidence,
  coverage_answered,
  coverage_total,
  axes,
  computed_at,
  out_of_date,
  invalidated_at
)
SELECT
  m.home_id,
  'v2',
  'insufficient_data',
  0,
  0,
  COUNT(*)::int,
  '{}'::jsonb,
  now(),
  true,
  now()
FROM public.memberships m
WHERE m.is_current = true
GROUP BY m.home_id
ON CONFLICT (home_id, mapping_version) DO UPDATE
SET
  label_id = EXCLUDED.label_id,
  confidence = EXCLUDED.confidence,
  coverage_answered = EXCLUDED.coverage_answered,
  coverage_total = EXCLUDED.coverage_total,
  axes = EXCLUDED.axes,
  computed_at = EXCLUDED.computed_at,
  out_of_date = EXCLUDED.out_of_date,
  invalidated_at = EXCLUDED.invalidated_at;

-- Mark existing v1 snapshots stale for consistency after cutover.
UPDATE public.house_vibes
SET
  out_of_date = true,
  invalidated_at = now()
WHERE mapping_version = 'v1';
