# Chores Contracts v2

Status: Draft (recurrence every/unit refactor)  
Scope: Replace legacy RecurrenceInterval enum usage at the API boundary for create/update with flexible `recurrenceEvery` + `recurrenceUnit`. Preserve the single-row recurring chore flow and keep v1 intact for production compatibility.

## Domain overview (delta from v1)
- Recurrence intent moves from `recurrence: RecurrenceInterval` to paired fields:
  - `recurrenceEvery` (int|null)
  - `recurrenceUnit` (text|null) where unit ∈ `day|week|month|year`
- Only RPCs with parameter changes are versioned:
  - `public.chores_create_v2`
  - `public.chores_update_v2`
- `todayFlow.list` keeps its v1 name and return shape, but clarifies due filtering.

## Entities

### Chore (updated)
- `id` (uuid)
- `homeId` (uuid)
- `createdByUserId` (uuid)
- `assigneeUserId` (uuid|null)
- `name` (text) — required, trimmed length <= 140
- `startDate` (date|null) — defaults to `current_date`
- `recurrenceEvery` (int|null) — `NULL` for one-off; `>= 1` for recurring
- `recurrenceUnit` (text|null) — one of `day|week|month|year`; `NULL` for one-off
- `recurrenceCursor` (timestamptz|null) — backend-only cadence anchor
- `nextOccurrence` (date|null) — next scheduled date; a chore is “due” when `nextOccurrence <= current_date`
- `expectationPhotoPath` (text|null)
- `howToVideoUrl` (text|null)
- `notes` (text|null)
- `state` (enum `ChoreState`)
- `completedAt` (timestamptz|null)
- `createdAt` (timestamptz)
- `updatedAt` (timestamptz)

#### ChoreDetailDto (updated)
Subset used on edit screens:
- `id: uuid`
- `homeId: uuid`
- `createdByUserId: uuid`
- `assigneeUserId: uuid | null`
- `name: string`
- `startDate: date | null`
- `recurrenceEvery: int | null`
- `recurrenceUnit: text | null`
- `expectationPhotoPath: string | null`
- `howToVideoUrl: string | null`
- `notes: string | null`
- `assignee: ChoreAssigneeInlineDto | null`

> Note: does **not** include `state`, `completedAt`, `recurrenceCursor`, `nextOccurrence`, `createdAt`, `updatedAt`. Clients must not rely on those being present in this RPC.

#### ChoreAssigneeInlineDto
- `id: uuid` (user id)
- `fullName: string`
- `avatarStoragePath: string | null`

#### ChoreAssigneeDto
- `userId: uuid`
- `fullName: string`
- `avatarStoragePath: string | null`

### ChoreEvent
(unchanged from v1)
- `id` (uuid)
- `choreId` (uuid)
- `homeId` (uuid)
- `actorUserId` (uuid)
- `eventType` (enum `ChoreEventType`)
- `payload` (jsonb)
- `occurredAt` (timestamptz, default `now()`)
- `fromState` (`ChoreState|null`)
- `toState` (`ChoreState|null`)

### Enums
- `ChoreState` = `draft | active | completed | cancelled`
- `ChoreEventType` = `create | activate | update | complete | cancel`

## Validation and business rules (updated recurrence)
- `recurrenceEvery` IS NULL iff `recurrenceUnit` IS NULL.
- When set:
  - `recurrenceEvery >= 1`
  - `recurrenceUnit IN ('day','week','month','year')`
- Initial schedule computation (create/update):
  - `base_date = COALESCE(startDate, current_date)`
  - One-off: `nextOccurrence = base_date`
  - Recurring: compute the first occurrence on/after `base_date`, then roll forward until `nextOccurrence >= current_date`
  - `recurrenceCursor` is updated by the backend only
- Completing chores:
  - One-off: `state=completed`, `completedAt=now()`, `nextOccurrence=NULL`, decrement `home_usage_counters.active_chores`
  - Recurring: keep `state='active'`, emit `complete`, advance `recurrenceCursor`, and set `nextOccurrence` to the next date strictly after `current_date` so it no longer appears in Today due list
- Cancelling is allowed while `state in (draft, active)` and sets `state=cancelled` plus `nextOccurrence=null`
- Draft chores have no assignee. Setting an assignee via `chores_update_v2` transitions them to `state='active'`. Once `state='active'` a chore cannot return to `state='draft'`.

## RPC endpoints (v2 where required)

- ### chores.create → `public.chores_create_v2`
  - Caller: authenticated member of `homeId`.
  - Args: `{ homeId, name, assigneeUserId?, startDate?, recurrenceEvery?, recurrenceUnit?, notes?, howToVideoUrl?, expectationPhotoPath? }`
  - Returns: `Chore`
  - Effects: inserts draft chore (or `state='active'` if assignee provided), sets cursor/occurrence, emits `chore_events(event_type='create')`, increments `home_usage_counters.active_chores` (+`chore_photos` if a path is provided). Enforces `_home_assert_quota(home_id, jsonb_build_object('active_chores', 1, 'chore_photos', photoDelta))` prior to insert.
  - Errors: `PAYWALL_LIMIT_ACTIVE_CHORES`, `PAYWALL_LIMIT_CHORE_PHOTOS`, `INVALID_INPUT`, `NOT_HOME_MEMBER`.

- ### chores.update → `public.chores_update_v2`
  - Caller: any active member of the home (server asserts membership).
  - Args: `{ choreId, name, assigneeUserId, startDate?, recurrenceEvery?, recurrenceUnit?, notes?, howToVideoUrl?, expectationPhotoPath? }`
  - Behavior: upserts metadata, enforces assignee membership, flips state to `active`, emits `chore_events(event_type='activate' | 'update')` when fields change, adjusts `home_usage_counters.chore_photos` when expectation media is added or removed, and recomputes scheduling fields when recurrence/startDate change.
  - Errors: `PAYWALL_LIMIT_CHORE_PHOTOS` when a free home would exceed 15 expectation photos, validation errors on missing required args, `NOT_FOUND` for unknown chores.

- ### chores.getForHome (payload update)
  - Caller: active member.
  - Args: `{ homeId, choreId }`
  - Returns: `{ chore: ChoreDetailDto, assignees: ChoreAssigneeDto[] }`
    - `chore` returns `recurrenceEvery/recurrenceUnit` (not legacy recurrence enum).

- ### todayFlow.list (clarified due filtering)
  - Caller: active member.
  - Args: `{ homeId, p_state }`
  - Returns: `{ id, home_id, name, start_date, state }`
  - Notes:
    - Requires `_assert_home_member`.
    - When `p_state='active'`, rows are limited to chores assigned to `auth.uid()` **and** `next_occurrence <= current_date`.
    - When `p_state='draft'`, all draft chores for the home are returned.

- ### chore.complete (uses new recurrence fields)
  - Caller: current assignee.
  - Args: `{ choreId }`
  - Behavior: one-off chores -> `state=completed`, decrements `home_usage_counters.active_chores`. Recurring chores -> keep `state='active'`, roll cadence forward until `nextOccurrence > current_date`, emit `complete`, and respond with the new `nextOccurrence`.

- ### chores.cancel (unchanged)
  - Caller: creator or assignee.
  - Args: `{ choreId }`
  - Behavior: sets `state=cancelled`, clears scheduling fields, emits `cancel`, decrements `home_usage_counters.active_chores`.

- ### chores.listForHome (unchanged)
  - Caller: any active member.
  - Args: `{ homeId }`
  - Returns: actionable chores for the home ordered by creation time until the pagination/next-occurrence view lands.

## Contracts JSON

```contracts-json
{
  "domain": "chores",
  "version": "v2",
  "entities": {
    "Chore": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "assigneeUserId": "uuid|null",
      "name": "text",
      "startDate": "date",
      "recurrenceEvery": "int|null",
      "recurrenceUnit": "text|null",
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
    },
    "ChoreDetailDto": {
      "id": "uuid",
      "homeId": "uuid",
      "createdByUserId": "uuid",
      "assigneeUserId": "uuid|null",
      "name": "text",
      "startDate": "date|null",
      "recurrenceEvery": "int|null",
      "recurrenceUnit": "text|null",
      "expectationPhotoPath": "text|null",
      "howToVideoUrl": "text|null",
      "notes": "text|null",
      "assignee": "ChoreAssigneeInlineDto|null"
    },
    "ChoreAssigneeInlineDto": {
      "id": "uuid",
      "fullName": "text",
      "avatarStoragePath": "text|null"
    },
    "ChoreAssigneeDto": {
      "userId": "uuid",
      "fullName": "text",
      "avatarStoragePath": "text|null"
    }
  },
  "enums": {
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
        "ordering": "due only: next_occurrence <= current_date; internal ordering recommended by next_occurrence ASC, created_at ASC",
        "notes": [
          "Requires `_assert_home_member`",
          "When `p_state='active'`, rows are limited to chores assigned to `auth.uid()`",
          "When `p_state='active'`, only chores due today or earlier are returned (next_occurrence <= current_date)",
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
      "impl": "public.chores_create_v2",
      "args": {
        "p_home_id": "uuid",
        "p_name": "text",
        "p_assignee_user_id": "uuid|null",
        "p_start_date": "date|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_how_to_video_url": "text|null",
        "p_notes": "text|null",
        "p_expectation_photo_path": "text|null"
      },
      "returns": "Chore",
      "notes": [
        "recurrenceEvery/unit are paired: both null (one-off) OR both set (recurring).",
        "Backend computes recurrenceCursor and nextOccurrence.",
        "If assignee provided, state becomes active; otherwise draft."
      ]
    },
    "chores.getForHome": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_get_for_home",
      "args": {
        "p_home_id": "uuid",
        "p_chore_id": "uuid"
      },
      "returns": "jsonb",
      "notes": [
        "Payload returns recurrenceEvery/recurrenceUnit (not legacy recurrence enum).",
        "Edit DTO is partial; clients must not rely on state/cursors/timestamps being present."
      ]
    },
    "chores.update": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.chores_update_v2",
      "args": {
        "p_chore_id": "uuid",
        "p_name": "text",
        "p_assignee_user_id": "uuid",
        "p_start_date": "date|null",
        "p_recurrence_every": "int|null",
        "p_recurrence_unit": "text|null",
        "p_expectation_photo_path": "text|null",
        "p_how_to_video_url": "text|null",
        "p_notes": "text|null"
      },
      "returns": "Chore",
      "notes": [
        "Assignee is required; state remains active after updates.",
        "When recurrence fields change, backend recomputes recurrenceCursor/nextOccurrence."
      ]
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
      "returns": "jsonb",
      "notes": [
        "One-off: state=completed, completedAt=now(), nextOccurrence=null, decrements active_chores.",
        "Recurring: keep state=active, emit complete event, advance nextOccurrence to the next date after today so it no longer appears in Today due list."
      ]
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
