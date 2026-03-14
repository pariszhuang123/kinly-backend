-- House Norms publish jobs v1
-- Async public web delivery with observable job state.
--
-- Design choice:
-- - Publishing the house_norms row is the canonical "publish" inside Kinly.
-- - Public web delivery is async and tracked separately in house_norms_publish_jobs.
-- - UI should treat publish_sync_status as the public-delivery status, not the authoring status.

-- ---------------------------------------------------------------------------
-- JOB TABLE
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.house_norms_publish_jobs (
  job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  home_public_id public.citext NOT NULL,
  published_version text NOT NULL,
  published_at timestamptz NOT NULL,
  template_key text NOT NULL,
  locale_base text NOT NULL,
  public_url_path text NOT NULL,
  payload jsonb NOT NULL,

  status text NOT NULL DEFAULT 'queued',
  attempt_count integer NOT NULL DEFAULT 0,
  current_stage text,
  last_request_id text,
  last_error_code text,
  last_error text,
  last_error_at timestamptz,

  claimed_at timestamptz,
  dispatch_started_at timestamptz,
  processing_started_at timestamptz,
  heartbeat_at timestamptz,
  processed_at timestamptz,

  snapshot_upload_ms integer,
  manifest_upload_ms integer,
  revalidate_ms integer,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT house_norms_publish_jobs_home_version_unique
    UNIQUE (home_id, published_version),

  CONSTRAINT house_norms_publish_jobs_payload_object_check
    CHECK (jsonb_typeof(payload) = 'object'),

  CONSTRAINT house_norms_publish_jobs_published_version_check
    CHECK (published_version ~ '^v[0-9]{6}$'),

  CONSTRAINT house_norms_publish_jobs_locale_base_check
    CHECK (locale_base ~ '^[a-z]{2}$'),

  CONSTRAINT house_norms_publish_jobs_public_url_path_check
    CHECK (public_url_path ~ '^/'),

  CONSTRAINT house_norms_publish_jobs_status_check
    CHECK (status IN ('queued', 'dispatching', 'processing', 'succeeded', 'failed')),

  CONSTRAINT house_norms_publish_jobs_attempt_count_check
    CHECK (attempt_count >= 0),

  CONSTRAINT house_norms_publish_jobs_snapshot_upload_ms_check
    CHECK (snapshot_upload_ms IS NULL OR snapshot_upload_ms >= 0),

  CONSTRAINT house_norms_publish_jobs_manifest_upload_ms_check
    CHECK (manifest_upload_ms IS NULL OR manifest_upload_ms >= 0),

  CONSTRAINT house_norms_publish_jobs_revalidate_ms_check
    CHECK (revalidate_ms IS NULL OR revalidate_ms >= 0)
);

-- Forward-safe column additions for cases where an earlier version existed.
ALTER TABLE public.house_norms_publish_jobs
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS dispatch_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS processing_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS heartbeat_at timestamptz;

-- Replace prior status check if a previous version existed without 'dispatching'.
DO $$
BEGIN
  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      DROP CONSTRAINT IF EXISTS house_norms_publish_jobs_status_check;
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      ADD CONSTRAINT house_norms_publish_jobs_status_check
      CHECK (status IN ('queued', 'dispatching', 'processing', 'succeeded', 'failed'));
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      DROP CONSTRAINT IF EXISTS house_norms_publish_jobs_attempt_count_check;
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      ADD CONSTRAINT house_norms_publish_jobs_attempt_count_check
      CHECK (attempt_count >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      DROP CONSTRAINT IF EXISTS house_norms_publish_jobs_snapshot_upload_ms_check;
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      ADD CONSTRAINT house_norms_publish_jobs_snapshot_upload_ms_check
      CHECK (snapshot_upload_ms IS NULL OR snapshot_upload_ms >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      DROP CONSTRAINT IF EXISTS house_norms_publish_jobs_manifest_upload_ms_check;
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      ADD CONSTRAINT house_norms_publish_jobs_manifest_upload_ms_check
      CHECK (manifest_upload_ms IS NULL OR manifest_upload_ms >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      DROP CONSTRAINT IF EXISTS house_norms_publish_jobs_revalidate_ms_check;
  EXCEPTION
    WHEN undefined_table THEN NULL;
  END;

  BEGIN
    ALTER TABLE public.house_norms_publish_jobs
      ADD CONSTRAINT house_norms_publish_jobs_revalidate_ms_check
      CHECK (revalidate_ms IS NULL OR revalidate_ms >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END
$$;

CREATE INDEX IF NOT EXISTS idx_house_norms_publish_jobs_queued
  ON public.house_norms_publish_jobs (created_at, job_id)
  WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_house_norms_publish_jobs_dispatching
  ON public.house_norms_publish_jobs (claimed_at, job_id)
  WHERE status = 'dispatching';

CREATE INDEX IF NOT EXISTS idx_house_norms_publish_jobs_processing
  ON public.house_norms_publish_jobs (heartbeat_at, processing_started_at, job_id)
  WHERE status = 'processing';

CREATE INDEX IF NOT EXISTS idx_house_norms_publish_jobs_home_latest
  ON public.house_norms_publish_jobs (home_id, created_at DESC);

DROP TRIGGER IF EXISTS trg_house_norms_publish_jobs_touch_updated_at
  ON public.house_norms_publish_jobs;

CREATE TRIGGER trg_house_norms_publish_jobs_touch_updated_at
BEFORE UPDATE ON public.house_norms_publish_jobs
FOR EACH ROW
EXECUTE FUNCTION public._touch_updated_at();

COMMENT ON TABLE public.house_norms_publish_jobs IS
  'Tracks async public web delivery for published house norms documents.';

COMMENT ON COLUMN public.house_norms_publish_jobs.status IS
  'Queue lifecycle: queued -> dispatching -> processing -> succeeded|failed.';

COMMENT ON COLUMN public.house_norms_publish_jobs.attempt_count IS
  'Number of dispatch attempts. Incremented when a job is claimed for dispatch, not when worker heartbeats.';

COMMENT ON COLUMN public.house_norms_publish_jobs.heartbeat_at IS
  'Worker liveness timestamp used for stale-job requeue decisions.';

-- ---------------------------------------------------------------------------
-- INTERNAL DISPATCH
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._house_norms_publish_job_dispatch(
  p_job_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_job public.house_norms_publish_jobs%ROWTYPE;
  v_supabase_url text;
  v_secret text;
  v_request_id bigint;
BEGIN
  SELECT *
    INTO v_job
  FROM public.house_norms_publish_jobs j
  WHERE j.job_id = p_job_id;

  IF v_job.job_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_found',
      'job_id', p_job_id
    );
  END IF;

  IF v_job.status = 'succeeded' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', p_job_id,
      'skipped', 'already_succeeded'
    );
  END IF;

  IF v_job.status <> 'dispatching' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'job_id', p_job_id,
      'reason', 'not_dispatching_state',
      'status', v_job.status
    );
  END IF;

  BEGIN
    SELECT s.decrypted_secret
      INTO v_supabase_url
    FROM vault.decrypted_secrets s
    WHERE s.name = 'SUPABASE_URL'
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      v_supabase_url := NULL;
  END;

  BEGIN
    SELECT s.decrypted_secret
      INTO v_secret
    FROM vault.decrypted_secrets s
    WHERE s.name = 'WORKER_SHARED_SECRET'
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      v_secret := NULL;
  END;

  IF v_supabase_url IS NULL OR btrim(v_supabase_url) = '' THEN
    v_supabase_url := NULLIF(current_setting('app.settings.supabase_url', true), '');
  END IF;

  IF v_secret IS NULL OR btrim(v_secret) = '' THEN
    v_secret := NULLIF(current_setting('app.settings.worker_shared_secret', true), '');
  END IF;

  IF v_supabase_url IS NULL OR v_secret IS NULL THEN
    UPDATE public.house_norms_publish_jobs
    SET status = 'failed',
        current_stage = 'dispatch_config',
        last_error_code = 'dispatch_config_missing',
        last_error = 'Publish job dispatch missing SUPABASE_URL or WORKER_SHARED_SECRET.',
        last_error_at = now(),
        heartbeat_at = now(),
        processed_at = now()
    WHERE job_id = p_job_id
      AND status = 'dispatching';

    RETURN jsonb_build_object(
      'ok', false,
      'job_id', p_job_id,
      'reason', 'dispatch_config_missing'
    );
  END IF;

  BEGIN
    SELECT net.http_post(
      url := v_supabase_url || '/functions/v1/house_norms_publish_sync',
      headers := jsonb_strip_nulls(jsonb_build_object(
        'Content-Type', 'application/json',
        'x-internal-secret', v_secret
      )),
      body := v_job.payload || jsonb_build_object(
        'publish_job_id', v_job.job_id
      )
    )
      INTO v_request_id;
  EXCEPTION
    WHEN OTHERS THEN
      UPDATE public.house_norms_publish_jobs
      SET status = 'failed',
          current_stage = 'dispatch_enqueue',
          last_error_code = SQLSTATE,
          last_error = left(SQLERRM, 1000),
          last_error_at = now(),
          heartbeat_at = now(),
          processed_at = now()
      WHERE job_id = p_job_id
        AND status = 'dispatching';

      RETURN jsonb_build_object(
        'ok', false,
        'job_id', p_job_id,
        'reason', 'dispatch_enqueue_failed',
        'sqlstate', SQLSTATE
      );
  END;

  UPDATE public.house_norms_publish_jobs
  SET current_stage = 'dispatch_queued',
      last_request_id = v_request_id::text,
      last_error_code = NULL,
      last_error = NULL,
      last_error_at = NULL,
      heartbeat_at = now()
  WHERE job_id = p_job_id
    AND status = 'dispatching';

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', p_job_id,
    'request_id', v_request_id
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- DISPATCHER: REQUEUE STALE + CLAIM NEW WORK SAFELY
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.house_norms_publish_jobs_dispatch_queued_v1(
  p_limit integer DEFAULT 25,
  p_stale_for interval DEFAULT interval '10 minutes'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := GREATEST(COALESCE(p_limit, 25), 1);
  v_requeued_count integer := 0;
  v_claimed_count integer := 0;
  v_dispatched_count integer := 0;
  v_job record;
BEGIN
  -- Requeue stale dispatching/processing jobs using a dedicated liveness timestamp.
  WITH stale_jobs AS (
    SELECT j.job_id
    FROM public.house_norms_publish_jobs j
    WHERE j.status IN ('dispatching', 'processing')
      AND COALESCE(
            j.heartbeat_at,
            j.processing_started_at,
            j.dispatch_started_at,
            j.claimed_at,
            j.updated_at
          ) <= now() - COALESCE(p_stale_for, interval '10 minutes')
    ORDER BY COALESCE(
               j.heartbeat_at,
               j.processing_started_at,
               j.dispatch_started_at,
               j.claimed_at,
               j.updated_at
             ) ASC,
             j.job_id ASC
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  ),
  requeued AS (
    UPDATE public.house_norms_publish_jobs j
    SET status = 'queued',
        current_stage = 'queued',
        last_error_code = 'stale_job_requeued',
        last_error = 'Requeued stale publish job for retry.',
        last_error_at = now(),
        claimed_at = NULL,
        dispatch_started_at = NULL,
        processing_started_at = NULL,
        heartbeat_at = NULL,
        processed_at = NULL
    WHERE j.job_id IN (SELECT job_id FROM stale_jobs)
    RETURNING 1
  )
  SELECT count(*)::integer
    INTO v_requeued_count
  FROM requeued;

  -- Claim queued jobs safely.
  WITH jobs_to_claim AS (
    SELECT j.job_id
    FROM public.house_norms_publish_jobs j
    WHERE j.status = 'queued'
    ORDER BY j.created_at ASC, j.job_id ASC
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  ),
  claimed AS (
    UPDATE public.house_norms_publish_jobs j
    SET status = 'dispatching',
        attempt_count = j.attempt_count + 1,
        current_stage = 'dispatch_claimed',
        claimed_at = now(),
        dispatch_started_at = now(),
        processing_started_at = NULL,
        heartbeat_at = now(),
        processed_at = NULL,
        last_error_code = NULL,
        last_error = NULL,
        last_error_at = NULL
    WHERE j.job_id IN (SELECT job_id FROM jobs_to_claim)
    RETURNING j.job_id
  )
  SELECT count(*)::integer
    INTO v_claimed_count
  FROM claimed;

  FOR v_job IN
    SELECT j.job_id
    FROM public.house_norms_publish_jobs j
    WHERE j.status = 'dispatching'
      AND j.current_stage = 'dispatch_claimed'
      AND j.dispatch_started_at IS NOT NULL
    ORDER BY j.dispatch_started_at ASC, j.job_id ASC
    LIMIT v_limit
  LOOP
    PERFORM public._house_norms_publish_job_dispatch(v_job.job_id);
    v_dispatched_count := v_dispatched_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'requeued_count', v_requeued_count,
    'claimed_count', v_claimed_count,
    'dispatched_count', v_dispatched_count
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- MANUAL REDRIVE
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.house_norms_publish_job_redrive_v1(
  p_job_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_job public.house_norms_publish_jobs%ROWTYPE;
BEGIN
  UPDATE public.house_norms_publish_jobs
  SET status = 'dispatching',
      attempt_count = attempt_count + 1,
      current_stage = 'dispatch_claimed',
      claimed_at = now(),
      dispatch_started_at = now(),
      processing_started_at = NULL,
      heartbeat_at = now(),
      processed_at = NULL,
      last_error_code = NULL,
      last_error = NULL,
      last_error_at = NULL
  WHERE job_id = p_job_id
    AND status IN ('failed', 'queued')
  RETURNING *
    INTO v_job;

  IF v_job.job_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'job_id', p_job_id,
      'reason', 'not_redrivable'
    );
  END IF;

  RETURN public._house_norms_publish_job_dispatch(p_job_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- WORKER CALLBACKS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.house_norms_publish_job_mark_processing(
  p_job_id uuid,
  p_request_id text DEFAULT NULL,
  p_stage text DEFAULT 'processing'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms_publish_jobs%ROWTYPE;
BEGIN
  UPDATE public.house_norms_publish_jobs
  SET status = CASE
                 WHEN status IN ('dispatching', 'processing') THEN 'processing'
                 ELSE status
               END,
      current_stage = COALESCE(NULLIF(btrim(p_stage), ''), 'processing'),
      last_request_id = COALESCE(NULLIF(btrim(p_request_id), ''), last_request_id),
      processing_started_at = COALESCE(processing_started_at, now()),
      heartbeat_at = now(),
      last_error_code = CASE
                          WHEN status IN ('dispatching', 'processing') THEN NULL
                          ELSE last_error_code
                        END,
      last_error = CASE
                     WHEN status IN ('dispatching', 'processing') THEN NULL
                     ELSE last_error
                   END,
      last_error_at = CASE
                        WHEN status IN ('dispatching', 'processing') THEN NULL
                        ELSE last_error_at
                      END,
      processed_at = CASE
                       WHEN status IN ('dispatching', 'processing') THEN NULL
                       ELSE processed_at
                     END
  WHERE job_id = p_job_id
    AND status IN ('dispatching', 'processing')
  RETURNING *
    INTO v_row;

  RETURN jsonb_build_object(
    'ok', v_row.job_id IS NOT NULL,
    'job_id', p_job_id,
    'status', v_row.status,
    'reason', CASE WHEN v_row.job_id IS NULL THEN 'invalid_transition' ELSE NULL END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.house_norms_publish_job_mark_succeeded(
  p_job_id uuid,
  p_request_id text DEFAULT NULL,
  p_snapshot_upload_ms integer DEFAULT NULL,
  p_manifest_upload_ms integer DEFAULT NULL,
  p_revalidate_ms integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms_publish_jobs%ROWTYPE;
BEGIN
  PERFORM public.api_assert(
    p_snapshot_upload_ms IS NULL OR p_snapshot_upload_ms >= 0,
    'INVALID_DURATION',
    'snapshot_upload_ms must be null or >= 0.',
    '22023'
  );

  PERFORM public.api_assert(
    p_manifest_upload_ms IS NULL OR p_manifest_upload_ms >= 0,
    'INVALID_DURATION',
    'manifest_upload_ms must be null or >= 0.',
    '22023'
  );

  PERFORM public.api_assert(
    p_revalidate_ms IS NULL OR p_revalidate_ms >= 0,
    'INVALID_DURATION',
    'revalidate_ms must be null or >= 0.',
    '22023'
  );

  UPDATE public.house_norms_publish_jobs
  SET status = 'succeeded',
      current_stage = 'done',
      last_request_id = COALESCE(NULLIF(btrim(p_request_id), ''), last_request_id),
      snapshot_upload_ms = p_snapshot_upload_ms,
      manifest_upload_ms = p_manifest_upload_ms,
      revalidate_ms = p_revalidate_ms,
      last_error_code = NULL,
      last_error = NULL,
      last_error_at = NULL,
      heartbeat_at = now(),
      processed_at = now()
  WHERE job_id = p_job_id
    AND status IN ('dispatching', 'processing')
  RETURNING *
    INTO v_row;

  RETURN jsonb_build_object(
    'ok', v_row.job_id IS NOT NULL,
    'job_id', p_job_id,
    'status', v_row.status,
    'reason', CASE WHEN v_row.job_id IS NULL THEN 'invalid_transition' ELSE NULL END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.house_norms_publish_job_mark_failed(
  p_job_id uuid,
  p_request_id text DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_stage text DEFAULT NULL,
  p_snapshot_upload_ms integer DEFAULT NULL,
  p_manifest_upload_ms integer DEFAULT NULL,
  p_revalidate_ms integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms_publish_jobs%ROWTYPE;
BEGIN
  PERFORM public.api_assert(
    p_snapshot_upload_ms IS NULL OR p_snapshot_upload_ms >= 0,
    'INVALID_DURATION',
    'snapshot_upload_ms must be null or >= 0.',
    '22023'
  );

  PERFORM public.api_assert(
    p_manifest_upload_ms IS NULL OR p_manifest_upload_ms >= 0,
    'INVALID_DURATION',
    'manifest_upload_ms must be null or >= 0.',
    '22023'
  );

  PERFORM public.api_assert(
    p_revalidate_ms IS NULL OR p_revalidate_ms >= 0,
    'INVALID_DURATION',
    'revalidate_ms must be null or >= 0.',
    '22023'
  );

  UPDATE public.house_norms_publish_jobs
  SET status = 'failed',
      current_stage = COALESCE(NULLIF(btrim(p_stage), ''), current_stage, 'failed'),
      last_request_id = COALESCE(NULLIF(btrim(p_request_id), ''), last_request_id),
      last_error_code = NULLIF(btrim(p_error_code), ''),
      last_error = CASE
                     WHEN p_error IS NULL THEN NULL
                     ELSE left(p_error, 1000)
                   END,
      last_error_at = now(),
      snapshot_upload_ms = COALESCE(p_snapshot_upload_ms, snapshot_upload_ms),
      manifest_upload_ms = COALESCE(p_manifest_upload_ms, manifest_upload_ms),
      revalidate_ms = COALESCE(p_revalidate_ms, revalidate_ms),
      heartbeat_at = now(),
      processed_at = now()
  WHERE job_id = p_job_id
    AND status IN ('dispatching', 'processing')
  RETURNING *
    INTO v_row;

  RETURN jsonb_build_object(
    'ok', v_row.job_id IS NOT NULL,
    'job_id', p_job_id,
    'status', v_row.status,
    'reason', CASE WHEN v_row.job_id IS NULL THEN 'invalid_transition' ELSE NULL END
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- READ RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.house_norms_get_for_home(
  p_home_id uuid,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms%ROWTYPE;
  v_requested_locale_base text;
  v_is_owner boolean := false;
  v_show_publish_button boolean := false;
  v_show_republish_button boolean := false;
  v_show_public_url boolean := false;
  v_owner_meta jsonb := '{}'::jsonb;
  v_publish_job record;
  v_publish_sync_status text := NULL;
  v_publish_sync_error jsonb := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  v_is_owner := public.is_home_owner(p_home_id, auth.uid());

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  v_requested_locale_base := lower(COALESCE(public.locale_base(p_locale), 'en'));

  PERFORM public.api_assert(
    v_requested_locale_base ~ '^[a-z]{2}$',
    'INVALID_LOCALE',
    'Locale base must be ISO 639-1 lowercase (e.g. en).',
    '22023',
    jsonb_build_object('locale_base', v_requested_locale_base)
  );

  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id;

  IF v_row.home_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'home_id', p_home_id,
      'requested_locale_base', v_requested_locale_base,
      'house_norms', NULL
    );
  END IF;

  IF v_is_owner THEN
    IF v_row.published_content IS NULL THEN
      v_show_publish_button := true;
      v_show_republish_button := false;
      v_show_public_url := false;
    ELSIF v_row.generated_content IS DISTINCT FROM v_row.published_content THEN
      v_show_publish_button := false;
      v_show_republish_button := true;
      v_show_public_url := true;
    ELSE
      v_show_publish_button := false;
      v_show_republish_button := false;
      v_show_public_url := true;
    END IF;

    IF v_row.published_version IS NOT NULL THEN
      SELECT j.status,
             j.last_error_code,
             j.last_error,
             j.last_error_at,
             j.current_stage,
             j.attempt_count,
             j.job_id
        INTO v_publish_job
      FROM public.house_norms_publish_jobs j
      WHERE j.home_id = p_home_id
        AND j.published_version = v_row.published_version
      ORDER BY j.created_at DESC
      LIMIT 1;

      v_publish_sync_status := COALESCE(v_publish_job.status, 'unknown');

      IF v_publish_sync_status = 'failed' THEN
        v_publish_sync_error := jsonb_strip_nulls(jsonb_build_object(
          'code', v_publish_job.last_error_code,
          'message', v_publish_job.last_error,
          'stage', v_publish_job.current_stage,
          'at', v_publish_job.last_error_at
        ));
      END IF;
    END IF;

    v_owner_meta := jsonb_strip_nulls(jsonb_build_object(
      'home_public_id', v_row.home_public_id,
      'public_url',
        CASE
          WHEN v_row.home_public_id IS NULL THEN NULL
          ELSE public._house_norms_build_public_url(v_row.home_public_id::text)
        END,
      'published_version', v_row.published_version,
      'show_publish_button', v_show_publish_button,
      'show_republish_button', v_show_republish_button,
      'show_public_url', v_show_public_url,
      'publish_sync_status', v_publish_sync_status,
      'publish_sync_error', v_publish_sync_error,
      'publish_job_id', v_publish_job.job_id,
      'publish_job_stage', v_publish_job.current_stage,
      'publish_attempt_count', v_publish_job.attempt_count
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'house_norms',
      jsonb_strip_nulls(
        jsonb_build_object(
          'template_key', v_row.template_key,
          'status', v_row.status,
          'inputs', v_row.inputs,
          'draft_content', v_row.generated_content,
          'draft_updated_at', v_row.generated_at,
          'published_content', v_row.published_content,
          'published_at', v_row.published_at,
          'published_version', v_row.published_version,
          'is_published', (v_row.published_content IS NOT NULL),
          'has_unpublished_changes',
            (v_row.published_content IS NULL OR v_row.generated_content IS DISTINCT FROM v_row.published_content),
          'last_edited_at', v_row.last_edited_at,
          'last_edited_by', v_row.last_edited_by
        )
        || CASE
             WHEN v_is_owner THEN v_owner_meta
             ELSE jsonb_build_object(
               'member_viewed_at',
                 (
                   SELECT v.viewed_at
                   FROM public.house_norms_member_views v
                   WHERE v.home_id = p_home_id
                     AND v.user_id = auth.uid()
                 ),
               'show_member_review_card',
                 public.house_norms_should_show_member_review(p_home_id)
             )
           END
      )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- PUBLISH RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.house_norms_publish_for_home(
  p_home_id uuid,
  p_locale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.house_norms%ROWTYPE;
  v_now timestamptz := now();
  v_requested_locale_base text;
  v_home_public_id public.citext;
  v_next_published_version text;
  v_public_url text;
  v_public_url_path text;
  v_publish_job_id uuid;
  v_publish_payload jsonb;
  v_publish_job record;
  v_publish_sync_status text;
  v_publish_sync_error jsonb := NULL;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_norms_assert_owner(p_home_id);

  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ).',
    '22023'
  );

  v_requested_locale_base := lower(COALESCE(public.locale_base(p_locale), 'en'));

  PERFORM public.api_assert(
    v_requested_locale_base ~ '^[a-z]{2}$',
    'INVALID_LOCALE',
    'Locale base must be ISO 639-1 lowercase (e.g. en).',
    '22023',
    jsonb_build_object('locale_base', v_requested_locale_base)
  );

  SELECT *
    INTO v_row
  FROM public.house_norms hn
  WHERE hn.home_id = p_home_id
  FOR UPDATE;

  IF v_row.home_id IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_NOT_FOUND',
      'No house norms document found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  PERFORM public.api_assert(
    v_row.generated_content IS NOT NULL,
    'HOUSE_NORMS_DRAFT_MISSING',
    'Cannot publish because no generated draft content exists.',
    '22023',
    jsonb_build_object('home_id', p_home_id)
  );

  PERFORM public.api_assert(
    v_row.template_key IS NOT NULL AND btrim(v_row.template_key) <> '',
    'HOUSE_NORMS_TEMPLATE_KEY_REQUIRED',
    'Cannot publish because template_key is missing.',
    '22023',
    jsonb_build_object('home_id', p_home_id)
  );

  PERFORM public.api_assert(
    v_row.locale_base ~ '^[a-z]{2}$',
    'HOUSE_NORMS_INVALID_DOC_LOCALE',
    'Cannot publish because the document locale_base is invalid.',
    '22023',
    jsonb_build_object('locale_base', v_row.locale_base)
  );

  v_home_public_id := COALESCE(v_row.home_public_id, public._house_norms_generate_public_id());
  v_next_published_version := public._house_norms_next_published_version(v_row.published_version);
  v_public_url_path := '/kinly/norms/' || v_home_public_id::text;

  UPDATE public.house_norms
  SET published_content = v_row.generated_content,
      published_at = v_now,
      status = 'published',
      published_version = v_next_published_version,
      home_public_id = v_home_public_id
  WHERE home_id = p_home_id
  RETURNING *
    INTO v_row;

  v_public_url := public._house_norms_build_public_url(v_row.home_public_id::text);

  v_publish_payload := jsonb_build_object(
    'home_public_id', v_row.home_public_id::text,
    'published_at', public._to_iso_utc_ms(v_row.published_at),
    'published_version', v_row.published_version,
    'template_key', v_row.template_key,
    'locale_base', v_row.locale_base,
    'published_content', v_row.published_content,
    'public_url_path', v_public_url_path
  );

  INSERT INTO public.house_norms_publish_jobs (
    home_id,
    home_public_id,
    published_version,
    published_at,
    template_key,
    locale_base,
    public_url_path,
    payload,
    status,
    current_stage
  )
  VALUES (
    p_home_id,
    v_row.home_public_id,
    v_row.published_version,
    v_row.published_at,
    v_row.template_key,
    v_row.locale_base,
    v_public_url_path,
    v_publish_payload,
    'queued',
    'queued'
  )
  ON CONFLICT (home_id, published_version) DO UPDATE
  SET home_public_id = EXCLUDED.home_public_id,
      published_at = EXCLUDED.published_at,
      template_key = EXCLUDED.template_key,
      locale_base = EXCLUDED.locale_base,
      public_url_path = EXCLUDED.public_url_path,
      payload = EXCLUDED.payload
  RETURNING job_id
    INTO v_publish_job_id;

  PERFORM public.house_norms_publish_job_redrive_v1(v_publish_job_id);

  SELECT j.status,
         j.last_error_code,
         j.last_error,
         j.last_error_at,
         j.current_stage,
         j.attempt_count
    INTO v_publish_job
  FROM public.house_norms_publish_jobs j
  WHERE j.job_id = v_publish_job_id;

  v_publish_sync_status := COALESCE(v_publish_job.status, 'unknown');

  IF v_publish_sync_status = 'failed' THEN
    v_publish_sync_error := jsonb_strip_nulls(jsonb_build_object(
      'code', v_publish_job.last_error_code,
      'message', v_publish_job.last_error,
      'stage', v_publish_job.current_stage,
      'at', v_publish_job.last_error_at
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'requested_locale_base', v_requested_locale_base,
    'doc_locale_base', v_row.locale_base,
    'status', v_row.status,
    'published_content', v_row.published_content,
    'published_at', v_row.published_at,
    'published_version', v_row.published_version,
    'home_public_id', v_row.home_public_id,
    'public_url', v_public_url,
    'has_unpublished_changes', false,
    'publish_sync_status', v_publish_sync_status,
    'publish_sync_error', v_publish_sync_error,
    'publish_job_id', v_publish_job_id,
    'publish_job_stage', v_publish_job.current_stage,
    'publish_attempt_count', v_publish_job.attempt_count
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- SECURITY
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.house_norms_publish_jobs FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.house_norms_publish_jobs TO service_role;

REVOKE ALL ON FUNCTION public._house_norms_publish_job_dispatch(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.house_norms_publish_jobs_dispatch_queued_v1(integer, interval) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.house_norms_publish_job_redrive_v1(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.house_norms_publish_job_mark_processing(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.house_norms_publish_job_mark_succeeded(uuid, text, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.house_norms_publish_job_mark_failed(uuid, text, text, text, text, integer, integer, integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._house_norms_publish_job_dispatch(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_jobs_dispatch_queued_v1(integer, interval) TO service_role;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_job_redrive_v1(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_job_mark_processing(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_job_mark_succeeded(uuid, text, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.house_norms_publish_job_mark_failed(uuid, text, text, text, text, integer, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- CRON
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_job_id integer;
BEGIN
  BEGIN
    SELECT j.jobid
      INTO v_job_id
    FROM cron.job j
    WHERE j.jobname = 'house_norms_publish_jobs_dispatch_every_10_min'
    LIMIT 1;

    IF v_job_id IS NOT NULL THEN
      PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
      'house_norms_publish_jobs_dispatch_every_10_min',
      '*/10 * * * *',
      $cmd$
      SELECT public.house_norms_publish_jobs_dispatch_queued_v1();
      $cmd$
    );
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE NOTICE 'Skipping pg_cron schedule: house norms publish jobs dispatcher.';
  END;
END
$$;