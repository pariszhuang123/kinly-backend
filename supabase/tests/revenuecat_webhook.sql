SET search_path = pgtap, public, auth, extensions;

BEGIN;
SET ROLE postgres;

SELECT plan(7);

-- Seed defaults required by handle_new_user()
INSERT INTO public.avatars (id, storage_path, category, name)
VALUES ('00000000-0000-4000-8000-000000000999', 'avatars/default.png', 'animal', 'Test Avatar')
ON CONFLICT (id) DO NOTHING;

-- Seed minimal user + home
INSERT INTO auth.users (id, instance_id, email, raw_user_meta_data, raw_app_meta_data, aud, role, encrypted_password)
VALUES (
  '00000000-0000-4000-8000-000000000701',
  '00000000-0000-0000-0000-000000000000',
  'paywall-webhook@example.com',
  '{}'::jsonb,
  '{"provider":"email"}'::jsonb,
  'authenticated',
  'authenticated',
  'secret'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.homes (id, owner_user_id)
VALUES (
  '00000000-0000-4000-8000-000000000702',
  '00000000-0000-4000-8000-000000000701'
)
ON CONFLICT (id) DO NOTHING;

-- Ensure baseline entitlement exists (free)
INSERT INTO public.home_entitlements (home_id, plan, expires_at)
VALUES ('00000000-0000-4000-8000-000000000702', 'free', NULL)
ON CONFLICT (home_id) DO NOTHING;

SELECT lives_ok(
  $$
  SELECT public.paywall_record_subscription(
    'evt-1',                                      -- p_idempotency_key
    '00000000-0000-4000-8000-000000000701'::uuid, -- p_user_id
    '00000000-0000-4000-8000-000000000702'::uuid, -- p_home_id
    'play_store'::public.subscription_store,      -- p_store
    '00000000-0000-4000-8000-000000000701',       -- p_rc_app_user_id
    'kinly_premium',                              -- p_entitlement_id
    'com.example.kinly.premium.monthly',          -- p_product_id
    'active'::public.subscription_status,         -- p_status
    now() + interval '30 days',                   -- p_current_period_end_at
    now() - interval '1 day',                     -- p_original_purchase_at
    now(),                                        -- p_last_purchase_at
    'test-txn-1',                                 -- p_latest_transaction_id
    ARRAY['kinly_premium'],                       -- p_entitlement_ids
    now(),                                        -- p_event_timestamp
    'sandbox',                                    -- p_environment
    'evt-1',                                      -- p_rc_event_id
    'orig-txn-1',                                 -- p_original_transaction_id
    '{"event":{"type":"INITIAL_PURCHASE"}}'::jsonb, -- p_raw_event
    ARRAY['missing_latest_transaction_id']        -- p_warnings
  );
  $$,
  'paywall_record_subscription succeeds'
);

SELECT is(
  (SELECT COUNT(*) FROM public.user_subscriptions WHERE user_id = '00000000-0000-4000-8000-000000000701'::uuid AND rc_entitlement_id = 'kinly_premium'),
  1::bigint,
  'user_subscriptions row upserted'
);

SELECT is(
  (SELECT COUNT(*) FROM public.revenuecat_webhook_events WHERE rc_app_user_id = '00000000-0000-4000-8000-000000000701' AND entitlement_id = 'kinly_premium' AND rc_event_id = 'evt-1'),
  1::bigint,
  'revenuecat_webhook_events row inserted with rc_event_id'
);

SELECT is(
  (SELECT plan FROM public.home_entitlements WHERE home_id = '00000000-0000-4000-8000-000000000702'::uuid),
  'premium',
  'home_entitlements promoted to premium'
);

SELECT ok(
  (SELECT expires_at IS NULL OR expires_at > now() FROM public.home_entitlements WHERE home_id = '00000000-0000-4000-8000-000000000702'::uuid),
  'home_entitlements expires_at is in the future (or NULL)'
);

SELECT is(
  (SELECT original_transaction_id FROM public.revenuecat_webhook_events WHERE rc_event_id = 'evt-1'),
  'orig-txn-1',
  'original_transaction_id persisted'
);

SELECT is(
  (SELECT COUNT(*) FROM public.revenuecat_webhook_events WHERE rc_event_id = 'evt-1'),
  1::bigint,
  'rc_event_id idempotency enforced (no duplicates)'
);

SELECT * FROM finish();
ROLLBACK;
