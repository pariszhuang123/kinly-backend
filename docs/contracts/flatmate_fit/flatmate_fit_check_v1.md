---
Domain: Homes
Capability: Flatmate Fit Check
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v3.6
---

# Kinly Flatmate Fit Check Contract v3.6

Status: Draft

Scope: Owner-first pre-interview screening tool. Captures a home's living
style via behavioural scenario questions, collects anonymous candidate
responses, and generates a briefing for the head tenant on what to be
aware of and what to ask before the interview.

Audience: Product, design, engineering, AI agents.

Platform: Web (must be web-accessible). Must be i18n-ready from day one.

Depends on:
- House Norms Taxonomy v1 (`contracts/product/kinly/shared/house_norms_taxonomy_v1.md`)
- House Norms Scenarios v1 (`contracts/product/kinly/shared/house_norms_scenarios_v1.md`)

## 1. Purpose

The Flatmate Fit Check gives a head tenant (or lived-in landlord) a
structured way to screen applicants before an interview.

This helps surface issues that are usually invisible during interviews
but often become ongoing friction after move-in.

The system:
1. Captures the home's living style via behavioural scenario questions
2. Collects the same scenarios from the candidate (anonymous)
3. Generates a **pre-interview briefing** for the owner: what to be aware
   of + what questions to ask to confirm
4. May show a candidate-specific **Alignment Preview** to help the owner
   understand where living-style expectations already line up
5. After login, gives the owner an app inbox for all candidate
   submissions tied to that fit-check draft
6. After login, stores the owner's answers so they can later prefill
   House Norms and personal preference flows (but does not auto-write
   to those systems)

## 2. Core Product Principle

This is an **owner-first screening tool**.

Value flows to the head tenant / lived-in landlord. The candidate
participates, but the product does not promise the candidate independent
value.

The system focuses on identifying where day-to-day friction is most
likely to occur, rather than evaluating whether someone is a "good" or
"bad" fit.

It is NOT:
- A mutual compatibility tool
- A scoring, ranking, or gatekeeping system
- A replacement for conversation or interviews

## 3. Problem Definition

Head tenants and lived-in landlords:
- Receive multiple applicants
- Rely on gut feel and repeated conversations
- Often discover lifestyle mismatches after move-in

This system gives the owner a structured briefing on what to explore
before committing, based on how the applicant answered the same living
scenarios.

## 4. Scope

### Included
- Behavioural scenario-based question capture (3 options per question)
- Anonymous candidate response flow
- Owner pre-interview briefing (alignments, watchouts, suggested
  questions, and temporary candidate-specific alignment preview)
- Anonymous → authenticated conversion
- Persistent storage of owner answers for later prefill into House Norms

### Excluded
- Financial verification (bond, job checks)
- Legal tenancy processes
- Personality matching or scoring
- Ranked applicant lists or sorting by fit
- Candidate-facing compatibility or comparison results
- Direct writes to `house_norms` or `preference_responses` (see §7)

## 5. Questions: Behavioural Scenario Capture

### 5.1 Design Principles

Questions are behavioural, not moral or preferential:
- Ask what the person **usually does**, not what they believe is right
- Use the same phrasing for owner and candidate (no insider/outsider
  framing problem)
- Each question targets a specific **friction type** (expectation gap,
  timing collision, ownership model, friction style)
- Exactly 3 options per question (matches Kinly scenario convention)
- Options ordered from most structured/proactive (index 0) to most
  relaxed/avoidant (index 2)
- No enforcement language, no deal-breakers, no importance ranking

### 5.2 Fit Check Taxonomy

The Fit Check uses its own behavioural taxonomy with 4 scenario IDs.
Each has exactly 3 options, mapping 1:1 to a house norms dimension
(see §7.2).

| ID | Friction Type | Options (index 0–2) |
|---|---|---|
| `fit_cleanliness` | Expectation gap | `clean_immediately`, `clean_later`, `leave_unless_mine` |
| `fit_rhythm` | Timing collision | `quiet_early`, `chill_media`, `social_late` |
| `fit_chores` | Ownership model | `roster_system`, `take_initiative`, `own_things_only` |
| `fit_conflict` | Friction style | `raise_early`, `wait_then_raise`, `avoid_unless_serious` |

### 5.3 Canonical Scenarios (v1)

Both the owner and candidate answer the **same 4 questions with the same
wording**.

#### `fit_cleanliness` — Expectation Gap

Scenario:
> "When the kitchen is messy, what do you usually do?"

Options:
- `0`: "Clean it straight away"
- `1`: "Leave it a while, then clean it"
- `2`: "Leave it unless it's mine"

Reveals: cleanliness threshold — the #1 source of flatmate conflict.

#### `fit_rhythm` — Timing Collision

Scenario:
> "What does a normal weekday night look like for you?"

Options:
- `0`: "Quiet, early night"
- `1`: "Chill — TV or music"
- `2`: "Social or late nights"

Reveals: energy mismatch and sleep disruption risk.

#### `fit_chores` — Ownership Model

Scenario:
> "How do you prefer shared chores to work?"

Options:
- `0`: "Roster or system"
- `1`: "Take initiative when needed"
- `2`: "Only handle my own things"

Reveals: system vs chaos tolerance and future resentment risk.

#### `fit_conflict` — Friction Style

Scenario:
> "If something bothers you about a housemate, what do you usually do?"

Options:
- `0`: "Bring it up early"
- `1`: "Wait a bit, then raise it"
- `2`: "Avoid it unless it's serious"

Reveals: communication style mismatch and silent tension risk.

### 5.4 Internationalisation

Scenario prompts and option labels MUST NOT be hardcoded in application
logic.

Requirements:
- All scenario prompts and options are resolved from template data by
  `locale`
- Fit check scenario IDs and option keys are stable across locales
- Only the display strings change per locale
- Fallback locale: `en`
- Template keys:
  - `fit_check.scenario.{id}.prompt`
  - `fit_check.scenario.{id}.option.{index}`

Since both parties see the same wording, there is only one set of
scenario templates (no owner/candidate variants needed).

## 6. Functional Flow

### 6.1 Owner Flow (No Login Required)

**Step 1 — Entry (web)**

Owner sees scenario framing:
> Template key: `fit_check.owner.entry_prompt`
> (en: "Quick check to spot potential issues before inviting someone to
> view")

**Step 2 — Answer 4 scenarios**

Owner answers 4 behavioural questions. Each answer stores a
`scenario_id` + `option_index` (0, 1, or 2).

**Step 3 — Immediate output**

System generates a home vibe summary from captured values.

Output uses template keys per dimension, resolved by locale and
option_index. In the current backend implementation, owner summary
labels reuse the scenario option template keys rather than a separate
summary namespace. Example (en):

> "Cleans straight away · Quiet early nights · Roster system · Raises
> things early"

**Step 4 — Share link**

System creates a `fit_check_share_token` and displays a shareable URL.

The owner's browser session stores opaque references to a server-side
draft and claim token. The owner is informed:

> Template key: `fit_check.owner.save_prompt`
> (en: "Continue in the app to save your results and see candidate
> briefings later")

### 6.2 Candidate Flow (Anonymous, Web)

**Step 1 — Open shared link**

Candidate sees scenario framing:
> Template key: `fit_check.candidate.entry_prompt`
> (en: "Answer a few quick questions about how you live day-to-day")

The candidate MUST NOT see the owner's answers or the home vibe summary
before submitting.

**Step 2 — Identify self + answer scenarios**

Before answering the scenarios, the candidate MUST provide:
- `display_name` (required)

`display_name` is a lightweight identifier shown to the owner so the
owner can distinguish submissions during review. It is not an
authentication mechanism.

The candidate MAY also provide an optional contact method in a future
version, but contact details are out of scope for v1.

**Step 3 — Answer same 4 scenarios**

Candidate answers the same 4 questions (same wording). Stored in
`candidate_fit_submissions`.

**Step 4 — Location capture (required)**

Immediately after the candidate answers the final scenario question, and
before any confirmation or personalized result is shown, the candidate
MUST complete a location step.

Required fields:
- `country_code` (required)
- `city_name` (required)

Rules:
- This step MUST happen after the last scenario question and before the
  candidate-specific result is rendered
- `country_code` and `city_name` MUST appear on the same page
- `country_code` MUST be pre-selected using IP-based geolocation from
  the web edge/runtime layer (for example, Vercel request geolocation)
- The candidate MUST be able to change the pre-selected country if the
  inferred country is wrong
- `city_name` MUST start empty even when `country_code` is pre-selected
- The client MUST fetch or query country-scoped city options using the
  currently selected `country_code`
- `city_name` MUST be selected from a country-scoped city list
- If the user changes `country_code`, the client MUST clear the current
  `city_name` value and reload city options for the new country
- The city picker SHOULD use search/typeahead behaviour rather than
  rendering a full long dropdown for all cities
- The UI MAY visually show a curated "important cities" section first,
  followed by other matching cities for the selected country
- Location is collected to improve the usefulness and relevance of the
  candidate-specific informational result content

This step MUST NOT reveal owner answers or comparison output.

**Step 5 — Confirmation**

Candidate sees a simple confirmation:
> Template key: `fit_check.candidate.submitted`
> (en: "Thanks — this helps the household understand how you live
> day-to-day and makes things easier once you move in.")

The candidate does NOT receive a compatibility result, watchouts about
the owner, or suggested interview questions. This is an owner-first
tool.

**Step 6 — Personalized result page + CTA (non-blocking)**

After submission, the candidate MUST land on a candidate-specific
post-submit page for that submission.

This page is personalized to the candidate's own answers, but remains
strictly non-comparative.

The page MAY show:
- a lightweight self-reflection
- a short description of the kind of living environment their answers
  suggest they usually prefer
- localized informational content shaped by `country_code` and
  `city_name`
- a prompt to continue into Kinly

The page MUST NOT show:
- owner answers
- owner watchouts
- owner suggested interview questions
- candidate ranking
- compatibility or comparison against the owner
- compatibility or comparison against other candidates

The personalized page is intended to make the flow feel complete for the
candidate and provide a natural handoff into Kinly, without exposing any
owner-only screening output.

Example (en):
> "People who answered like you usually prefer flexible living
> environments."

CTA:
> Template key: `fit_check.candidate.create_own_cta`
> (en: "Looking for a place to live? Explore Kinly and download the app")

This step MUST:
- Not reveal owner answers
- Not show compatibility or comparison results
- Not imply acceptance, rejection, or ranking
- Route to a renter/prospective-tenant landing page or app download path

### 6.2A Candidate Conversion Framing

Candidate conversion SHOULD come from immediate personal value, not from
withholding basic completion state.

Recommended framing:
- "Save your answers in Kinly"
- "Keep your living-style profile for future homes"
- "Continue in the app if you want to reuse this later"

Candidate conversion MUST NOT depend on promising access to owner-only
briefings or cross-candidate comparisons.

### 6.3 Owner Briefing (Core Output)

When the owner views a candidate's submission, the system generates a
**pre-interview briefing**. This is the primary value of the product.

#### 6.3.1 Briefing Structure

The briefing contains:

0. **Context** (always shown)

> Template key: `fit_check.briefing.context`
> (en: "Most issues in shared homes aren't big — they're small things
> repeated daily. The points below are where differences may show up.")

1. **Alignments** — dimensions where both answered the same (distance = 0)
2. **Watchouts** — dimensions where answers differ, with plain-language
   description of the gap and what friction type it signals
3. **Suggested questions** — 1–2 conversational questions per watchout,
   designed to probe tolerance and importance
4. **Alignment Preview** — an owner-only, candidate-specific summary of
   where the candidate already appears compatible with the owner's
   day-to-day living style

#### 6.3.1A Alignment Preview Boundaries

The Alignment Preview is optional briefing output. If shown, it MUST be:
- candidate-specific
- temporary
- non-binding
- framed as interview preparation, not as acceptance guidance
- clearly separate from canonical House Norms

The Alignment Preview MUST NOT:
- rank candidates
- act as a decision or approval signal
- create or update canonical `house_norms`
- be treated as a persisted home-level agreement

If the owner later chooses a candidate, the owner MAY use the Fit Check
outcome as reference material when completing House Norms, but House
Norms remains the single canonical home-level source of truth.

#### 6.3.2 Comparison Logic

Each question's options are ordinal (index 0, 1, 2).

```
distance = |owner_index - candidate_index|
```

| Distance | Label | Briefing Framing |
|---|---|---|
| 0 | Aligned | No friction expected |
| 1 | Noticeable difference | Likely to show up in day-to-day living |
| 2 | Friction risk | Common source of tension in shared homes |

#### 6.3.3 Priority Order

When multiple watchouts exist, surface them in this order:
1. `fit_cleanliness` (highest real-world friction)
2. `fit_rhythm`
3. `fit_chores`
4. `fit_conflict`

The system MUST highlight the top 1–2 highest-risk watchouts as primary
focus areas for the interview.

#### 6.3.4 Limitations

The comparison model is deliberately simple. Known limitations:
- Assumes equal spacing between options (0→1 ≈ 1→2)
- Treats mismatches symmetrically regardless of direction
- Captures behaviour, not tolerance — someone who usually does X may be
  comfortable living with Y

These are acceptable because the output is a briefing (what to ask), not
a verdict.

Alignment Preview follows the same rule: it is guidance for
conversation, not a binding compatibility result.

### 6.4 Owner Review and Notifications

Owners MUST have a way to review candidate submissions after claim.

The owner review surface is a required product outcome, not an optional
admin utility. It is the canonical place where the head tenant or
lived-in landlord sees all candidate submissions tied to the claimed
fit-check draft.

#### 6.4.1 Submission list

The owner review surface MUST show one row/card per candidate
submission.

The owner MUST be able to see every candidate submission linked to that
claimed draft from a single app inbox or review list.

Each submission card MUST include:
- `display_name`
- `country_code` and `city_name`, or a localized location label derived
  from them
- `submission_id` or another stable system-generated review identifier
- `submitted_at`
- A lightweight qualitative summary or top watchout preview
- A way to open the full briefing

The review surface MUST NOT show a ranked list of candidates by fit.
The review surface MUST treat `display_name` as a human label, not as a
guaranteed unique identifier. If multiple submissions have the same
`display_name`, the system MUST disambiguate them using `submitted_at`
and/or a stable system-generated review identifier.

#### 6.4.2 Full briefing view

The full briefing view MUST include:
- Candidate `display_name`
- Candidate `country_code`
- Candidate `city_name`
- Submission timestamp
- Candidate raw structured answers (`scenario_id` + `option_index`)
- Context
- Alignments
- Watchouts
- Suggested interview questions
- Alignment Preview when enabled
- Limitation disclaimer

Showing the candidate's raw structured answers to the owner is
acceptable in v1. The briefing remains the primary surface, but owners
MAY inspect the candidate's direct answers as supporting detail for
interview preparation.

#### 6.4.3 Notification model

The system SHOULD notify the owner when a new candidate submission is
available.

In v1:
- While the owner is on the active review surface, new submissions MAY
  appear via polling or refresh
- After the draft is claimed in app, the system MAY show an in-app
  notification or inbox/event badge for new submissions

Email notification is optional and secondary. Product MUST NOT rely on
email as the primary owner review mechanism because the core retained
value is the in-app inbox of applicant briefings.

Push notification delivery is optional and out of scope for v1.

### 6.5 Output Rules

#### Watchout Copy

MUST:
- Describe the difference in plain language
- Name the friction type it signals (expectation gap, timing collision,
  etc.)
- Clearly signal real-life friction risk, not just neutral difference
- Include a concrete day-to-day example of how the difference might
  show up
- Frame as something to explore in the interview
- Use template keys resolved by locale, scenario_id, direction, and
  distance

MUST NOT:
- Use scores, percentages, or technical language
- Blame either party
- Imply the candidate is unsuitable
- Reference protected characteristics or proxies

Watchouts SHOULD explicitly connect the difference to a likely emotional
response (e.g. frustration, annoyance, tension) where appropriate.

Example (en):
> **Cleanliness (expectation gap)**
> "You clean straight away — they leave it unless it's theirs. This is
> one of the most common sources of tension in shared homes. This might
> show up as dishes sitting longer than you're comfortable with, which
> can quickly become frustrating if it happens often."

#### Suggested Questions

Each watchout MUST include at least one suggested question.

Questions MUST:
- Be conversational
- Probe tolerance and importance, not just behaviour
- Use template keys (i18n-ready)

Examples (en):
> "What does clean enough look like to you?"
> "If dishes sit until the evening, is that fine or stressful?"
> "How would you prefer we handle it if something's bothering one of us?"

#### Watchout + Question Templates

All watchout descriptions and suggested questions MUST be template-driven:
- `fit_check.watchout.{scenario_id}.{direction}.{distance}`
- `fit_check.question.{scenario_id}.{variant}`
- Resolved by locale with `en` fallback

Canonical `direction` values:
- `owner_higher` when `owner_index > candidate_index`
- `candidate_higher` when `candidate_index > owner_index`

Canonical `distance` values for watchouts:
- `1`
- `2`

Distance `0` is not a watchout and MUST NOT use the watchout namespace.
If aligned copy is needed, it MUST use a separate namespace.

No hardcoded copy in application logic.

#### Briefing Limitation

The briefing MUST include a visible limitation disclaimer.

> Template key: `fit_check.briefing.limitation`
> (en: "This is a starting point — people can be flexible. Use this to
> guide the conversation, not make the decision.")

#### Interview Focus

> Template key: `fit_check.briefing.focus`
> (en: "If you only have time to cover a few things, start with the top
> watchouts above — these are the most likely to affect day-to-day
> living.")

#### Real-Life Framing

All outputs SHOULD prioritise real-life interpretation over abstract
terminology. Avoid relying solely on labels such as "expectation gap" or
"timing collision" without describing how the difference manifests in
daily living.

## 7. Downstream Data: Prefill, Not Auto-Write

### 7.1 Principle

The Fit Check does NOT directly write to `house_norms` or
`preference_responses`. Those systems have their own creation flows,
required fields, and lifecycle contracts that the Fit Check cannot
satisfy.

Instead, owner answers are stored in fit-check tables and made available
as **prefill data** for downstream flows.

### 7.2 House Norms Prefill

The Fit Check's 3-option behavioural taxonomy maps 1:1 to 4 of the 6
house norms directional dimensions:

| Fit Check ID | House Norms ID | 0 → | 1 → | 2 → |
|---|---|---|---|---|
| `fit_cleanliness` | `norms_shared_spaces` | `clear_now` | `reset_later` | `relaxed` |
| `fit_rhythm` | `norms_rhythm_quiet` | `wind_down` | `variable` | `flexible` |
| `fit_chores` | `norms_responsibility_flow` | `clear_agreements` | `notice_and_do` | `own_areas` |
| `fit_conflict` | `norms_repair_style` | `talk_soon` | `gentle_check_in` | `let_small_pass` |

When the owner later enters the standard House Norms creation flow, the
system MAY prefill these 4 dimensions using the mapping above.

If the owner later chooses a specific candidate, product MAY use the Fit
Check outcome for that candidate as supporting context to help seed the
subsequent House Norms flow. This remains advisory only and MUST NOT
replace explicit House Norms completion and confirmation.

Prefill MUST:
- Pre-select options in the UI, not skip them
- Allow the owner to change any prefilled answer
- Not create any `house_norms` row until the full creation flow completes

The system MUST NOT auto-generate House Norms immediately from Fit Check
answers alone. Fit Check data is sufficient to seed House Norms, but not
to produce a canonical House Norms artifact without the remaining
required dimensions and explicit owner confirmation.

Dimensions not captured by the Fit Check (remain unprefilled):
- `norms_guests_social`
- `norms_home_identity`
- Context anchors (`norms_property_context`, `norms_relationship_model`)

### 7.3 Personal Preferences

The Fit Check behavioural taxonomy does not map cleanly to the full
14-item personal preference taxonomy. The concepts are related but not
globally semantically equivalent.

The system MUST NOT auto-populate `preference_responses` from fit check
answers.

The system MAY use a bounded crosswalk for a subset of preference-flow
questions where product and engineering agree the mapping quality is
strong enough to show a preselected default in the UI.

Preference-flow prefill rules:
- Prefill is advisory only
- Prefilled answers MUST remain editable
- Prefill MUST NOT silently create `preference_responses`
- Questions without a defensible mapping MUST remain unanswered
- The preference flow remains the canonical place where the user confirms
  their answers

The system MAY also surface a nudge to complete personal preferences via
the standard Preference Scenarios flow after the owner has used the Fit
Check.

### 7.4 Candidate Answer Reuse (Future)

In v1, candidate answers are used only for briefing generation. They are
not linked to any future user identity.

A future version MAY define a mechanism to link a candidate's anonymous
submission to their authenticated account after joining the home, but
this requires:
- A candidate claim token or personalised invite binding
- An explicit "accepted applicant" concept in Homes
- A review-and-confirm flow for the new member

None of these exist today. This is explicitly out of scope for v1.

## 8. Conversion Model

### 8.1 No Login Required For
- Owner: answering scenarios, viewing initial briefing (same session)
- Candidate: answering scenarios

### 8.2 Login Required For
- Owner: re-accessing briefings after closing the browser
- Owner: viewing multiple candidate briefings across sessions
- Owner: accessing the full candidate review inbox in app
- Owner: revoking/regenerating the share token
- Owner: persisting the draft and associating it with a home
- Owner: creating a new home from the fit-check draft when they do not
  already have one

### 8.3 App-Only Claim Model

Kinly authentication is app-based. For this flow, the web experience
MUST NOT depend on standalone web sign-in.

Required model:
1. Anonymous owner completes Fit Check on web
2. Backend creates a server-side `fit_check_draft`
3. Browser session stores opaque references needed to resume or claim
4. Owner selects "Continue in app"
5. App handles authentication and submits the claim
6. Backend atomically links the draft to the authenticated owner
7. App opens the owner review inbox for that draft, including all
   candidate submissions and briefings collected so far

Claim requires possession of a short-lived `claim_token` bound to the
draft. The claim token is an implementation detail and MUST NOT be shown
to the user as raw text.

Multiple anonymous drafts MAY later be claimed by the same authenticated
owner account. The product MUST NOT assume a 1:1 relationship between
owner and fit-check draft.

### 8.4 Post-Claim Actions

System MUST:
1. Claim the `fit_check_draft` from the app handoff flow
2. Persist all candidate submissions and briefings linked to the draft
3. Store owner's 4 scenario answers for later House Norms prefill (§7.2)

Claim only establishes ownership of the draft. Claim MUST NOT
automatically attach the draft to a home.

### 8.5 Home Attachment

After claim, attaching a fit-check draft to a home MUST be a separate,
explicit user action.

Rules:
- The app MAY offer home creation immediately after claim if the owner
  has no home
- The app MAY offer attachment to an existing home if the owner already
  has one
- Backend MUST NOT silently attach a draft to a home during claim
- Backend MUST NOT silently merge multiple claimed drafts for the same
  owner or home
- If the owner has multiple claimed drafts, the app must present an
  explicit choice of which draft to attach

### 8.6 Anonymous Draft Editing

Anonymous owner draft editing MUST use a browser-held opaque draft edit
authority separate from claim authority.

Rules:
- Creating an anonymous draft yields:
  - a server-side `fit_check_draft`
  - a public `share_token`
  - a short-lived owner `claim_token`
  - a browser-held `draft_session_token` for anonymous editing
- Updating an anonymous draft requires the matching
  `draft_session_token`
- `draft_session_token` is not a public share token and not an app claim
  token
- `draft_session_token` becomes invalid after successful claim or draft
  expiry/purge

### 8.7 No Canonical Writes on Claim/Conversion

Claim/login/conversion MUST NOT:
- Create or update a `house_norms` row
- Create or update `preference_responses` rows
- Trigger House Norms generation
- Persist any candidate-specific Alignment Preview as canonical home data

Those flows are entered separately by the owner when ready.

## 9. Visibility Model

This is an owner-first tool. Visibility is intentionally asymmetric.

| Data | Owner | Candidate |
|---|---|---|
| Owner's scenario answers | ✅ (own answers) | ❌ |
| Candidate's scenario answers | ✅ (structured answers + briefing context) | ✅ (own personalized result page only; no owner comparison) |
| Candidate `country_code` / `city_name` | ✅ (submission context) | ✅ (own provided values) |
| Home vibe summary | ✅ | ❌ |
| Pre-interview briefing | ✅ | ❌ |
| Suggested questions | ✅ | ❌ |
| Other candidates' data | N/A (one briefing at a time) | ❌ |
| Candidate `display_name` | ✅ | ✅ (own provided value) |

The candidate sees: question flow → location capture → submission
confirmation → personalized result page → optional app CTA.

### 9.1 Answer Leakage

With a 3-point ordinal scale and directional watchout copy, the owner can
often infer the candidate's approximate position from the briefing. This
is acceptable and intentional — the briefing is meant to inform the
owner's interview preparation.

## 10. Web Platform Requirements

### 10.1 Rendering
- All surfaces (owner flow, candidate flow, briefing) MUST be
  web-accessible
- No native app dependency for v1
- Responsive design for mobile web

### 10.2 Internationalisation
- All user-facing strings MUST use template keys resolved by locale
- Scenario prompts, options, watchout copy, suggested questions, and UI
  chrome are all template-driven
- Locale is determined from browser/user settings
- Fallback locale: `en`
- Template structure follows the existing `house_norm_templates` pattern
  (keyed by `template_key` + `locale_base`)
- Public candidate flow payloads SHOULD return template keys and stable
  metadata rather than fully rendered strings

### 10.3 Template Key Inventory

Required template namespaces for v1:

| Namespace | Purpose |
|---|---|
| `fit_check.owner.*` | Owner flow UI strings |
| `fit_check.candidate.*` | Candidate flow UI strings |
| `fit_check.scenario.{id}.*` | Scenario prompts and options (single set, both audiences) |
| `fit_check.scenario.{id}.option.{index}` | Scenario option labels, reused for owner summary rendering in v1 |
| `fit_check.watchout.{id}.*` | Watchout descriptions by direction and distance |
| `fit_check.question.{id}.*` | Suggested interview questions per dimension |
| `fit_check.briefing.*` | Briefing structure chrome |

## 11. Data Model

### Required Tables

| Table | Purpose |
|---|---|
| `fit_check_drafts` | Owner scenario answers (created server-side pre-claim; post-claim: persisted, linked to owner and optionally a home) |
| `fit_check_share_tokens` | Public tokens for candidate access; FK to `fit_check_drafts` |
| `candidate_fit_submissions` | Candidate `display_name`, `country_code`, `city_name`, and scenario answers; FK to `fit_check_drafts` |
| `candidate_fit_briefings` | Generated briefing per submission; FK to `candidate_fit_submissions`; includes frozen owner answers snapshot |

### Relationships

```
fit_check_drafts (1)
  ├── fit_check_share_tokens (1:many, typically 1 active)
  ├── candidate_fit_submissions (1:many)
  │     └── candidate_fit_briefings (1:1)
  └── homes (0:1, FK after login/claim)
```

### Design Notes

- `fit_check_drafts` is the parent entity. All tokens, submissions, and
  briefings reference it.
- Pre-claim drafts are created server-side on first anonymous owner
  save. Browser session state stores only opaque references.
- On app claim, the draft is atomically linked to the authenticated user
  and optionally a home.
- `candidate_fit_briefings` stores a frozen snapshot of the owner's
  answers at comparison time, so briefings remain valid if the owner
  later changes answers.
- Unclaimed drafts are ephemeral and subject to purge (§12.4).
- Each answer is stored as `scenario_id` + `option_index` (0–2).

## 12. Privacy and Lifecycle

### 12.1 Token Expiry
- `fit_check_share_tokens`: configurable TTL (default: 30 days)
- Expired tokens MUST return a clear localised "link expired" message

### 12.2 Token Revocation (Post-Login Only)
- Authenticated owner MUST be able to revoke and regenerate the share
  token
- Revoking MUST NOT delete existing submissions or briefings

### 12.3 Submission Limits
- Max submissions per share token: configurable (default: 20)
- One submission per anonymous session per token (duplicate rejection)
- Rate limiting MUST be applied to the submission endpoint

Backend-enforced anti-abuse requirements:
- Anonymous session identity MUST be server-issued (for example, an
  opaque cookie-backed session identifier)
- Duplicate detection MUST be defined against `(share_token,
  anonymous_session_id)`
- Duplicate submissions from the same anonymous session for the same
  token MUST be rejected with a structured duplicate error
- Rate limiting SHOULD consider token and short-window network abuse
  signals
- Expired, revoked, invalid, duplicate, rate-limited, and submission-cap
  failures MUST be distinguishable in backend error handling

The product MUST NOT rely on browser session state alone as the sole
anti-abuse control.

### 12.4 Data Retention
- Unclaimed `fit_check_drafts` (not linked to a user) MUST be purged
  after 90 days
- Claimed drafts follow standard home data retention
- Candidate submissions linked to a purged draft are cascade-deleted

### 12.5 Candidate Privacy
- No open-text answers (structured option_index only)
- Candidate location is limited to bounded fields: `country_code` and
  `city_name`
- Candidate submissions MUST NOT store device fingerprints or IP addresses
  beyond rate-limit window
- Rate-limiting metadata MUST NOT be persisted

### 12.6 Deletion
- Home deletion MUST cascade to all fit check data (drafts, tokens,
  submissions, briefings)
- Candidates cannot self-delete in v1 (no identity to authenticate
  against). Deletion is via cascade or retention purge.

## 13. Anti-Discrimination

Scenario prompts, watchout copy, and suggested questions MUST:
- Stay focused on household logistics (cleaning, noise, chores,
  communication)
- Never reference or proxy for protected characteristics (age, gender,
  ethnicity, religion, disability, sexuality, family status)
- Be reviewed for bias before launch and at each locale addition

## 14. Non-Goals

The system MUST NOT:
- Verify truthfulness of responses
- Enforce decisions
- Replace in-person interviews
- Guarantee compatibility
- Produce ranked or sorted applicant lists
- Sort or filter candidates by fit
- Auto-reject candidates based on distance values
- Write directly to `house_norms` or `preference_responses`

## 15. Success Criteria

### Product Metrics
- ≥ 80% completion rate (4 scenarios)
- ≥ 50% owners share link to at least one candidate
- ≥ 30% conversion to login after viewing briefing
- measurable owner claim-to-inbox conversion after first applicant
- measurable candidate click-through from personalized result page to app

### Behavioural Indicators
- Owners use suggested questions in real interviews
- Owners report better clarity before committing
- Reduced post-move-in friction reports

## 16. Coupling

- House Norms Taxonomy v1 defines the norms dimension IDs used as
  prefill targets (§7.2).
- House Norms Scenarios v1 provides the format inspiration but the Fit
  Check uses its own behavioural scenarios (§5.2).
- House Norms v1 is the downstream consumer of prefill data (§7.2), but
  the Fit Check does not write to it directly.
- Home creation uses existing Homes v2 flow.

## 17. Future Considerations

The following are explicitly deferred and MAY be addressed in future
versions:

- **Direct house norms population** — requires House Norms contract
  changes to support partial/seeded state
- **Personal preference crosswalk** — requires validated 1:1 semantic
  mappings (currently not available)
- **Candidate answer seeding on home join** — requires candidate claim
  tokens, acceptance model in Homes, and review-confirm flow
- **Additional dimensions** — `norms_guests_social`,
  `norms_home_identity`

## 18. Invariant

The Flatmate Fit Check is an owner's pre-interview preparation tool.
It surfaces what to be aware of and what to ask — it does not score,
rank, or gatekeep. It MUST NOT become a mechanism for sorting or
filtering people.
