# Chores Contracts v1

Status: Draft (pre-migration)  
Scope: Defines the household chore lifecycle for the Home-only MVP so UI, BLoC, repositories, and Supabase schema work from the same contract.

## Domain overview
- Any active home member can author chores. `name` is the only required input; other metadata is optional and can be updated later.
- Only one assignee is allowed. Reassigning replaces the previous assignee; removing the assignee returns the chore to the draft pool.
- Recurring chores follow a fixed cadence. Backend roll-forward advances to the first occurrence on/after today so clients show a single actionable row.
- Expectation photos live in Supabase Storage under `storage://households/{homeId}/chores/{choreId}/expectation.jpg`. Clients never store raw URLs; repositories fetch signed URLs on demand.
- Every meaningful state change emits a `chore_events` record (`create`, `activate`, `update`, `complete`, `cancel`) to power audits, notifications, analytics, and debugging.
- Free plan guardrails: homes without an active premium entitlement are capped at 20 active chores and 15 expectation photos across all chores. Premium homes (`home_entitlements.plan = 'premium'` and `expires_at > now()`) bypass the cap. Counts are cached per home in `home_usage_counters` so paywall checks are O(1), and the per-plan limits live in `home_plan_limits` so `_home_assert_quota(homeId, deltas jsonb)` can enforce/raise meaningful errors.
- Lifecycle diagram reference: `docs/diagrams/chores/chore_flow.md`.

## Entities

### Chore
- `id` (uuid)
- `homeId` (uuid) — FK `homes.id`
- `createdByUserId` (uuid) — FK `profiles.id`
- `assigneeUserId` (uuid|null) — nullable FK `profiles.id`; <=1 assignee when `state='active'`
- `name` (text) — required, trimmed length <= 140
- `startDate` (date|null) — defaults to `current_date`
- `recurrence` (enum `RecurrenceInterval`) — defaults to `none`
- `recurrenceCursor` (timestamptz|null) — last cadence anchor; updated by backend only
- `nextOccurrence` (date|null) — computed view or RPC field (>= today for recurring chores)
- `expectationPhotoPath` (text|null) — Supabase Storage path
- `howToVideoUrl` (text|null)
- `notes` (text|null)
- `state` (enum `ChoreState`)
- `completedAt` (timestamptz|null)
- `createdAt` (timestamptz)
- `updatedAt` (timestamptz)

#### ChoreDetailDto

Subset of the `chores` entity used on edit screens:

- `id: uuid`
- `homeId: uuid`
- `createdByUserId: uuid`
- `assigneeUserId: uuid | null`
- `name: string`
- `startDate: date | null`
- `recurrence: RecurrenceInterval | null`
- `expectationPhotoPath: string | null`
- `howToVideoUrl: string | null`
- `notes: string | null`
- `assignee: ChoreAssigneeInlineDto | null`

> Note: does **not** include `state`, `completedAt`, `recurrenceCursor`, `nextOccurrence`, `createdAt`, `updatedAt`. Clients must not rely on those being present in this RPC.

#### ChoreAssigneeInlineDto

Used inside `chore.assignee`:

- `id: uuid` (user id)
- `fullName: string`
- `avatarStoragePath: string | null`

#### ChoreAssigneeDto

Used in the `assignees` array:

- `userId: uuid`
- `fullName: string`
- `avatarStoragePath: string | null`

### ChoreEvent
- `id` (uuid)
- `choreId` (uuid) — FK `chores.id`
- `homeId` (uuid)
- `actorUserId` (uuid)
- `eventType` (enum `ChoreEventType`) — create, activate, update, complete, cancel
- `payload` (jsonb) — structured diff (e.g., `{ "fromAssignee": "...", "toAssignee": "..." }`)
- `occurredAt` (timestamptz, default `now()`)
- `fromState` (`ChoreState|null`)
- `toState` (`ChoreState|null`)

### Enums
- `RecurrenceInterval` = `none | daily | weekly | every_2_weeks | monthly | every_2_months | annual`
- `ChoreState` = `draft | active | completed | cancelled`
- `ChoreEventType` = `create | activate | update | complete | cancel`

```contracts-json
{
  "domain": "chores",
  "version": "v1",
  "entities": {
    "Chore": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "assigneeUserId": "uuid|null",
      "name": "text",
      "startDate": "date",
      "recurrence": "RecurrenceInterval",
      "recurrenceCursor": "timestamptz|null",
      "nextOccurrence": "date|null",
      "expectationPhotoPath": "text|null",
      "howToVideoUrl": "text|null",
      "notes": "text|null",
      "state": "ChoreState",
      "completedAt": "timestamptz|null",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "ChoreEvent": {
      "id": "uuid",
      "choreId": "uuid",
      "homeId": "uuid",
      "actorUserId": "uuid",
      "eventType": "ChoreEventType",
      "payload": "jsonb",
      "occurredAt": "timestamptz",
      "fromState": "ChoreState",
      "toState": "ChoreState"
    }
  },
  "enums": {
    "RecurrenceInterval": [
      "none",
      "daily",
      "weekly",
      "every_2_weeks",
      "monthly",
      "every_2_months",
      "annual"
    ],
    "ChoreState": [
      "draft",
      "active",
      "completed",
      "cancelled"
    ],
    "ChoreEventType": [
      "create",
      "activate",
      "update",
      "complete",
      "cancel"
    ]
  },
  "functions": {
    "chores.listForHome": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_list_for_home",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": {
        "columns": {
          "id": "uuid",
          "home_id": "uuid",
          "assignee_user_id": "uuid|null",
          "name": "text",
          "start_date": "date",
          "assignee_full_name": "text|null",
          "assignee_avatar_storage_path": "text|null"
        }
      }
    },
    "todayFlow.list": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.today_flow_list",
      "args": {
        "p_home_id": "uuid",
        "p_state": "public.chore_state"
      },
      "returns": {
        "columns": {
          "id": "uuid",
          "home_id": "uuid",
          "name": "text",
          "start_date": "date",
          "state": "public.chore_state"
        },
        "ordering": "start_date ASC, created_at ASC",
        "notes": [
          "Requires `_assert_home_member`",
          "When `p_state='active'`, rows are limited to chores assigned to `auth.uid()`",
          "When `p_state='draft'`, all draft chores for the home are returned"
        ]
      }
    },
    "homeAssignees.list": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.home_assignees_list",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": {
        "columns": {
          "user_id": "uuid",
          "full_name": "text",
          "email": "text",
          "avatar_storage_path": "text|null"
        }
      }
    },
    "chores.create": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_create",
      "args": {
        "p_home_id": "uuid",
        "p_name": "text",
        "p_assignee_user_id": "uuid|null",
        "p_start_date": "date|null",
        "p_recurrence": "RecurrenceInterval|null",
        "p_how_to_video_url": "text|null",
        "p_notes": "text|null",
        "p_expectation_photo_path": "text|null"
      },
      "returns": "Chore"
    },
    "chores.getForHome": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_get_for_home",
      "args": {
        "p_home_id": "uuid",
        "p_chore_id": "uuid"
      },
      "returns": "jsonb"
    },
    "chores.update": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_update",
      "args": {
        "p_chore_id": "uuid",
        "p_name": "text",
        "p_assignee_user_id": "uuid",
        "p_start_date": "date",
        "p_recurrence": "RecurrenceInterval|null",
        "p_expectation_photo_path": "text|null",
        "p_how_to_video_url": "text|null",
        "p_notes": "text|null"
      },
      "returns": "Chore"
    },
    "chores.cancel": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_cancel",
      "args": {
        "p_chore_id": "uuid"
      },
      "returns": "jsonb"
    },
    "chore.complete": {
      "type": "rpc",
      "caller": "assignee-only",
      "impl": "public.chore_complete",
      "args": {
        "_chore_id": "uuid"
      },
      "returns": "jsonb"
    }
  },
  "rls": [
    {
      "table": "public.chores",
      "rule": "RLS enabled; anon/auth revoked; all client access via SECURITY DEFINER RPCs."
    },
    {
      "table": "public.chore_events",
      "rule": "RLS enabled; anon/auth revoked; rows inserted via trigger only; no direct client access."
    }
  ]
}

```

## Validation and business rules
- `name` required, trimmed, length <= 140.
- `assigneeUserId` must be an active member of the same `homeId`. RPC rejects cross-home assignments through `home_assignees_list` backed by memberships.
- Draft chores have no assignee. Setting an assignee via `chores_update` transitions them to `state='active'`. Once `state='active'` you can't returns the record to `state='draft'`, as someone must always be assigned.
- Completing a non-recurring chore sets `state=completed`, clears `nextOccurrence`, and hides it from default lists.
- Completing a recurring chore emits `complete`, updates `recurrenceCursor`, rolls cadence forward until `nextOccurrence >= today`, and reuses `state='active'`.
- Cancelling is allowed while `state in (draft, active)` and sets `state=cancelled` plus `nextOccurrence=null`.
- Expectation photos: upload RPC returns a storage path; only backend stores `expectationPhotoPath` (or null when removed) and generates signed URLs per fetch.
- Paywall enforcement: when `_home_is_premium(homeId)` is false, free homes cannot exceed 20 non-finalized (draft or active) chores (non-cancelled, non-completed one-offs) or 15 chores with expectation photos. RPCs raise `PAYWALL_LIMIT_ACTIVE_CHORES` / `PAYWALL_LIMIT_CHORE_PHOTOS` based on the cached counters stored in `home_usage_counters`.
- Counters: `home_usage_counters.active_chores` increments on create and decrements on cancel / one-off complete; `chore_photos` increments/decrements when expectation photos are added/removed so limits stay accurate without scanning all chores.

## RPC endpoints

- ### chores.create
  - Caller: authenticated member of `homeId`.
  - Args: `{ homeId, name, assigneeUserId?, startDate?, recurrence?, notes?, howToVideoUrl?, expectationPhotoPath? }`
  - Returns: `ChoreDto`
  - Effects: inserts draft chore (or `state='active'` if assignee provided), sets cursor/occurrence, emits `chore_events(event_type='create')`, increments `home_usage_counters.active_chores` (+`chore_photos` if a path is provided). Enforces `_home_assert_quota(home_id, jsonb_build_object('active_chores', 1, 'chore_photos', photoDelta))` prior to insert.
  - Errors: `PAYWALL_LIMIT_ACTIVE_CHORES`, `PAYWALL_LIMIT_CHORE_PHOTOS`, `INVALID_INPUT`, `NOT_HOME_MEMBER`.

- ### chores.update
  - Caller: any active member of the home (server asserts membership).
  - Args: `{ choreId, name, assigneeUserId, startDate, recurrence?, notes?, howToVideoUrl?, expectationPhotoPath? }`
  - Behavior: upserts metadata, enforces assignee, flips state to `active`, emits `chore_events(event_type='activate' | 'update')` when fields change, adjusts `home_usage_counters.chore_photos` when expectation media is added or removed.
  - Errors: `PAYWALL_LIMIT_CHORE_PHOTOS` when a free home would exceed 15 expectation photos, validation errors on missing required args, `NOT_FOUND` for unknown chores.

- ### chores.getForHome
  - Caller: active member.
  - Args: `{ homeId, choreId }`
  - Returns: `{ chore: ChoreDetailDto, assignees: ChoreAssigneeDto[] }`
    - `chore` is a *partial* view of the chore for edit screens (not the full entity row).
    - `assignees` is the list of active members in the home that can be assigned to this chore.

- ### homeAssignees.list
  - Caller: active member.
  - Args: `{ homeId }`
  - Returns: members (id, full name, avatar path, email) that can be assigned to chores; used by UI pickers.

- ### chore.complete
  - Caller: current assignee.
  - Args: `{ choreId }`
  - Behavior: one-off chores -> `state=completed`, decrements `home_usage_counters.active_chores`. Recurring chores -> keep `state='active'`, roll cadence forward (skipping past dates), emit `complete` via trigger, and respond with the new `nextOccurrence`.

- ### chores.cancel
  - Caller: creator or assignee.
  - Args: `{ choreId }`
  - Behavior: sets `state=cancelled`, clears scheduling fields, emits `cancel`, decrements `home_usage_counters.active_chores`.

- ### chores.listForHome
  - Caller: any active member.
  - Args: `{ homeId }`
  - Returns: actionable chores for the home ordered by creation time until the pagination/next-occurrence view lands. Future iteration will extend the response with signed photo URLs.

## RLS and access
- `chores`: insert/update limited to members of the associated home. Owners can cancel/delete any record. Non-owners can edit chores they created or are assigned to.
- `chore_events`: insert through trigger only; select allowed for home members (append-only).
- Storage bucket `households` enforces path guards so members can only read/write files under their home prefix. Signed URLs minted via RPC with short TTLs.

## Decisions
1. **Fixed cadence roll-forward**: computed entirely server-side so the client only receives the first occurrence on/after today.
2. **Expectation media**: stored in Supabase Storage; contracts persist the Storage path plus optional signed URL in responses.
3. **Chore events**: append-only `chore_events` table adopted in v1 to power analytics, notifications, and audit logs.
4. **Usage counters**: `home_usage_counters` caches paywall-relevant totals so RPCs can enforce quotas without scanning `chores`.
5. **Entitlement cache**: `home_entitlements` is the single source of truth for free vs premium. Attachment helpers invoked from `homes_create_with_invite`, `homes_join`, and `homes_leave` associate/detach active `user_subscriptions` rows so `_home_is_premium` can make O(1) decisions.
