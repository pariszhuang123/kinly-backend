-- =====================================================================
--  ENUMS
-- =====================================================================

-- Shared / cross-domain recurrence interval
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recurrence_interval') THEN
    CREATE TYPE public.recurrence_interval AS ENUM (
      'none',
      'daily',
      'weekly',
      'every_2_weeks',
      'monthly',
      'every_2_months',
      'annual'
    );
  END IF;
END$$;

-- Chore-specific enums
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chore_state') THEN
    CREATE TYPE public.chore_state AS ENUM (
      'draft',
      'active',
      'completed',
      'cancelled'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chore_event_type') THEN
    CREATE TYPE public.chore_event_type AS ENUM (
      'create',              -- initial creation
      'activate',            -- draft → active
      'update',              -- changed while active
      'complete',            -- completed
      'cancel'               -- cancelled
    );
  END IF;
END$$;


-- =====================================================================
--  CHORES TABLE
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.chores (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id                uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  created_by_user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  assignee_user_id       uuid REFERENCES public.profiles(id) ON DELETE SET NULL,

  name                   text NOT NULL,

  start_date             date NOT NULL DEFAULT current_date,
  recurrence             public.recurrence_interval NOT NULL DEFAULT 'none',

  recurrence_cursor      timestamptz,
  next_occurrence        date,

  expectation_photo_path text,
  how_to_video_url       text,
  notes                  text,

  -- completion timestamp when state transitions to completed
  completed_at           timestamptz,

  state                  public.chore_state NOT NULL DEFAULT 'draft',

  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  -- Valid name range
  CONSTRAINT chk_chore_name_length
    CHECK (char_length(btrim(name)) BETWEEN 1 AND 140),

  -- active ⇒ must have assignee
  CONSTRAINT chk_chore_active_has_assignee
    CHECK (state <> 'active' OR assignee_user_id IS NOT NULL),

  -- draft ⇒ must NOT have assignee
  CONSTRAINT chk_chore_draft_without_assignee
    CHECK (state <> 'draft' OR assignee_user_id IS NULL),

  -- expectation images must be in your household bucket
  CONSTRAINT chk_chore_expectation_path
    CHECK (
      expectation_photo_path IS NULL
      OR expectation_photo_path LIKE 'households/%'
    )
);

COMMENT ON TABLE  public.chores IS 'Household chores authored within a home. Single-assignee, optional recurrence.';
COMMENT ON COLUMN public.chores.home_id                IS 'FK to homes.id. Chore belongs to this home.';
COMMENT ON COLUMN public.chores.created_by_user_id     IS 'Author of the chore.';
COMMENT ON COLUMN public.chores.assignee_user_id       IS 'Responsible user when state=active.';
COMMENT ON COLUMN public.chores.start_date             IS 'Initial due date.';
COMMENT ON COLUMN public.chores.recurrence             IS 'none|daily|weekly|every_2_weeks|monthly|every_2_months|annual';
COMMENT ON COLUMN public.chores.recurrence_cursor      IS 'Anchor timestamptz for recurrence.';
COMMENT ON COLUMN public.chores.next_occurrence        IS 'Next actionable due date.';
COMMENT ON COLUMN public.chores.expectation_photo_path IS 'Supabase Storage path for expectation photos.';
COMMENT ON COLUMN public.chores.completed_at           IS 'Time when first marked completed.';
COMMENT ON COLUMN public.chores.state                  IS 'draft|active|completed|cancelled.';

CREATE INDEX IF NOT EXISTS idx_chores_home_next_occurrence
  ON public.chores (home_id, next_occurrence NULLS LAST, created_at DESC);


-- =====================================================================
--  RLS (NO POLICIES — RPC-WHITELISTED WRITE MODEL)
-- =====================================================================

ALTER TABLE public.chores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chores FROM anon, authenticated;



-- =====================================================================
--  CHORE EVENTS TABLE
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.chore_events (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chore_id       uuid NOT NULL REFERENCES public.chores(id) ON DELETE CASCADE,
  home_id        uuid NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  actor_user_id  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  event_type     public.chore_event_type NOT NULL,
  from_state     public.chore_state,
  to_state       public.chore_state,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.chore_events IS 'Append-only audit log for chore lifecycle transitions.';
COMMENT ON COLUMN public.chore_events.home_id       IS 'Denormalised home id for easier filtering.';
COMMENT ON COLUMN public.chore_events.actor_user_id IS 'User who triggered the event.';
COMMENT ON COLUMN public.chore_events.from_state    IS 'Previous state.';
COMMENT ON COLUMN public.chore_events.to_state      IS 'New state.';
COMMENT ON COLUMN public.chore_events.payload       IS 'Structured diff / metadata.';
COMMENT ON COLUMN public.chore_events.occurred_at   IS 'Timestamp of event.';

CREATE INDEX IF NOT EXISTS idx_chore_events_chore
  ON public.chore_events (chore_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_chore_events_home
  ON public.chore_events (home_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_chore_events_event_type
  ON public.chore_events (event_type, occurred_at DESC);


-- =====================================================================
--  RLS (NO POLICIES — RPC-WHITELISTED WRITE MODEL)
-- =====================================================================

ALTER TABLE public.chore_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chore_events FROM anon, authenticated;
