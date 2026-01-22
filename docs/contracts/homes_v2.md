---
Domain: HOME
Capability: Homes & Membership Stints
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: Draft
Version: v2.0
---

# Kinly Contracts v2 — Home MVP (membership stints)

Status: Draft for alignment with new SQL

Scope: Align contracts with the new homes/memberships/invites migration introducing append-only membership stints and invite code details.
Related domain slices: household actions such as chores are documented in `docs/contracts/chores_v1.md`.

## Entities

Home
- id
- ownerUserId
- createdAt
- updatedAt
- isActive            // true until last member leaves
- deactivatedAt       // set when last active member leaves

Membership
- id                  // unique stint id
- userId
- homeId
- role (owner|member)
- validFrom           // inclusive start
- validTo             // exclusive end; NULL = current
- isCurrent           // derived in DB; exposed to clients
- createdAt
- updatedAt

Invite
- id
- homeId
- code                // CITEXT; Crockford Base32 (6 chars)
- revokedAt           // NULL = active; set if owner rotates/revokes
- usedCount           // total times used (analytics)
- createdAt

```contracts-json
{
  "domain": "homes",
  "version": "v2",
  "entities": {
    "Home": {
      "id": "uuid",
      "name": "text",
      "ownerUserId": "uuid",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz",
      "isActive": "boolean",
      "deactivatedAt": "timestamptz|null"
    },
    "Membership": {
      "id": "uuid",
      "userId": "uuid",
      "homeId": "uuid",
      "role": "text",
      "validFrom": "timestamptz",
      "validTo": "timestamptz|null",
      "isCurrent": "boolean",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "Invite": {
      "id": "uuid",
      "homeId": "uuid",
      "code": "citext",
      "revokedAt": "timestamptz|null",
      "usedCount": "int4",
      "createdAt": "timestamptz"
    }
  },
  "functions": {
    "homes.create": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.homes_create_with_invite",
      "args": {},
      "returns": "jsonb",
      "errors": ["UNAUTHORIZED"],
      "notes": "Creates a home, owner membership, and initial invite; returns { home: { id } }."
    },
    "homes.join": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.homes_join",
      "args": { "p_code": "text" },
      "returns": "jsonb",
      "errors": [
        "INVALID_CODE",
        "INACTIVE_INVITE",
        "ALREADY_IN_OTHER_HOME",
        "PAYWALL_LIMIT_ACTIVE_MEMBERS",
        "FORBIDDEN",
        "UNAUTHORIZED"
      ]
    },
    "homes.transferOwner": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.homes_transfer_owner",
      "args": { "p_home_id": "uuid", "p_new_owner_id": "uuid" },
      "returns": "jsonb",
      "errors": [
        "INVALID_NEW_OWNER",
        "NEW_OWNER_NOT_MEMBER",
        "STATE_CHANGED_RETRY",
        "FORBIDDEN",
        "UNAUTHORIZED"
      ]
    },
    "homes.leave": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.homes_leave",
      "args": { "p_home_id": "uuid" },
      "returns": "jsonb",
      "errors": [
        "NOT_MEMBER",
        "OWNER_MUST_TRANSFER_FIRST",
        "STATE_CHANGED_RETRY",
        "FORBIDDEN",
        "UNAUTHORIZED"
      ]
    },
    "invites.getOrCreate": {
      "type": "rpc",
      "caller": "owner-only",
      "status": "absent",
      "notes": "Not present in DB; initial invite is created by homes.create; manual rotation via invites.rotate."
    },
    "invites.revoke": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.invites_revoke",
      "args": { "p_home_id": "uuid" },
      "returns": "jsonb",
      "errors": ["FORBIDDEN", "UNAUTHORIZED"],
      "notes": "Idempotent when no active invite exists (returns info payload)."
    },
    "invites.rotate": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.invites_rotate",
      "args": { "p_home_id": "uuid" },
      "returns": "jsonb",
      "errors": ["FORBIDDEN", "UNAUTHORIZED"],
      "notes": "Revokes existing active invite(s) and creates a new one; returns { invite_code }."
    },
    "membership.meCurrent": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.membership_me_current",
      "args": {},
      "returns": "jsonb",
      "errors": ["UNAUTHORIZED"],
      "notes": "Returns { ok: true, current: null | { user_id, home_id, role, valid_from } }"
    },
    "members.listActiveByHome": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.members_list_active_by_home",
      "args": { "p_home_id": "uuid", "p_exclude_self": "boolean" },
      "returns": {
        "columns": {
          "user_id": "uuid",
          "username": "citext",
          "role": "text",
          "valid_from": "timestamptz",
          "avatar_url": "text",
          "can_transfer_to": "boolean"
        }
      }
    }
  },
  "rls": [
    {"table": "homes", "rule": "inactive home denied"},
    {"table": "memberships", "rule": "member allowed; non-member denied"},
    {"table": "invites", "rule": "no client access; RPC-only"}
  ],
  "db": {
    "tables": {
      "public.homes": {
        "constraints": ["chk_homes_active_vs_deactivated_at"],
        "indexes": ["pk_homes(id)"]
      },
      "public.memberships": {
        "constraints": ["no_overlap_per_user_home"],
        "indexes": [
          "uq_memberships_user_one_current(user_id) WHERE is_current",
          "uq_memberships_home_one_current_owner(home_id) WHERE is_current AND role = 'owner'"
        ]
      },
      "public.invites": {
        "constraints": [
          "chk_invites_code_format",
          "chk_invites_revoked_after_created",
          "chk_invites_used_nonneg"
        ],
        "indexes": [
          "uq_invites_active_one_per_home(home_id) WHERE revoked_at IS NULL",
          "idx_invites_code_active(code) WHERE revoked_at IS NULL"
        ]
      },
      "public.home_plan_limits": {
        "constraints": [
          "pk_home_plan_limits(plan, metric)"
        ],
        "indexes": []
      },
      "public.home_usage_counters": {
        "constraints": [],
        "indexes": [
          "pk_home_usage_counters(home_id)"
        ]
      }
    },
    "functions": {
      "public.homes_create_with_invite": {
        "type": "rpc",
        "args": {},
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.homes_join": {
        "type": "rpc",
        "args": { "p_code": "text" },
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.homes_transfer_owner": {
        "type": "rpc",
        "args": { "p_home_id": "uuid", "p_new_owner_id": "uuid" },
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.homes_leave": {
        "type": "rpc",
        "args": { "p_home_id": "uuid" },
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.invites_revoke": {
        "type": "rpc",
        "args": { "p_home_id": "uuid" },
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.invites_rotate": {
        "type": "rpc",
        "args": { "p_home_id": "uuid" },
        "returns": "jsonb",
        "security": "definer",
        "volatility": "volatile",
        "grants": { "execute": ["authenticated"] }
      },
      "public.members_list_active_by_home": {
        "type": "rpc",
        "args": { "p_home_id": "uuid", "p_exclude_self": "boolean" },
        "returns": "setof record",
        "security": "definer",
        "volatility": "stable",
        "grants": { "execute": ["authenticated"] }
      },
      "public.membership_me_current": {
        "type": "rpc",
        "args": {},
        "returns": "jsonb",
        "security": "definer",
        "volatility": "stable",
        "grants": { "execute": ["authenticated"] }
      }
    }
  }
}
```

## RPCs / Endpoints

homes.create()
- Creates a home; caller becomes owner and a current membership stint (role=owner). Returns `{ home: { id } }`.
 - Seeds `home_entitlements` with `plan='free'` and invokes `_home_attach_subscription_to_home` so any pre-existing subscription from the creator funds the new home.
 - DB Impl: `public.homes_create_with_invite`

invites.get_active(homeId)
- Returns the current active invite for the home.
- Caller: any active member can fetch. 
- Behavior:
  - If an active invite exists (revokedAt IS NULL and home.isActive = true), returns it unchanged.
  - If the home is inactive, returns an error (forbidden/inactive).
 - DB Impl: `public.invites_get_active`

invites.revoke(homeId)
- Revokes the current active invite (disable without replacement).
 - DB Impl: `public.invites_revoke`

invites.rotate(homeId)
- Atomically revokes the current active invite (if any) and issues a new invite with a fresh unique code.
- Returns the new active invite for immediate sharing.
 - DB Impl: `public.invites_rotate`

homes.join(code)
- Joins the home for the caller using invite code.
- Guards:
  - home.isActive = true
  - invite.revokedAt IS NULL
  - user has no other current membership (unique partial index enforces)
- Paywall:
  - `_home_assert_quota(homeId, jsonb_build_object('active_members', 1))` enforces `home_plan_limits` before inserting the membership.
  - Free homes raise `PAYWALL_LIMIT_ACTIVE_MEMBERS` when moving past the active-member cap; premium homes bypass the quota.
 - DB Impl: `public.homes_join` (attaches any floating subscription via `_home_attach_subscription_to_home`)

homes.transferOwner(homeId, newOwnerId)
- Transfers ownership (both users must be current members).
- Serializes with leave/join and emits `STATE_CHANGED_RETRY` if membership state changes mid-transfer.
- After success the previous owner receives a new `member` stint so history and `membership.meCurrent` stay consistent.
 - DB Impl: `public.homes_transfer_owner`

homes.leave(homeId)
- Closes caller’s current membership stint (sets validTo = now()).
- If that was the last current member:
  - home.isActive = false
  - home.deactivatedAt = now()
 - DB Impl: `public.homes_leave` (detaches the leaver’s subscription via `_home_detach_subscription_to_home` before reassigning chores; if the home deactivates the entitlement row downgrades through `home_entitlements_refresh`)

members.listActiveByHome(homeId)
- Lists current members only (isCurrent = true).
 - DB Impl: `public.members_list_active_by_home`

membership.meCurrent()
- Returns the caller's current membership details (homeId, role, validFrom) or null if not currently in a home.
 - DB Impl: `public.membership_me_current`

profile.me()
- Returns `{ user_id, username, avatar_storage_path }` for the authenticated caller’s active profile.
- DB Impl: `public.profile_me`

profile.identityUpdate(username, avatarId)
- Validates username shape/uniqueness, enforces avatar existence, and applies plan gating (free plans limited to `category='animal'`).
- Ensures no other active member in the caller’s home already uses the avatar (`memberships.is_current = TRUE` uniqueness guard).
- Returns `{ username, avatar_id, avatar_storage_path }`.
- DB Impl: `public.profile_identity_update`

avatars.listForHome(homeId)
- Lists available avatars ordered by `created_at ASC`, scoped to the caller and hides avatars already picked by other members (except the caller’s current avatar).
- Plan-aware: uses `_home_effective_plan` so free homes only see the allowed categories.
- DB Impl: `public.avatars_list_for_home`

## Errors
- Format: exceptions include JSON message `{ code, message, details }` and SQLSTATE maps to HTTP.
- Codes:
  - UNAUTHORIZED → 401 (28000): Authentication required.
  - FORBIDDEN_OWNER_ONLY → 403 (42501): Owner-only operation (or home inactive where noted).
  - HOMES_NOT_MEMBER → 403 (42501): Caller is not a current member of the home.
  - OWNER_TRANSFER_REQUIRED → 403 (42501): Owner must transfer before leaving.
  - INVITE_INVALID → 400 (22023): Invite not found, revoked, or home inactive.
  - MEMBERSHIP_ALREADY_ACTIVE → 409 (23505): User already has a current membership.
  - INVALID_NEW_OWNER → 400 (22023): New owner id invalid (null/self).
  - NEW_OWNER_NOT_MEMBER → 400 (22023): New owner is not a current member of the home.
- Client handling: parse error.message as JSON; route UX by `code` with HTTP as fallback.

## Invariants & Constraints
- A user has at most one current membership across all homes (partial unique index on memberships where is_current = true).
- Only one current owner per home (partial unique index on (home_id) where is_current AND role = 'owner').
- No overlapping stints for the same (user, home) via GiST exclusion on (user_id, home_id, validity &&).
- Invite code is unique; six characters Crockford Base32 (no I/O/0/1); stored as CITEXT.
- An invite is valid only if its home is active and the invite is not revoked.
- No direct client reads/writes on invites; access via RPCs.

## Versioning
- v2 supersedes v1 for memberships and invites. Breaking due to replacing Member with Membership and changing Invite fields.
- Repositories and BLoC should pin to v2.

## Related
- Migration: `supabase/migrations/20251111225015_home_membership_invites_table.sql`
