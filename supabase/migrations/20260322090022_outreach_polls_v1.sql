-- =====================================================================
-- Outreach polls v1.0
-- - Adds poll schema, UC-focused read views, and RPCs.
-- - Enforces one-net-vote per session per poll.
-- - Uses short-link attribution as trust boundary.
-- - Rolls outreach tracking event taxonomy to include poll events.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Roll outreach tracking event taxonomy to include poll events
-- ---------------------------------------------------------------------
alter table public.outreach_event_logs
  drop constraint if exists chk_outreach_event_type;

alter table public.outreach_event_logs
  add constraint chk_outreach_event_type check (
    event in ('page_view', 'cta_click', 'poll_page_view', 'poll_vote', 'poll_results_view')
  );

comment on column public.outreach_event_logs.event is
  'Allowed: page_view, cta_click, poll_page_view, poll_vote, poll_results_view.';

create or replace function public.outreach_log_event(
  p_event           text,
  p_app_key         text,
  p_page_key        text,
  p_utm_campaign    text,
  p_utm_source      text,
  p_utm_medium      text,
  p_session_id      text,
  p_store           text default null,
  p_country         text default null,
  p_ui_locale       text default null,
  p_client_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event text := lower(trim(p_event));
  v_app_key text := trim(p_app_key);
  v_page_key text := trim(p_page_key);

  v_utm_campaign text := coalesce(nullif(trim(p_utm_campaign), ''), 'unknown');
  v_utm_source   text := coalesce(nullif(lower(trim(p_utm_source)), ''), 'unknown');
  v_utm_medium   text := coalesce(nullif(lower(trim(p_utm_medium)), ''), 'unknown');

  v_store text := coalesce(nullif(lower(trim(p_store)), ''), 'unknown');

  v_session_id text := trim(p_session_id);
  v_country text := nullif(upper(trim(p_country)), '');
  v_ui_locale text := nullif(trim(p_ui_locale), '');

  v_resolved text := 'unknown';
  v_id uuid;

  v_global_bucket timestamptz := date_trunc('minute', now());
  v_session_bucket timestamptz := date_trunc('hour', now());
begin
  perform public.api_assert(
    v_session_id ~ '^anon_[A-Za-z0-9_-]{16,32}$',
    'INVALID_SESSION',
    'session_id format invalid',
    '22023'
  );
  perform public.api_assert(
    v_event in ('page_view', 'cta_click', 'poll_page_view', 'poll_vote', 'poll_results_view'),
    'INVALID_EVENT',
    'event must be page_view, cta_click, poll_page_view, poll_vote, or poll_results_view',
    '22023'
  );
  perform public.api_assert(
    v_store in ('web', 'ios_app_store', 'google_play', 'unknown'),
    'INVALID_STORE',
    'store must be web, ios_app_store, google_play, or unknown',
    '22023'
  );

  perform public.api_assert(
    v_app_key is not null and v_app_key <> '' and char_length(v_app_key) <= 40,
    'INVALID_INPUT',
    'app_key is required',
    '22023'
  );
  perform public.api_assert(
    v_page_key is not null and v_page_key <> '' and char_length(v_page_key) <= 80,
    'INVALID_INPUT',
    'page_key is required',
    '22023'
  );

  perform public.api_assert(char_length(v_utm_campaign) <= 128, 'INVALID_INPUT', 'utm_campaign too long', '22023');
  perform public.api_assert(char_length(v_utm_source)   <= 128, 'INVALID_INPUT', 'utm_source too long', '22023');
  perform public.api_assert(char_length(v_utm_medium)   <= 128, 'INVALID_INPUT', 'utm_medium too long', '22023');
  perform public.api_assert(
    v_session_id is not null and v_session_id <> '' and char_length(v_session_id) <= 40,
    'INVALID_INPUT',
    'session_id is required',
    '22023'
  );

  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
    v_country := null;
  end if;

  if v_ui_locale is not null and (length(v_ui_locale) < 2 or length(v_ui_locale) > 35 or v_ui_locale ~ '\s') then
    v_ui_locale := null;
  end if;

  perform public.api_assert(
    public._outreach_rate_limit_bucketed('global', v_global_bucket, 500),
    'RATE_LIMIT_GLOBAL',
    'Global outreach logging rate limit exceeded',
    '42901'
  );

  perform public.api_assert(
    public._outreach_rate_limit_bucketed('session:' || v_session_id, v_session_bucket, 100),
    'RATE_LIMIT_SESSION',
    'Session outreach logging rate limit exceeded',
    '42901'
  );

  select s.source_id
    into v_resolved
    from public.outreach_sources s
   where s.source_id = v_utm_source
     and s.active = true
   limit 1;

  if v_resolved is null then
    select s.source_id
      into v_resolved
      from public.outreach_source_aliases a
      join public.outreach_sources s on s.source_id = a.source_id
     where a.alias = v_utm_source
       and a.active = true
       and s.active = true
     limit 1;
  end if;

  if v_resolved is null then
    v_resolved := 'unknown';
  end if;

  begin
    insert into public.outreach_event_logs (
      event, app_key, page_key, utm_campaign, utm_source, utm_medium,
      source_id_resolved, store, session_id, country, ui_locale, client_event_id
    ) values (
      v_event, v_app_key, v_page_key, v_utm_campaign, v_utm_source, v_utm_medium,
      v_resolved, v_store, v_session_id, v_country, v_ui_locale, p_client_event_id
    )
    returning id into v_id;
  exception when unique_violation then
    if p_client_event_id is not null then
      select id
        into v_id
        from public.outreach_event_logs
       where client_event_id = p_client_event_id
       limit 1;

      if v_id is not null then
        return jsonb_build_object('ok', true, 'id', v_id);
      end if;
    end if;

    raise;
  end;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 1) Poll tables
-- ---------------------------------------------------------------------
create table if not exists public.outreach_polls (
  id          uuid primary key default gen_random_uuid(),
  app_key     text not null,
  page_key    text not null,
  title       text not null,
  question    text not null,
  description text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint uq_outreach_polls_app_page unique (app_key, page_key),
  constraint chk_outreach_polls_app_key_len check (char_length(trim(app_key)) between 1 and 40),
  constraint chk_outreach_polls_page_key_len check (char_length(trim(page_key)) between 1 and 80),
  constraint chk_outreach_polls_title_len check (char_length(trim(title)) between 1 and 160),
  constraint chk_outreach_polls_question_len check (char_length(trim(question)) between 1 and 400)
);

create table if not exists public.outreach_poll_options (
  id         uuid primary key default gen_random_uuid(),
  poll_id    uuid not null references public.outreach_polls(id) on delete cascade,
  option_key text not null,
  label      text not null,
  position   integer not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_outreach_poll_options_poll_option_key unique (poll_id, option_key),
  constraint uq_outreach_poll_options_poll_position unique (poll_id, position),
  constraint uq_outreach_poll_options_poll_id_id unique (poll_id, id),
  constraint chk_outreach_poll_options_option_key check (option_key ~ '^[a-z0-9_]{1,40}$'),
  constraint chk_outreach_poll_options_label_len check (char_length(trim(label)) between 1 and 120),
  constraint chk_outreach_poll_options_position check (position >= 1)
);

create table if not exists public.outreach_poll_votes (
  id                 uuid primary key default gen_random_uuid(),
  poll_id            uuid not null references public.outreach_polls(id) on delete cascade,
  option_id          uuid not null,
  session_id         text not null,
  client_vote_id     uuid,
  short_link_id      uuid not null references public.outreach_short_links(id),
  page_key           text not null,
  source_id_resolved text not null references public.outreach_sources(source_id),
  utm_campaign       text not null,
  utm_source         text not null,
  utm_medium         text not null,
  store              text not null,
  country            text,
  ui_locale          text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint fk_outreach_poll_votes_poll_option_membership
    foreign key (poll_id, option_id) references public.outreach_poll_options(poll_id, id),
  constraint uq_outreach_poll_votes_poll_session unique (poll_id, session_id),
  constraint chk_outreach_poll_votes_session check (session_id ~ '^anon_[A-Za-z0-9_-]{16,32}$'),
  constraint chk_outreach_poll_votes_store check (store in ('web', 'ios_app_store', 'google_play', 'unknown')),
  constraint chk_outreach_poll_votes_country check (country is null or country ~ '^[A-Z]{2}$'),
  constraint chk_outreach_poll_votes_ui_locale check (
    ui_locale is null or (length(ui_locale) between 2 and 35 and ui_locale !~ '\s')
  ),
  constraint chk_outreach_poll_votes_page_key_len check (char_length(trim(page_key)) between 1 and 80),
  constraint chk_outreach_poll_votes_campaign_len check (char_length(trim(utm_campaign)) between 1 and 128),
  constraint chk_outreach_poll_votes_source_len check (char_length(trim(utm_source)) between 1 and 128),
  constraint chk_outreach_poll_votes_medium_len check (char_length(trim(utm_medium)) between 1 and 128)
);

create unique index if not exists uq_outreach_poll_votes_client_vote_id
  on public.outreach_poll_votes (client_vote_id)
  where client_vote_id is not null;

create index if not exists idx_outreach_poll_votes_poll_id
  on public.outreach_poll_votes (poll_id);

create index if not exists idx_outreach_poll_votes_option_id
  on public.outreach_poll_votes (option_id);

create index if not exists idx_outreach_poll_votes_page_key_created_at
  on public.outreach_poll_votes (page_key, created_at desc);

create index if not exists idx_outreach_poll_votes_source_resolved_created_at
  on public.outreach_poll_votes (source_id_resolved, created_at desc);

comment on table public.outreach_polls is 'Poll definitions keyed by app_key + page_key.';
comment on table public.outreach_poll_options is 'Poll options with deterministic ordering by position.';
comment on table public.outreach_poll_votes is 'One-net-vote-per-session poll votes with short-link attribution snapshot.';

drop trigger if exists trg_outreach_polls_touch_updated_at on public.outreach_polls;
create trigger trg_outreach_polls_touch_updated_at
before update on public.outreach_polls
for each row execute function public._touch_updated_at();

drop trigger if exists trg_outreach_poll_options_touch_updated_at on public.outreach_poll_options;
create trigger trg_outreach_poll_options_touch_updated_at
before update on public.outreach_poll_options
for each row execute function public._touch_updated_at();

drop trigger if exists trg_outreach_poll_votes_touch_updated_at on public.outreach_poll_votes;
create trigger trg_outreach_poll_votes_touch_updated_at
before update on public.outreach_poll_votes
for each row execute function public._touch_updated_at();

-- ---------------------------------------------------------------------
-- 2) Read views
-- ---------------------------------------------------------------------
create or replace view public.outreach_poll_results_uc_v1 as
with base as (
  select
    p.id as poll_id,
    p.page_key,
    o.id as option_id,
    o.option_key,
    o.position
  from public.outreach_polls p
  join public.outreach_poll_options o on o.poll_id = p.id
  where p.active = true
    and o.active = true
),
uc_counts as (
  select
    v.poll_id,
    v.option_id,
    count(*)::bigint as vote_count
  from public.outreach_poll_votes v
  where v.source_id_resolved = 'uc'
  group by v.poll_id, v.option_id
),
uc_totals as (
  select
    v.poll_id,
    count(*)::bigint as total_votes
  from public.outreach_poll_votes v
  where v.source_id_resolved = 'uc'
  group by v.poll_id
)
select
  b.page_key,
  b.option_key,
  coalesce(c.vote_count, 0)::bigint as vote_count,
  coalesce(t.total_votes, 0)::bigint as total_votes
from base b
left join uc_counts c
  on c.poll_id = b.poll_id and c.option_id = b.option_id
left join uc_totals t
  on t.poll_id = b.poll_id
order by b.page_key, b.position, b.option_id;

create or replace view public.outreach_poll_totals_uc_v1 as
select
  p.page_key,
  count(v.id)::bigint as total_votes,
  max(v.created_at) as last_vote_at
from public.outreach_polls p
left join public.outreach_poll_votes v
  on v.poll_id = p.id
 and v.source_id_resolved = 'uc'
where p.active = true
group by p.page_key;

create or replace view public.outreach_polls_overview_v1 as
with all_votes as (
  select
    v.poll_id,
    count(*)::bigint as total_votes_all,
    max(v.created_at) as last_vote_at_all
  from public.outreach_poll_votes v
  group by v.poll_id
),
uc_votes as (
  select
    v.poll_id,
    count(*)::bigint as total_votes_uc,
    max(v.created_at) as last_vote_at_uc
  from public.outreach_poll_votes v
  where v.source_id_resolved = 'uc'
  group by v.poll_id
)
select
  p.id,
  p.app_key,
  p.page_key,
  p.title,
  p.question,
  p.description,
  p.active,
  coalesce(a.total_votes_all, 0)::bigint as total_votes_all,
  coalesce(u.total_votes_uc, 0)::bigint as total_votes_uc,
  greatest(coalesce(a.last_vote_at_all, p.updated_at), coalesce(u.last_vote_at_uc, p.updated_at)) as last_activity_at
from public.outreach_polls p
left join all_votes a on a.poll_id = p.id
left join uc_votes u on u.poll_id = p.id;

-- ---------------------------------------------------------------------
-- 3) Poll RPCs
-- ---------------------------------------------------------------------
create or replace function public.outreach_poll_get_v1(
  p_app_key text,
  p_page_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app_key text := trim(coalesce(p_app_key, ''));
  v_page_key text := trim(coalesce(p_page_key, ''));
  v_poll public.outreach_polls%rowtype;
  v_options jsonb;
begin
  perform public.api_assert(
    v_app_key <> '' and char_length(v_app_key) <= 40,
    'INVALID_INPUT',
    'app_key is required',
    '22023'
  );

  perform public.api_assert(
    v_page_key <> '' and char_length(v_page_key) <= 80,
    'INVALID_INPUT',
    'page_key is required',
    '22023'
  );

  select *
    into v_poll
    from public.outreach_polls p
   where p.app_key = v_app_key
     and p.page_key = v_page_key
     and p.active = true
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'POLL_NOT_FOUND');
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id', o.id,
               'option_key', o.option_key,
               'label', o.label,
               'position', o.position
             )
             order by o.position asc, o.id asc
           ),
           '[]'::jsonb
         )
    into v_options
    from public.outreach_poll_options o
   where o.poll_id = v_poll.id
     and o.active = true;

  return jsonb_build_object(
    'ok', true,
    'poll', jsonb_build_object(
      'id', v_poll.id,
      'app_key', v_poll.app_key,
      'page_key', v_poll.page_key,
      'title', v_poll.title,
      'question', v_poll.question,
      'description', v_poll.description
    ),
    'options', v_options
  );
end;
$$;

create or replace function public.outreach_poll_vote_submit_v1(
  p_short_code text,
  p_option_key text,
  p_session_id text,
  p_store text default 'unknown',
  p_client_vote_id uuid default null,
  p_country text default null,
  p_ui_locale text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_short_code text := lower(trim(coalesce(p_short_code, '')));
  v_option_key text := lower(trim(coalesce(p_option_key, '')));
  v_session_id text := trim(coalesce(p_session_id, ''));
  v_store text := coalesce(nullif(lower(trim(p_store)), ''), 'unknown');
  v_country text := nullif(upper(trim(p_country)), '');
  v_ui_locale text := nullif(trim(p_ui_locale), '');

  v_short_link public.outreach_short_links%rowtype;
  v_poll public.outreach_polls%rowtype;
  v_option public.outreach_poll_options%rowtype;
  v_vote public.outreach_poll_votes%rowtype;
  v_existing_vote public.outreach_poll_votes%rowtype;
  v_counts jsonb;
  v_total_votes bigint;
begin
  perform public.api_assert(
    v_short_code ~ '^[a-z0-9_-]{4,24}$',
    'INVALID_SHORT_CODE',
    'short_code must match ^[a-z0-9_-]{4,24}$',
    '22023'
  );

  perform public.api_assert(
    v_option_key ~ '^[a-z0-9_]{1,40}$',
    'INVALID_OPTION',
    'option_key format invalid',
    '22023'
  );

  perform public.api_assert(
    v_session_id ~ '^anon_[A-Za-z0-9_-]{16,32}$',
    'INVALID_SESSION',
    'session_id format invalid',
    '22023'
  );

  perform public.api_assert(
    v_store in ('web', 'ios_app_store', 'google_play', 'unknown'),
    'INVALID_STORE',
    'store must be web, ios_app_store, google_play, or unknown',
    '22023'
  );

  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
    v_country := null;
  end if;

  if v_ui_locale is not null and (length(v_ui_locale) < 2 or length(v_ui_locale) > 35 or v_ui_locale ~ '\s') then
    v_ui_locale := null;
  end if;

  if p_client_vote_id is not null then
    select *
      into v_existing_vote
      from public.outreach_poll_votes v
     where v.client_vote_id = p_client_vote_id
     limit 1;

    if found then
      select o.option_key
        into v_option_key
        from public.outreach_poll_options o
       where o.id = v_existing_vote.option_id
       limit 1;

      select
        coalesce(sum(x.vote_count), 0)::bigint,
        coalesce(
          jsonb_agg(
            jsonb_build_object('option_key', x.option_key, 'vote_count', x.vote_count)
            order by x.position asc, x.option_id asc
          ),
          '[]'::jsonb
        )
      into v_total_votes, v_counts
      from (
        select
          o.id as option_id,
          o.option_key,
          o.position,
          count(v.id)::bigint as vote_count
        from public.outreach_poll_options o
        left join public.outreach_poll_votes v
          on v.option_id = o.id
         and v.poll_id = v_existing_vote.poll_id
        where o.poll_id = v_existing_vote.poll_id
          and o.active = true
        group by o.id, o.option_key, o.position
      ) x;

      return jsonb_build_object(
        'ok', true,
        'poll_id', v_existing_vote.poll_id,
        'selected_option_key', v_option_key,
        'results', jsonb_build_object(
          'total_votes', v_total_votes,
          'option_counts', v_counts
        )
      );
    end if;
  end if;

  select s.*
    into v_short_link
    from public.outreach_short_links s
    join public.outreach_short_links_effective l on l.id = s.id
   where l.short_code = v_short_code::public.citext
     and l.effective_active = true
   limit 1;

  if not found then
    select l.*
      into v_short_link
      from public.outreach_short_links l
     where l.short_code = v_short_code::public.citext
     limit 1;

    if not found then
      perform public.api_error('SHORT_CODE_NOT_FOUND', 'short_code was not found', 'P0002');
    else
      perform public.api_error('SHORT_CODE_INACTIVE', 'short_code is inactive or expired', 'P0001');
    end if;
  end if;

  select p.*
    into v_poll
    from public.outreach_polls p
   where p.app_key = v_short_link.app_key
     and p.page_key = v_short_link.page_key
     and p.active = true
   limit 1;

  if not found then
    perform public.api_error('POLL_NOT_FOUND', 'No active poll found for short_code destination', 'P0002');
  end if;

  select o.*
    into v_option
    from public.outreach_poll_options o
   where o.poll_id = v_poll.id
     and o.option_key = v_option_key
     and o.active = true
   limit 1;

  if not found then
    perform public.api_error('INVALID_OPTION', 'option_key is not valid for poll', '22023');
  end if;

  begin
    insert into public.outreach_poll_votes (
      poll_id,
      option_id,
      session_id,
      client_vote_id,
      short_link_id,
      page_key,
      source_id_resolved,
      utm_campaign,
      utm_source,
      utm_medium,
      store,
      country,
      ui_locale
    ) values (
      v_poll.id,
      v_option.id,
      v_session_id,
      p_client_vote_id,
      v_short_link.id,
      v_short_link.page_key,
      v_short_link.source_id_resolved,
      v_short_link.utm_campaign,
      v_short_link.utm_source,
      v_short_link.utm_medium,
      v_store,
      v_country,
      v_ui_locale
    )
    on conflict (poll_id, session_id) do update
      set option_id = excluded.option_id,
          client_vote_id = coalesce(public.outreach_poll_votes.client_vote_id, excluded.client_vote_id),
          short_link_id = excluded.short_link_id,
          page_key = excluded.page_key,
          source_id_resolved = excluded.source_id_resolved,
          utm_campaign = excluded.utm_campaign,
          utm_source = excluded.utm_source,
          utm_medium = excluded.utm_medium,
          store = excluded.store,
          country = excluded.country,
          ui_locale = excluded.ui_locale,
          updated_at = now()
    returning * into v_vote;
  exception when unique_violation then
    if p_client_vote_id is not null then
      select *
        into v_vote
        from public.outreach_poll_votes v
       where v.client_vote_id = p_client_vote_id
       limit 1;

      if found then
        select o.option_key
          into v_option_key
          from public.outreach_poll_options o
         where o.id = v_vote.option_id
         limit 1;

        select
          coalesce(sum(x.vote_count), 0)::bigint,
          coalesce(
            jsonb_agg(
              jsonb_build_object('option_key', x.option_key, 'vote_count', x.vote_count)
              order by x.position asc, x.option_id asc
            ),
            '[]'::jsonb
          )
        into v_total_votes, v_counts
        from (
          select
            o.id as option_id,
            o.option_key,
            o.position,
            count(v2.id)::bigint as vote_count
          from public.outreach_poll_options o
          left join public.outreach_poll_votes v2
            on v2.option_id = o.id
           and v2.poll_id = v_vote.poll_id
          where o.poll_id = v_vote.poll_id
            and o.active = true
          group by o.id, o.option_key, o.position
        ) x;

        return jsonb_build_object(
          'ok', true,
          'poll_id', v_vote.poll_id,
          'selected_option_key', v_option_key,
          'results', jsonb_build_object(
            'total_votes', v_total_votes,
            'option_counts', v_counts
          )
        );
      end if;
    end if;

    raise;
  end;

  perform public.outreach_log_event(
    'poll_vote',
    v_short_link.app_key,
    v_short_link.page_key,
    v_short_link.utm_campaign,
    v_short_link.utm_source,
    v_short_link.utm_medium,
    v_session_id,
    v_store,
    v_country,
    v_ui_locale,
    null
  );

  select
    coalesce(sum(x.vote_count), 0)::bigint,
    coalesce(
      jsonb_agg(
        jsonb_build_object('option_key', x.option_key, 'vote_count', x.vote_count)
        order by x.position asc, x.option_id asc
      ),
      '[]'::jsonb
    )
  into v_total_votes, v_counts
  from (
    select
      o.id as option_id,
      o.option_key,
      o.position,
      count(v.id)::bigint as vote_count
    from public.outreach_poll_options o
    left join public.outreach_poll_votes v
      on v.option_id = o.id
     and v.poll_id = v_poll.id
    where o.poll_id = v_poll.id
      and o.active = true
    group by o.id, o.option_key, o.position
  ) x;

  return jsonb_build_object(
    'ok', true,
    'poll_id', v_poll.id,
    'selected_option_key', v_option.option_key,
    'results', jsonb_build_object(
      'total_votes', v_total_votes,
      'option_counts', v_counts
    )
  );
end;
$$;

revoke all on function public.outreach_poll_get_v1(text, text) from public;
revoke all on function public.outreach_poll_vote_submit_v1(text, text, text, text, uuid, text, text) from public;

grant execute on function public.outreach_poll_get_v1(text, text) to anon, authenticated, service_role;
grant execute on function public.outreach_poll_vote_submit_v1(text, text, text, text, uuid, text, text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4) RLS + grants
-- ---------------------------------------------------------------------
alter table public.outreach_polls enable row level security;
alter table public.outreach_poll_options enable row level security;
alter table public.outreach_poll_votes enable row level security;

revoke all on table public.outreach_polls from public, anon, authenticated;
revoke all on table public.outreach_poll_options from public, anon, authenticated;
revoke all on table public.outreach_poll_votes from public, anon, authenticated;

grant select, insert, update, delete on table public.outreach_polls to service_role;
grant select, insert, update, delete on table public.outreach_poll_options to service_role;
grant select, insert, update, delete on table public.outreach_poll_votes to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'outreach_polls'
       and policyname = 'service_role_all_outreach_polls'
  ) then
    execute $p$
      create policy "service_role_all_outreach_polls"
      on public.outreach_polls
      for all
      to service_role
      using (true)
      with check (true)
    $p$;
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'outreach_poll_options'
       and policyname = 'service_role_all_outreach_poll_options'
  ) then
    execute $p$
      create policy "service_role_all_outreach_poll_options"
      on public.outreach_poll_options
      for all
      to service_role
      using (true)
      with check (true)
    $p$;
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'outreach_poll_votes'
       and policyname = 'service_role_all_outreach_poll_votes'
  ) then
    execute $p$
      create policy "service_role_all_outreach_poll_votes"
      on public.outreach_poll_votes
      for all
      to service_role
      using (true)
      with check (true)
    $p$;
  end if;
end $$;
