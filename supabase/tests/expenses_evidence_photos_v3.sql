SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_home (
  home_id uuid
);

CREATE TEMP TABLE tmp_invite (
  code text
);

CREATE TEMP TABLE tmp_expenses (
  label      text PRIMARY KEY,
  expense_id uuid
);

CREATE TEMP TABLE tmp_plans (
  label   text PRIMARY KEY,
  plan_id uuid
);

CREATE TEMP TABLE tmp_metrics (
  label            text PRIMARY KEY,
  active_expenses  integer,
  expense_photos   integer
);

CREATE OR REPLACE FUNCTION pg_temp.expect_api_error(
  p_sql         text,
  p_error_code  text,
  p_description text
)
RETURNS text
LANGUAGE sql
AS $$
  SELECT throws_like(
    p_sql,
    '%' || p_error_code || '%',
    p_description
  );
$$;

-- Seed avatars required by profile triggers.
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-9800-000000000001', 'avatars/default.png', 'animal', 'Expense Photo Avatar 1'),
  ('00000000-0000-4000-9800-000000000002', 'avatars/expense-photo-a.png', 'animal', 'Expense Photo Avatar 2'),
  ('00000000-0000-4000-9800-000000000003', 'avatars/expense-photo-b.png', 'animal', 'Expense Photo Avatar 3'),
  ('00000000-0000-4000-9800-000000000004', 'avatars/expense-photo-c.png', 'animal', 'Expense Photo Avatar 4')
ON CONFLICT (id) DO NOTHING;

-- Seed users.
INSERT INTO tmp_users (label, user_id, email) VALUES
  ('owner',    '51000000-0000-4000-9000-000000000001', 'expense-photo-owner@example.com'),
  ('member1',  '51000000-0000-4000-9000-000000000002', 'expense-photo-member1@example.com'),
  ('member2',  '51000000-0000-4000-9000-000000000003', 'expense-photo-member2@example.com'),
  ('outsider', '51000000-0000-4000-9000-000000000004', 'expense-photo-outsider@example.com');

INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
SELECT
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  email,
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
FROM tmp_users
ON CONFLICT (id) DO NOTHING;

-- Create home via owner.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH created AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_home (home_id)
SELECT (payload->'home'->>'id')::uuid
FROM created;

INSERT INTO tmp_invite (code)
SELECT code
FROM public.invites
WHERE home_id = (SELECT home_id FROM tmp_home)
  AND revoked_at IS NULL
LIMIT 1;

-- Join members.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invite));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member2'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.homes_join((SELECT code FROM tmp_invite));

-- Back to owner.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Ensure free entitlement and keep low cap for explicit paywall assertions.
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ((SELECT home_id FROM tmp_home), 'free', NULL)
ON CONFLICT (home_id) DO UPDATE
SET plan = EXCLUDED.plan,
    expires_at = EXCLUDED.expires_at;

UPDATE public.home_plan_limits
SET max_value = 2
WHERE plan = 'free'
  AND metric = 'expense_photos';

-- Seed baseline metrics snapshot.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'baseline',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'home_usage_metric'
      AND e.enumlabel = 'expense_photos'
  ),
  'home_usage_metric contains expense_photos'
);

-- Invalid path rejected.
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v3(
      p_home_id => '%s',
      p_description => 'Invalid path draft',
      p_amount_cents => NULL,
      p_notes => NULL,
      p_split_mode => NULL,
      p_member_ids => NULL,
      p_splits => NULL,
      p_recurrence_every => NULL,
      p_recurrence_unit => NULL,
      p_start_date => current_date,
      p_evidence_photo_path => 'invalid/path.jpg'
    );
  $sql$, (SELECT home_id FROM tmp_home)),
  'INVALID_EVIDENCE_PHOTO_PATH',
  'expenses_create_v3 rejects invalid evidence photo path'
);

-- Draft with evidence photo stays quota-free.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Draft Keep',
    p_amount_cents => NULL,
    p_notes => NULL,
    p_split_mode => NULL,
    p_member_ids => NULL,
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/keep-draft.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'draft_keep', (expense).id
FROM created;

SELECT is(
  (SELECT status::text FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep')),
  'draft',
  'draft_keep is stored as draft'
);

SELECT is(
  (SELECT evidence_photo_path FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep')),
  'households/keep-draft.jpg',
  'draft_keep stores evidence photo path'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'baseline'),
  'draft create does not increment expense_photos'
);

-- Activate draft while omitting evidence arg (NULL) keeps existing path and increments quota once.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_keep_activate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expenses_edit_v3(
  p_expense_id => (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep'),
  p_amount_cents => 1200,
  p_description => 'Draft Keep Activated',
  p_notes => NULL,
  p_split_mode => 'equal',
  p_member_ids => ARRAY[
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    (SELECT user_id FROM tmp_users WHERE label = 'member1')
  ],
  p_splits => NULL,
  p_recurrence_every => NULL,
  p_recurrence_unit => NULL,
  p_start_date => current_date,
  p_evidence_photo_path => NULL
);

SELECT is(
  (SELECT evidence_photo_path FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep')),
  'households/keep-draft.jpg',
  'NULL evidence arg keeps existing draft evidence path'
);

SELECT is(
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT active_expenses + 1 FROM tmp_metrics WHERE label = 'before_keep_activate'),
  'activating draft_keep increments active_expenses'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos + 1 FROM tmp_metrics WHERE label = 'before_keep_activate'),
  'activating draft_keep increments expense_photos once'
);

-- Active one-off evidence photo is immutable.
SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_edit_v3(
      p_expense_id => '%s',
      p_amount_cents => 1200,
      p_description => 'Draft Keep Activated',
      p_notes => NULL,
      p_split_mode => NULL,
      p_member_ids => NULL,
      p_splits => NULL,
      p_recurrence_every => NULL,
      p_recurrence_unit => NULL,
      p_start_date => NULL,
      p_evidence_photo_path => 'households/changed-active.jpg'
    );
  $sql$, (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep')),
  'EDIT_NOT_ALLOWED',
  'active one-off evidence photo is immutable'
);

-- Draft activation with explicit empty string clears photo and does not charge expense_photos.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Draft Clear',
    p_amount_cents => NULL,
    p_notes => NULL,
    p_split_mode => NULL,
    p_member_ids => NULL,
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/clear-draft.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'draft_clear', (expense).id
FROM created;

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_clear_activate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expenses_edit_v3(
  p_expense_id => (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_clear'),
  p_amount_cents => 1100,
  p_description => 'Draft Clear Activated',
  p_notes => NULL,
  p_split_mode => 'equal',
  p_member_ids => ARRAY[
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    (SELECT user_id FROM tmp_users WHERE label = 'member1')
  ],
  p_splits => NULL,
  p_recurrence_every => NULL,
  p_recurrence_unit => NULL,
  p_start_date => current_date,
  p_evidence_photo_path => ''
);

SELECT is(
  (SELECT evidence_photo_path FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_clear')),
  NULL,
  'empty-string evidence arg clears draft photo on activation'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'before_clear_activate'),
  'clearing draft photo avoids expense_photos increment'
);

-- Draft activation replacing photo still charges once.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Draft Replace',
    p_amount_cents => NULL,
    p_notes => NULL,
    p_split_mode => NULL,
    p_member_ids => NULL,
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/replace-old.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'draft_replace', (expense).id
FROM created;

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_replace_activate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expenses_edit_v3(
  p_expense_id => (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_replace'),
  p_amount_cents => 1300,
  p_description => 'Draft Replace Activated',
  p_notes => NULL,
  p_split_mode => 'equal',
  p_member_ids => ARRAY[
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    (SELECT user_id FROM tmp_users WHERE label = 'member1')
  ],
  p_splits => NULL,
  p_recurrence_every => NULL,
  p_recurrence_unit => NULL,
  p_start_date => current_date,
  p_evidence_photo_path => 'households/replace-new.jpg'
);

SELECT is(
  (SELECT evidence_photo_path FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'draft_replace')),
  'households/replace-new.jpg',
  'replacing draft photo before activation persists the replacement'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos + 1 FROM tmp_metrics WHERE label = 'before_replace_activate'),
  'replacing non-null draft photo charges expense_photos once at activation'
);

-- Cap reached: third charged photo on free plan is blocked.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_photo_cap',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT pg_temp.expect_api_error(
  format($sql$
    SELECT public.expenses_create_v3(
      p_home_id => '%s',
      p_description => 'Cap Blocked',
      p_amount_cents => 1600,
      p_notes => NULL,
      p_split_mode => 'equal',
      p_member_ids => ARRAY['%s'::uuid, '%s'::uuid],
      p_splits => NULL,
      p_recurrence_every => NULL,
      p_recurrence_unit => NULL,
      p_start_date => current_date,
      p_evidence_photo_path => 'households/cap-blocked.jpg'
    );
  $sql$,
    (SELECT home_id FROM tmp_home),
    (SELECT user_id FROM tmp_users WHERE label = 'owner'),
    (SELECT user_id FROM tmp_users WHERE label = 'member1')
  ),
  'PAYWALL_LIMIT_EXPENSE_PHOTOS',
  'free plan blocks charged expense photo above cap'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'before_photo_cap'),
  'failed create does not change expense_photos counter'
);

-- Evidence path appears in get_for_edit + created list.
WITH payload AS (
  SELECT public.expenses_get_for_edit((SELECT expense_id FROM tmp_expenses WHERE label = 'draft_keep')) AS body
)
SELECT is(
  (SELECT body->>'evidencePhotoPath' FROM payload),
  'households/keep-draft.jpg',
  'expenses_get_for_edit returns evidencePhotoPath'
);

WITH payload AS (
  SELECT public.expenses_get_created_by_me((SELECT home_id FROM tmp_home)) AS body
),
entry AS (
  SELECT elem
  FROM payload,
       LATERAL jsonb_array_elements(body) elem
  WHERE elem->>'expenseId' = (SELECT expense_id::text FROM tmp_expenses WHERE label = 'draft_keep')
)
SELECT is(
  (SELECT elem->>'evidencePhotoPath' FROM entry),
  'households/keep-draft.jpg',
  'expenses_get_created_by_me returns evidencePhotoPath'
);

-- Member owed payload includes evidencePhotoPath.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member1'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.expenses_get_current_owed((SELECT home_id FROM tmp_home)) AS body
),
items AS (
  SELECT item
  FROM payload,
       LATERAL jsonb_array_elements(body) payer,
       LATERAL jsonb_array_elements(payer->'items') item
),
target AS (
  SELECT item
  FROM items
  WHERE item->>'expenseId' = (SELECT expense_id::text FROM tmp_expenses WHERE label = 'draft_keep')
)
SELECT is(
  (SELECT item->>'evidencePhotoPath' FROM target),
  'households/keep-draft.jpg',
  'expenses_get_current_owed item includes evidencePhotoPath'
);

-- Restore owner context.
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Increase free cap for remaining flow-heavy tests.
UPDATE public.home_plan_limits
SET max_value = 10
WHERE plan = 'free'
  AND metric = 'expense_photos';

-- Recurring with photo: plan + first cycle carry path, and quota charged once.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_recurring_main',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Recurring Main',
    p_amount_cents => 2200,
    p_notes => NULL,
    p_split_mode => 'equal',
    p_member_ids => ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT user_id FROM tmp_users WHERE label = 'member1')
    ],
    p_splits => NULL,
    p_recurrence_every => 1,
    p_recurrence_unit => 'day',
    p_start_date => current_date,
    p_evidence_photo_path => 'households/recurring-main.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'recurring_main_cycle', (expense).id
FROM created;

INSERT INTO tmp_plans (label, plan_id)
SELECT 'recurring_main', plan_id
FROM public.expenses
WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_main_cycle');

SELECT is(
  (SELECT evidence_photo_path FROM public.expense_plans WHERE id = (SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main')),
  'households/recurring-main.jpg',
  'recurring plan stores evidence photo path'
);

SELECT is(
  (SELECT evidence_photo_path FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_main_cycle')),
  'households/recurring-main.jpg',
  'first recurring cycle copies evidence photo path'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos + 1 FROM tmp_metrics WHERE label = 'before_recurring_main'),
  'recurring activation charges expense_photos once at plan-creation boundary'
);

-- Simulate an overdue plan cursor without violating (next_cycle_date >= start_date).
UPDATE public.expense_plans
SET start_date = current_date - 1,
    next_cycle_date = current_date - 1
WHERE id = (SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main');

-- Generate one more due cycle; photo counter must not change.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_recurring_cron',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expense_plans_generate_due_cycles();

SELECT ok(
  (SELECT COUNT(*) FROM public.expenses WHERE plan_id = (SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main')) >= 2,
  'due cycle generation creates additional recurring cycle'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.expenses
    WHERE plan_id = (SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main')
      AND evidence_photo_path IS DISTINCT FROM 'households/recurring-main.jpg'
  ),
  'all recurring cycles snapshot plan evidence photo path'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'before_recurring_cron'),
  'recurring cron cycle does not increment expense_photos'
);

-- Manual termination decrements recurring plan charge once.
INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_manual_terminate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expense_plans_terminate((SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main'));

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos - 1 FROM tmp_metrics WHERE label = 'before_manual_terminate'),
  'manual plan termination decrements expense_photos once'
);

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'after_manual_terminate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expense_plans_terminate((SELECT plan_id FROM tmp_plans WHERE label = 'recurring_main'));

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'after_manual_terminate'),
  'repeat termination is idempotent for expense_photos'
);

-- Membership-change helper also decrements recurring photo charge once.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Recurring Member Change',
    p_amount_cents => 2500,
    p_notes => NULL,
    p_split_mode => 'equal',
    p_member_ids => ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT user_id FROM tmp_users WHERE label = 'member2')
    ],
    p_splits => NULL,
    p_recurrence_every => 1,
    p_recurrence_unit => 'day',
    p_start_date => current_date,
    p_evidence_photo_path => 'households/recurring-member-change.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'recurring_member_change_cycle', (expense).id
FROM created;

INSERT INTO tmp_plans (label, plan_id)
SELECT 'recurring_member_change', plan_id
FROM public.expenses
WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'recurring_member_change_cycle');

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_member_change_terminate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public._expense_plans_terminate_for_member_change(
  (SELECT home_id FROM tmp_home),
  (SELECT user_id FROM tmp_users WHERE label = 'member2')
);

SELECT is(
  (SELECT status::text FROM public.expense_plans WHERE id = (SELECT plan_id FROM tmp_plans WHERE label = 'recurring_member_change')),
  'terminated',
  'membership-change helper terminates affected recurring plan'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos - 1 FROM tmp_metrics WHERE label = 'before_member_change_terminate'),
  'membership-change helper decrements expense_photos once'
);

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'after_member_change_terminate',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public._expense_plans_terminate_for_member_change(
  (SELECT home_id FROM tmp_home),
  (SELECT user_id FROM tmp_users WHERE label = 'member2')
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'after_member_change_terminate'),
  'membership-change helper is idempotent for expense_photos'
);

-- Cancel transitions.
-- Draft cancel is quota-neutral.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Draft Cancel',
    p_amount_cents => NULL,
    p_notes => NULL,
    p_split_mode => NULL,
    p_member_ids => NULL,
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/draft-cancel.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'draft_cancel', (expense).id
FROM created;

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_draft_cancel',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expenses_cancel((SELECT expense_id FROM tmp_expenses WHERE label = 'draft_cancel'));

SELECT is(
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT active_expenses FROM tmp_metrics WHERE label = 'before_draft_cancel'),
  'cancelling draft does not change active_expenses'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos FROM tmp_metrics WHERE label = 'before_draft_cancel'),
  'cancelling draft does not change expense_photos'
);

-- Active one-off cancel frees both active_expenses and expense_photos when charged.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Active Cancel',
    p_amount_cents => 1700,
    p_notes => NULL,
    p_split_mode => 'equal',
    p_member_ids => ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT user_id FROM tmp_users WHERE label = 'member1')
    ],
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/active-cancel.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'active_cancel', (expense).id
FROM created;

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_active_cancel',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT public.expenses_cancel((SELECT expense_id FROM tmp_expenses WHERE label = 'active_cancel'));

SELECT is(
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT active_expenses - 1 FROM tmp_metrics WHERE label = 'before_active_cancel'),
  'cancelling active one-off decrements active_expenses'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos - 1 FROM tmp_metrics WHERE label = 'before_active_cancel'),
  'cancelling charged active one-off decrements expense_photos'
);

-- Bulk pay fully-paid transition decrements one-off expense_photos once.
WITH created AS (
  SELECT public.expenses_create_v3(
    p_home_id => (SELECT home_id FROM tmp_home),
    p_description => 'Paydown One-off',
    p_amount_cents => 1900,
    p_notes => NULL,
    p_split_mode => 'equal',
    p_member_ids => ARRAY[
      (SELECT user_id FROM tmp_users WHERE label = 'owner'),
      (SELECT user_id FROM tmp_users WHERE label = 'member2')
    ],
    p_splits => NULL,
    p_recurrence_every => NULL,
    p_recurrence_unit => NULL,
    p_start_date => current_date,
    p_evidence_photo_path => 'households/paydown-oneoff.jpg'
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'paydown_oneoff', (expense).id
FROM created;

INSERT INTO tmp_metrics (label, active_expenses, expense_photos)
VALUES (
  'before_paydown',
  COALESCE((SELECT active_expenses FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0)
)
ON CONFLICT (label) DO UPDATE
SET active_expenses = EXCLUDED.active_expenses,
    expense_photos = EXCLUDED.expense_photos;

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'member2'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.expenses_pay_my_due((SELECT user_id FROM tmp_users WHERE label = 'owner'));

SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'owner'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT ok(
  (SELECT fully_paid_at IS NOT NULL FROM public.expenses WHERE id = (SELECT expense_id FROM tmp_expenses WHERE label = 'paydown_oneoff')),
  'bulk pay stamps fully_paid_at for one-off'
);

SELECT is(
  COALESCE((SELECT expense_photos FROM public.home_usage_counters WHERE home_id = (SELECT home_id FROM tmp_home)), 0),
  (SELECT expense_photos - 1 FROM tmp_metrics WHERE label = 'before_paydown'),
  'bulk pay fully-paid transition decrements one-off expense_photos once'
);

SELECT * FROM finish();

ROLLBACK;
