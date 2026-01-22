# Kinly Contracts v1 — Home MVP

Status: Frozen on merge

Scope: Entities and RPCs used by the Home‑only MVP. This document is the single source of truth for client ↔ server contracts. Changes require Planner + DB + Test approval and a version bump.

## Entities

Home
- id
- name
- ownerUserId
- createdBy
- createdAt
- updatedAt
- isActive            // true until last member leaves
- deactivatedAt       // set when last active member leaves

Member
- id
- userId
- homeId
- role (owner|member)
- createdAt
- updatedAt
- leftAt              // NULL = active; timestamp = user left this home

Invite
- id
- homeId
- code                // UNIQUE
- createdBy
- createdAt
- updatedAt
- revokedAt           // NULL = active; set if owner rotates/revokes
- Valid iff: home.isActive = true AND revokedAt IS NULL

```contracts-json
{
  "domain": "homes",
  "version": "v1",
  "entities": {
    "Home": {
      "id": "uuid",
      "ownerUserId": "uuid",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz",
      "isActive": "boolean",
      "deactivatedAt": "timestamptz|null"
    },
    "Member": {
      "userId": "uuid",
      "homeId": "uuid",
      "role": "text",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz",
      "leftAt": "timestamptz|null"
    },
    "Invite": {
      "id": "uuid",
      "homeId": "uuid",
      "code": "text",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz",
      "revokedAt": "timestamptz|null"
    }
  },
  "functions": {
    "homes.create": {"type": "rpc", "caller": "authenticated"},
    "homes.join": {"type": "rpc", "caller": "authenticated"},
    "homes.transferOwner": {"type": "rpc", "caller": "owner-only"},
    "homes.leave": {"type": "rpc", "caller": "member"},
    "invites.getOrCreate": {"type": "rpc", "caller": "owner-only"},
    "invites.revoke": {"type": "rpc", "caller": "owner-only"},
    "invites.rotate": {"type": "rpc", "caller": "owner-only"}
  },
  "rls": [
    {"table": "homes", "rule": "inactive home denied"},
    {"table": "members", "rule": "member allowed; non-member denied"}
  ]
}
```

## RPCs / Endpoints

homes.create()
- Creates a home; caller becomes owner and an active member.

invites.getOrCreate(homeId)
- Returns the current active invite for the home, or creates one if none exists.
- No ttl/maxUses; permanent until revoked or home deactivated.
 - Caller: owner-only. Idempotent.
 - Behavior:
   - If an active invite exists (revokedAt IS NULL and home.isActive = true), returns it unchanged.
   - If none exists and the home is active, inserts a new invite row (revokedAt = NULL) and returns it.
   - If the home is inactive, returns an error (forbidden/inactive).
 - Notes:
   - Does not rotate codes. To force a new code, use `invites.rotate(homeId)` (or `invites.revoke` + `invites.getOrCreate`).
   - Return includes: id, homeId, code, revokedAt, createdAt, updatedAt.

invites.revoke(homeId)
- Revokes the current active invite (disable without replacement).
- Does NOT create a new invite.

invites.rotate(homeId)
- Atomically revokes the current active invite (if any) and issues a new invite with a fresh unique code.
- Returns the new active invite for immediate sharing.

homes.join(code)
- Joins the home for the caller using invite code.
- Guards:
  - home.isActive = true
  - invite.revokedAt IS NULL
  - user has no other active membership (unique index enforces)

homes.transferOwner(homeId, newOwnerId)
- Transfers ownership (both users must be active members).

homes.leave(homeId)
- Sets member.leftAt = now() for caller.
- If that was the last active member:
  - home.isActive = false
  - home.deactivatedAt = now()

members.kick(homeId, userId)
- Owner-only: sets member.leftAt = now() for target user (must be an active member and not the owner).

members.listActiveByHome(homeId)
- Lists active members only (leftAt IS NULL).

members.listByHome(homeId)
- Lists all historical memberships (active + past).

## Invariants & Constraints
- A user has at most one active membership across all homes.
- Invite `code` is unique.
- An invite is valid only if its home is active and the invite is not revoked.
- Exactly one active invite per home (unique partial index on (homeId) where revokedAt IS NULL).
- Owner cannot leave while other active members exist (must transfer ownership first).
 - No separate `active` column is required on `invites`: activity is derived as `home.isActive = true AND revokedAt IS NULL`. If convenient for queries, consider a view (e.g., `invites_active`) rather than duplicating state.
 - User self-delete integration: when a user invokes `users.selfDelete()` (see `docs/contracts/users_v1.md`), ownership of any homes with other active members is automatically transferred to the earliest active member; if no other active members exist, the home is deactivated and the owner's membership is closed.

## Versioning
- Any breaking change creates `homes_v2.md` (or higher) and an ADR.
- Repositories and BLoC must pin to a contract version.

## Related Flows & Diagrams
- Pseudocode: Join Home `docs/flows/home_membership/join.md`
- Pseudocode: Invite Rotation `docs/flows/home_membership/invite_rotation.md`
 - Flow: Transfer Owner `docs/flows/home_membership/transfer_owner.md`
 - Flow: Leave Home `docs/flows/home_membership/leave_home.md`
 - Flow: Kick Member `docs/flows/home_membership/kick_member.md`
 - Diagram: Join `docs/diagrams/home_membership/join_flow.mmd`
 - Diagram: Invite Rotation `docs/diagrams/home_membership/invite_rotation.mmd`
  - Diagram: Transfer Owner (flow) `docs/diagrams/home_membership/transfer_owner_flow.mmd`
  - Diagram: Ownership Model `docs/diagrams/home_membership/ownership_model.mmd`
  - Diagram: Home State `docs/diagrams/home_membership/home_state.mmd`
  - Diagram: Permissions `docs/diagrams/home_membership/permissions_flow.mmd`
  - Diagram: Owner Transfer `docs/diagrams/home_membership/transfer_owner_sequence.mmd`
  - Diagram: Kick member `docs/diagrams/home_membership/kick_member.mmd`
  - Diagram: Leave Home `docs/diagrams/home_membership/leave_home.mmd`
