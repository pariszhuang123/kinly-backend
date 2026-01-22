# Kinly Preference Interpretation & Scenarios Contract v1

Status: Proposed (MVP)

Scope: Home-only personal preference capture, interpretation, and aggregation.

Audience: Product, design, engineering, AI agents.

Depends on:
- Preference Taxonomy v1
- Home Dynamics Contract v1

1. Purpose

This contract defines how personal preferences are expressed, interpreted, and
safely aggregated in Kinly.

It standardizes:
- scenario-based preference capture
- implicit preference intensity (without numeric strength)
- non-enforceable interpretation rules
- aggregation constraints into Home Vibe

This contract applies only to personal preferences. It does not define rules,
permissions, enforcement, or eligibility.

2. Core Principles

2.1 Nature of Preferences
- Preferences are self-reported comfort ranges, not demands.
- Preferences are descriptive, not prescriptive.
- Preferences do not imply obligation, permission, or enforcement.
- Preferences do not auto-convert into rules.

2.2 Intensity & Strength (Explicit Clarification)
- Preference "intensity" reflects how narrow or wide a person's comfort range is.
- Intensity is implicit, derived from the selected option.
- Intensity is not priority, importance, or urgency.
- No preference is treated as more valid than another.
- Strongly felt preferences must surface via phrasing, not policy.

2.3 Absence & Silence
- Absence of a preference implies flexibility, not indifference.
- Users are never penalized for skipping preferences.

3. Scenario-Based Capture Model

3.1 Structure
Each preference is captured via:
- One contextual scenario.
- Exactly three response options.
- Ordered from narrow comfort -> balanced -> wide comfort (or inverse where
  appropriate).
- Option index maps to `preference_taxonomy_defs.value_keys` in order (0..2).

No scenario may:
- Use enforcement language.
- Ask for deal-breakers.
- Ask users to rank importance.
- Reference other people's behavior.

4. Canonical Preference Scenarios (v1)

Each scenario maps 1:1 to a taxonomy ID.

```preference-scenarios-json
{
  "items": [
    {
      "id": "environment_noise_tolerance",
      "domain": "environment",
      "mapsToPreferenceId": "environment_noise_tolerance"
    },
    {
      "id": "environment_light_preference",
      "domain": "environment",
      "mapsToPreferenceId": "environment_light_preference"
    },
    {
      "id": "environment_scent_sensitivity",
      "domain": "environment",
      "mapsToPreferenceId": "environment_scent_sensitivity"
    },
    {
      "id": "schedule_quiet_hours_preference",
      "domain": "schedule",
      "mapsToPreferenceId": "schedule_quiet_hours_preference"
    },
    {
      "id": "schedule_sleep_timing",
      "domain": "schedule",
      "mapsToPreferenceId": "schedule_sleep_timing"
    },
    {
      "id": "communication_channel",
      "domain": "communication",
      "mapsToPreferenceId": "communication_channel"
    },
    {
      "id": "communication_directness",
      "domain": "communication",
      "mapsToPreferenceId": "communication_directness"
    },
    {
      "id": "cleanliness_shared_space_tolerance",
      "domain": "cleanliness",
      "mapsToPreferenceId": "cleanliness_shared_space_tolerance"
    },
    {
      "id": "privacy_room_entry",
      "domain": "privacy",
      "mapsToPreferenceId": "privacy_room_entry"
    },
    {
      "id": "privacy_notifications",
      "domain": "privacy",
      "mapsToPreferenceId": "privacy_notifications"
    },
    {
      "id": "social_hosting_frequency",
      "domain": "social",
      "mapsToPreferenceId": "social_hosting_frequency"
    },
    {
      "id": "social_togetherness",
      "domain": "social",
      "mapsToPreferenceId": "social_togetherness"
    },
    {
      "id": "routine_planning_style",
      "domain": "routine",
      "mapsToPreferenceId": "routine_planning_style"
    },
    {
      "id": "conflict_resolution_style",
      "domain": "conflict",
      "mapsToPreferenceId": "conflict_resolution_style"
    }
  ]
}
```

environment_noise_tolerance
Scenario
When there's background noise in shared spaces, what usually feels okay for you?

Options
1) I'm most comfortable when things are generally quiet
2) A moderate level of everyday noise feels fine
3) Noise doesn't bother me much - lively spaces are okay

environment_light_preference
Scenario
In shared areas, what kind of lighting do you tend to feel most comfortable with?

Options
1) Softer or dimmer lighting
2) Balanced, natural lighting
3) Bright, well-lit spaces

environment_scent_sensitivity
Scenario
How do you generally experience strong or lingering scents at home (e.g. candles, cooking smells, detergents, pets)?

Options
1) I'm quite sensitive
2) I’m usually okay
3) I’m rarely bothered

schedule_quiet_hours_preference
Scenario
As the day winds down, what usually feels okay to you at home?

Options
1) Earlier evenings tend to be quieter for me
2) Later evenings or nights tend to be quieter for me
3) I don't usually need quiet hours

schedule_sleep_timing
Scenario
When do you usually feel most in sync with your sleep routine?

Options
1) Earlier nights and mornings
2) Somewhere in the middle
3) Later nights and mornings

communication_channel
Scenario
If something needs coordinating at home, what usually works best for you?

Options
1) Messaging or text
2) A quick call feels easiest
3) Talking in person when it comes up

communication_directness
Scenario
When something small is on your mind, how do you naturally prefer to express it?

Options
1) Gently, with context or easing in
2) A mix - it depends on the situation
3) Directly and clearly

cleanliness_shared_space_tolerance
Scenario
In shared spaces, what level of tidiness feels comfortable for you?

Options
1) I feel best when things are kept fairly tidy
2) Some clutter is okay day-to-day
3) I'm relaxed about mess in shared areas

privacy_room_entry
Scenario
When it comes to entering each other's rooms or personal areas, what feels right
to you?

Options
1) I prefer people to ask or knock first
2) Asking is nice, but flexibility is okay
3) I'm generally comfortable with open access

privacy_notifications
Scenario
How do you feel about messages or notifications late at night?

Options
1) I prefer not to be contacted after quiet hours
2) Limited or important messages are okay
3) I'm fine being contacted anytime

social_hosting_frequency
Scenario
How do you generally feel about guests coming over to the home?

Options
1) I'm most comfortable with guests being rare
2) Occasional guests feel fine
3) Frequent guests are okay with me

social_togetherness
Scenario
At home, what balance usually feels best for you?

Options
1) Mostly doing my own thing
2) A mix of shared time and solo time
3) Spending time together often

routine_planning_style
Scenario
When it comes to daily life at home, what feels most natural to you?

Options
1) Having plans and structure helps me
2) A mix of planning and spontaneity
3) Going with the flow feels best

conflict_resolution_style
Scenario
If something feels a bit off between people at home, what usually helps you most?

Options
1) Taking time to cool off first
2) Gently checking in at the right moment
3) Talking it through sooner rather than later

5. Interpretation Rules (AI + Product)
- Preferences must be interpreted in aggregate only.
- Never surface single-user preferences when member count < 3.
- Never phrase outputs as instructions.
- Never infer compliance, responsibility, or fault.
- Mixed extremes must be phrased as "varied" or "mixed".

Approved phrasing patterns:
- "Some people here prefer..."
- "This home tends to..."
- "Preferences vary across the home..."

6. Aggregation Constraints
- Preferences may inform Home Vibe, not Home Rules.
- Aggregation is distribution-aware, never winner-takes-all.
- Recalculation occurs on: member join, member leave, preference update.

7. Explicit Non-goals
- No numeric strength or priority fields.
- No deal-breakers.
- No identity, medical, or diagnostic inference.
- No gating, enforcement, or eligibility logic.
- No automatic rule suggestion.

8. Governance & Versioning

Owners:
- Product: semantic meaning and scope.
- Design: phrasing and UX safety.
- Engineering: schema and enforcement.
- Docs: versioning and change log.

Versioning:
- Scenario wording may change without version bump.
- Taxonomy IDs are immutable.
- New scenarios require v2 + ADR.
- Deprecations must be non-breaking.

9. Contract Schema (Reference)

```contracts-json
{
  "domain": "preference_scenarios",
  "version": "v1",
  "entities": {
    "PreferenceScenario": {
      "id": "text",
      "domain": "text",
      "scenario": "text",
      "options": "text[3]",
      "mapsToPreferenceId": "text",
      "intensityModel": "implicit",
      "enforceable": false
    }
  },
  "functions": {},
  "rls": []
}
```

Final Note

This contract intentionally does not try to capture everything. It captures what
is safe, stable, and meaningful at home scale. That restraint is a feature, not
a limitation.
