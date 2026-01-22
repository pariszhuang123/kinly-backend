# Kinly Hub Personal Preferences Visibility Contract v1

Status: Proposed (MVP)

Scope: Hub surface visibility and access rules for personal preference reports.

Audience: Product, design, engineering, AI agents.

Depends on:
- Preference Reports v1
- Home Dynamics Contract v1
- Homes v2 (memberships)

1. Purpose

The Hub is a shared, low-pressure space for relational context in a home. It
surfaces personal preferences to support understanding and empathy without
creating rules, obligations, or automated behavior changes.

2. Eligibility and Visibility

2.1 When the Personal Preferences slot appears
- The Hub MAY show a Personal Preferences slot only when at least one published
  preference report exists for the current home_id.
- Reports with status out_of_date MUST NOT appear in the Hub.
- If no published reports exist, the Hub MUST show no slot, placeholder, or CTA.
  Absence is intentional.

2.2 Who can see the slot
- All current members of an active home MAY see the Personal Preferences slot.
- Visibility is read-only at the group level.
- Editing rights are strictly individual (subject-only).

3. Data Access and APIs

The Hub uses existing RPCs; no additional API contracts are required.

- preference_reports_list_for_home(home_id, template_key, locale)
  - Used to determine if any published reports exist for the home.
  - Returns report ids + subject_user_id for current members with published
    reports.

- members_list_active_by_home(home_id, exclude_self)
  - Used to render cards (avatar, display name, role).
  - Owner crown is derived from membership role, not the report.

- preference_reports_get_for_home(home_id, subject_user_id, template_key, locale)
  - Used to fetch the published report for the detail view.

- preference_reports_edit_section_text(template_key, locale, section_key, new_text, change_summary)
  - Subject-only edit action for personal sections.

- preference_reports_acknowledge(report_id)
  - Optional read receipt; no UI requirement in Hub.

4. Hub Slot Presentation

4.1 Visual semantics
- Use a distinct, calm color that is not shared with Bills or Flows.
- Avoid urgency or action signaling.
- Slot appears only in Hub, never in Explore.

4.2 Slot copy
- Copy must reinforce understanding, not rules or standards.
- Allowed intent examples:
  - "How each person experiences shared living."
- Disallowed intent:
  - "House standards"
  - "Preferences applied"
  - "Guidelines"

5. Personal Preferences Card Grid

5.1 Card contents
- Avatar
- Display name (profile username or equivalent display name)
- Owner indicator (crown) if the member role is owner

5.2 Forbidden card content
- Completion state
- Last updated timestamps
- Status badges
- Comparison indicators

5.3 Owner indicator semantics
- The owner crown is contextual only.
- It does not grant any additional preference-related actions.

6. Preference Detail View

6.1 Viewing another person
- Read-only view.
- No edit affordances.
- Copy reinforces understanding, not expectation.

6.2 Viewing yourself
- Edit action may be shown.
- Edits affect only the current user's report.
- No user may edit another person's report (including the owner).

7. Empty States

7.1 Hub empty state
If the Hub contains no gratitude posts, no preference reports, and no house
rules, the surface remains visually empty. A single low-weight explanatory line
MAY be shown. It MUST NOT prompt action or guilt.

Allowed intent:
- "This space reflects moments of care and understanding in your home."

7.2 No partial empty indicators
- Do not highlight which members have not completed preferences.
- Do not show progress metaphors or missing counts.

8. Separation of Concerns

- Hub contains relational artifacts; Explore contains operational systems.
- Personal Preferences must not surface in Explore.
- Preferences must not affect Bills, Flows, or automation.

9. Non-Goals

- Applying preferences automatically
- Enforcing preferences as rules
- Blocking actions based on preferences
- Scoring or ranking comfort styles
- Treating preferences as house agreements

10. Invariant

Personal Preferences exist to increase empathy, not compliance. Any
implementation that violates this principle breaches the contract.
