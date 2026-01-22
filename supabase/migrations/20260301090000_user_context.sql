-- user_context_v1: unified context for Start Page avatar menu + personal profile access
-- NOTE: Start Page assumes the caller has no home context; this function intentionally does NOT return any home fields.
CREATE OR REPLACE FUNCTION public.user_context_v1()
RETURNS TABLE (
  user_id uuid,
  has_preference_report boolean,
  has_personal_mentions boolean,
  show_avatar boolean,
  avatar_storage_path text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  -- Broad existence check: any published personal preference report (any template/locale)
  has_preference_report := EXISTS (
    SELECT 1
    FROM public.preference_reports pr
    WHERE pr.subject_user_id = v_user
      AND pr.status = 'published'
  );

  -- Personal mentions exist (self-only existence check)
  has_personal_mentions := EXISTS (
    SELECT 1
    FROM public.gratitude_wall_personal_items i
    WHERE i.recipient_user_id = v_user
      AND i.author_user_id <> v_user
  );

  show_avatar := (has_preference_report OR has_personal_mentions);

  -- Only return avatar storage path if the avatar should be shown
  IF show_avatar THEN
    SELECT a.storage_path
      INTO avatar_storage_path
    FROM public.profiles p
    LEFT JOIN public.avatars a
      ON a.id = p.avatar_id
    WHERE p.id = v_user;
  ELSE
    avatar_storage_path := NULL;
  END IF;

  user_id := v_user;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.user_context_v1()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.user_context_v1()
  TO authenticated;

COMMENT ON FUNCTION public.user_context_v1() IS
  'Self-only context for Start Page avatar menu + personal profile access. No home fields are returned. show_avatar gates avatar rendering; avatar_storage_path is NULL when show_avatar=false.';


-- Allow personal preference retrieval outside a home context (self-only)
CREATE OR REPLACE FUNCTION public.preference_reports_get_personal_v1(
  p_template_key text DEFAULT 'personal_preferences_v1',
  p_locale text DEFAULT 'en'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user   uuid;
  v_report public.preference_reports%ROWTYPE;
BEGIN
  PERFORM public._assert_authenticated();
  v_user := auth.uid();

  PERFORM public.api_assert(
    p_template_key ~ '^[a-z0-9_]{1,64}$',
    'INVALID_TEMPLATE_KEY',
    'Template key format is invalid.',
    '22023'
  );

  -- We accept "en" or "en-NZ" style values, but normalize to a base language.
  PERFORM public.api_assert(
    p_locale ~ '^[a-z]{2}(-[A-Z]{2})?$',
    'INVALID_LOCALE',
    'Locale must be ISO 639-1 (e.g. en) or ISO 639-1 + "-" + ISO 3166-1 (e.g. en-NZ). It will be normalized to a base language.',
    '22023'
  );

  p_locale := public.locale_base(p_locale);

  PERFORM public.api_assert(
    p_locale IN ('en', 'es', 'ar'),
    'INVALID_LOCALE',
    'Supported base languages are: en, es, ar.',
    '22023'
  );

  SELECT *
    INTO v_report
  FROM public.preference_reports r
  WHERE r.subject_user_id = v_user
    AND r.template_key = p_template_key
    AND r.locale = p_locale
    AND r.status = 'published'
  ORDER BY r.published_at DESC NULLS LAST, r.generated_at DESC, r.id DESC
  LIMIT 1;

  IF v_report.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'found', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'found', true,
    'report', jsonb_build_object(
      'id', v_report.id,
      'subject_user_id', v_report.subject_user_id,
      'template_key', v_report.template_key,
      'locale', v_report.locale,
      'published_at', v_report.published_at,
      'published_content', v_report.published_content,
      'last_edited_at', v_report.last_edited_at,
      'last_edited_by', v_report.last_edited_by
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.preference_reports_get_personal_v1(text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.preference_reports_get_personal_v1(text, text)
  TO authenticated;

COMMENT ON FUNCTION public.preference_reports_get_personal_v1(text, text) IS
  'Fetches the caller''s published personal preference report (self-only). Not intended for Start Page gating; use user_context_v1.';
