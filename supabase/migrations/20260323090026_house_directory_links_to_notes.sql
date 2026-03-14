-- House Directory v1.1
-- Replace legacy links with house notes in a forward-only migration.
-- Legacy house directory link rows are intentionally discarded.

-- ---------------------------------------------------------------------------
-- NOTE PHOTO QUOTA SUPPORT
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  BEGIN
    ALTER TYPE public.home_usage_metric ADD VALUE 'house_directory_note_photos';
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

ALTER TABLE public.home_usage_counters
ADD COLUMN IF NOT EXISTS house_directory_note_photos integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  BEGIN
    ALTER TABLE public.home_usage_counters
      ADD CONSTRAINT home_usage_counters_house_directory_note_photos_check
      CHECK (house_directory_note_photos >= 0);
  EXCEPTION
    WHEN duplicate_object THEN NULL;
  END;
END $$;

COMMENT ON COLUMN public.home_usage_counters.house_directory_note_photos IS
  'Cumulative count of home-directory note photos added for the home. Replacements do not increment again.';

-- ---------------------------------------------------------------------------
-- NOTES TABLE
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.home_directory_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  title text NOT NULL,
  details text NOT NULL,
  reference_url text NULL,
  photo_path text NULL,
  archived_at timestamptz NULL,
  created_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT home_directory_notes_title_check
    CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  CONSTRAINT home_directory_notes_details_check
    CHECK (
      char_length(btrim(details)) BETWEEN 1 AND 4000
    ),
  CONSTRAINT home_directory_notes_reference_url_check
    CHECK (
      reference_url IS NULL
      OR (
        char_length(reference_url) <= 2048
        AND reference_url ~* '^https?://'
      )
    ),
  CONSTRAINT home_directory_notes_photo_path_check
    CHECK (
      photo_path IS NULL
      OR (
        char_length(photo_path) <= 512
        AND photo_path LIKE 'households/%'
      )
    )
);

COMMENT ON TABLE public.home_directory_notes IS
  'Shared home directory notes for operational home context. Optional reference_url and photo_path support lightweight annotations.';
COMMENT ON COLUMN public.home_directory_notes.photo_path IS
  'Supabase Storage object path (no bucket/host) for note photos.';

CREATE INDEX IF NOT EXISTS idx_home_directory_notes_home_active
  ON public.home_directory_notes (home_id, created_at DESC, id)
  WHERE archived_at IS NULL;

ALTER TABLE public.home_directory_notes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.home_directory_notes
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_home_directory_notes_touch_updated_at ON public.home_directory_notes;
CREATE TRIGGER trg_home_directory_notes_touch_updated_at
BEFORE UPDATE ON public.home_directory_notes
FOR EACH ROW EXECUTE FUNCTION public._touch_updated_at();

-- ---------------------------------------------------------------------------
-- CONTENT + NOTE RPCS
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_home_directory_content(
  p_home_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_services jsonb := '[]'::jsonb;
  v_notes jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_member(p_home_id);
  PERFORM public._assert_home_active(p_home_id);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', s.id,
               'home_id', s.home_id,
               'service_type', s.service_type,
               'custom_label', s.custom_label,
               'provider_name', s.provider_name,
               'account_reference', s.account_reference,
               'link_url', s.link_url,
               'term_start_date', s.term_start_date,
               'term_end_date', s.term_end_date,
               'renewal_reminder_offset_value', s.renewal_reminder_offset_value,
               'renewal_reminder_offset_unit', s.renewal_reminder_offset_unit,
               'notes', s.notes,
               'created_at', s.created_at,
               'updated_at', s.updated_at
             )
             ORDER BY lower(s.provider_name), s.created_at DESC, s.id
           ),
           '[]'::jsonb
         )
    INTO v_services
  FROM public.home_directory_services s
  WHERE s.home_id = p_home_id
    AND s.archived_at IS NULL;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', n.id,
               'home_id', n.home_id,
               'title', n.title,
               'details', n.details,
               'reference_url', n.reference_url,
               'photo_path', n.photo_path,
               'created_at', n.created_at,
               'updated_at', n.updated_at
             )
             ORDER BY lower(n.title), n.created_at DESC, n.id
           ),
           '[]'::jsonb
         )
    INTO v_notes
  FROM public.home_directory_notes n
  WHERE n.home_id = p_home_id
    AND n.archived_at IS NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'home_id', p_home_id,
    'services', v_services,
    'notes', v_notes
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_home_directory_note(
  p_home_id uuid,
  p_note_id uuid DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_reference_url text DEFAULT NULL,
  p_photo_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_note public.home_directory_notes%ROWTYPE;
  v_existing public.home_directory_notes%ROWTYPE;
  v_title text := nullif(btrim(p_title), '');
  v_details text := nullif(btrim(p_details), '');
  v_reference_url text := nullif(btrim(p_reference_url), '');
  v_photo_path text := nullif(btrim(p_photo_path), '');
  v_photo_delta integer := 0;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  PERFORM public.api_assert(
    v_title IS NOT NULL AND v_details IS NOT NULL,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'title and details are required.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_title) BETWEEN 1 AND 120,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'title must be between 1 and 120 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    char_length(v_details) BETWEEN 1 AND 4000,
    'HOUSE_DIRECTORY_NOTE_REQUIRED_FIELDS',
    'details must be between 1 and 4000 characters.',
    '22023'
  );

  PERFORM public.api_assert(
    v_reference_url IS NULL OR (char_length(v_reference_url) <= 2048 AND v_reference_url ~* '^https?://'),
    'HOUSE_DIRECTORY_NOTE_INVALID_URL',
    'reference_url must be null or an http/https URL.',
    '22023'
  );

  PERFORM public.api_assert(
    v_photo_path IS NULL
    OR (
      char_length(v_photo_path) <= 512
      AND v_photo_path LIKE 'households/%'
    ),
    'HOUSE_DIRECTORY_INVALID_INPUT',
    'photo_path must be a storage object path under households/.',
    '22023'
  );

  IF p_note_id IS NULL THEN
    v_photo_delta := CASE WHEN v_photo_path IS NOT NULL THEN 1 ELSE 0 END;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_assert_quota(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;

    INSERT INTO public.home_directory_notes (
      home_id,
      title,
      details,
      reference_url,
      photo_path,
      archived_at,
      created_by_user_id,
      updated_by_user_id
    )
    VALUES (
      p_home_id,
      v_title,
      v_details,
      v_reference_url,
      v_photo_path,
      NULL,
      v_user,
      v_user
    )
    RETURNING * INTO v_note;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;
  ELSE
    SELECT *
      INTO v_existing
    FROM public.home_directory_notes n
    WHERE n.id = p_note_id
      AND n.home_id = p_home_id
      AND n.archived_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
      PERFORM public.api_error(
        'HOUSE_DIRECTORY_NOTE_NOT_FOUND',
        'The note was not found for this home, or it has been archived.',
        'P0002',
        jsonb_build_object('home_id', p_home_id, 'note_id', p_note_id)
      );
    END IF;

    v_photo_delta := CASE
      WHEN v_existing.photo_path IS NULL AND v_photo_path IS NOT NULL THEN 1
      ELSE 0
    END;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_assert_quota(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;

    UPDATE public.home_directory_notes n
       SET title = v_title,
           details = v_details,
           reference_url = v_reference_url,
           photo_path = v_photo_path,
           updated_by_user_id = v_user
     WHERE n.id = p_note_id
       AND n.home_id = p_home_id
       AND n.archived_at IS NULL
    RETURNING * INTO v_note;

    IF v_photo_delta > 0 THEN
      PERFORM public._home_usage_apply_delta(
        p_home_id,
        jsonb_build_object('house_directory_note_photos', v_photo_delta)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'note', jsonb_build_object(
      'id', v_note.id,
      'home_id', v_note.home_id,
      'title', v_note.title,
      'details', v_note.details,
      'reference_url', v_note.reference_url,
      'photo_path', v_note.photo_path,
      'archived_at', v_note.archived_at,
      'created_at', v_note.created_at,
      'updated_at', v_note.updated_at
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.archive_home_directory_note(
  p_home_id uuid,
  p_note_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_note public.home_directory_notes%ROWTYPE;
  v_existing public.home_directory_notes%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  PERFORM public._assert_home_active(p_home_id);
  PERFORM public._house_directory_assert_owner(p_home_id);

  UPDATE public.home_directory_notes n
     SET archived_at = now(),
         updated_by_user_id = v_user
   WHERE n.id = p_note_id
     AND n.home_id = p_home_id
     AND n.archived_at IS NULL
  RETURNING * INTO v_note;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_archived', false,
      'note', jsonb_build_object(
        'id', v_note.id,
        'home_id', v_note.home_id,
        'title', v_note.title,
        'details', v_note.details,
        'reference_url', v_note.reference_url,
        'photo_path', v_note.photo_path,
        'archived_at', v_note.archived_at,
        'created_at', v_note.created_at,
        'updated_at', v_note.updated_at
      )
    );
  END IF;

  SELECT *
    INTO v_existing
  FROM public.home_directory_notes n
  WHERE n.id = p_note_id
    AND n.home_id = p_home_id;

  IF NOT FOUND THEN
    PERFORM public.api_error(
      'HOUSE_DIRECTORY_NOTE_NOT_FOUND',
      'The note was not found for this home.',
      'P0002',
      jsonb_build_object('home_id', p_home_id, 'note_id', p_note_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_archived', true,
    'note', jsonb_build_object(
      'id', v_existing.id,
      'home_id', v_existing.home_id,
      'title', v_existing.title,
      'details', v_existing.details,
      'reference_url', v_existing.reference_url,
      'photo_path', v_existing.photo_path,
      'archived_at', v_existing.archived_at,
      'created_at', v_existing.created_at,
      'updated_at', v_existing.updated_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_home_directory_content(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_home_directory_content(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.upsert_home_directory_note(uuid, uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_home_directory_note(uuid, uuid, text, text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.archive_home_directory_note(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_home_directory_note(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- RETIRE LEGACY LINK SURFACE
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.upsert_home_directory_link(uuid, uuid, text, text, text, text, date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.archive_home_directory_link(uuid, uuid) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.upsert_home_directory_link(uuid, uuid, text, text, text, text, date, date);
DROP FUNCTION IF EXISTS public.archive_home_directory_link(uuid, uuid);

DO $$
BEGIN
  IF to_regclass('public.home_directory_links') IS NULL THEN
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_home_directory_links_touch_updated_at ON public.home_directory_links;
  DROP TABLE public.home_directory_links;
END;
$$;
