SET search_path = pgtap, public, auth, extensions;

BEGIN;

SELECT no_plan();

CREATE TEMP TABLE tmp_users (
  label   text PRIMARY KEY,
  user_id uuid,
  email   text
);

CREATE TEMP TABLE tmp_homes (
  label   text PRIMARY KEY,
  home_id uuid
);

CREATE TEMP TABLE tmp_expenses (
  label      text PRIMARY KEY,
  expense_id uuid
);

-- Seed avatar for profiles
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES
  ('00000000-0000-4000-8000-000000000777', 'avatars/paid-to-me.png', 'animal', 'Paid To Me Avatar'),
  ('00000000-0000-4000-8000-000000000778', 'avatars/paid-to-me-2.png', 'animal', 'Paid To Me Avatar 2'),
  ('00000000-0000-4000-8000-000000000779', 'avatars/paid-to-me-3.png', 'animal', 'Paid To Me Avatar 3')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tmp_users (label, user_id, email) VALUES
  ('creator', '20000000-0000-4000-8000-000000000001', 'creator-paid@example.com'),
  ('debtor',  '20000000-0000-4000-8000-000000000002', 'debtor-paid@example.com');

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

-- Upsert profiles with avatars for deterministic avatar responses
INSERT INTO public.profiles (id, email, username, avatar_id)
VALUES
  ((SELECT user_id FROM tmp_users WHERE label = 'creator'),
   (SELECT email FROM tmp_users WHERE label = 'creator'),
   'creatorpaid',
   '00000000-0000-4000-8000-000000000777'),
  ((SELECT user_id FROM tmp_users WHERE label = 'debtor'),
   (SELECT email FROM tmp_users WHERE label = 'debtor'),
   'debtorpaid',
   '00000000-0000-4000-8000-000000000778')
ON CONFLICT (id) DO UPDATE
SET avatar_id = EXCLUDED.avatar_id,
    username = EXCLUDED.username,
    email = EXCLUDED.email;

-- Creator creates home + invite
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT public.profile_identity_update(
  'creatorpaid',
  '00000000-0000-4000-8000-000000000777'
);

WITH res AS (
  SELECT public.homes_create_with_invite() AS payload
)
INSERT INTO tmp_homes (label, home_id)
SELECT 'primary', (payload->'home'->>'id')::uuid FROM res;

-- Ensure owner column is set for deterministic isOwner checks
UPDATE public.homes
SET owner_user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')
WHERE id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND owner_user_id IS NULL;

-- Debtor joins
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'debtor'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

SELECT public.homes_join(
  (SELECT code
   FROM public.invites
   WHERE home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  AND revoked_at IS NULL
  LIMIT 1)
);

-- After join, set debtor avatar deterministically using the contract function
SELECT public.profile_identity_update(
  'debtorpaid',
  '00000000-0000-4000-8000-000000000778'
);

-- Switch back to creator for expense creation
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

-- Creator creates expense with self + debtor; creator split auto-paid
-- Expense A
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH created AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Dinner',
    2500,
    NULL,
    'custom',
    NULL,
    jsonb_build_array(
      jsonb_build_object(
        'user_id', (SELECT user_id FROM tmp_users WHERE label = 'creator'),
        'amount_cents', 100
      ),
      jsonb_build_object(
        'user_id', (SELECT user_id FROM tmp_users WHERE label = 'debtor'),
        'amount_cents', 2400
      )
    ),
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'dinner', (expense).id FROM created;

-- Expense B (second paid item from same debtor)
WITH created AS (
  SELECT public.expenses_create(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    'Snacks',
    1000,
    NULL,
    'custom',
    NULL,
    jsonb_build_array(
      jsonb_build_object(
        'user_id', (SELECT user_id FROM tmp_users WHERE label = 'creator'),
        'amount_cents', 100
      ),
      jsonb_build_object(
        'user_id', (SELECT user_id FROM tmp_users WHERE label = 'debtor'),
        'amount_cents', 900
      )
    ),
    'none',
    current_date
  ) AS expense
)
INSERT INTO tmp_expenses (label, expense_id)
SELECT 'snacks', (expense).id FROM created;

-- Debtor sees owed items with recurrence metadata
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'debtor'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH owed AS (
  SELECT public.expenses_get_current_owed(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length((body->0->'items')) FROM owed),
  2,
  'Owed list returns both unpaid items with metadata'
);
WITH owed AS (
  SELECT public.expenses_get_current_owed(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT (body->0->'items'->0->>'recurrenceEvery') IS NULL FROM owed),
  true,
  'Owed items include null recurrenceEvery'
);
WITH owed AS (
  SELECT public.expenses_get_current_owed(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT (body->0->'items'->0->>'recurrenceUnit') IS NULL FROM owed),
  true,
  'Owed items include null recurrenceUnit'
);
WITH owed AS (
  SELECT public.expenses_get_current_owed(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT (body->0->'items'->0->>'startDate')::date FROM owed),
  current_date,
  'Owed items include start date'
);

-- Debtor pays all owed to creator (bulk)
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'debtor'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.expenses_pay_my_due(
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ) AS body
)
SELECT is(
  (SELECT (body->>'splitsPaid')::int FROM payload),
  2,
  'Bulk pay marks both owed splits as paid'
);

WITH payload AS (
  SELECT public.expenses_pay_my_due(
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ) AS body
)
SELECT is(
  (SELECT (body->>'expensesNewlyFullyPaid')::int FROM payload),
  0,
  'Second bulk pay call is idempotent for fully paid expenses'
);

-- Creator sees only debtor share (creator auto-paid split filtered out)
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH list AS (
  SELECT public.expenses_get_current_paid_to_me_debtors(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM list),
  1,
  'Paid-to-me list has one debtor with unseen items'
);

WITH list AS (
  SELECT public.expenses_get_current_paid_to_me_debtors(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT (body->0->>'totalPaidCents')::int FROM list),
  3300,
  'Paid-to-me total aggregates multiple paid items and excludes creator auto-paid split'
);

WITH list AS (
  SELECT public.expenses_get_current_paid_to_me_debtors(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT body->0->>'debtorAvatarUrl' FROM list),
  'avatars/paid-to-me-2.png',
  'Paid-to-me list includes debtor avatar path'
);
WITH list AS (
  SELECT public.expenses_get_current_paid_to_me_debtors(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT (body->0->>'isOwner')::boolean FROM list),
  FALSE,
  'Paid-to-me list marks debtor owner flag correctly'
);

-- Detail excludes creator split
WITH details AS (
  SELECT public.expenses_get_current_paid_to_me_by_debtor_details(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM details),
  2,
  'Debtor detail includes both debtor-paid items only'
);

WITH details AS (
  SELECT public.expenses_get_current_paid_to_me_by_debtor_details(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT body->0->>'debtorAvatarUrl' FROM details),
  'avatars/paid-to-me-2.png',
  'Debtor detail includes avatar path for debtor'
);
WITH details AS (
  SELECT public.expenses_get_current_paid_to_me_by_debtor_details(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT body->0->>'recurrenceEvery' IS NULL FROM details),
  true,
  'Debtor detail includes null recurrenceEvery'
);
WITH details AS (
  SELECT public.expenses_get_current_paid_to_me_by_debtor_details(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT body->0->>'recurrenceUnit' IS NULL FROM details),
  true,
  'Debtor detail includes null recurrenceUnit'
);
WITH details AS (
  SELECT public.expenses_get_current_paid_to_me_by_debtor_details(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT (body->0->>'startDate')::date FROM details),
  current_date,
  'Debtor detail includes start date'
);

-- Mark viewed clears unseen
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'creator'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH viewed AS (
  SELECT public.expenses_mark_paid_received_viewed_for_debtor(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary'),
    (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  ) AS body
)
SELECT is(
  (SELECT (body->>'updated')::int FROM viewed),
  2,
  'Mark paid received returns count of updated rows'
);

-- Debug unseen splits count after marking viewed
SELECT diag(
  (
    SELECT jsonb_build_object(
      'unseenSplits',
      COUNT(*) FILTER (WHERE s.recipient_viewed_at IS NULL)
    )
    FROM public.expense_splits s
    JOIN public.expenses e
      ON e.id = s.expense_id
    WHERE e.home_id = (SELECT home_id FROM tmp_homes WHERE label = 'primary')
      AND e.created_by_user_id = (SELECT user_id FROM tmp_users WHERE label = 'creator')
      AND s.debtor_user_id = (SELECT user_id FROM tmp_users WHERE label = 'debtor')
  )::text
);

WITH list AS (
  SELECT public.expenses_get_current_paid_to_me_debtors(
    (SELECT home_id FROM tmp_homes WHERE label = 'primary')
  ) AS body
)
SELECT is(
  (SELECT jsonb_array_length(body) FROM list),
  0,
  'Paid-to-me list hides entries once all unseen are viewed'
);

-- Calling bulk pay again stays idempotent
SELECT set_config('request.jwt.claim.sub', (SELECT user_id::text FROM tmp_users WHERE label = 'debtor'), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);

WITH payload AS (
  SELECT public.expenses_pay_my_due(
    (SELECT user_id FROM tmp_users WHERE label = 'creator')
  ) AS body
)
SELECT is(
  (SELECT (body->>'splitsPaid')::int FROM payload),
  0,
  'Repeat bulk pay no-ops once everything is paid'
);

SELECT * FROM finish();

ROLLBACK;
