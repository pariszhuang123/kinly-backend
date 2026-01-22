-- supabase/migrations/xxxx_revenuecat_webhook_safety.sql
-- -------------------------------------------------------------------
-- RevenueCat webhook: audit + idempotent processing + retry safety
-- -------------------------------------------------------------------

-- NOTE: You said prod has no data and this is one-time for dev.
TRUNCATE TABLE public.revenuecat_webhook_events;

-- 1) Audit table: ensure required columns exist
ALTER TABLE public.revenuecat_webhook_events
  ADD COLUMN IF NOT EXISTS idempotency_key text,
  ADD COLUMN IF NOT EXISTS rc_event_id text,
  ADD COLUMN IF NOT EXISTS original_transaction_id text,
  ADD COLUMN IF NOT EXISTS entitlement_ids text[],
  ADD COLUMN IF NOT EXISTS warnings text[],
  ADD COLUMN IF NOT EXISTS fatal_error_code text,
  ADD COLUMN IF NOT EXISTS fatal_error text,
  ADD COLUMN IF NOT EXISTS rpc_error_code text,
  ADD COLUMN IF NOT EXISTS rpc_error text,
  ADD COLUMN IF NOT EXISTS rpc_retryable boolean;

-- If you don't already have created_at, add it (helps retention)
ALTER TABLE public.revenuecat_webhook_events
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

-- SAFETY: audit writes happen even on fatal payloads.
-- Ensure audit table columns that can be missing are nullable:
-- (Only do these ALTERs if you previously set NOT NULL on them.)
-- Example:
ALTER TABLE public.revenuecat_webhook_events
  ALTER COLUMN entitlement_id DROP NOT NULL,
  ALTER COLUMN product_id DROP NOT NULL;

-- 2) Unique index for audit idempotency
CREATE UNIQUE INDEX IF NOT EXISTS revenuecat_webhook_events_env_idem_unique
  ON public.revenuecat_webhook_events (environment, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- Helpful indexes
CREATE INDEX IF NOT EXISTS revenuecat_webhook_events_rc_event_idx
  ON public.revenuecat_webhook_events (environment, rc_event_id)
  WHERE rc_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS revenuecat_webhook_events_latest_txn_idx
  ON public.revenuecat_webhook_events (latest_transaction_id)
  WHERE latest_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS revenuecat_webhook_events_orig_txn_idx
  ON public.revenuecat_webhook_events (original_transaction_id)
  WHERE original_transaction_id IS NOT NULL;

-- 3) Processing table for RPC idempotency with retries
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'revenuecat_processing_status'
  ) THEN
    CREATE TYPE public.revenuecat_processing_status AS ENUM ('processing', 'succeeded', 'failed');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.revenuecat_event_processing (
  environment text NOT NULL,
  idempotency_key text NOT NULL,
  status public.revenuecat_processing_status NOT NULL DEFAULT 'processing',
  attempts int NOT NULL DEFAULT 0,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (environment, idempotency_key)
);

DROP FUNCTION IF EXISTS public.paywall_record_subscription(
  uuid,
  uuid,
  public.subscription_store,
  text,
  text,
  text,
  public.subscription_status,
  timestamptz,
  timestamptz,
  timestamptz,
  text,
  timestamptz,
  text,
  jsonb,
  text
);

-- 4) Idempotent RPC: paywall_record_subscription
-- RETURNS boolean: true = deduped (already succeeded), false = processed now
CREATE OR REPLACE FUNCTION public.paywall_record_subscription(
  p_idempotency_key text,
  p_user_id uuid,
  p_home_id uuid,
  p_store public.subscription_store,
  p_rc_app_user_id text,
  p_entitlement_id text,
  p_product_id text,
  p_status public.subscription_status,
  p_current_period_end_at timestamptz,
  p_original_purchase_at timestamptz,
  p_last_purchase_at timestamptz,
  p_latest_transaction_id text,

  -- optional (defaults) MUST be last
  p_entitlement_ids text[] DEFAULT NULL,
  p_event_timestamp timestamptz DEFAULT now(),
  p_environment text DEFAULT 'unknown',
  p_rc_event_id text DEFAULT NULL,
  p_original_transaction_id text DEFAULT NULL,
  p_raw_event jsonb DEFAULT NULL,
  p_warnings text[] DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status public.revenuecat_processing_status;
  v_home_id uuid;
BEGIN
  -- Prevent concurrent double-runs for the same idempotency key
  PERFORM pg_advisory_xact_lock(hashtext(p_environment || ':' || p_idempotency_key));

  -- Basic validation (defense in depth; webhook already validated)
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'Missing p_idempotency_key';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Missing p_user_id';
  END IF;

  -- home_id may be null (floating sub); allow nullable to align with edge behavior

  -- Acquire processing record (or reuse)
  INSERT INTO public.revenuecat_event_processing AS ep (environment, idempotency_key, status, attempts, updated_at)
  VALUES (p_environment, p_idempotency_key, 'processing'::public.revenuecat_processing_status, 1, now())
  ON CONFLICT (environment, idempotency_key)
  DO UPDATE SET
    attempts   = ep.attempts + 1,
    status     = CASE
                  WHEN ep.status = 'succeeded' THEN 'succeeded'::public.revenuecat_processing_status
                  ELSE 'processing'::public.revenuecat_processing_status
                 END,
    updated_at = now()
  RETURNING status INTO v_status;

  -- If already succeeded, return immediately (idempotent)
  IF v_status = 'succeeded'::public.revenuecat_processing_status THEN
    RETURN true; -- deduped
  END IF;

  ------------------------------------------------------------------
  -- Upsert subscription snapshot
  ------------------------------------------------------------------
  INSERT INTO public.user_subscriptions AS us (
    user_id,
    home_id,
    store,
    rc_app_user_id,
    rc_entitlement_id,
    product_id,
    status,
    current_period_end_at,
    original_purchase_at,
    last_purchase_at,
    latest_transaction_id,
    last_synced_at,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_home_id,
    p_store,
    p_rc_app_user_id,
    p_entitlement_id,
    p_product_id,
    p_status,
    p_current_period_end_at,
    p_original_purchase_at,
    p_last_purchase_at,
    p_latest_transaction_id,
    now(),
    now(),
    now()
  )
  ON CONFLICT (user_id, rc_entitlement_id) DO UPDATE
  SET
    home_id               = EXCLUDED.home_id,
    store                 = EXCLUDED.store,
    rc_app_user_id        = EXCLUDED.rc_app_user_id,
    product_id            = EXCLUDED.product_id,
    status                = EXCLUDED.status,
    current_period_end_at = EXCLUDED.current_period_end_at,
    original_purchase_at  = EXCLUDED.original_purchase_at,
    last_purchase_at      = EXCLUDED.last_purchase_at,
    latest_transaction_id = EXCLUDED.latest_transaction_id,
    last_synced_at        = now(),
    updated_at            = now()
  RETURNING home_id INTO v_home_id;

  ------------------------------------------------------------------
  -- Optional: log inside RPC too (safe upsert)
  ------------------------------------------------------------------
INSERT INTO public.revenuecat_webhook_events (
  created_at,
  event_timestamp,
  environment,
  idempotency_key,
  rc_event_id,
  original_transaction_id,
  latest_transaction_id,
  rc_app_user_id,
  home_id,
  entitlement_id,
  entitlement_ids,
  product_id,
  store,
  status,
  current_period_end_at,
  original_purchase_at,
  last_purchase_at,
  warnings,
  raw
) VALUES (
  now(),
  p_event_timestamp,
  p_environment,
  p_idempotency_key,
  p_rc_event_id,
  p_original_transaction_id,
  p_latest_transaction_id,
  p_rc_app_user_id,
  COALESCE(p_home_id, v_home_id),
  p_entitlement_id,
  p_entitlement_ids,
  p_product_id,
  p_store,
  p_status,
  p_current_period_end_at,
  p_original_purchase_at,
  p_last_purchase_at,
  p_warnings,
  p_raw_event
)
ON CONFLICT (environment, idempotency_key)
WHERE idempotency_key IS NOT NULL
DO NOTHING;

  ------------------------------------------------------------------
  -- Refresh home entitlements
  ------------------------------------------------------------------
  PERFORM public.home_entitlements_refresh(COALESCE(p_home_id, v_home_id));

  -- Mark succeeded
  UPDATE public.revenuecat_event_processing
  SET status = 'succeeded'::public.revenuecat_processing_status, last_error = NULL, updated_at = now()
  WHERE environment = p_environment AND idempotency_key = p_idempotency_key;

  RETURN false; -- processed now

EXCEPTION
  WHEN OTHERS THEN
    -- Mark failed (so retries can reattempt)
  UPDATE public.revenuecat_event_processing
  SET status = 'failed'::public.revenuecat_processing_status, last_error = SQLERRM, updated_at = now()
  WHERE environment = p_environment AND idempotency_key = p_idempotency_key;

    RAISE;
END;
$$;

COMMENT ON FUNCTION public.paywall_record_subscription IS
  'Idempotent service-role helper invoked by RevenueCat webhook. Safe for retries via revenuecat_event_processing. Returns deduped boolean.';

REVOKE ALL ON FUNCTION public.paywall_record_subscription(
  text,                    -- p_idempotency_key
  uuid,                    -- p_user_id
  uuid,                    -- p_home_id
  public.subscription_store,-- p_store
  text,                    -- p_rc_app_user_id
  text,                    -- p_entitlement_id
  text,                    -- p_product_id
  public.subscription_status, -- p_status
  timestamptz,             -- p_current_period_end_at
  timestamptz,             -- p_original_purchase_at
  timestamptz,             -- p_last_purchase_at
  text,                    -- p_latest_transaction_id
  text[],                  -- p_entitlement_ids
  timestamptz,             -- p_event_timestamp
  text,                    -- p_environment
  text,                    -- p_rc_event_id
  text,                    -- p_original_transaction_id
  jsonb,                   -- p_raw_event
  text[]                   -- p_warnings
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.paywall_record_subscription(
  text, uuid, uuid, public.subscription_store,
  text, text, text, public.subscription_status,
  timestamptz, timestamptz, timestamptz, text,
  text[], timestamptz, text, text, text, jsonb, text[]
) TO service_role;

-- -------------------------------------------------------------------
-- Retention policy (choose one)
-- -------------------------------------------------------------------

-- Option A: pg_cron (if available) - keep 90 days
SELECT cron.schedule(
  'revenuecat_webhook_events_retention',
  '0 3 * * *',
$$
  DELETE FROM public.revenuecat_webhook_events
  WHERE created_at < now() - interval '90 days';
$$
);

SELECT cron.schedule(
  'revenuecat_event_processing_retention',
  '15 3 * * *',
$$
  -- Mark stuck "processing" as failed so retries can happen safely
  UPDATE public.revenuecat_event_processing
     SET status = 'failed',
         last_error = COALESCE(last_error, 'stuck processing > 24h'),
         updated_at = now()
   WHERE status = 'processing'
     AND updated_at < now() - interval '24 hours';

  -- Keep idempotency decisions for the same window as webhook payloads
  DELETE FROM public.revenuecat_event_processing
   WHERE status IN ('succeeded', 'failed')
     AND updated_at < now() - interval '90 days';
$$
);
