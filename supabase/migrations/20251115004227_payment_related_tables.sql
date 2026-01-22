-- ---------------------------------------------------------------------
-- Payment-related enums + tables
-- ---------------------------------------------------------------------

-- region ENUMS

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_store') THEN
    CREATE TYPE public.subscription_store AS ENUM (
      'app_store',   -- iOS
      'play_store',  -- Android
      'stripe',      -- Web / Stripe
      'promotional'  -- manual, gift, etc.
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_status') THEN
    CREATE TYPE public.subscription_status AS ENUM (
      'active',      -- currently entitled to premium
      'cancelled',   -- auto-renew off, may still be active until end date
      'expired',     -- entitlement ended and not active anymore
      'inactive'     -- catch-all: never started / revoked / test
    );
  END IF;
END$$;

-- endregion ENUMS



-- ---------------------------------------------------------------------
-- TABLE: home_usage_counters
-- Cached usage per home for paywall checks.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.home_usage_counters (
  home_id       uuid PRIMARY KEY
                REFERENCES public.homes(id) ON DELETE CASCADE,

  active_chores integer NOT NULL DEFAULT 0 CHECK (active_chores >= 0),
  chore_photos  integer NOT NULL DEFAULT 0 CHECK (chore_photos >= 0),

  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.home_usage_counters IS
  'Cached usage counters (active chores, expectation photos) for paywall checks.';
COMMENT ON COLUMN public.home_usage_counters.active_chores IS
  'Non-cancelled chores that still count versus the free quota (e.g. completed recurring + scheduled/assigned, one-off completed removed).';
COMMENT ON COLUMN public.home_usage_counters.chore_photos IS
  'Number of chores with expectation photos.';

-- No direct client access; only via RPC / service role.
REVOKE ALL ON TABLE public.home_usage_counters FROM anon, authenticated;



-- ---------------------------------------------------------------------
-- TABLE: home_entitlements
-- Logical plan per home (free/premium) + expiration.
-- "Is premium?" will be derived from plan + expires_at in RPC/cron.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.home_entitlements (
  home_id    uuid PRIMARY KEY
             REFERENCES public.homes(id) ON DELETE CASCADE,

  plan       text NOT NULL DEFAULT 'free'
             CHECK (plan IN ('free', 'premium')),

  -- Optional max expiration among supporting subs; NULL = indefinite.
  expires_at timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.home_entitlements IS
  'Cached subscription status per home (free vs premium) for fast paywall checks.';
COMMENT ON COLUMN public.home_entitlements.plan IS
  'Logical plan for the home: free | premium.';
COMMENT ON COLUMN public.home_entitlements.expires_at IS
  'Optional max expiration among supporting subscriptions; NULL means indefinite or unknown.';

-- No direct client access; only via RPC / service role.
REVOKE ALL ON TABLE public.home_entitlements FROM anon, authenticated;

-- Example RPC logic (for later) to compute "is_premium":
-- is_premium := (plan = ''premium'' AND (expires_at IS NULL OR expires_at > now()));



-- ---------------------------------------------------------------------
-- TABLE: user_subscriptions
-- Mutable snapshot of per-user recurring subscription entitlements.
-- One row per (user, rc_entitlement_id).
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.user_subscriptions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id                uuid REFERENCES public.homes(id) ON DELETE CASCADE,
  store                  public.subscription_store NOT NULL,
  rc_app_user_id         text NOT NULL,  -- "current" RC app_user_id for this user
  rc_entitlement_id      text NOT NULL,
  product_id             text NOT NULL,
  status                 public.subscription_status NOT NULL,
  current_period_end_at  timestamptz,          -- RC expiration_date
  original_purchase_at   timestamptz,          -- RC original_purchase_date
  last_purchase_at       timestamptz,          -- RC latest_purchase_date
  latest_transaction_id   text,                -- RC / store transaction id
  last_synced_at         timestamptz NOT NULL DEFAULT now(),  -- when we last synced from RC
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.user_subscriptions IS
  'Per-user subscription entitlement snapshot from RevenueCat, tied to a single home and entitlement.';
COMMENT ON COLUMN public.user_subscriptions.user_id IS
  'Paying user (canonical Supabase profile).';
COMMENT ON COLUMN public.user_subscriptions.home_id IS
  'Home whose premium is funded by this subscription (if home-scoped).';
COMMENT ON COLUMN public.user_subscriptions.store IS
  'Store / source of the subscription (app_store, play_store, stripe, promotional).';
COMMENT ON COLUMN public.user_subscriptions.rc_app_user_id IS
  'Latest RevenueCat app_user_id associated with this user/entitlement.';
COMMENT ON COLUMN public.user_subscriptions.rc_entitlement_id IS
  'RevenueCat entitlement identifier, e.g. home_premium.';
COMMENT ON COLUMN public.user_subscriptions.product_id IS
  'Store product id that most recently granted this entitlement.';
COMMENT ON COLUMN public.user_subscriptions.status IS
  'Subscription state snapshot mapped from RevenueCat.';
COMMENT ON COLUMN public.user_subscriptions.current_period_end_at IS
  'End of the current entitlement period (from RevenueCat).';
COMMENT ON COLUMN public.user_subscriptions.last_synced_at IS
  'Timestamp when this row was last updated from RevenueCat.';

-- No direct client access; only via RPC / service role.
REVOKE ALL ON TABLE public.user_subscriptions FROM anon, authenticated;

-- One mutable snapshot row per (user, entitlement).
CREATE UNIQUE INDEX IF NOT EXISTS user_subscriptions_user_entitlement_uniq
ON public.user_subscriptions (user_id, rc_entitlement_id);

-- Helpful for home-level aggregation and debugging.
CREATE INDEX IF NOT EXISTS user_subscriptions_by_home_status
ON public.user_subscriptions (home_id, rc_entitlement_id, status, current_period_end_at);
