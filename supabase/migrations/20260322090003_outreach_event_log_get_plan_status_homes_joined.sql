-- Outreach event logging for marketing pages (anonymous, RPC-only)
-- FULL ADJUSTED (pre-production) VERSION
-- Adjustments in this version:
-- - pg_cron scheduling is IDempotent AND FAIL-FAST if pg_cron isn't enabled
-- - digest() call is schema-qualified for search_path = ''
-- - service_role RLS policies added so admin ops work when RLS is enabled

-- ---------------------------
-- Sources registry + aliases
-- ---------------------------
CREATE TABLE IF NOT EXISTS public.outreach_sources (
  source_id  text PRIMARY KEY,
  label      text NOT NULL,
  active     boolean NOT NULL DEFAULT TRUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.outreach_source_aliases (
  alias      text PRIMARY KEY,
  source_id  text NOT NULL REFERENCES public.outreach_sources(source_id),
  active     boolean NOT NULL DEFAULT TRUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_outreach_alias_lower CHECK (alias = lower(alias))
);

COMMENT ON TABLE  public.outreach_sources IS 'Registry of allowed outreach sources (server-managed).';
COMMENT ON COLUMN public.outreach_sources.source_id IS 'Canonical source identifier expected from clients.';
COMMENT ON COLUMN public.outreach_sources.label IS 'Human-friendly label for the source.';
COMMENT ON COLUMN public.outreach_sources.active IS 'Whether the source is allowed for resolution.';

COMMENT ON TABLE  public.outreach_source_aliases IS 'Alias-to-canonical mapping for outreach sources.';
COMMENT ON COLUMN public.outreach_source_aliases.alias IS 'Normalized alias key (lowercased).';
COMMENT ON COLUMN public.outreach_source_aliases.source_id IS 'Canonical source id this alias maps to.';
COMMENT ON COLUMN public.outreach_source_aliases.active IS 'Whether the alias is allowed for resolution.';

-- ---------------------------
-- Event logs (append-only)
-- ---------------------------
CREATE TABLE IF NOT EXISTS public.outreach_event_logs (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event              text NOT NULL,
  app_key            text NOT NULL,
  page_key           text NOT NULL,
  utm_campaign       text NOT NULL DEFAULT 'unknown',
  utm_source         text NOT NULL DEFAULT 'unknown',
  utm_medium         text NOT NULL DEFAULT 'unknown',
  source_id_resolved text NOT NULL DEFAULT 'unknown',
  store              text NOT NULL DEFAULT 'unknown',
  session_id         text NOT NULL,
  country            text,
  ui_locale          text,
  client_event_id    uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_outreach_event_type CHECK (event IN ('page_view', 'cta_click')),
  CONSTRAINT chk_outreach_store CHECK (
    store IN ('ios_app_store', 'google_play', 'web', 'unknown')
  ),
  CONSTRAINT chk_outreach_app_key CHECK (char_length(app_key) BETWEEN 1 AND 40),
  CONSTRAINT chk_outreach_page_key CHECK (char_length(page_key) BETWEEN 1 AND 80),
  CONSTRAINT chk_outreach_campaign CHECK (char_length(utm_campaign) BETWEEN 1 AND 128),
  CONSTRAINT chk_outreach_source CHECK (char_length(utm_source) BETWEEN 1 AND 128),
  CONSTRAINT chk_outreach_medium CHECK (char_length(utm_medium) BETWEEN 1 AND 128),
  CONSTRAINT chk_outreach_session CHECK (char_length(session_id) BETWEEN 1 AND 40)
);

-- Enforce resolved source exists in registry (unknown is seeded + protected below)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_outreach_event_logs_source_resolved'
      AND conrelid = 'public.outreach_event_logs'::regclass
  ) THEN
    ALTER TABLE public.outreach_event_logs
      ADD CONSTRAINT fk_outreach_event_logs_source_resolved
      FOREIGN KEY (source_id_resolved)
      REFERENCES public.outreach_sources(source_id);
  END IF;
END $$;

COMMENT ON TABLE  public.outreach_event_logs IS 'Append-only outreach events from marketing pages; RPC-only (except retention cleanup).';
COMMENT ON COLUMN public.outreach_event_logs.event IS 'Allowed: page_view, cta_click.';
COMMENT ON COLUMN public.outreach_event_logs.app_key IS 'Emitter app key (e.g., kinly-web).';
COMMENT ON COLUMN public.outreach_event_logs.page_key IS 'Marketing page or section identifier.';
COMMENT ON COLUMN public.outreach_event_logs.utm_campaign IS 'Campaign identifier (e.g., UTM campaign).';
COMMENT ON COLUMN public.outreach_event_logs.utm_source IS 'Source bucket (utm_source; used for alias resolution).';
COMMENT ON COLUMN public.outreach_event_logs.utm_medium IS 'Medium bucket (e.g., utm_medium).';
COMMENT ON COLUMN public.outreach_event_logs.source_id_resolved IS 'Registry-resolved source id or ''unknown'' fallback.';
COMMENT ON COLUMN public.outreach_event_logs.store IS 'Store target: web | ios_app_store | google_play | unknown.';
COMMENT ON COLUMN public.outreach_event_logs.session_id IS 'Opaque client session token; never an auth id.';
COMMENT ON COLUMN public.outreach_event_logs.country IS 'Optional ISO 3166-1 alpha-2 country code.';
COMMENT ON COLUMN public.outreach_event_logs.ui_locale IS 'Optional BCP-47 locale.';

CREATE INDEX IF NOT EXISTS idx_outreach_event_logs_event_created_at
  ON public.outreach_event_logs (event, created_at);

CREATE INDEX IF NOT EXISTS idx_outreach_event_logs_campaign_source_created_at
  ON public.outreach_event_logs (utm_campaign, utm_source, utm_medium, created_at);

CREATE INDEX IF NOT EXISTS idx_outreach_event_logs_source_resolved_created_at
  ON public.outreach_event_logs (source_id_resolved, created_at);

CREATE INDEX IF NOT EXISTS idx_outreach_event_logs_session_id
  ON public.outreach_event_logs (session_id);

-- Idempotency support (partial unique index)
CREATE UNIQUE INDEX IF NOT EXISTS uq_outreach_event_logs_client_event_id
  ON public.outreach_event_logs (client_event_id)
  WHERE client_event_id IS NOT NULL;

-- ---------------------------
-- Rate limit storage (rolling-window counters)
-- ---------------------------
CREATE TABLE IF NOT EXISTS public.outreach_rate_limits (
  k            text NOT NULL,
  bucket_start timestamptz NOT NULL,
  n            integer NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_outreach_rate_limits PRIMARY KEY (k, bucket_start)
);

CREATE INDEX IF NOT EXISTS idx_outreach_rate_limits_bucket
  ON public.outreach_rate_limits (bucket_start);

CREATE INDEX IF NOT EXISTS idx_outreach_rate_limits_updated
  ON public.outreach_rate_limits (updated_at);

-- ---------------------------
-- RLS lock-down: no direct client access (RPC-only)
-- ---------------------------
ALTER TABLE public.outreach_event_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outreach_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outreach_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outreach_source_aliases ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.outreach_event_logs FROM PUBLIC;
REVOKE ALL ON TABLE public.outreach_event_logs FROM anon;
REVOKE ALL ON TABLE public.outreach_event_logs FROM authenticated;

REVOKE ALL ON TABLE public.outreach_sources FROM PUBLIC;
REVOKE ALL ON TABLE public.outreach_sources FROM anon;
REVOKE ALL ON TABLE public.outreach_sources FROM authenticated;

REVOKE ALL ON TABLE public.outreach_rate_limits FROM PUBLIC;
REVOKE ALL ON TABLE public.outreach_rate_limits FROM anon;
REVOKE ALL ON TABLE public.outreach_rate_limits FROM authenticated;

REVOKE ALL ON TABLE public.outreach_source_aliases FROM PUBLIC;
REVOKE ALL ON TABLE public.outreach_source_aliases FROM anon;
REVOKE ALL ON TABLE public.outreach_source_aliases FROM authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.outreach_sources TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.outreach_rate_limits TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.outreach_source_aliases TO service_role;

-- (Optional/explicit) allow service_role to read logs directly for admin/ops
GRANT SELECT ON TABLE public.outreach_event_logs TO service_role;

-- RLS policies for service_role so admin ops work with RLS enabled
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'outreach_sources'
      AND policyname = 'service_role_all_outreach_sources'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "service_role_all_outreach_sources"
      ON public.outreach_sources
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true)
    $p$;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'outreach_source_aliases'
      AND policyname = 'service_role_all_outreach_aliases'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "service_role_all_outreach_aliases"
      ON public.outreach_source_aliases
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true)
    $p$;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'outreach_rate_limits'
      AND policyname = 'service_role_all_outreach_rate_limits'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "service_role_all_outreach_rate_limits"
      ON public.outreach_rate_limits
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true)
    $p$;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'outreach_event_logs'
      AND policyname = 'service_role_read_outreach_event_logs'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "service_role_read_outreach_event_logs"
      ON public.outreach_event_logs
      FOR SELECT
      TO service_role
      USING (true)
    $p$;
  END IF;
END $$;

-- ---------------------------
-- Seed known outreach sources (idempotent)
-- ---------------------------
INSERT INTO public.outreach_sources (source_id, label, active)
VALUES
  ('fish_and_chips', 'Fish & Chips QR', TRUE),
  ('uc', 'University of Canterbury', TRUE),
  ('go_get_page', 'Go Get Interest Page', TRUE),
  ('unknown', 'Unknown Source', TRUE)
ON CONFLICT (source_id) DO NOTHING;

-- Seed aliases (examples + self-alias for canonical parity)
-- NOTE: alias column is enforced lowercase by constraint
INSERT INTO public.outreach_source_aliases (alias, source_id, active)
VALUES
  ('fish&chips', 'fish_and_chips', TRUE),
  ('fish-chips', 'fish_and_chips', TRUE),
  ('fish_and_chips', 'fish_and_chips', TRUE),
  ('uc', 'uc', TRUE),
  ('go_get_page', 'go_get_page', TRUE),
  ('unknown', 'unknown', TRUE)
ON CONFLICT (alias) DO NOTHING;

-- ---------------------------
-- Protect canonical 'unknown' source from deletion / deactivation / rename
-- ---------------------------
CREATE OR REPLACE FUNCTION public._outreach_sources_protect_unknown()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (TG_OP = 'DELETE') AND (OLD.source_id = 'unknown') THEN
    RAISE EXCEPTION 'Cannot delete outreach_sources.unknown' USING ERRCODE = '42501';
  END IF;

  IF (TG_OP = 'UPDATE') AND (OLD.source_id = 'unknown') THEN
    IF NEW.source_id <> 'unknown' THEN
      RAISE EXCEPTION 'Cannot rename outreach_sources.unknown' USING ERRCODE = '42501';
    END IF;
    IF NEW.active IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Cannot deactivate outreach_sources.unknown' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_outreach_sources_protect_unknown ON public.outreach_sources;

CREATE TRIGGER trg_outreach_sources_protect_unknown
BEFORE UPDATE OR DELETE ON public.outreach_sources
FOR EACH ROW
EXECUTE FUNCTION public._outreach_sources_protect_unknown();

-- ---------------------------
-- Protect canonical 'unknown' alias from deletion / deactivation / rename / repoint
-- ---------------------------
CREATE OR REPLACE FUNCTION public._outreach_aliases_protect_unknown()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (TG_OP = 'DELETE') AND (OLD.alias = 'unknown') THEN
    RAISE EXCEPTION 'Cannot delete outreach_source_aliases.unknown' USING ERRCODE = '42501';
  END IF;

  IF (TG_OP = 'UPDATE') AND (OLD.alias = 'unknown') THEN
    IF NEW.alias <> 'unknown' THEN
      RAISE EXCEPTION 'Cannot rename outreach_source_aliases.unknown' USING ERRCODE = '42501';
    END IF;
    IF NEW.active IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Cannot deactivate outreach_source_aliases.unknown' USING ERRCODE = '42501';
    END IF;
    IF NEW.source_id <> 'unknown' THEN
      RAISE EXCEPTION 'Cannot repoint outreach_source_aliases.unknown' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_outreach_aliases_protect_unknown ON public.outreach_source_aliases;

CREATE TRIGGER trg_outreach_aliases_protect_unknown
BEFORE UPDATE OR DELETE ON public.outreach_source_aliases
FOR EACH ROW
EXECUTE FUNCTION public._outreach_aliases_protect_unknown();

-- ---------------------------
-- Helper: bucketed counter rate limit (idempotent per bucket)
-- ---------------------------
CREATE OR REPLACE FUNCTION public._outreach_rate_limit_bucketed(
  p_key text,
  p_bucket_start timestamptz,
  p_limit integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_hash text;
  v_count integer;
BEGIN
  -- IMPORTANT: with search_path='', schema-qualify digest()
  v_hash := encode(extensions.digest(p_key, 'sha256'), 'hex');

  INSERT INTO public.outreach_rate_limits (k, bucket_start, n, updated_at)
  VALUES (v_hash, p_bucket_start, 1, now())
  ON CONFLICT (k, bucket_start) DO UPDATE
    SET n = public.outreach_rate_limits.n + 1,
        updated_at = now()
  RETURNING n INTO v_count;

  RETURN v_count <= p_limit;
END;
$$;

-- ---------------------------
-- RPC: outreach.log_event
-- ---------------------------
CREATE OR REPLACE FUNCTION public.outreach_log_event(
  p_event           text,
  p_app_key         text,
  p_page_key        text,
  p_utm_campaign    text,
  p_utm_source      text,
  p_utm_medium      text,
  p_session_id      text,
  p_store           text DEFAULT NULL,
  p_country         text DEFAULT NULL,
  p_ui_locale       text DEFAULT NULL,
  p_client_event_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event text := lower(trim(p_event));
  v_app_key text := trim(p_app_key);
  v_page_key text := trim(p_page_key);

  -- Default blanks to 'unknown'
  v_utm_campaign text := COALESCE(NULLIF(trim(p_utm_campaign), ''), 'unknown');
  v_utm_source   text := COALESCE(NULLIF(lower(trim(p_utm_source)), ''), 'unknown');
  v_utm_medium   text := COALESCE(NULLIF(lower(trim(p_utm_medium)), ''), 'unknown');

  -- store is non-null in table; normalize to 'unknown' if omitted/blank
  v_store text := COALESCE(NULLIF(lower(trim(p_store)), ''), 'unknown');

  v_session_id text := trim(p_session_id);
  v_country text := NULLIF(upper(trim(p_country)), '');
  v_ui_locale text := NULLIF(trim(p_ui_locale), '');

  v_resolved text := 'unknown';
  v_id uuid;

  v_global_bucket timestamptz := date_trunc('minute', now());
  v_session_bucket timestamptz := date_trunc('hour', now());
BEGIN
  PERFORM public.api_assert(v_session_id ~ '^anon_[A-Za-z0-9_-]{16,32}$', 'INVALID_SESSION', 'session_id format invalid', '22023');
  PERFORM public.api_assert(v_event IN ('page_view', 'cta_click'), 'INVALID_EVENT', 'event must be page_view or cta_click', '22023');
  PERFORM public.api_assert(v_store IN ('web', 'ios_app_store', 'google_play', 'unknown'), 'INVALID_STORE', 'store must be web, ios_app_store, google_play, or unknown', '22023');

  PERFORM public.api_assert(v_app_key IS NOT NULL AND v_app_key <> '' AND char_length(v_app_key) <= 40, 'INVALID_INPUT', 'app_key is required', '22023');
  PERFORM public.api_assert(v_page_key IS NOT NULL AND v_page_key <> '' AND char_length(v_page_key) <= 80, 'INVALID_INPUT', 'page_key is required', '22023');

  -- UTMs are always at least 'unknown', so enforce max length only
  PERFORM public.api_assert(char_length(v_utm_campaign) <= 128, 'INVALID_INPUT', 'utm_campaign too long', '22023');
  PERFORM public.api_assert(char_length(v_utm_source)   <= 128, 'INVALID_INPUT', 'utm_source too long', '22023');
  PERFORM public.api_assert(char_length(v_utm_medium)   <= 128, 'INVALID_INPUT', 'utm_medium too long', '22023');

  PERFORM public.api_assert(v_session_id IS NOT NULL AND v_session_id <> '' AND char_length(v_session_id) <= 40, 'INVALID_INPUT', 'session_id is required', '22023');

  -- Normalize best-effort country + locale
  IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN
    v_country := NULL;
  END IF;

  IF v_ui_locale IS NOT NULL AND (length(v_ui_locale) < 2 OR length(v_ui_locale) > 35 OR v_ui_locale ~ '\s') THEN
    v_ui_locale := NULL;
  END IF;

  -- Rate limits: stable keys; bucket_start defines the window
  PERFORM public.api_assert(
    public._outreach_rate_limit_bucketed('global', v_global_bucket, 500),
    'RATE_LIMIT_GLOBAL',
    'Global outreach logging rate limit exceeded',
    '42901'
  );

  PERFORM public.api_assert(
    public._outreach_rate_limit_bucketed('session:' || v_session_id, v_session_bucket, 100),
    'RATE_LIMIT_SESSION',
    'Session outreach logging rate limit exceeded',
    '42901'
  );

  -- Resolve canonical source: direct match (active) then alias (alias active + source active), else unknown
  SELECT s.source_id
    INTO v_resolved
    FROM public.outreach_sources s
   WHERE s.source_id = v_utm_source
     AND s.active = TRUE
   LIMIT 1;

  IF v_resolved IS NULL THEN
    SELECT s.source_id
      INTO v_resolved
      FROM public.outreach_source_aliases a
      JOIN public.outreach_sources s ON s.source_id = a.source_id
     WHERE a.alias = v_utm_source
       AND a.active = TRUE
       AND s.active = TRUE
     LIMIT 1;
  END IF;

  IF v_resolved IS NULL THEN
    v_resolved := 'unknown';
  END IF;

  -- Idempotency: insert; if another request inserted same client_event_id concurrently, return that row
  BEGIN
    INSERT INTO public.outreach_event_logs (
      event, app_key, page_key, utm_campaign, utm_source, utm_medium,
      source_id_resolved, store, session_id, country, ui_locale, client_event_id
    ) VALUES (
      v_event, v_app_key, v_page_key, v_utm_campaign, v_utm_source, v_utm_medium,
      v_resolved, v_store, v_session_id, v_country, v_ui_locale, p_client_event_id
    )
    RETURNING id INTO v_id;

  EXCEPTION WHEN unique_violation THEN
    IF p_client_event_id IS NOT NULL THEN
      SELECT id INTO v_id
        FROM public.outreach_event_logs
       WHERE client_event_id = p_client_event_id
       LIMIT 1;

      IF v_id IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'id', v_id);
      END IF;
    END IF;

    RAISE;
  END;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION public.outreach_log_event(
  text, text, text, text, text, text, text, text, text, text, uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.outreach_log_event(
  text, text, text, text, text, text, text, text, text, text, uuid
) TO anon, authenticated, service_role;

-- ---------------------------
-- Cleanup helpers (service_role only)
-- ---------------------------
-- Rate-limit retention (rolling counters)
CREATE OR REPLACE FUNCTION public.outreach_rate_limits_cleanup(
  p_keep interval DEFAULT interval '14 days'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM public.outreach_rate_limits
   WHERE bucket_start < (now() - p_keep);

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.outreach_rate_limits_cleanup(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.outreach_rate_limits_cleanup(interval) TO service_role;

-- Event log retention (append-only table)
CREATE OR REPLACE FUNCTION public.outreach_event_logs_cleanup(
  p_keep interval DEFAULT interval '180 days'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM public.outreach_event_logs
   WHERE created_at < (now() - p_keep);

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.outreach_event_logs_cleanup(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.outreach_event_logs_cleanup(interval) TO service_role;

-- ---------------------------
-- pg_cron scheduling (REQUIRED; FAIL-FAST + idempotent)
-- ---------------------------
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  -- Hard fail if pg_cron isn't enabled (local dev should fail)
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION
      'pg_cron is required but not installed/enabled. Enable pg_cron in your local Supabase and in prod.'
      USING ERRCODE = '0A000';
  END IF;

  -- Extra guard: ensure cron schema exists
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    RAISE EXCEPTION
      'pg_cron extension is present but cron schema is missing. pg_cron is not usable.'
      USING ERRCODE = '0A000';
  END IF;

  -- Job 1: outreach_event_logs_cleanup_daily
  SELECT jobid INTO v_jobid
  FROM cron.job
  WHERE jobname = 'outreach_event_logs_cleanup_daily'
  LIMIT 1;

  IF v_jobid IS NULL THEN
    PERFORM cron.schedule(
      'outreach_event_logs_cleanup_daily',
      '15 3 * * *',
      'select public.outreach_event_logs_cleanup(interval ''180 days'');'
    );
  ELSE
    PERFORM cron.alter_job(
      v_jobid,
      schedule => '15 3 * * *',
      command  => 'select public.outreach_event_logs_cleanup(interval ''180 days'');',
      active   => true
    );
  END IF;

  -- Job 2: outreach_rate_limits_cleanup_daily
  SELECT jobid INTO v_jobid
  FROM cron.job
  WHERE jobname = 'outreach_rate_limits_cleanup_daily'
  LIMIT 1;

  IF v_jobid IS NULL THEN
    PERFORM cron.schedule(
      'outreach_rate_limits_cleanup_daily',
      '20 3 * * *',
      'select public.outreach_rate_limits_cleanup(interval ''14 days'');'
    );
  ELSE
    PERFORM cron.alter_job(
      v_jobid,
      schedule => '20 3 * * *',
      command  => 'select public.outreach_rate_limits_cleanup(interval ''14 days'');',
      active   => true
    );
  END IF;

END $$;

-- Plan status entrypoint for Profile app bar
-- Provides current home plan for the caller (free/premium) without exposing entitlements table directly.

CREATE OR REPLACE FUNCTION public.get_plan_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_home_id uuid;
  v_plan    text := 'free';
BEGIN
  PERFORM public._assert_authenticated();

  -- Resolve caller's current home (one active stint enforced by uq_memberships_user_one_current)
  SELECT m.home_id
    INTO v_home_id
    FROM public.memberships m
   WHERE m.user_id = v_user_id
     AND m.is_current = TRUE
   LIMIT 1;

  -- No current home → UI should use failure fallback
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'NO_CURRENT_HOME',
      'You are not currently a member of any home.',
      '42501',
      jsonb_build_object(
        'context', 'get_plan_status',
        'reason',  'no_current_home'
      )
    );
  END IF;

  -- Guards
  PERFORM public._assert_home_member(v_home_id);
  PERFORM public._assert_home_active(v_home_id);

  -- Effective plan (subscription-aware)
  v_plan := COALESCE(public._home_effective_plan(v_home_id), 'free');

  RETURN jsonb_build_object(
    'plan',    v_plan,
    'home_id', v_home_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_plan_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_plan_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.homes_join(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user    uuid := auth.uid();
  v_home_id uuid;
  v_revoked boolean;
  v_active  boolean;

  v_plan    text;
  v_cap     integer;
  v_current_members integer := 0;

  v_req public.member_cap_join_requests;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_active_profile();

  -- Combined lookup: home_id + invite state
  SELECT
    i.home_id,
    (i.revoked_at IS NOT NULL) AS revoked,
    h.is_active
  INTO
    v_home_id,
    v_revoked,
    v_active
  FROM public.invites i
  JOIN public.homes h ON h.id = i.home_id
  WHERE i.code = p_code::public.citext
  LIMIT 1;

  -- Code not found at all
  IF v_home_id IS NULL THEN
    PERFORM public.api_error(
      'INVALID_CODE',
      'Invite code not found. Please check and try again.',
      '22023',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'code_not_found'
      )
    );
  END IF;

  -- Invite revoked or home inactive
  IF v_revoked OR NOT v_active THEN
    PERFORM public.api_error(
      'INACTIVE_INVITE',
      'This invite or household is no longer active.',
      'P0001',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'revoked_or_home_inactive'
      )
    );
  END IF;

  -- Ensure caller has a unique avatar within this home (plan-gated)
  PERFORM public._ensure_unique_avatar_for_home(v_home_id, v_user);

  -- Already current member of this same home
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.home_id = v_home_id
       AND m.is_current = TRUE
  ) THEN
    RETURN jsonb_build_object(
      'status',  'success',
      'code',    'already_member',
      'message', 'You are already part of this household.',
      'home_id', v_home_id
    );
  END IF;

  -- Already in another active home (only one allowed)
  IF EXISTS (
    SELECT 1
      FROM public.memberships m
     WHERE m.user_id = v_user
       AND m.is_current = TRUE
       AND m.home_id <> v_home_id
  ) THEN
    PERFORM public.api_error(
      'ALREADY_IN_OTHER_HOME',
      'You are already a member of another household. Leave it first before joining a new one.',
      '42501',
      jsonb_build_object(
        'context', 'homes_join',
        'reason', 'single_home_rule'
      )
    );
  END IF;

  -- Member-cap precheck (free-only): block + enqueue instead of raising paywall
  v_plan := public._home_effective_plan(v_home_id);

  IF v_plan = 'free' THEN
    -- Align lock order explicitly (homes -> home_usage_counters ...)
    PERFORM 1
      FROM public.homes h
     WHERE h.id = v_home_id
     FOR UPDATE;

    -- Ensure counters row exists and lock it
    PERFORM public._home_usage_apply_delta(v_home_id, '{}'::jsonb);

    SELECT COALESCE(active_members, 0)
      INTO v_current_members
      FROM public.home_usage_counters
     WHERE home_id = v_home_id
     FOR UPDATE;

    SELECT max_value
      INTO v_cap
      FROM public.home_plan_limits
     WHERE plan = v_plan
       AND metric = 'active_members';

    IF v_cap IS NOT NULL AND (v_current_members + 1) > v_cap THEN
      v_req := public._member_cap_enqueue_request(v_home_id, v_user);

      RETURN jsonb_build_object(
        'status',     'blocked',
        'code',       'member_cap',
        'message',    'Home is not accepting new members right now. We notified the owner.',
        'home_id',    v_home_id,
        'request_id', v_req.id
      );
    END IF;
  END IF;

  -- Paywall: enforce active_members limit on this home (raises on free over-limit)
  PERFORM public._home_assert_quota(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Create new membership (race-safe)
  BEGIN
    INSERT INTO public.memberships (user_id, home_id, role, valid_from, valid_to)
    VALUES (v_user, v_home_id, 'member', now(), NULL);
  EXCEPTION
    WHEN unique_violation THEN
      PERFORM public.api_error(
        'ALREADY_IN_OTHER_HOME',
        'You are already a member of another household. Leave it first before joining a new one.',
        '42501',
        jsonb_build_object(
          'context', 'homes_join',
          'reason', 'unique_violation_memberships'
        )
      );
  END;

  -- Increment cached active_members
  PERFORM public._home_usage_apply_delta(
    v_home_id,
    jsonb_build_object('active_members', 1)
  );

  -- Increment invite analytics
  UPDATE public.invites
     SET used_count = used_count + 1
   WHERE home_id = v_home_id
     AND code = p_code::public.citext;

  -- Attach Subscription to home
  PERFORM public._home_attach_subscription_to_home(v_user, v_home_id);

  -- Success response
  RETURN jsonb_build_object(
    'status',  'success',
    'code',    'joined',
    'message', 'You have joined the household successfully!',
    'home_id', v_home_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.homes_join(p_code text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.homes_join(p_code text) TO authenticated;
