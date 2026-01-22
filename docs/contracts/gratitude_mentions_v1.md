# Weekly Feedback → Gratitude + Mentions v1

Contract ID: KINLY.CONTRACT.WEEKLY_FEEDBACK.GRATITUDE_MENTIONS.V1  
Status: Draft (aligned with migration 20260223072456_gratitude_mentions_v2)  
Scope: Weekly mood submit with optional publishing (home wall + mentions) and personal gratitude inbox.

## Domain overview
- Entry point: `public.mood_submit_v2` (JSONB response); legacy `mood_submit` remains unchanged and does not handle mentions.
- Single-call publish: v2 creates the weekly entry and, if requested and mood is positive, publishes to home wall and personal inbox in the same transaction.
- Positive-only publishing: publishing (wall and mentions) is allowed only when mood is `sunny | partially_sunny`; otherwise `NOT_POSITIVE_MOOD`.
- Publishing toggle: `p_public_wall` controls home wall post; personal inbox delivery happens whenever mentions are present (positive mood only). If neither wall nor mentions requested, it just records the weekly entry.
- Mention eligibility: must be current home members at submit time; self-mention disallowed; max 5 after dedup; duplicates rejected.
- Idempotency: `home_mood_entries.id` is the canonical key; `gratitude_wall_posts.source_entry_id` and `(recipient_user_id, source_entry_id)` on personal items enforce “first publish wins.”
- Immutability: append-only tables; RLS enabled; table access revoked for anon/authenticated; writes only via SECURITY DEFINER RPCs.
- Visibility: home wall via existing wall RPCs; personal inbox via new status/list/read RPCs scoped to recipient.

## Entities (new/extended)
### GratitudeWallPost (extended)
- Adds `source_entry_id uuid|null` (FK `home_mood_entries.id`, on delete set null).
- Constraint: partial `UNIQUE(source_entry_id)` (one post per mood entry when present).

### GratitudeWallMention (new)
- `post_id` (FK `gratitude_wall_posts`, cascade delete)
- `home_id` (FK `homes`, cascade delete)
- `mentioned_user_id` (FK `profiles`, cascade delete)
- `created_at` timestamptz default now()
- PK `(post_id, mentioned_user_id)`
- Indexes: `(home_id, post_id)`, `(mentioned_user_id, created_at desc)`

### GratitudeWallPersonalItem (new, personal inbox)
- `id` uuid PK
- `recipient_user_id` (FK `profiles`, cascade delete)
- `home_id` (FK `homes`, restrict delete)
- `author_user_id` (FK `profiles`, restrict delete)
- `mood` mood_scale
- `message` text (trimmed, <=500)
- `created_at` timestamptz default now()
- `source_kind` `home_post | mention_only`
- `source_post_id` uuid|null (FK `gratitude_wall_posts`, restrict delete)
- `source_entry_id` uuid not null (FK `home_mood_entries`, cascade delete)
- No snapshots stored; display fields resolved live at read time.
- Uniqueness: `(recipient_user_id, source_entry_id)` (“first publish wins”; no later enrichment).
- Indexes: `(recipient_user_id, created_at desc, id desc)`, `(recipient_user_id, author_user_id)`, `(recipient_user_id, home_id)`

### GratitudeWallPersonalRead (new)
- `user_id` PK (FK `profiles`, cascade delete)
- `last_read_at` timestamptz default now()

## Mention rules (server-enforced)
- Publishing (wall + mentions) requires positive mood; otherwise `NOT_POSITIVE_MOOD`.
- Max mentions: 5 (after dedup). Error `MENTION_LIMIT_EXCEEDED`.
- Duplicates: rejected with `DUPLICATE_MENTIONS_NOT_ALLOWED`.
- Self mention: rejected with `SELF_MENTION_NOT_ALLOWED`.
- Membership: each mentioned user must be `memberships.is_current = true` for `home_id`; error `MENTION_NOT_HOME_MEMBER`.
- Existence: all mentioned users must exist in `profiles`; error `INVALID_MENTION_USER`.

## RPC surface (security definer, JSONB returns)
- `mood_submit_v2(home_id, mood, comment?, public_wall=false, mentions uuid[]?) -> jsonb { entry_id, public_post_id, mention_count }`
  - Guards: authenticated, current member, home active, non-null home/mood; ISO-week uniqueness (`MOOD_ALREADY_SUBMITTED`).
  - Behavior:
    - Always inserts weekly entry (trimmed comment <=500).
    - If neither public_wall nor mentions requested → returns entry only.
    - Publishing requires positive mood; otherwise `NOT_POSITIVE_MOOD`.
    - Home wall post: created when `public_wall=true` (idempotent via `source_entry_id`).
    - Home mentions: only when a post exists.
    - Personal inbox items: created per mention (positive mood only), “first publish wins” on `(recipient_user_id, source_entry_id)`.
  - Mention rules: positive-only publish, dedup, max 5, no self, membership + existence checks; see errors above.
  - Idempotency: `source_entry_id` uniqueness on posts and `(recipient_user_id, source_entry_id)` on personal items; advisory lock on entry_id during publish.

- Personal inbox/status RPCs:
  - `personal_gratitude_wall_status_v1() -> table(has_unread bool, last_read_at timestamptz)`; ignores self-authored items for unread.
  - `personal_gratitude_wall_mark_read_v1() -> bool` (upsert last_read_at=now()).
  - `personal_gratitude_inbox_list_v1(limit=30, before_at?, before_id?) -> table(...)` newest-first; cursor requires both `before_at` and `before_id`; resolves author username/avatar live.
  - `personal_gratitude_showcase_stats_v1(exclude_self=true) -> jsonb { total_received, unique_individuals, unique_homes }`.

- Legacy RPCs unchanged: `mood_submit`, `mood_get_current_weekly`, `gratitude_wall_list`, `gratitude_wall_mark_read`, `home_nps_get_status`, `home_nps_submit`.

## RLS / access
- RLS enabled on gratitude wall, mentions, personal items, personal reads, home_mood_entries, wall_reads.
- Table privileges revoked for anon/authenticated; no direct table policies defined (access only via SECURITY DEFINER RPCs).

## Non-scope (v1)
- No negative/neutral mentions.
- No edit/delete of gratitude items.
- No mention limits beyond max=5 and membership checks.
- No push notifications; read state is per-surface only.

## Testing invariants (v2)
- Weekly uniqueness: second submit in same ISO week → `MOOD_ALREADY_SUBMITTED`.
- No publish path: `public_wall=false`, mentions empty → entry only; post_id null; mention_count 0.
- Positive publish: `public_wall=true`, mood positive → post created (source_entry_id set); repeat call does not create duplicate post.
- Positive mentions (with or without wall): personal items created once per recipient; mention_count matches deduped payload; repeat call does not duplicate.
- Non-positive publish attempt: any publish flag or mentions with non-positive mood → `NOT_POSITIVE_MOOD`; no artifacts created.
- Mention rules: duplicates → `DUPLICATE_MENTIONS_NOT_ALLOWED`; >5 → `MENTION_LIMIT_EXCEEDED`; self → `SELF_MENTION_NOT_ALLOWED`; non-member or missing profile → `MENTION_NOT_HOME_MEMBER`/`INVALID_MENTION_USER`.
- Advisory lock/idempotency: concurrent publish for same entry_id does not produce duplicates.
- Personal status: unread=true when newer item exists (excluding self-authored); mark_read clears has_unread.
- Inbox pagination: both-or-neither cursor enforced (`INVALID_PAGINATION_CURSOR`); ordering `(created_at desc, id desc)` stable.
- Showcase stats: counts respect `exclude_self` flag.
