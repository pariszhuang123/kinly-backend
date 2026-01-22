CREATE OR REPLACE FUNCTION public.invites_get_active(
  p_home_id uuid
)
RETURNS public.invites
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv public.invites;
BEGIN
  -- Ensure caller is authenticated + active member of this home
  PERFORM public._assert_home_member(p_home_id);

  -- Fetch the current active invite (no side-effects)
  SELECT *
    INTO v_inv
  FROM public.invites i
  WHERE i.home_id   = p_home_id
    AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    -- Use the same structured error pattern as your helpers
    PERFORM public.api_error(
      'INVITE_NOT_FOUND',
      'No active invite exists for this home.',
      'P0001',
      jsonb_build_object('home_id', p_home_id)
    );
  END IF;

  RETURN v_inv;
END;
$$;


-- Lock down who can call this function
REVOKE ALL
ON FUNCTION public.invites_get_active(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.invites_get_active(uuid)
TO authenticated;      -- Supabase logged-in users


-- Enable RLS (default is: no policies = deny all)
ALTER TABLE public.gratitude_wall_reads           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gratitude_wall_posts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_mood_entries              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_mood_feedback_counters    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.home_nps                       ENABLE ROW LEVEL SECURITY;


-- Gratitude wall reads
REVOKE ALL
ON TABLE public.gratitude_wall_reads
FROM PUBLIC, anon, authenticated;

-- Gratitude wall posts
REVOKE ALL
ON TABLE public.gratitude_wall_posts
FROM PUBLIC, anon, authenticated;

-- Home mood entries
REVOKE ALL
ON TABLE public.home_mood_entries
FROM PUBLIC, anon, authenticated;

-- Home mood feedback counters
REVOKE ALL
ON TABLE public.home_mood_feedback_counters
FROM PUBLIC, anon, authenticated;

-- Home NPS
REVOKE ALL
ON TABLE public.home_nps
FROM PUBLIC, anon, authenticated;
