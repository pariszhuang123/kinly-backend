-- ============================================================================
-- Flatmate Fit Check
-- Hard-cut production migration
--
-- Goals:
-- - remove plaintext token storage completely
-- - keep share links reusable for multiple applicants
-- - make claim single-use with guarded update
-- - serialize submission-cap enforcement per share link
-- - move rate-limit cleanup out of hot path
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

create table if not exists public.fit_check_drafts (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid null references auth.users(id) on delete set null,
  home_id uuid null references public.homes(id) on delete set null,
  owner_answers jsonb not null,
  requested_locale_base text not null default 'en',
  draft_session_token_hash text null,
  claim_token_hash text not null,
  claim_token_used_at timestamptz null,
  claimed_at timestamptz null,
  home_attached_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fit_check_drafts_owner_answers_object_check
    check (jsonb_typeof(owner_answers) = 'object'),
  constraint fit_check_drafts_requested_locale_base_check
    check (requested_locale_base ~ '^[a-z]{2}$'),
  constraint fit_check_drafts_claim_token_hash_check
    check (char_length(claim_token_hash) = 64),
  constraint fit_check_drafts_draft_session_token_hash_check
    check (
      draft_session_token_hash is null
      or char_length(draft_session_token_hash) = 64
    )
);

create unique index if not exists uq_fit_check_drafts_home_id
  on public.fit_check_drafts (home_id)
  where home_id is not null;

create unique index if not exists uq_fit_check_drafts_claim_token_hash
  on public.fit_check_drafts (claim_token_hash);

create unique index if not exists uq_fit_check_drafts_draft_session_token_hash
  on public.fit_check_drafts (draft_session_token_hash)
  where draft_session_token_hash is not null;

create index if not exists idx_fit_check_drafts_owner_user_id
  on public.fit_check_drafts (owner_user_id);

create index if not exists idx_fit_check_drafts_created_at
  on public.fit_check_drafts (created_at desc);

drop trigger if exists trg_fit_check_drafts_touch_updated_at on public.fit_check_drafts;
create trigger trg_fit_check_drafts_touch_updated_at
before update on public.fit_check_drafts
for each row execute function public._touch_updated_at();

create table if not exists public.fit_check_share_tokens (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.fit_check_drafts(id) on delete cascade,
  token_hash text not null,
  status text not null default 'active',
  expires_at timestamptz not null,
  revoked_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint fit_check_share_tokens_hash_check
    check (char_length(token_hash) = 64),
  constraint fit_check_share_tokens_status_check
    check (status in ('active', 'revoked', 'expired'))
);

create unique index if not exists uq_fit_check_share_tokens_token_hash
  on public.fit_check_share_tokens (token_hash);

create unique index if not exists uq_fit_check_share_tokens_active_per_draft
  on public.fit_check_share_tokens (draft_id)
  where status = 'active';

create index if not exists idx_fit_check_share_tokens_draft_created_at
  on public.fit_check_share_tokens (draft_id, created_at desc);

create table if not exists public.candidate_fit_submissions (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.fit_check_drafts(id) on delete cascade,
  share_token_id uuid not null references public.fit_check_share_tokens(id) on delete restrict,
  display_name text not null,
  answers jsonb not null,
  anonymous_session_hash text not null,
  submitted_at timestamptz not null default now(),
  constraint candidate_fit_submissions_answers_object_check
    check (jsonb_typeof(answers) = 'object'),
  constraint candidate_fit_submissions_display_name_check
    check (char_length(trim(display_name)) between 1 and 80),
  constraint candidate_fit_submissions_anonymous_session_hash_check
    check (char_length(anonymous_session_hash) = 64)
);

create unique index if not exists uq_candidate_fit_submissions_token_session
  on public.candidate_fit_submissions (share_token_id, anonymous_session_hash);

create index if not exists idx_candidate_fit_submissions_draft_submitted_at
  on public.candidate_fit_submissions (draft_id, submitted_at desc);

create table if not exists public.candidate_fit_briefings (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null unique references public.candidate_fit_submissions(id) on delete cascade,
  draft_id uuid not null references public.fit_check_drafts(id) on delete cascade,
  owner_answers_snapshot jsonb not null,
  briefing_payload jsonb not null,
  generated_at timestamptz not null default now(),
  constraint candidate_fit_briefings_owner_answers_snapshot_object_check
    check (jsonb_typeof(owner_answers_snapshot) = 'object'),
  constraint candidate_fit_briefings_briefing_payload_object_check
    check (jsonb_typeof(briefing_payload) = 'object')
);

create index if not exists idx_candidate_fit_briefings_draft_generated_at
  on public.candidate_fit_briefings (draft_id, generated_at desc);

create table if not exists public.fit_check_templates (
  template_key text not null,
  locale_base text not null,
  template_value text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (template_key, locale_base),
  constraint fit_check_templates_template_key_check
    check (template_key ~ '^[a-z0-9._-]{1,160}$'),
  constraint fit_check_templates_locale_base_check
    check (locale_base ~ '^[a-z]{2}$'),
  constraint fit_check_templates_template_value_check
    check (char_length(trim(template_value)) between 1 and 1000)
);

drop trigger if exists trg_fit_check_templates_touch_updated_at on public.fit_check_templates;
create trigger trg_fit_check_templates_touch_updated_at
before update on public.fit_check_templates
for each row execute function public._touch_updated_at();

create table if not exists public.fit_check_rate_limits (
  k text primary key,
  bucket_at timestamptz not null,
  n integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint fit_check_rate_limits_n_check check (n >= 0)
);

create index if not exists idx_fit_check_rate_limits_updated_at
  on public.fit_check_rate_limits (updated_at);

alter table public.fit_check_drafts enable row level security;
alter table public.fit_check_share_tokens enable row level security;
alter table public.candidate_fit_submissions enable row level security;
alter table public.candidate_fit_briefings enable row level security;
alter table public.fit_check_templates enable row level security;
alter table public.fit_check_rate_limits enable row level security;

revoke all on table public.fit_check_drafts from public, anon, authenticated;
revoke all on table public.fit_check_share_tokens from public, anon, authenticated;
revoke all on table public.candidate_fit_submissions from public, anon, authenticated;
revoke all on table public.candidate_fit_briefings from public, anon, authenticated;
revoke all on table public.fit_check_templates from public, anon, authenticated;
revoke all on table public.fit_check_rate_limits from public, anon, authenticated;

comment on table public.fit_check_drafts is 'Anonymous and claimed owner draft state for Flatmate Fit Check. Only token hashes are stored.';
comment on table public.fit_check_share_tokens is 'Public share tokens for candidate fit-check access; only one active token per draft; only token hashes are stored.';
comment on table public.candidate_fit_submissions is 'Anonymous candidate scenario submissions keyed by share token + opaque session.';
comment on table public.candidate_fit_briefings is 'Frozen owner-facing briefings generated from candidate submissions.';
comment on table public.fit_check_templates is 'Locale-backed template catalog for fit-check summaries, watchouts, and prompts.';
comment on table public.fit_check_rate_limits is 'Short-lived anti-abuse buckets; cleaned by scheduled job.';

-- ----------------------------------------------------------------------------
-- Template seed data (en)
-- ----------------------------------------------------------------------------

insert into public.fit_check_templates (template_key, locale_base, template_value)
values
  ('fit_check.owner.entry_prompt', 'en', 'Quick check to spot potential issues before inviting someone to view'),
  ('fit_check.owner.save_prompt', 'en', 'Continue in the app to save your results and see candidate briefings later'),
  ('fit_check.candidate.entry_prompt', 'en', 'Answer a few quick questions about how you live day-to-day'),
  ('fit_check.candidate.submitted', 'en', 'Thanks - this helps the household understand how you live day-to-day and makes things easier once you move in.'),
  ('fit_check.candidate.create_own_cta', 'en', 'Looking for a place to live? Explore Kinly and download the app'),
  ('fit_check.candidate.reflection.structured', 'en', 'People who answered like you usually prefer clearer routines and expectations at home.'),
  ('fit_check.candidate.reflection.balanced', 'en', 'People who answered like you usually do well in homes that mix structure with flexibility.'),
  ('fit_check.candidate.reflection.flexible', 'en', 'People who answered like you usually prefer flexible living environments.'),
  ('fit_check.briefing.context', 'en', 'Use this briefing to spot where day-to-day friction is most likely to show up before the interview.'),
  ('fit_check.briefing.limitation', 'en', 'This is a starting point - people can be flexible. Use this to guide the conversation, not make the decision.'),
  ('fit_check.briefing.focus', 'en', 'If you only have time to cover a few things, start with the top watchouts above - these are the most likely to affect day-to-day living.'),
  ('fit_check.error.link_expired', 'en', 'Link expired'),
  ('fit_check.error.link_exhausted', 'en', 'This link is no longer accepting submissions.'),
  ('fit_check.error.link_revoked', 'en', 'Link revoked'),
  ('fit_check.error.link_unavailable', 'en', 'Link unavailable'),
  ('fit_check.review.summary.aligned', 'en', 'Mostly aligned'),
  ('fit_check.review.summary.discuss', 'en', 'A few things to discuss'),
  ('fit_check.review.summary.high_risk', 'en', 'Strong watchouts to cover'),
  ('fit_check.scenario.fit_cleanliness.prompt', 'en', 'When the kitchen is messy, what do you usually do?'),
  ('fit_check.scenario.fit_cleanliness.option.0', 'en', 'Clean it straight away'),
  ('fit_check.scenario.fit_cleanliness.option.1', 'en', 'Leave it a while, then clean it'),
  ('fit_check.scenario.fit_cleanliness.option.2', 'en', 'Leave it unless it''s mine'),
  ('fit_check.scenario.fit_rhythm.prompt', 'en', 'What does a normal weekday night look like for you?'),
  ('fit_check.scenario.fit_rhythm.option.0', 'en', 'Quiet, early night'),
  ('fit_check.scenario.fit_rhythm.option.1', 'en', 'Chill - TV or music'),
  ('fit_check.scenario.fit_rhythm.option.2', 'en', 'Social or late nights'),
  ('fit_check.scenario.fit_chores.prompt', 'en', 'How do you prefer shared chores to work?'),
  ('fit_check.scenario.fit_chores.option.0', 'en', 'Roster or system'),
  ('fit_check.scenario.fit_chores.option.1', 'en', 'Take initiative when needed'),
  ('fit_check.scenario.fit_chores.option.2', 'en', 'Only handle my own things'),
  ('fit_check.scenario.fit_conflict.prompt', 'en', 'If something bothers you about a housemate, what do you usually do?'),
  ('fit_check.scenario.fit_conflict.option.0', 'en', 'Bring it up early'),
  ('fit_check.scenario.fit_conflict.option.1', 'en', 'Wait a bit, then raise it'),
  ('fit_check.scenario.fit_conflict.option.2', 'en', 'Avoid it unless it''s serious'),
  ('fit_check.watchout.fit_cleanliness.owner_higher.1', 'en', 'You are more relaxed than they are about shared kitchen mess. Even a small difference here can show up quickly in day-to-day living and create frustration if the reset timing is unclear.'),
  ('fit_check.watchout.fit_cleanliness.owner_higher.2', 'en', 'You are much more relaxed than they are about shared kitchen mess. Cleanliness gaps like this are one of the most common sources of flat tension and can turn into ongoing annoyance fast.'),
  ('fit_check.watchout.fit_cleanliness.candidate_higher.1', 'en', 'They are a bit more relaxed than you are about shared kitchen mess. That difference is likely to show up in dishes, benches, and how quickly shared spaces get reset.'),
  ('fit_check.watchout.fit_cleanliness.candidate_higher.2', 'en', 'They are much more relaxed than you are about shared kitchen mess. This is a classic expectation gap that can feel unfair very quickly if you end up carrying the reset work.'),
  ('fit_check.watchout.fit_rhythm.owner_higher.1', 'en', 'You are a bit more flexible than they are about noise and activity at night. It is worth checking sleep schedules, guests, and what “quiet” means in practice.'),
  ('fit_check.watchout.fit_rhythm.owner_higher.2', 'en', 'You are much more flexible than they are about noise and activity at night. This can become a regular tension point if expectations around evenings are not made explicit.'),
  ('fit_check.watchout.fit_rhythm.candidate_higher.1', 'en', 'They are a bit more flexible than you are about noise and activity at night. It is worth checking bedtime routines, guests, and how noise is handled on weeknights.'),
  ('fit_check.watchout.fit_rhythm.candidate_higher.2', 'en', 'They are much more flexible than you are about noise and activity at night. This kind of gap can lead to repeated friction if quiet hours are assumed rather than discussed.'),
  ('fit_check.watchout.fit_chores.owner_higher.1', 'en', 'You prefer more flexibility than they do around how shared responsibilities get handled. It is worth checking whether people expect a system, reminders, or just initiative.'),
  ('fit_check.watchout.fit_chores.owner_higher.2', 'en', 'You are much more flexible than they are around how shared responsibilities get handled. This can quickly feel unfair if one person expects a system and the other expects things to happen naturally.'),
  ('fit_check.watchout.fit_chores.candidate_higher.1', 'en', 'They prefer a bit more flexibility than you do around shared responsibilities. It is worth checking how chores are noticed, tracked, and what counts as “pulling your weight.”'),
  ('fit_check.watchout.fit_chores.candidate_higher.2', 'en', 'They are much more flexible than you are around shared responsibilities. This can create frustration fast if you expect clarity and they expect people to self-manage loosely.'),
  ('fit_check.watchout.fit_conflict.owner_higher.1', 'en', 'You are a bit more likely than they are to let small issues pass. It is worth checking how feedback is usually raised and whether problems get addressed early or only when serious.'),
  ('fit_check.watchout.fit_conflict.owner_higher.2', 'en', 'You are much more likely than they are to let small issues pass. This can create a mismatch where one person wants early directness and the other prefers to avoid tension until it builds up.'),
  ('fit_check.watchout.fit_conflict.candidate_higher.1', 'en', 'They are a bit more likely than you are to let small issues pass. It is worth checking how people raise concerns and what happens when something feels off.'),
  ('fit_check.watchout.fit_conflict.candidate_higher.2', 'en', 'They are much more likely than you are to let small issues pass. That difference can make repair harder if one person expects early directness and the other waits too long.'),
  ('fit_check.question.fit_cleanliness.q1', 'en', 'What does “clean enough” mean to you in shared spaces like the kitchen or bathroom?'),
  ('fit_check.question.fit_cleanliness.q2', 'en', 'How quickly do you usually expect dishes, benches, or shared mess to be reset?'),
  ('fit_check.question.fit_rhythm.q1', 'en', 'What time do you normally wind down on weeknights, and what feels too noisy?'),
  ('fit_check.question.fit_rhythm.q2', 'en', 'How do you feel about guests, music, TV, or late-night activity during the week?'),
  ('fit_check.question.fit_chores.q1', 'en', 'Do you prefer chores to be assigned clearly, or handled more informally as people notice things?'),
  ('fit_check.question.fit_chores.q2', 'en', 'What does a fair split of shared responsibilities look like to you?'),
  ('fit_check.question.fit_conflict.q1', 'en', 'If something is bothering you at home, how do you usually bring it up?'),
  ('fit_check.question.fit_conflict.q2', 'en', 'Do you prefer issues to be raised early, or only once they are clearly serious?')
on conflict (template_key, locale_base) do update
set template_value = excluded.template_value,
    updated_at = now();

-- ----------------------------------------------------------------------------
-- Helper functions
-- ----------------------------------------------------------------------------

create or replace function public._fit_check_share_token_ttl()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '30 days';
$$;

create or replace function public._fit_check_claim_token_ttl()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '30 days';
$$;

create or replace function public._fit_check_unclaimed_purge_ttl()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '90 days';
$$;

create or replace function public._fit_check_submission_cap()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 20;
$$;

create or replace function public._fit_check_requested_locale_base(p_locale text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_requested_locale_base text;
begin
  perform public.api_assert(
    p_locale is not null
    and p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'FIT_CHECK_INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  v_requested_locale_base := lower(coalesce(public.locale_base(p_locale), 'en'));

  perform public.api_assert(
    v_requested_locale_base ~ '^[a-z]{2}$',
    'FIT_CHECK_INVALID_LOCALE',
    'Locale base must be ISO 639-1 lowercase (e.g. en).',
    '22023',
    jsonb_build_object('locale_base', v_requested_locale_base)
  );

  return v_requested_locale_base;
end;
$$;

create or replace function public._fit_check_resolved_locale_base(p_requested_locale_base text)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when exists (
      select 1
      from public.fit_check_templates t
      where t.locale_base = p_requested_locale_base
    ) then p_requested_locale_base
    else 'en'
  end;
$$;

create or replace function public._fit_check_template_value(
  p_template_key text,
  p_requested_locale_base text
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_template_value text;
begin
  select t.template_value
    into v_template_value
  from public.fit_check_templates t
  where t.template_key = p_template_key
    and t.locale_base = p_requested_locale_base
  limit 1;

  if v_template_value is null then
    select t.template_value
      into v_template_value
    from public.fit_check_templates t
    where t.template_key = p_template_key
      and t.locale_base = 'en'
    limit 1;
  end if;

  perform public.api_assert(
    v_template_value is not null,
    'FIT_CHECK_NOT_FOUND',
    'Missing fit-check template.',
    'P0001',
    jsonb_build_object(
      'template_key', p_template_key,
      'requested_locale_base', p_requested_locale_base
    )
  );

  return v_template_value;
end;
$$;

create or replace function public._fit_check_request_headers()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    nullif(current_setting('request.headers', true), ''),
    '{}'
  )::jsonb;
$$;

create or replace function public._fit_check_anonymous_session_id()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_headers jsonb := public._fit_check_request_headers();
  v_session_id text := nullif(
    coalesce(
      v_headers ->> 'x-fit-check-session-id',
      v_headers ->> 'X-Fit-Check-Session-Id'
    ),
    ''
  );
begin
  perform public.api_assert(
    v_session_id is not null
    and v_session_id ~ '^anon_[A-Za-z0-9_-]{16,64}$',
    'FIT_CHECK_INVALID_INPUTS',
    'Missing or invalid anonymous fit-check session header.',
    '22023',
    jsonb_build_object('header', 'x-fit-check-session-id')
  );

  return v_session_id;
end;
$$;

create or replace function public._fit_check_anonymous_session_hash()
returns text
language sql
stable
set search_path = ''
as $$
  select public._sha256_hex(public._fit_check_anonymous_session_id());
$$;

create or replace function public._fit_check_validate_answers(p_answers jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_answers jsonb := p_answers;
  v_key text;
  v_keys text[];
begin
  perform public.api_assert(
    v_answers is not null
    and jsonb_typeof(v_answers) = 'object',
    'FIT_CHECK_INVALID_INPUTS',
    'answers must be a JSON object.',
    '22023'
  );

  perform public.api_assert(
    pg_column_size(v_answers) <= 2048,
    'FIT_CHECK_INVALID_INPUTS',
    'answers payload too large.',
    '22023'
  );

  v_keys := array(
    select jsonb_object_keys(v_answers)
    order by 1
  );

  perform public.api_assert(
    v_keys = array['fit_chores', 'fit_cleanliness', 'fit_conflict', 'fit_rhythm'],
    'FIT_CHECK_INVALID_INPUTS',
    'answers must contain exactly fit_cleanliness, fit_rhythm, fit_chores, and fit_conflict.',
    '22023',
    jsonb_build_object('keys', coalesce(v_keys, array[]::text[]))
  );

  foreach v_key in array array['fit_cleanliness', 'fit_rhythm', 'fit_chores', 'fit_conflict']
  loop
    perform public.api_assert(
      (v_answers ->> v_key) ~ '^[012]$',
      'FIT_CHECK_INVALID_INPUTS',
      'answer values must be integers 0..2.',
      '22023',
      jsonb_build_object('scenario_id', v_key, 'value', v_answers ->> v_key)
    );
  end loop;

  return jsonb_build_object(
    'fit_cleanliness', (v_answers ->> 'fit_cleanliness')::integer,
    'fit_rhythm', (v_answers ->> 'fit_rhythm')::integer,
    'fit_chores', (v_answers ->> 'fit_chores')::integer,
    'fit_conflict', (v_answers ->> 'fit_conflict')::integer
  );
end;
$$;

create or replace function public._fit_check_generate_token(p_prefix text)
returns text
language sql
volatile
set search_path = ''
as $$
  select lower(
    p_prefix
    || '_'
    || substring(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') from 1 for 32)
  );
$$;

create or replace function public._fit_check_build_share_url(p_share_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://go.makinglifeeasie.com/kinly/fit-check/' || p_share_token;
$$;

create or replace function public._fit_check_build_continue_in_app_url(p_claim_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://go.makinglifeeasie.com/kinly/app/fit-check/claim/' || p_claim_token;
$$;

create or replace function public._fit_check_candidate_cta_url()
returns text
language sql
immutable
set search_path = ''
as $$
  select 'https://go.makinglifeeasie.com/kinly';
$$;

create or replace function public._fit_check_summary_labels(
  p_answers jsonb,
  p_requested_locale_base text
)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_array(
    public._fit_check_template_value(
      'fit_check.scenario.fit_cleanliness.option.' || (p_answers ->> 'fit_cleanliness'),
      p_requested_locale_base
    ),
    public._fit_check_template_value(
      'fit_check.scenario.fit_rhythm.option.' || (p_answers ->> 'fit_rhythm'),
      p_requested_locale_base
    ),
    public._fit_check_template_value(
      'fit_check.scenario.fit_chores.option.' || (p_answers ->> 'fit_chores'),
      p_requested_locale_base
    ),
    public._fit_check_template_value(
      'fit_check.scenario.fit_conflict.option.' || (p_answers ->> 'fit_conflict'),
      p_requested_locale_base
    )
  );
$$;

create or replace function public._fit_check_prefill_payload(p_answers jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'norms_shared_spaces',
      (array['clear_now', 'reset_later', 'relaxed'])[((p_answers ->> 'fit_cleanliness')::integer) + 1],
    'norms_rhythm_quiet',
      (array['wind_down', 'variable', 'flexible'])[((p_answers ->> 'fit_rhythm')::integer) + 1],
    'norms_responsibility_flow',
      (array['clear_agreements', 'notice_and_do', 'own_areas'])[((p_answers ->> 'fit_chores')::integer) + 1],
    'norms_repair_style',
      (array['talk_soon', 'gentle_check_in', 'let_small_pass'])[((p_answers ->> 'fit_conflict')::integer) + 1]
  );
$$;

create or replace function public._fit_check_onboarding_seed(p_answers jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'house_norms', jsonb_build_object(
      'initial_responses', jsonb_build_object(
        'norms_shared_spaces', (p_answers ->> 'fit_cleanliness')::integer,
        'norms_rhythm_quiet', (p_answers ->> 'fit_rhythm')::integer,
        'norms_responsibility_flow', (p_answers ->> 'fit_chores')::integer,
        'norms_repair_style', (p_answers ->> 'fit_conflict')::integer
      )
    ),
    'preferences', jsonb_build_object(
      'initial_responses', jsonb_build_object()
    )
  );
$$;

create or replace function public._fit_check_reflection_key(p_answers jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_avg numeric;
begin
  v_avg := (
    ((p_answers ->> 'fit_cleanliness')::numeric
    + (p_answers ->> 'fit_rhythm')::numeric
    + (p_answers ->> 'fit_chores')::numeric
    + (p_answers ->> 'fit_conflict')::numeric) / 4.0
  );

  if v_avg <= 0.50 then
    return 'fit_check.candidate.reflection.structured';
  elsif v_avg >= 1.50 then
    return 'fit_check.candidate.reflection.flexible';
  end if;

  return 'fit_check.candidate.reflection.balanced';
end;
$$;

create or replace function public._fit_check_review_summary_label(
  p_briefing_payload jsonb,
  p_requested_locale_base text
)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_watchouts jsonb := coalesce(p_briefing_payload -> 'watchouts', '[]'::jsonb);
  v_has_distance_two boolean := false;
begin
  select exists (
    select 1
    from jsonb_array_elements(v_watchouts) elem
    where (elem ->> 'distance')::integer = 2
  )
    into v_has_distance_two;

  if jsonb_array_length(v_watchouts) = 0 then
    return public._fit_check_template_value('fit_check.review.summary.aligned', p_requested_locale_base);
  elsif v_has_distance_two then
    return public._fit_check_template_value('fit_check.review.summary.high_risk', p_requested_locale_base);
  end if;

  return public._fit_check_template_value('fit_check.review.summary.discuss', p_requested_locale_base);
end;
$$;

create or replace function public._fit_check_generate_briefing_payload(
  p_owner_answers jsonb,
  p_candidate_answers jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_scenarios text[] := array['fit_cleanliness', 'fit_rhythm', 'fit_chores', 'fit_conflict'];
  v_primary_candidates text[] := array[]::text[];
  v_primary_focus text[] := array[]::text[];
  v_alignments jsonb := '[]'::jsonb;
  v_watchouts jsonb := '[]'::jsonb;
  v_scenario text;
  v_owner_idx integer;
  v_candidate_idx integer;
  v_distance integer;
  v_direction text;
begin
  for v_scenario in select unnest(v_scenarios)
  loop
    v_owner_idx := (p_owner_answers ->> v_scenario)::integer;
    v_candidate_idx := (p_candidate_answers ->> v_scenario)::integer;
    v_distance := abs(v_owner_idx - v_candidate_idx);

    if v_distance = 0 then
      v_alignments := v_alignments || jsonb_build_array(
        jsonb_build_object('scenario_id', v_scenario)
      );
    else
      v_direction := case
        when v_owner_idx > v_candidate_idx then 'owner_higher'
        else 'candidate_higher'
      end;

      v_watchouts := v_watchouts || jsonb_build_array(
        jsonb_build_object(
          'scenario_id', v_scenario,
          'distance', v_distance,
          'direction', v_direction,
          'watchout_key', 'fit_check.watchout.' || v_scenario || '.' || v_direction || '.' || v_distance,
          'question_keys', jsonb_build_array(
            'fit_check.question.' || v_scenario || '.q1',
            'fit_check.question.' || v_scenario || '.q2'
          ),
          'is_primary_focus', false
        )
      );

      if v_distance = 2 then
        v_primary_candidates := array_append(v_primary_candidates, v_scenario);
      end if;
    end if;
  end loop;

  if cardinality(v_primary_candidates) = 0 then
    for v_scenario in select unnest(v_scenarios)
    loop
      if abs((p_owner_answers ->> v_scenario)::integer - (p_candidate_answers ->> v_scenario)::integer) = 1 then
        v_primary_candidates := array_append(v_primary_candidates, v_scenario);
      end if;
    end loop;
  end if;

  v_primary_focus := coalesce(v_primary_candidates[1:2], array[]::text[]);

  return jsonb_build_object(
    'context_key', 'fit_check.briefing.context',
    'limitation_key', 'fit_check.briefing.limitation',
    'focus_key', 'fit_check.briefing.focus',
    'alignments', v_alignments,
    'watchouts',
      (
        select coalesce(jsonb_agg(
          case
            when (elem ->> 'scenario_id') = any(v_primary_focus) then
              jsonb_set(elem, '{is_primary_focus}', 'true'::jsonb)
            else elem
          end
          order by case elem ->> 'scenario_id'
            when 'fit_cleanliness' then 1
            when 'fit_rhythm' then 2
            when 'fit_chores' then 3
            when 'fit_conflict' then 4
            else 99
          end
        ), '[]'::jsonb)
        from jsonb_array_elements(v_watchouts) with ordinality as e(elem, ordinality)
      )
  );
end;
$$;

create or replace function public._fit_check_rate_limit_bucketed(
  p_key text,
  p_bucket timestamptz,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  insert into public.fit_check_rate_limits (k, bucket_at, n, updated_at)
  values (p_key, p_bucket, 1, now())
  on conflict (k) do update
    set n = case
              when public.fit_check_rate_limits.bucket_at = excluded.bucket_at
                then public.fit_check_rate_limits.n + 1
              else 1
            end,
        bucket_at = excluded.bucket_at,
        updated_at = now()
  returning n into v_n;

  return v_n <= p_limit;
end;
$$;

create or replace function public._fit_check_assert_owner(p_draft_id uuid)
returns public.fit_check_drafts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
begin
  perform public._assert_authenticated();

  select *
    into v_draft
  from public.fit_check_drafts d
  where d.id = p_draft_id
  limit 1;

  perform public.api_assert(
    v_draft.id is not null,
    'FIT_CHECK_NOT_FOUND',
    'Flatmate fit-check draft not found.',
    'P0001',
    jsonb_build_object('draft_id', p_draft_id)
  );

  perform public.api_assert(
    v_draft.owner_user_id = auth.uid(),
    'FORBIDDEN_OWNER_ONLY',
    'Only the draft owner can access this fit-check draft.',
    '42501',
    jsonb_build_object('draft_id', p_draft_id)
  );

  if v_draft.home_id is not null then
    perform public.api_assert(
      public.is_home_owner(v_draft.home_id, auth.uid()),
      'FORBIDDEN_OWNER_ONLY',
      'Only the current home owner can access this fit-check draft.',
      '42501',
      jsonb_build_object('draft_id', p_draft_id, 'home_id', v_draft.home_id)
    );
  end if;

  return v_draft;
end;
$$;

create or replace function public._fit_check_get_effective_share_token_by_hash(p_token_hash text)
returns public.fit_check_share_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.fit_check_share_tokens;
begin
  select *
    into v_row
  from public.fit_check_share_tokens st
  where st.token_hash = p_token_hash
  limit 1;

  if v_row.id is null then
    return null;
  end if;

  if v_row.status = 'active' and v_row.expires_at <= now() then
    update public.fit_check_share_tokens
       set status = 'expired'
     where id = v_row.id
     returning * into v_row;
  end if;

  return v_row;
end;
$$;

create or replace function public._fit_check_get_active_share_token_for_draft(p_draft_id uuid)
returns public.fit_check_share_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.fit_check_share_tokens;
begin
  select *
    into v_row
  from public.fit_check_share_tokens st
  where st.draft_id = p_draft_id
    and st.status = 'active'
  order by st.created_at desc
  limit 1;

  if v_row.id is null then
    return null;
  end if;

  if v_row.expires_at <= now() then
    update public.fit_check_share_tokens
       set status = 'expired'
     where id = v_row.id
     returning * into v_row;

    return null;
  end if;

  return v_row;
end;
$$;

create or replace function public._fit_check_purge_unclaimed_drafts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer := 0;
begin
  with deleted_rows as (
    delete from public.fit_check_drafts d
    where d.owner_user_id is null
      and d.claimed_at is null
      and d.created_at < now() - public._fit_check_unclaimed_purge_ttl()
    returning 1
  )
  select count(*) into v_deleted from deleted_rows;

  return v_deleted;
end;
$$;

create or replace function public.fit_check_cleanup_rate_limits(
  p_older_than interval default interval '15 minutes'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer := 0;
begin
  with deleted_rows as (
    delete from public.fit_check_rate_limits
    where updated_at < now() - p_older_than
    returning 1
  )
  select count(*) into v_deleted from deleted_rows;

  return v_deleted;
end;
$$;

-- ----------------------------------------------------------------------------
-- RPCs
-- ----------------------------------------------------------------------------

create or replace function public.fit_check_upsert_draft(
  p_draft_id uuid default null,
  p_draft_session_token text default null,
  p_locale text default 'en',
  p_answers jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested_locale_base text;
  v_resolved_locale_base text;
  v_answers jsonb;
  v_draft public.fit_check_drafts;
  v_share public.fit_check_share_tokens;
  v_share_token text := null;
  v_claim_token text := null;
  v_draft_session_token text := null;
  v_is_new boolean := false;
  v_share_json jsonb;
  v_draft_session_json jsonb;
  v_claim_json jsonb;
begin
  v_requested_locale_base := public._fit_check_requested_locale_base(p_locale);
  v_resolved_locale_base := public._fit_check_resolved_locale_base(v_requested_locale_base);
  v_answers := public._fit_check_validate_answers(p_answers);

  perform public._fit_check_purge_unclaimed_drafts();

  if p_draft_id is null then
    v_is_new := true;
    v_claim_token := public._fit_check_generate_token('fitclaim');
    v_draft_session_token := public._fit_check_generate_token('fitdraft');

    insert into public.fit_check_drafts (
      owner_answers,
      draft_session_token_hash,
      claim_token_hash,
      requested_locale_base
    )
    values (
      v_answers,
      public._sha256_hex(v_draft_session_token),
      public._sha256_hex(v_claim_token),
      v_requested_locale_base
    )
    returning * into v_draft;

    v_share_token := public._fit_check_generate_token('fitshare');

    insert into public.fit_check_share_tokens (
      draft_id,
      token_hash,
      status,
      expires_at
    )
    values (
      v_draft.id,
      public._sha256_hex(v_share_token),
      'active',
      now() + public._fit_check_share_token_ttl()
    )
    returning * into v_share;
  else
    select *
      into v_draft
    from public.fit_check_drafts d
    where d.id = p_draft_id
    limit 1;

    perform public.api_assert(
      v_draft.id is not null,
      'FIT_CHECK_NOT_FOUND',
      'Flatmate fit-check draft not found.',
      'P0001',
      jsonb_build_object('draft_id', p_draft_id)
    );

    perform public.api_assert(
      v_draft.claimed_at is null
      and v_draft.draft_session_token_hash is not null
      and p_draft_session_token is not null
      and public._sha256_hex(trim(p_draft_session_token)) = v_draft.draft_session_token_hash,
      'FIT_CHECK_INVALID_DRAFT_SESSION',
      'Draft session token is missing, invalid, or expired.',
      '42501',
      jsonb_build_object('draft_id', p_draft_id)
    );

    update public.fit_check_drafts
       set owner_answers = v_answers,
           requested_locale_base = v_requested_locale_base,
           updated_at = now()
     where id = v_draft.id
     returning * into v_draft;

    v_share := public._fit_check_get_active_share_token_for_draft(v_draft.id);
  end if;

  v_share_json := jsonb_build_object(
    'expires_at', v_share.expires_at
  );

  if v_is_new then
    v_share_json := v_share_json || jsonb_build_object(
      'share_token', v_share_token,
      'share_url', public._fit_check_build_share_url(v_share_token),
      'reveal_once', true
    );

    v_draft_session_json := jsonb_build_object(
      'resume_available', true,
      'draft_session_token', v_draft_session_token,
      'reveal_once', true
    );

    v_claim_json := jsonb_build_object(
      'claim_required', true,
      'claim_token', v_claim_token,
      'continue_in_app_url', public._fit_check_build_continue_in_app_url(v_claim_token),
      'reveal_once', true
    );
  else
    v_share_json := v_share_json || jsonb_build_object(
      'reveal_once', false
    );

    v_draft_session_json := jsonb_build_object(
      'resume_available', true,
      'reveal_once', false
    );

    v_claim_json := jsonb_build_object(
      'claim_required', true,
      'reveal_once', false
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'requested_locale_base', v_requested_locale_base,
    'resolved_locale_base', v_resolved_locale_base,
    'owner_answers', v_answers,
    'summary', jsonb_build_object(
      'labels', public._fit_check_summary_labels(v_answers, v_requested_locale_base)
    ),
    'share', v_share_json,
    'draft_session', v_draft_session_json,
    'claim', v_claim_json
  );
end;
$$;

create or replace function public.fit_check_get_public_by_token(
  p_share_token text,
  p_locale text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested_locale_base text;
  v_resolved_locale_base text;
  v_token_hash text;
  v_share public.fit_check_share_tokens;
  v_error_code text := null;
  v_error_message text := null;
  v_submission_count integer := 0;
begin
  v_requested_locale_base := public._fit_check_requested_locale_base(p_locale);
  v_resolved_locale_base := public._fit_check_resolved_locale_base(v_requested_locale_base);

  perform public.api_assert(
    p_share_token is not null and char_length(trim(p_share_token)) between 8 and 128,
    'FIT_CHECK_INVALID_TOKEN',
    'Share token is invalid.',
    '22023'
  );

  v_token_hash := public._sha256_hex(trim(p_share_token));
  v_share := public._fit_check_get_effective_share_token_by_hash(v_token_hash);

  if v_share.id is not null then
    select count(*)
      into v_submission_count
    from public.candidate_fit_submissions s
    where s.share_token_id = v_share.id;
  end if;

  if v_share.id is null then
    v_error_code := 'FIT_CHECK_INVALID_TOKEN';
    v_error_message := public._fit_check_template_value('fit_check.error.link_unavailable', v_requested_locale_base);
  elsif v_share.status = 'expired' then
    v_error_code := 'FIT_CHECK_TOKEN_EXPIRED';
    v_error_message := public._fit_check_template_value('fit_check.error.link_expired', v_requested_locale_base);
  elsif v_share.status = 'revoked' then
    v_error_code := 'FIT_CHECK_TOKEN_REVOKED';
    v_error_message := public._fit_check_template_value('fit_check.error.link_revoked', v_requested_locale_base);
  elsif v_submission_count >= public._fit_check_submission_cap() then
    v_error_code := 'FIT_CHECK_TOKEN_SUBMISSION_LIMIT_REACHED';
    v_error_message := public._fit_check_template_value('fit_check.error.link_exhausted', v_requested_locale_base);
  end if;

  if v_error_code is not null then
    return jsonb_build_object(
      'ok', true,
      'available', false,
      'requested_locale_base', v_requested_locale_base,
      'resolved_locale_base', v_resolved_locale_base,
      'fit_check_public', null,
      'error', jsonb_build_object(
        'code', v_error_code,
        'message', v_error_message
      )
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'available', true,
    'requested_locale_base', v_requested_locale_base,
    'resolved_locale_base', v_resolved_locale_base,
    'token_status', v_share.status,
    'fit_check_public', jsonb_build_object(
      'entry_prompt_key', 'fit_check.candidate.entry_prompt',
      'scenarios', jsonb_build_array(
        jsonb_build_object(
          'scenario_id', 'fit_cleanliness',
          'prompt_key', 'fit_check.scenario.fit_cleanliness.prompt',
          'option_keys', jsonb_build_array(
            'fit_check.scenario.fit_cleanliness.option.0',
            'fit_check.scenario.fit_cleanliness.option.1',
            'fit_check.scenario.fit_cleanliness.option.2'
          )
        ),
        jsonb_build_object(
          'scenario_id', 'fit_rhythm',
          'prompt_key', 'fit_check.scenario.fit_rhythm.prompt',
          'option_keys', jsonb_build_array(
            'fit_check.scenario.fit_rhythm.option.0',
            'fit_check.scenario.fit_rhythm.option.1',
            'fit_check.scenario.fit_rhythm.option.2'
          )
        ),
        jsonb_build_object(
          'scenario_id', 'fit_chores',
          'prompt_key', 'fit_check.scenario.fit_chores.prompt',
          'option_keys', jsonb_build_array(
            'fit_check.scenario.fit_chores.option.0',
            'fit_check.scenario.fit_chores.option.1',
            'fit_check.scenario.fit_chores.option.2'
          )
        ),
        jsonb_build_object(
          'scenario_id', 'fit_conflict',
          'prompt_key', 'fit_check.scenario.fit_conflict.prompt',
          'option_keys', jsonb_build_array(
            'fit_check.scenario.fit_conflict.option.0',
            'fit_check.scenario.fit_conflict.option.1',
            'fit_check.scenario.fit_conflict.option.2'
          )
        )
      )
    )
  );
end;
$$;

create or replace function public.fit_check_submit_candidate_by_token(
  p_share_token text,
  p_locale text default 'en',
  p_display_name text default null,
  p_answers jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested_locale_base text;
  v_resolved_locale_base text;
  v_answers jsonb;
  v_share public.fit_check_share_tokens;
  v_draft public.fit_check_drafts;
  v_submission public.candidate_fit_submissions;
  v_briefing_payload jsonb;
  v_session_hash text;
  v_display_name text := trim(coalesce(p_display_name, ''));
  v_submission_count integer;
  v_token_hash text;
  v_bucket_minute timestamptz := date_trunc('minute', now());
begin
  v_requested_locale_base := public._fit_check_requested_locale_base(p_locale);
  v_resolved_locale_base := public._fit_check_resolved_locale_base(v_requested_locale_base);
  v_answers := public._fit_check_validate_answers(p_answers);

  perform public.api_assert(
    v_display_name <> '' and char_length(v_display_name) <= 80,
    'FIT_CHECK_INVALID_INPUTS',
    'display_name is required.',
    '22023'
  );

  perform public.api_assert(
    p_share_token is not null and char_length(trim(p_share_token)) between 8 and 128,
    'FIT_CHECK_INVALID_TOKEN',
    'Share token is invalid.',
    '22023'
  );

  v_token_hash := public._sha256_hex(trim(p_share_token));

  select *
    into v_share
  from public.fit_check_share_tokens st
  where st.token_hash = v_token_hash
  for update;

  perform public.api_assert(
    v_share.id is not null,
    'FIT_CHECK_INVALID_TOKEN',
    'Share token is invalid.',
    '42501'
  );

  if v_share.status = 'active' and v_share.expires_at <= now() then
    update public.fit_check_share_tokens
       set status = 'expired'
     where id = v_share.id
     returning * into v_share;
  end if;

  perform public.api_assert(
    v_share.status <> 'expired',
    'FIT_CHECK_TOKEN_EXPIRED',
    'Share token has expired.',
    '42501'
  );

  perform public.api_assert(
    v_share.status <> 'revoked',
    'FIT_CHECK_TOKEN_REVOKED',
    'Share token has been revoked.',
    '42501'
  );

  v_session_hash := public._fit_check_anonymous_session_hash();

  perform public.api_assert(
    public._fit_check_rate_limit_bucketed('fit_check:token:' || v_share.token_hash, v_bucket_minute, 30),
    'FIT_CHECK_RATE_LIMITED',
    'Too many submissions for this link. Please try again shortly.',
    '42901'
  );

  perform public.api_assert(
    public._fit_check_rate_limit_bucketed('fit_check:session:' || v_session_hash, v_bucket_minute, 5),
    'FIT_CHECK_RATE_LIMITED',
    'Too many submissions from this session. Please try again shortly.',
    '42901'
  );

  select *
    into v_draft
  from public.fit_check_drafts d
  where d.id = v_share.draft_id
  limit 1;

  select count(*)
    into v_submission_count
  from public.candidate_fit_submissions s
  where s.share_token_id = v_share.id;

  perform public.api_assert(
    v_submission_count < public._fit_check_submission_cap(),
    'FIT_CHECK_TOKEN_SUBMISSION_LIMIT_REACHED',
    'This link is no longer accepting submissions.',
    '42501',
    jsonb_build_object('submission_cap', public._fit_check_submission_cap())
  );

  begin
    insert into public.candidate_fit_submissions (
      draft_id,
      share_token_id,
      display_name,
      answers,
      anonymous_session_hash
    )
    values (
      v_draft.id,
      v_share.id,
      v_display_name,
      v_answers,
      v_session_hash
    )
    returning * into v_submission;
  exception when unique_violation then
    perform public.api_error(
      'FIT_CHECK_DUPLICATE_SUBMISSION',
      'This anonymous session has already submitted for this link.',
      '23505'
    );
  end;

  v_briefing_payload := public._fit_check_generate_briefing_payload(v_draft.owner_answers, v_answers);

  insert into public.candidate_fit_briefings (
    submission_id,
    draft_id,
    owner_answers_snapshot,
    briefing_payload
  )
  values (
    v_submission.id,
    v_draft.id,
    v_draft.owner_answers,
    v_briefing_payload
  );

  return jsonb_build_object(
    'ok', true,
    'submission_id', v_submission.id,
    'requested_locale_base', v_requested_locale_base,
    'resolved_locale_base', v_resolved_locale_base,
    'candidate', jsonb_build_object(
      'display_name', v_submission.display_name
    ),
    'confirmation', jsonb_build_object(
      'message_key', 'fit_check.candidate.submitted',
      'reflection', jsonb_build_object(
        'show', true,
        'text_key', public._fit_check_reflection_key(v_answers)
      ),
      'cta', jsonb_build_object(
        'text_key', 'fit_check.candidate.create_own_cta',
        'target_url', public._fit_check_candidate_cta_url()
      )
    )
  );
end;
$$;

create or replace function public.fit_check_claim_draft(
  p_claim_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
  v_owner_home_count integer := 0;
  v_submission_count integer := 0;
  v_claim_hash text;
begin
  perform public._assert_authenticated();

  perform public.api_assert(
    p_claim_token is not null and char_length(trim(p_claim_token)) between 8 and 128,
    'FIT_CHECK_INVALID_CLAIM_TOKEN',
    'Claim token is invalid.',
    '22023'
  );

  v_claim_hash := public._sha256_hex(trim(p_claim_token));

  update public.fit_check_drafts
     set owner_user_id = auth.uid(),
         claimed_at = now(),
         claim_token_used_at = now(),
         draft_session_token_hash = null,
         updated_at = now()
   where claim_token_hash = v_claim_hash
     and claim_token_used_at is null
     and created_at > now() - public._fit_check_claim_token_ttl()
  returning * into v_draft;

  perform public.api_assert(
    v_draft.id is not null,
    'FIT_CHECK_INVALID_OR_USED_CLAIM_TOKEN',
    'Claim token is invalid or has already been used.',
    '42501'
  );

  select count(*)
    into v_owner_home_count
  from public.memberships m
  where m.user_id = auth.uid()
    and m.role = 'owner'
    and m.is_current = true;

  select count(*)
    into v_submission_count
  from public.candidate_fit_submissions s
  where s.draft_id = v_draft.id;

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'owner_user_id', v_draft.owner_user_id,
    'home_attachment_required', v_draft.home_id is null,
    'owner_home_count', v_owner_home_count,
    'seed_house_norms_prefill_available', true,
    'seed_preferences_prefill_available', false,
    'setup_handoff_recommended', true,
    'submission_count', v_submission_count
  );
end;
$$;

create or replace function public.fit_check_attach_draft_to_home(
  p_draft_id uuid,
  p_home_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
begin
  v_draft := public._fit_check_assert_owner(p_draft_id);

  perform public._assert_home_active(p_home_id);

  perform public.api_assert(
    public.is_home_owner(p_home_id, auth.uid()),
    'FORBIDDEN_OWNER_ONLY',
    'Only the target home owner can attach this draft.',
    '42501',
    jsonb_build_object('home_id', p_home_id)
  );

  perform public.api_assert(
    v_draft.claimed_at is not null,
    'FIT_CHECK_INVALID_CLAIM_TOKEN',
    'Draft must be claimed before it can be attached to a home.',
    '42501',
    jsonb_build_object('draft_id', p_draft_id)
  );

  perform public.api_assert(
    not exists (
      select 1
      from public.fit_check_drafts d
      where d.home_id = p_home_id
        and d.id <> p_draft_id
    ),
    'FIT_CHECK_HOME_ATTACHMENT_CONFLICT',
    'This home already has another fit-check draft attached.',
    '23505',
    jsonb_build_object('home_id', p_home_id)
  );

  update public.fit_check_drafts
     set home_id = p_home_id,
         home_attached_at = now(),
         updated_at = now()
   where id = p_draft_id
   returning * into v_draft;

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'home_id', v_draft.home_id,
    'attached_at', v_draft.home_attached_at,
    'setup_prefill_ready', true
  );
end;
$$;

create or replace function public.fit_check_get_owner_review(
  p_draft_id uuid,
  p_locale text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested_locale_base text;
  v_resolved_locale_base text;
  v_draft public.fit_check_drafts;
  v_share public.fit_check_share_tokens;
  v_latest_share_status text := 'revoked';
  v_latest_share_expires_at timestamptz := null;
  v_submissions jsonb := '[]'::jsonb;
  v_submission_count integer := 0;
begin
  v_requested_locale_base := public._fit_check_requested_locale_base(p_locale);
  v_resolved_locale_base := public._fit_check_resolved_locale_base(v_requested_locale_base);
  v_draft := public._fit_check_assert_owner(p_draft_id);
  v_share := public._fit_check_get_active_share_token_for_draft(v_draft.id);

  select count(*)
    into v_submission_count
  from public.candidate_fit_submissions s
  where s.draft_id = v_draft.id;

  select st.status, st.expires_at
    into v_latest_share_status, v_latest_share_expires_at
  from public.fit_check_share_tokens st
  where st.draft_id = v_draft.id
  order by st.created_at desc
  limit 1;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'submission_id', s.id,
      'display_name', s.display_name,
      'review_label', s.display_name || ' · ' || to_char(s.submitted_at at time zone 'utc', 'YYYY-MM-DD HH24:MI'),
      'submitted_at', s.submitted_at,
      'preview', jsonb_build_object(
        'top_watchouts', coalesce(
          (
            select jsonb_agg(w.elem ->> 'scenario_id')
            from (
              select elem
              from jsonb_array_elements(coalesce(b.briefing_payload -> 'watchouts', '[]'::jsonb)) with ordinality as e(elem, ordinality)
              order by ordinality
              limit 2
            ) w
          ),
          '[]'::jsonb
        ),
        'summary_label', public._fit_check_review_summary_label(b.briefing_payload, v_requested_locale_base)
      )
    )
    order by s.submitted_at desc
  ), '[]'::jsonb)
    into v_submissions
  from public.candidate_fit_submissions s
  join public.candidate_fit_briefings b
    on b.submission_id = s.id
  where s.draft_id = v_draft.id;

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'home_id', v_draft.home_id,
    'requested_locale_base', v_requested_locale_base,
    'resolved_locale_base', v_resolved_locale_base,
    'owner_summary', jsonb_build_object(
      'labels', public._fit_check_summary_labels(v_draft.owner_answers, v_requested_locale_base)
    ),
    'share', jsonb_build_object(
      'share_token_status', coalesce(v_share.status, v_latest_share_status, 'revoked'),
      'share_url', null,
      'link_reveal_requires_rotation', true,
      'expires_at', case when v_share.id is null then v_latest_share_expires_at else v_share.expires_at end,
      'submissions_remaining', greatest(public._fit_check_submission_cap() - v_submission_count, 0)
    ),
    'submissions', v_submissions
  );
end;
$$;

create or replace function public.fit_check_get_owner_briefing(
  p_submission_id uuid,
  p_locale text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested_locale_base text;
  v_resolved_locale_base text;
  v_submission public.candidate_fit_submissions;
  v_draft public.fit_check_drafts;
  v_briefing public.candidate_fit_briefings;
begin
  v_requested_locale_base := public._fit_check_requested_locale_base(p_locale);
  v_resolved_locale_base := public._fit_check_resolved_locale_base(v_requested_locale_base);

  select *
    into v_submission
  from public.candidate_fit_submissions s
  where s.id = p_submission_id
  limit 1;

  perform public.api_assert(
    v_submission.id is not null,
    'FIT_CHECK_NOT_FOUND',
    'Candidate fit-check submission not found.',
    'P0001',
    jsonb_build_object('submission_id', p_submission_id)
  );

  v_draft := public._fit_check_assert_owner(v_submission.draft_id);

  select *
    into v_briefing
  from public.candidate_fit_briefings b
  where b.submission_id = v_submission.id
  limit 1;

  perform public.api_assert(
    v_briefing.id is not null,
    'FIT_CHECK_NOT_FOUND',
    'Candidate fit-check briefing not found.',
    'P0001',
    jsonb_build_object('submission_id', p_submission_id)
  );

  return jsonb_build_object(
    'ok', true,
    'submission_id', v_submission.id,
    'draft_id', v_draft.id,
    'requested_locale_base', v_requested_locale_base,
    'resolved_locale_base', v_resolved_locale_base,
    'candidate', jsonb_build_object(
      'display_name', v_submission.display_name,
      'submitted_at', v_submission.submitted_at,
      'answers', v_submission.answers
    ),
    'briefing', v_briefing.briefing_payload
  );
end;
$$;

create or replace function public.fit_check_rotate_share_token(
  p_draft_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
  v_share public.fit_check_share_tokens;
  v_new_share_token text;
begin
  v_draft := public._fit_check_assert_owner(p_draft_id);

  update public.fit_check_share_tokens
     set status = case when status = 'active' then 'revoked' else status end,
         revoked_at = case when status = 'active' then now() else revoked_at end
   where draft_id = v_draft.id
     and status = 'active';

  v_new_share_token := public._fit_check_generate_token('fitshare');

  insert into public.fit_check_share_tokens (
    draft_id,
    token_hash,
    status,
    expires_at
  )
  values (
    v_draft.id,
    public._sha256_hex(v_new_share_token),
    'active',
    now() + public._fit_check_share_token_ttl()
  )
  returning * into v_share;

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'share_token_status', v_share.status,
    'share_token', v_new_share_token,
    'share_url', public._fit_check_build_share_url(v_new_share_token),
    'expires_at', v_share.expires_at
  );
end;
$$;

create or replace function public.fit_check_revoke_share_token(
  p_draft_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
begin
  v_draft := public._fit_check_assert_owner(p_draft_id);

  update public.fit_check_share_tokens
     set status = 'revoked',
         revoked_at = now()
   where draft_id = v_draft.id
     and status = 'active';

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'share_token_status', 'revoked'
  );
end;
$$;

create or replace function public.fit_check_get_prefill_payload(
  p_draft_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.fit_check_drafts;
begin
  v_draft := public._fit_check_assert_owner(p_draft_id);

  return jsonb_build_object(
    'ok', true,
    'draft_id', v_draft.id,
    'house_norms_prefill', public._fit_check_prefill_payload(v_draft.owner_answers),
    'onboarding_seed', public._fit_check_onboarding_seed(v_draft.owner_answers),
    'preference_flow_hints', jsonb_build_object(
      'supported', false,
      'answers', jsonb_build_object()
    )
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- Grants / hardening
-- ----------------------------------------------------------------------------

revoke all on function public._fit_check_share_token_ttl() from public, anon, authenticated;
revoke all on function public._fit_check_claim_token_ttl() from public, anon, authenticated;
revoke all on function public._fit_check_unclaimed_purge_ttl() from public, anon, authenticated;
revoke all on function public._fit_check_submission_cap() from public, anon, authenticated;
revoke all on function public._fit_check_requested_locale_base(text) from public, anon, authenticated;
revoke all on function public._fit_check_resolved_locale_base(text) from public, anon, authenticated;
revoke all on function public._fit_check_template_value(text, text) from public, anon, authenticated;
revoke all on function public._fit_check_request_headers() from public, anon, authenticated;
revoke all on function public._fit_check_anonymous_session_id() from public, anon, authenticated;
revoke all on function public._fit_check_anonymous_session_hash() from public, anon, authenticated;
revoke all on function public._fit_check_validate_answers(jsonb) from public, anon, authenticated;
revoke all on function public._fit_check_generate_token(text) from public, anon, authenticated;
revoke all on function public._fit_check_build_share_url(text) from public, anon, authenticated;
revoke all on function public._fit_check_build_continue_in_app_url(text) from public, anon, authenticated;
revoke all on function public._fit_check_candidate_cta_url() from public, anon, authenticated;
revoke all on function public._fit_check_summary_labels(jsonb, text) from public, anon, authenticated;
revoke all on function public._fit_check_prefill_payload(jsonb) from public, anon, authenticated;
revoke all on function public._fit_check_onboarding_seed(jsonb) from public, anon, authenticated;
revoke all on function public._fit_check_reflection_key(jsonb) from public, anon, authenticated;
revoke all on function public._fit_check_review_summary_label(jsonb, text) from public, anon, authenticated;
revoke all on function public._fit_check_generate_briefing_payload(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public._fit_check_rate_limit_bucketed(text, timestamptz, integer) from public, anon, authenticated;
revoke all on function public._fit_check_assert_owner(uuid) from public, anon, authenticated;
revoke all on function public._fit_check_get_effective_share_token_by_hash(text) from public, anon, authenticated;
revoke all on function public._fit_check_get_active_share_token_for_draft(uuid) from public, anon, authenticated;
revoke all on function public._fit_check_purge_unclaimed_drafts() from public, anon, authenticated;
revoke all on function public.fit_check_cleanup_rate_limits(interval) from public, anon, authenticated;

revoke all on function public.fit_check_upsert_draft(uuid, text, text, jsonb) from public;
revoke all on function public.fit_check_get_public_by_token(text, text) from public;
revoke all on function public.fit_check_submit_candidate_by_token(text, text, text, jsonb) from public;
revoke all on function public.fit_check_claim_draft(text) from public;
revoke all on function public.fit_check_attach_draft_to_home(uuid, uuid) from public;
revoke all on function public.fit_check_get_owner_review(uuid, text) from public;
revoke all on function public.fit_check_get_owner_briefing(uuid, text) from public;
revoke all on function public.fit_check_rotate_share_token(uuid) from public;
revoke all on function public.fit_check_revoke_share_token(uuid) from public;
revoke all on function public.fit_check_get_prefill_payload(uuid) from public;

grant execute on function public.fit_check_upsert_draft(uuid, text, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.fit_check_get_public_by_token(text, text) to anon, authenticated, service_role;
grant execute on function public.fit_check_submit_candidate_by_token(text, text, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.fit_check_claim_draft(text) to authenticated, service_role;
grant execute on function public.fit_check_attach_draft_to_home(uuid, uuid) to authenticated, service_role;
grant execute on function public.fit_check_get_owner_review(uuid, text) to authenticated, service_role;
grant execute on function public.fit_check_get_owner_briefing(uuid, text) to authenticated, service_role;
grant execute on function public.fit_check_rotate_share_token(uuid) to authenticated, service_role;
grant execute on function public.fit_check_revoke_share_token(uuid) to authenticated, service_role;
grant execute on function public.fit_check_get_prefill_payload(uuid) to authenticated, service_role;
grant execute on function public.fit_check_cleanup_rate_limits(interval) to service_role;

commit;

select cron.schedule( 'fit-check-rate-limit-cleanup-every-10-min', '*/10 * * * *', $$ select public.fit_check_cleanup_rate_limits(interval '15 minutes'); $$ );
