-- House Norms publish sync: fail-fast timeout alignment for synchronous publish RPC.
-- Keep API/error contracts stable while preventing long blocking calls.
CREATE OR REPLACE FUNCTION public._house_norms_publish_sync_call(
  p_home_public_id text,
  p_published_at timestamptz,
  p_published_version text,
  p_template_key text,
  p_locale_base text,
  p_published_content jsonb,
  p_public_url_path text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_supabase_url text;
  v_secret text;
  v_published_at_iso text := public._to_iso_utc_ms(p_published_at);
  v_http_url text;

  v_req_id bigint;
  v_started timestamptz := clock_timestamp();
  -- Keep below authenticated role timeout budget (currently 8s in runtime env).
  v_deadline interval := interval '7 seconds';
  -- Explicit pg_net timeout to avoid relying on default (often 5000 ms).
  v_http_timeout_milliseconds integer := 6500;
  v_status_code int;
  v_content text;
  v_error_msg text;
  v_body jsonb := '{}'::jsonb;
  v_edge_error_code text;
  v_edge_error_details text;
  v_artifact_ok boolean := false;
  v_revalidate_ok boolean := false;
BEGIN
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

  IF v_supabase_url IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync config missing SUPABASE_URL.',
      'P0001',
      jsonb_build_object(
        'stage', 'config',
        'missing', 'SUPABASE_URL',
        'lookup_order', jsonb_build_array(
          'vault.decrypted_secrets.SUPABASE_URL',
          'app.settings.supabase_url'
        )
      )
    );
  END IF;

  IF v_secret IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync config missing WORKER_SHARED_SECRET.',
      'P0001',
      jsonb_build_object(
        'stage', 'config',
        'missing', 'WORKER_SHARED_SECRET',
        'lookup_order', jsonb_build_array(
          'vault.decrypted_secrets.WORKER_SHARED_SECRET',
          'app.settings.worker_shared_secret'
        )
      )
    );
  END IF;

  v_http_url := v_supabase_url || '/functions/v1/house_norms_publish_sync';

  v_req_id := net.http_post(
    url := v_http_url,
    headers := jsonb_strip_nulls(jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-secret', v_secret
    )),
    body := jsonb_build_object(
      'home_public_id', p_home_public_id,
      'published_at', v_published_at_iso,
      'published_version', p_published_version,
      'template_key', p_template_key,
      'locale_base', p_locale_base,
      'published_content', p_published_content,
      'public_url_path', p_public_url_path
    ),
    timeout_milliseconds := v_http_timeout_milliseconds
  );

  LOOP
    SELECT r.status_code, r.content, r.error_msg
      INTO v_status_code, v_content, v_error_msg
    FROM net._http_response r
    WHERE r.id = v_req_id
    ORDER BY r.created DESC
    LIMIT 1;

    EXIT WHEN v_status_code IS NOT NULL
           OR v_error_msg IS NOT NULL
           OR clock_timestamp() - v_started > v_deadline;

    PERFORM pg_sleep(0.10);
  END LOOP;

  IF v_error_msg IS NOT NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync HTTP request failed before receiving a response.',
      'P0001',
      jsonb_build_object(
        'stage', 'http_post',
        'request_id', v_req_id,
        'url', v_http_url,
        'error', v_error_msg,
        'timeout_milliseconds', v_http_timeout_milliseconds,
        'timeout_seconds', EXTRACT(epoch FROM v_deadline)
      )
    );
  END IF;

  IF v_status_code IS NULL THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish sync request timed out waiting for edge response.',
      'P0001',
      jsonb_build_object(
        'stage', 'wait_response',
        'request_id', v_req_id,
        'url', v_http_url,
        'timeout_seconds', EXTRACT(epoch FROM v_deadline),
        'timeout_milliseconds', v_http_timeout_milliseconds
      )
    );
  END IF;

  IF v_status_code BETWEEN 200 AND 299 THEN
    BEGIN
      v_body := COALESCE(v_content, '{}')::jsonb;
    EXCEPTION WHEN others THEN
      PERFORM public.api_error(
        'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
        'Publish sync returned success status but invalid JSON body.',
        'P0001',
        jsonb_build_object(
          'stage', 'parse_response',
          'request_id', v_req_id,
          'status_code', v_status_code,
          'body', left(COALESCE(v_content, ''), 1200)
        )
      );
    END;
  ELSE
    BEGIN
      v_body := COALESCE(v_content, '{}')::jsonb;
    EXCEPTION WHEN others THEN
      v_body := jsonb_build_object('raw_body', left(COALESCE(v_content, ''), 1200));
    END;

    v_edge_error_code := nullif(v_body->>'error_code', '');
    v_edge_error_details := nullif(v_body->>'details', '');

    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      format('Publish sync returned non-success status (%s).', v_status_code),
      'P0001',
      jsonb_strip_nulls(jsonb_build_object(
        'stage', 'edge_response',
        'request_id', v_req_id,
        'status_code', v_status_code,
        'url', v_http_url,
        'edge_error_code', v_edge_error_code,
        'edge_error_details', v_edge_error_details,
        'body', v_body,
        'likely_causes',
          CASE
            WHEN v_status_code = 401 THEN jsonb_build_array(
              'WORKER_SHARED_SECRET mismatch between database config and edge function env.',
              'Edge function JWT verification is enabled; internal calls need verify_jwt=false.'
            )
            WHEN v_status_code = 400 THEN jsonb_build_array(
              'Payload validation failed in house_norms_publish_sync.'
            )
            WHEN v_status_code = 413 THEN jsonb_build_array(
              'Published payload exceeded edge size limits.'
            )
            WHEN v_status_code >= 500 THEN jsonb_build_array(
              'Missing edge env vars (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, WORKER_SHARED_SECRET, VERCEL_REVALIDATE_URL, VERCEL_REVALIDATE_SECRET).',
              'Storage artifact write failed, or revalidation endpoint failed.'
            )
            ELSE NULL
          END
      ))
    );
  END IF;

  v_edge_error_code := nullif(v_body->>'error_code', '');
  v_edge_error_details := nullif(v_body->>'details', '');
  v_artifact_ok := lower(COALESCE(v_body->>'artifact_ok', 'false')) IN ('true', 't', '1');
  v_revalidate_ok := lower(COALESCE(v_body->>'revalidate_ok', 'false')) IN ('true', 't', '1');

  IF NOT v_artifact_ok THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_ARTIFACT_FAILED',
      'Publish artifact write failed.',
      'P0001',
      jsonb_strip_nulls(jsonb_build_object(
        'stage', 'artifact_check',
        'request_id', v_req_id,
        'status_code', v_status_code,
        'edge_error_code', v_edge_error_code,
        'edge_error_details', v_edge_error_details,
        'body', v_body
      ))
    );
  END IF;

  IF NOT v_revalidate_ok THEN
    PERFORM public.api_error(
      'HOUSE_NORMS_PUBLISH_REVALIDATE_FAILED',
      'Publish revalidation failed.',
      'P0001',
      jsonb_strip_nulls(jsonb_build_object(
        'stage', 'revalidate_check',
        'request_id', v_req_id,
        'status_code', v_status_code,
        'edge_error_code', v_edge_error_code,
        'edge_error_details', v_edge_error_details,
        'body', v_body
      ))
    );
  END IF;
END;
$$;
