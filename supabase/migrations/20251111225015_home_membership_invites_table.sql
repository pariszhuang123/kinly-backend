-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;       -- case-insensitive text
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- GiST for range exclusion

-- ---------------------------------------------------------------------
-- Homes
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.homes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id   UUID NOT NULL REFERENCES public.profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  deactivated_at  TIMESTAMPTZ
);

COMMENT ON TABLE  public.homes                    IS 'Top-level container for collaboration within a household.';
COMMENT ON COLUMN public.homes.owner_user_id      IS 'User ID of the home owner (FK to profiles.id).';
COMMENT ON COLUMN public.homes.created_at         IS 'Date when the home was first created.';
COMMENT ON COLUMN public.homes.updated_at         IS 'Date when the home details were last updated.';
COMMENT ON COLUMN public.homes.is_active          IS 'Indicates if the home is currently active.';
COMMENT ON COLUMN public.homes.deactivated_at     IS 'Timestamp when the home was deactivated.';

-- Active/deactivated invariants
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_homes_active_vs_deactivated_at'
      AND conrelid = 'public.homes'::regclass
  ) THEN
    ALTER TABLE public.homes
      ADD CONSTRAINT chk_homes_active_vs_deactivated_at
      CHECK (
        (deactivated_at IS NULL AND is_active = TRUE)
        OR
        (deactivated_at IS NOT NULL AND is_active = FALSE)
      );
  END IF;
END$$;

-- ---------------------------------------------------------------------
-- Membership history (append-only stints with no overlaps)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.memberships (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),                       -- Surrogate key for this stint
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,   -- Who this stint belongs to
  home_id    UUID NOT NULL REFERENCES public.homes(id)    ON DELETE CASCADE,   -- Which home the stint is in
  role       TEXT NOT NULL CHECK (role IN ('owner','member')),                 -- Role during this stint
  valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),                               -- Inclusive start
  valid_to   TIMESTAMPTZ,                                                      -- Exclusive end; NULL = current
  is_current BOOLEAN GENERATED ALWAYS AS (valid_to IS NULL) STORED,            -- Derived “current” flag
  validity   TSTZRANGE GENERATED ALWAYS AS (                                   -- [from, to) open-ended to +infinity
               tstzrange(valid_from, COALESCE(valid_to, 'infinity'::timestamptz), '[)')
             ) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),                               -- Audit: row creation time
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()                                -- Audit: last update time
);

COMMENT ON TABLE  public.memberships IS 'Each row is one “stint” of a user in a home (with a role) and a start/end window; history preserved.';
COMMENT ON COLUMN public.memberships.id         IS 'Surrogate key for the stint row.';
COMMENT ON COLUMN public.memberships.user_id    IS 'FK to profiles.id; identifies the person holding this membership stint.';
COMMENT ON COLUMN public.memberships.home_id    IS 'FK to homes.id; the home this stint is associated with.';
COMMENT ON COLUMN public.memberships.role       IS 'Role during this stint: only "owner" or "member".';
COMMENT ON COLUMN public.memberships.valid_from IS 'Inclusive start timestamp for the stint.';
COMMENT ON COLUMN public.memberships.valid_to   IS 'Exclusive end timestamp; NULL means the stint is still current.';
COMMENT ON COLUMN public.memberships.is_current IS 'Computed: TRUE when valid_to IS NULL. Do not update directly.';
COMMENT ON COLUMN public.memberships.validity   IS 'Generated tstzrange of [valid_from, valid_to) (infinity if open) for overlap checks.';
COMMENT ON COLUMN public.memberships.created_at IS 'Audit timestamp when the row was created.';
COMMENT ON COLUMN public.memberships.updated_at IS 'Audit timestamp of the most recent update to the row.';

-- “Only one current stint per user” (across all homes)
CREATE UNIQUE INDEX IF NOT EXISTS uq_memberships_user_one_current
  ON public.memberships (user_id)
  WHERE is_current;

COMMENT ON INDEX uq_memberships_user_one_current
IS 'Guarantees a user has at most one current membership stint across all homes.';

-- “Only one current owner per home”
CREATE UNIQUE INDEX IF NOT EXISTS uq_memberships_home_one_current_owner
  ON public.memberships (home_id)
  WHERE is_current AND role = 'owner';

COMMENT ON INDEX uq_memberships_home_one_current_owner
IS 'Guarantees a home has at most one current owner stint.';

-- No overlapping stints for the same (user, home)
-- (Allows multiple sequential stints in the same home, but never overlapping.)
ALTER TABLE public.memberships
  DROP CONSTRAINT IF EXISTS no_overlap_per_user_home;
ALTER TABLE public.memberships
  ADD CONSTRAINT no_overlap_per_user_home
  EXCLUDE USING gist (
    user_id WITH =,
    home_id WITH =,
    validity WITH &&
  );

COMMENT ON CONSTRAINT no_overlap_per_user_home ON public.memberships
IS 'Prevents overlapping validity windows for the same user in the same home.';

-- ---------------------------------------------------------------------
-- Invites (permanent, owner-rotatable; short Crockford Base32 codes)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invites (
  id          UUID   PRIMARY KEY DEFAULT gen_random_uuid(),         -- unique row id
  home_id     UUID   NOT NULL REFERENCES public.homes(id) ON DELETE CASCADE,
  code        CITEXT NOT NULL UNIQUE,                               -- short, typeable invite code (case-insensitive)
  revoked_at  TIMESTAMPTZ,                                          -- if set, code no longer valid (manual rotation)
  used_count  INT    NOT NULL DEFAULT 0,                            -- analytics: total times used
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                   -- creation timestamp
  CONSTRAINT chk_invites_code_format
    CHECK (UPPER(code) ~ '^[A-HJ-NP-Z2-9]{6}$'),                    -- Crockford Base32 (no I O 0 1), 6 chars
  CONSTRAINT chk_invites_revoked_after_created
    CHECK (revoked_at IS NULL OR revoked_at >= created_at),
  CONSTRAINT chk_invites_used_nonneg
    CHECK (used_count >= 0)
);

COMMENT ON TABLE  public.invites                IS 'Permanent invitation codes for joining homes. Unlimited-use; owners can rotate by revoking.';
COMMENT ON COLUMN public.invites.id             IS 'Primary key (UUID).';
COMMENT ON COLUMN public.invites.home_id        IS 'FK to homes.id; identifies which home the code belongs to.';
COMMENT ON COLUMN public.invites.code           IS '6-char, typeable invite (A–H J–N P–Z, 2–9). Case-insensitive; normalized to uppercase.';
COMMENT ON COLUMN public.invites.revoked_at     IS 'UTC time when the invite was revoked by the owner; NULL means still active.';
COMMENT ON COLUMN public.invites.used_count     IS 'Analytics counter for how many times the code has been used.';
COMMENT ON COLUMN public.invites.created_at     IS 'UTC creation timestamp.';

-- Speeds lookup for active (non-revoked) codes
CREATE INDEX IF NOT EXISTS idx_invites_code_active
  ON public.invites (code)
  WHERE revoked_at IS NULL;

COMMENT ON INDEX idx_invites_code_active IS
  'Optimizes lookups for active (non-revoked) invite codes.';

-- Enable RLS (already safe defaults because we won't add permissive policies)
ALTER TABLE public.homes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memberships  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invites      ENABLE ROW LEVEL SECURITY;

-- Start from least privilege: remove direct table access
REVOKE ALL ON TABLE public.homes, public.memberships, public.invites FROM anon, authenticated;

 