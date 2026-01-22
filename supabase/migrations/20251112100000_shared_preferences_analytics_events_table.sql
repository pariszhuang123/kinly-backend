-- ---------------------------------------------------------------------
-- Shared Preferences storage (per-user key/value)
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.shared_preferences (
  user_id     uuid      NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  pref_key    text      NOT NULL,
  pref_value  jsonb     NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_shared_preferences PRIMARY KEY (user_id, pref_key)
);

COMMENT ON TABLE  public.shared_preferences IS
  'Per-user key/value preferences (current state only); accessed via RPCs, not direct client DML.';
COMMENT ON COLUMN public.shared_preferences.user_id IS
  'Owner of the preference; references profiles(id).';
COMMENT ON COLUMN public.shared_preferences.pref_key IS
  'Preference key (namespaced, e.g., legal.consent.v1, tutorial.free_upload_camera.v1).';
COMMENT ON COLUMN public.shared_preferences.pref_value IS
  'Preference value as JSONB (boolean, number, string, or structured object).';
COMMENT ON COLUMN public.shared_preferences.created_at IS
  'Timestamp when this preference row was first created.';
COMMENT ON COLUMN public.shared_preferences.updated_at IS
  'Timestamp when this preference row was last updated.';


-- Lock down direct table access; use SECURITY DEFINER RPCs instead
ALTER TABLE public.shared_preferences ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.shared_preferences FROM PUBLIC;
REVOKE ALL ON TABLE public.shared_preferences FROM anon;
REVOKE ALL ON TABLE public.shared_preferences FROM authenticated;

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  home_id     uuid REFERENCES public.homes(id) ON DELETE SET NULL,
  event_type  text NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata    jsonb NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE public.analytics_events IS
  'Append-only log of user/home actions for product analytics; written via RPCs.';
COMMENT ON COLUMN public.analytics_events.user_id IS
  'User responsible for the event (the actor).';
COMMENT ON COLUMN public.analytics_events.home_id IS
  'Home involved in the event, if any; NULL for global/user-only events.';
COMMENT ON COLUMN public.analytics_events.event_type IS
  'Logical event type identifier (e.g., home.created, home.left, legal_consent.accepted).';
COMMENT ON COLUMN public.analytics_events.occurred_at IS
  'Timestamp when the event occurred.';
COMMENT ON COLUMN public.analytics_events.metadata IS
  'Optional JSON payload with additional details for this event.';

-- Helpful indexes for analytics queries
CREATE INDEX IF NOT EXISTS idx_analytics_events_user_event_time
  ON public.analytics_events (user_id, event_type, occurred_at);

CREATE INDEX IF NOT EXISTS idx_analytics_events_home_event_time
  ON public.analytics_events (home_id, event_type, occurred_at);

-- Lock down direct table access; use SECURITY DEFINER RPCs instead
ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.analytics_events FROM PUBLIC;
REVOKE ALL ON TABLE public.analytics_events FROM anon;
REVOKE ALL ON TABLE public.analytics_events FROM authenticated;
