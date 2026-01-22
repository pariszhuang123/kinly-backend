-- ---------------------------------------------------------------------
-- Paywall telemetry + RevenueCat webhook plumbing
-- ---------------------------------------------------------------------

-- TABLE: revenuecat_webhook_events
CREATE TABLE IF NOT EXISTS public.revenuecat_webhook_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  received_at            timestamptz NOT NULL DEFAULT now(),
  event_timestamp        timestamptz,
  environment            text,
  rc_app_user_id         text NOT NULL,
  entitlement_id         text NOT NULL,
  product_id             text NOT NULL,
  store                  public.subscription_store,
  status                 public.subscription_status,
  current_period_end_at  timestamptz,
  original_purchase_at   timestamptz,
  last_purchase_at       timestamptz,
  latest_transaction_id  text,
  home_id                uuid REFERENCES public.homes(id) ON DELETE SET NULL,
  raw                    jsonb,
  error                  text
);

COMMENT ON TABLE public.revenuecat_webhook_events IS
  'Audit log of RevenueCat webhook events used for debugging and analytics.';

ALTER TABLE public.revenuecat_webhook_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.revenuecat_webhook_events FROM anon, authenticated;
GRANT ALL ON TABLE public.revenuecat_webhook_events TO service_role;


-- TABLE: paywall_events
CREATE TABLE IF NOT EXISTS public.paywall_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id     uuid REFERENCES public.homes(id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN ('impression', 'cta_click', 'dismiss', 'restore_attempt')),
  source      text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.paywall_events IS
  'Funnel events for the paywall (impression, CTA click, dismiss, restore).';

ALTER TABLE public.paywall_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.paywall_events FROM anon, authenticated;
GRANT ALL ON TABLE public.paywall_events TO service_role;


-- FUNCTION: paywall_record_subscription
CREATE OR REPLACE FUNCTION public.paywall_record_subscription(
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
  p_event_timestamp timestamptz DEFAULT now(),
  p_environment text DEFAULT NULL,
  p_raw_event jsonb DEFAULT NULL,
  p_error text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_home_id uuid;
BEGIN
  -- Upsert the user subscription snapshot
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
    home_id               = COALESCE(EXCLUDED.home_id, us.home_id),
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

  -- Persist audit record (fire and forget)
  INSERT INTO public.revenuecat_webhook_events (
    event_timestamp,
    environment,
    rc_app_user_id,
    entitlement_id,
    product_id,
    store,
    status,
    current_period_end_at,
    original_purchase_at,
    last_purchase_at,
    latest_transaction_id,
    home_id,
    raw,
    error
  ) VALUES (
    p_event_timestamp,
    p_environment,
    p_rc_app_user_id,
    p_entitlement_id,
    p_product_id,
    p_store,
    p_status,
    p_current_period_end_at,
    p_original_purchase_at,
    p_last_purchase_at,
    p_latest_transaction_id,
    COALESCE(p_home_id, v_home_id),
    p_raw_event,
    p_error
  );

  -- Refresh home entitlement if we know the home
  IF COALESCE(p_home_id, v_home_id) IS NOT NULL THEN
    PERFORM public.home_entitlements_refresh(COALESCE(p_home_id, v_home_id));
  END IF;
END;
$$;

COMMENT ON FUNCTION public.paywall_record_subscription IS
  'Service-role helper invoked by RevenueCat webhook to upsert user_subscriptions, refresh home_entitlements, and log the event.';

REVOKE ALL ON FUNCTION public.paywall_record_subscription FROM PUBLIC;
GRANT ALL ON FUNCTION public.paywall_record_subscription TO service_role;


-- FUNCTION: paywall_log_event
CREATE OR REPLACE FUNCTION public.paywall_log_event(
  p_home_id uuid,
  p_event_type text,
  p_source text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  PERFORM public._assert_authenticated();

  IF p_event_type NOT IN ('impression', 'cta_click', 'dismiss', 'restore_attempt') THEN
    PERFORM public.api_error(
      'INVALID_EVENT',
      'Unsupported paywall event type.',
      '22023'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = v_user
      AND m.home_id = p_home_id
      AND m.is_current = TRUE
  ) THEN
    PERFORM public.api_error(
      'HOME_NOT_MEMBER',
      'You are not a current member of this home.',
      '42501'
    );
  END IF;

  INSERT INTO public.paywall_events (user_id, home_id, event_type, source)
  VALUES (v_user, p_home_id, p_event_type, p_source);
END;
$$;

COMMENT ON FUNCTION public.paywall_log_event IS
  'Auth-only helper to log paywall funnel events for a home.';

REVOKE ALL ON FUNCTION public.paywall_log_event FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.paywall_log_event TO authenticated, service_role;
