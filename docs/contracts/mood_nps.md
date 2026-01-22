# Mood & NPS Contracts v1

Status: Draft (aligned with migration 20251125090700_mood_nps_table)  
Scope: Weekly mood capture, gratitude wall, and NPS gating for the Home-only MVP.

## Domain overview
- Each member can submit at most one mood per ISO week across all homes; the entry is bound to the home they were in when submitted.
- Positive moods (sunny, partially_sunny) can optionally post to the gratitude wall with the same comment.
- Gratitude wall is append-only and paginated newest-first; read markers are stored per user per home.
- Feedback milestones trigger NPS requirements every 13 submissions per user per home; NPS must be cleared before normal flow resumes.
- Access is via repositories -> RPCs only; RLS enforces membership and active-home guards on every table.

## Enums
- `MoodScale`: `sunny | partially_sunny | cloudy | rainy | thunderstorm`

## Entities
### GratitudeWallPost
- `id` uuid
- `homeId` uuid (FK homes.id, cascade delete)
- `authorUserId` uuid (FK profiles.id, cascade delete)
- `mood` MoodScale
- `message` text|null (trimmed, <= 500 chars)
- `createdAt` timestamptz

### HomeMoodEntry
- `id` uuid
- `homeId` uuid (FK homes.id, cascade delete)
- `userId` uuid (FK profiles.id, cascade delete)
- `mood` MoodScale
- `comment` text|null (trimmed, <= 500 chars)
- `createdAt` timestamptz
- `isoWeekYear` int
- `isoWeek` int
- `gratitudePostId` uuid|null (FK gratitude_wall_posts.id, set null on delete)
- Constraints:
  - Unique `(userId, isoWeekYear, isoWeek)` across all homes.
  - One optional gratitude post link; populated only when add-to-wall path is taken.

### GratitudeWallRead
- `homeId` uuid
- `userId` uuid
- `lastReadAt` timestamptz
- PK `(homeId, userId)`

### HomeMoodFeedbackCounters
- `homeId` uuid
- `userId` uuid
- `feedbackCount` int (total mood submissions in this home)
- `firstFeedbackAt` timestamptz|null
- `lastFeedbackAt` timestamptz|null
- `lastNpsAt` timestamptz|null
- `lastNpsScore` int|null (0-10)
- `lastNpsFeedbackCount` int (feedbackCount when last NPS submitted; 0 = never)
- `npsRequired` bool
- PK `(homeId, userId)`

### HomeNps
- `id` uuid
- `homeId` uuid
- `userId` uuid
- `score` int (0-10)
- `createdAt` timestamptz
- `npsFeedbackCount` int (feedbackCount snapshot at submission time)

## Derived rules and side-effects
- Trigger `home_mood_feedback_counters_inc` runs AFTER INSERT on `home_mood_entries`:
  - Upserts counters, increments `feedbackCount`, updates timestamps.
  - Computes milestone every 13 feedbacks; when `feedbackCount` crosses a new multiple of 13 and is greater than `lastNpsFeedbackCount`, sets `npsRequired = true`.
- Gratitude wall posts are immutable; only created through `mood_submit` when mood is positive and `addToWall=true`.
- RLS is enabled on all tables; anon/auth direct access revoked; clients reach data only via RPCs.

## RPC surface (security definer)
- `mood_submit(homeId, mood, comment?, addToWall=false) -> { entryId, gratitudePostId? }`
  - Guards: authenticated; member of `homeId`; home active; mood/home non-null.
  - Validations: trimmed comment <= 500; enforces one mood per ISO week across all homes (errors with `MOOD_ALREADY_SUBMITTED` and isoWeek/isoYear payload).
  - Side-effects: inserts `home_mood_entries`; optionally creates `gratitude_wall_posts` when mood in `sunny|partially_sunny` and `addToWall=true`; trigger updates counters.
- `mood_get_current_weekly(homeId) -> boolean`
  - Guards membership/active home; returns true if the user has already submitted a mood for the current ISO week (any home).
- `gratitude_wall_list(homeId, limit=20, cursorCreatedAt?, cursorId?) -> [post]`
  - Newest-first pagination on `(created_at desc, id desc)`; `limit` capped at 100.
- `gratitude_wall_mark_read(homeId) -> boolean`
  - Upserts `(homeId, userId, lastReadAt=now())` in `gratitude_wall_reads`.
- `home_nps_get_status(homeId) -> boolean`
  - Returns `npsRequired` for the current user/home; defaults false when no counter row exists.
- `home_nps_submit(homeId, score) -> HomeNps row`
  - Guards: membership/active home; score 0-10; counters row must exist; `npsRequired` must be true.
  - Side-effects: inserts into `home_nps` with `npsFeedbackCount = feedbackCount`; updates counters (`lastNpsAt`, `lastNpsScore`, `lastNpsFeedbackCount`) and clears `npsRequired`.
  - Errors: `INVALID_NPS_SCORE`, `NPS_NOT_ELIGIBLE`, `NPS_NOT_REQUIRED`.

## Diagram references
- ER/relationship view: `docs/diagrams/mood_nps/mood_nps_er.md`
- NPS flow: `docs/diagrams/mood_nps/mood_nps_flow.md`
