---
Domain: Shared
Capability: Today House Norms Member Review
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly Today House Norms Member Review Contract v1

Status: Proposed (Home MVP)

Scope: Today card notification for non-owner home members when house norms
have been created or updated, including view tracking and 24-hour debounce.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Norms v1 (storage model, `last_edited_at`, `generated_at`)
- Homes v2 (memberships + roles)
- Today surface (card registration)
- Kinly product philosophy (care, not control)

1. Purpose

Non-owner home members should be gently made aware when house norms are
created or updated. A Today card notifies members after a 24-hour debounce
window following the last edit, giving the owner time to finish making
changes before members are prompted to review.

This card exists to support shared understanding, not to pressure members.

2. Eligibility and Visibility

2.1 Show condition (all required)
- Caller is authenticated.
- Caller is a current member of the active home.
- Caller role is NOT `owner`.
- House norms exist for the home (`house_norms != null`).
- `norms_change_at = coalesce(last_edited_at, generated_at)` is not null.
- `now() >= norms_change_at + interval '24 hours'` (debounce window has
  elapsed).
- Either:
  - No `house_norms_member_views` row exists for this member, OR
  - `viewed_at < norms_change_at`.

2.2 Hide conditions
- Caller is the home owner.
- No house norms exist for the home.
- `norms_change_at` is null.
- Current time is within 24 hours of `norms_change_at` (debounce active).
- `viewed_at >= norms_change_at` (member has already reviewed).

2.3 Debounce rationale
If the owner makes multiple edits in a short period, the 24-hour window
resets with each edit (since `last_edited_at` updates). This ensures members
receive at most one card per editing session rather than one per individual
edit.

2.4 Deduplication
- At most one "Review House Norms" card per home per member at any time.
- The card MUST NOT re-appear for the same edit batch once the member has
  viewed the norms.

2.5 Canonical frontend signal
- Frontend MUST use backend-computed `show_member_review_card` from
  `house_norms_get_for_home`.
- Frontend MUST NOT re-implement debounce or comparison logic in client code.
- Frontend MAY still read `last_edited_at`, `generated_at`, and
  `member_viewed_at` for diagnostics, but visibility authority is
  `show_member_review_card`.

2.6 API binding
- Visibility data binds to the existing `house_norms_get_for_home` RPC.
- The RPC response MUST include `member_viewed_at` (timestamptz | null) for
  the calling member when the caller is a non-owner.
- The RPC response MUST include `show_member_review_card` (boolean), computed
  by backend rules in this contract.
- No Today-specific RPC is required for visibility in v1.

3. Card Presentation

3.1 Tone and semantics
- Card MUST be calm and non-urgent.
- Card MUST NOT imply the member is behind, non-compliant, or negligent.
- Card MUST NOT use setup-completion metaphors (no progress rings, no
  checklists).
- Card MUST NOT use enforcement language ("must read", "action required").
- Suggested framing: "Your home's shared norms were recently updated."

3.2 Placement
- Card appears in Today among low-pressure contextual cards.
- Card MUST NOT dominate primary operational tasks (chores, expenses).

4. Interaction

4.1 Primary action
- Tapping the card navigates to the house norms view screen for the same
  home.
- Navigation MUST open the full norms document, not a summary or snippet.

4.2 View recording
- When the member opens the house norms screen (via this card or any other
  entry point), the client MUST call `house_norms_record_view(p_home_id)`.
- This upserts the member's `viewed_at` timestamp.
- On next Today refresh, the card disappears because
  `viewed_at >= norms_change_at`.

4.3 No member action channel
- The card MUST NOT offer edit, comment, suggest, or request-change actions.
- Members view norms read-only, consistent with House Norms v1 permissions.

5. Storage (defined in House Norms v1)

5.1 Table: `house_norms_member_views`
- `home_id` (uuid, FK homes)
- `user_id` (uuid, FK auth.users)
- `viewed_at` (timestamptz)
- PK: (`home_id`, `user_id`)

One row per member per home. Upserted on each view.

5.2 RPC: `house_norms_record_view`
- `house_norms_record_view(p_home_id uuid) -> jsonb`
- Caller MUST be authenticated.
- Caller MUST be a current home member.
- Upserts `house_norms_member_views` with `viewed_at = now()`.
- Returns `{ "ok": true, "viewed_at": "<timestamptz>" }`.

5.3 Extended response: `house_norms_get_for_home`
- When the caller is a non-owner member, the response MUST additionally
  include:
  - `member_viewed_at` (timestamptz | null): the caller's most recent
    `viewed_at` from `house_norms_member_views`, or null if no view record
    exists.
  - `show_member_review_card` (boolean): backend visibility decision for the
    member review card.

6. Edge Cases

6.1 New members
- A member who joins a home after norms were created will have no
  `house_norms_member_views` row.
- The card will appear for them (once past the debounce window) since
  `viewed_at` is effectively null.

6.2 Owner transfers
- If ownership transfers, the new owner stops seeing the card (owner
  exclusion rule).
- The former owner (now a regular member) becomes eligible if they have not
  viewed the latest norms.

6.3 Member removal
- `house_norms_member_views` rows for removed members MAY be retained or
  cleaned up. No functional impact since removed members cannot access the
  home.

7. Non-Goals

- Notifying members about draft changes before the owner finishes editing.
- Push notifications for norms updates (Today card only in v1).
- Tracking how long a member spent reading norms.
- Member acknowledgment or sign-off workflows.
- Surfacing a specific diff of what changed.

8. Invariants

- The Today card is a gentle awareness prompt, not a compliance mechanism.
- Only non-owner members see the card.
- The 24-hour debounce prevents notification spam from rapid owner edits.
- View tracking is a timestamp, not a read-receipt or acknowledgment.
- No Kinly feature MAY be gated on whether a member has viewed norms.
