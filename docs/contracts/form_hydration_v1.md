# Kinly Form Hydration Contract v1

Status: Draft for MVP (home-only)

Scope: Local draft hydration for multi-step forms (Personal Preferences, House Rules).

Audience: Product, design, engineering, AI agents.

1. Goal

Ensure users never lose progress in multi-step forms when:
- going offline
- the app is backgrounded or killed
- the user leaves and returns later

The experience must feel:
- automatic
- invisible
- safe
- non-destructive

If a draft exists, resume it automatically. If not, start fresh.
No prompts or decisions are required.

2. In Scope

2.1 Personal Preferences
- Shown once per user
- Multi-step
- Local draft only
- Submitted once (or very rarely)

2.2 House Rules
- Shown once per home
- Multi-step
- Local draft only
- Draft cleared when the active home changes

3. Out of Scope
- Server syncing
- Collaborative editing
- Conflict resolution
- Draft selection UX
- Multiple drafts
- Draft history
- Large collections
- Attachments or media blobs

4. Core Principles

4.1 Hydration is local only
- Hydrated state lives on device only
- It is never authoritative
- It is never shared
- It is never synced

4.2 Auto-resume always
- If a hydrated draft exists, restore it automatically
- Land on the last completed step
- No resume or start-over prompt

4.3 Back or forward is never discard
- Users can move back and forward between steps
- Users can edit answers at any time
- No explicit discard UI required for v1

4.4 Draft resets are system-driven
- Drafts are cleared only when:
  - submission succeeds
  - user logs out
  - active home changes (house rules only)
  - hydration schema mismatch (local reset)

5. Architecture

5.1 Blocs
Form | Bloc type
- Personal Preferences | HydratedBloc
- House Rules | HydratedBloc

Each bloc:
- Extends HydratedBloc<Event, State>
- Serializes only form state
- Contains no server models

6. Storage Keys (simple and stable)

Personal Preferences
`kinly_formdraft::personal_preferences::<userId>`

House Rules
`kinly_formdraft::house_rules::<homeId>`

No draftId. One draft max per scope.

7. State Model (minimal)

Shared fields (both forms)
- schemaVersion: int (local only, v1 = 1)
- currentStep: int
- isDirty: bool
- lastEditedAt: ISO8601

Personal Preferences fields
- Typed preference values (bool, enum, string)
- Bounded free text (limits enforced elsewhere)

House Rules fields
- Rule toggles (ruleKey to bool)
- Custom rule text (bounded count and length)
- Acknowledgement flags

Explicitly NOT allowed in state
- Server responses
- Home objects
- User objects
- Counters
- Derived analytics
- Large lists

8. Lifecycle Behavior

8.1 On bloc creation
- Attempt to restore hydrated state
- If state exists and isDirty is true, restore it
- Otherwise start fresh at step 0

8.2 On field change
- Update field
- Mark isDirty true
- Update lastEditedAt
- Hydration writes automatically

8.3 Navigation (back or forward)
- Purely in-memory transitions
- State remains hydrated continuously
- No side effects

8.4 Submission flow
- Validate all steps
- Submit to server
- On success:
  - clear hydrated storage
  - reset bloc state
  - continue navigation
- On failure:
  - keep hydrated draft intact

9. Home Change Rules

House Rules
- When active home changes:
  - clear hydrated state
  - reset bloc
  - start from step 0

Personal Preferences
- Unaffected by home changes
- Scoped only to user

10. Logout Rules

On logout:
- Clear all hydrated form drafts
- No draft may restore for another user

11. Schema Versioning (local only)

schemaVersion exists only to protect against local state shape changes.
There is no server dependency.

Behavior:
- If fromJson detects mismatch, discard hydrated state
- Return initial state
- Do not crash
- Do not attempt migration (v1)

12. UX Requirements

- No resume prompt
- No discard button required
- No warnings on exit
- Draft saving is silent and automatic

Optional (future):
- Overflow menu: Reset answers

13. Observability (dev only)

Log events:
- form_draft_restored
- form_draft_cleared_on_submit
- form_draft_cleared_on_home_change
- form_draft_schema_reset

Include:
- form type
- scope id (hashed)
- schema version

14. Acceptance Criteria

- User can complete part of a form, close the app, and continue later.
- No draft ever restores for the wrong user or home.
- Submitting successfully always clears the draft.
- Home switching always resets house rules drafts.
- No UX decisions are required from the user to resume.

15. Summary Rule

If the user was in the middle of something, put them back exactly there.
