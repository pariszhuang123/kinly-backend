---
Domain: Homes
Capability: Flatmate Fit Check API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1
---

# Flatmate Fit Check API v1

Status: Proposed

Scope: Backend RPCs and public route contracts for anonymous owner draft
capture, public candidate submission, app-only draft claim, owner review,
share-token lifecycle, and downstream prefill retrieval.

Audience: Product, design, engineering, AI agents.

Depends on:
- Flatmate Fit Check Contract v3.6
- Homes v2
- House Norms v1

## 1. Purpose

Define the server-side contract for Flatmate Fit Check. This API must
support:
- anonymous owner capture on web
- anonymous candidate submission by share token
- authenticated owner claim in app
- owner review of candidate briefings
- downstream prefill retrieval for House Norms and bounded preference
  flows
- immediate post-claim, post-home-attachment setup handoff so seeded
  onboarding can reduce repeated questions

These APIs MUST remain briefing-oriented. They MUST NOT produce ranking,
sorting, or auto-rejection behavior.

## 2. Access Model

- Anonymous owner write:
  - `fit_check_upsert_draft`
- Public candidate read/write:
  - `fit_check_get_public_by_token`
  - `fit_check_submit_candidate_by_token`
- Authenticated owner claim/write:
  - `fit_check_claim_draft`
  - `fit_check_rotate_share_token`
  - `fit_check_revoke_share_token`
- Authenticated owner read:
  - `fit_check_get_owner_review`
  - `fit_check_get_owner_briefing`
  - `fit_check_get_prefill_payload`

Access requirements:
- Public RPCs MUST NOT require authentication.
- Claim/review/share-token mutation RPCs MUST require authentication.
- Owner read/write RPCs MUST assert that the caller owns the claimed
  draft, or is the current owner of the linked home when `home_id` is
  present.
- Direct client DML on fit-check tables MUST be denied; access is
  RPC-only.

## 3. Canonical Inputs

### 3.1 Locale

- `p_locale` accepts base or region forms (for example `en`, `en-NZ`).
- Server normalizes locale to lowercase base locale (`locale_base`).
- Template lookup uses exact `(template_key, locale_base)` and falls back
  to `en` when the requested locale is unavailable.
- Responses that include rendered summary/briefing content MUST return
  `requested_locale_base` and `resolved_locale_base`.

### 3.2 Scenario payload (`answers`)

`answers` is a JSON object with exactly four required keys and integer
values `0..2`.

Required keys:
- `fit_cleanliness`
- `fit_rhythm`
- `fit_chores`
- `fit_conflict`

Validation:
- Missing keys MUST fail.
- Unknown keys MUST fail.
- Values outside `0..2` MUST fail.
- Payload size above guardrails (2KB) MUST fail.

### 3.3 Candidate identity

- `p_display_name` is required for candidate submission.
- `p_display_name` is a lightweight label for owner review and MUST NOT
  be treated as authentication proof.
- `p_display_name` must be trimmed, non-empty, and at most 80 chars.
- `p_display_name` is not guaranteed unique across submissions.
- Owner review surfaces MUST use `submission_id` and `submitted_at` as
  canonical disambiguators when duplicate names exist.

### 3.4 Watchout direction

Canonical direction values:
- `owner_higher`
- `candidate_higher`

Semantics:
- `owner_higher` means `owner_index > candidate_index`
- `candidate_higher` means `candidate_index > owner_index`

Allowed watchout distances:
- `1`
- `2`

Distance `0` is alignment, not a watchout.

### 3.5 Anonymous session identity

- Public candidate submission dedupe uses an opaque anonymous session
  identifier validated by the backend.
- In the current backend implementation, the anonymous session
  identifier is supplied via request header and validated for required
  format before hashing/dedupe.
- Duplicate detection is canonical on `(share_token, anonymous_session_id)`.

### 3.6 Draft session token

- `draft_session_token` is the browser-held opaque authority for
  anonymous owner draft updates.
- `draft_session_token` MUST be bound to a single draft.
- `draft_session_token` MUST NOT grant app claim authority.
- `draft_session_token` becomes invalid after successful claim or draft
  expiry/purge.

### 3.7 Share token and claim token

- `share_token` is the public token used for candidate access.
- `claim_token` is a short-lived owner-only token used for app claim.
- `claim_token` MUST be bound to a single draft and MUST NOT be reused
  after successful claim.
- One draft may be claimed at most once.
- One authenticated owner MAY own multiple claimed drafts.

## 4. RPC Contracts

### 4.1 `fit_check_upsert_draft(p_draft_id uuid null, p_draft_session_token text null, p_locale text, p_answers jsonb) -> jsonb`

Caller: public (anonymous or authenticated owner before claim finalization).

Behavior:
- Creates a new server-side `fit_check_draft` when `p_draft_id is null`.
- Updates the existing draft when `p_draft_id` is present and the caller
  presents the matching `p_draft_session_token`.
- Generates:
  - `draft_id`
  - `claim_token`
  - `draft_session_token`
  - one active `share_token`
  - owner summary labels
- Stores only owner answers and draft metadata; does not create a home.
- Does not generate House Norms or `preference_responses`.
- Raw `claim_token` and `draft_session_token` are transport/internal
  credentials. API responses SHOULD expose continuation metadata and edit
  continuity metadata without encouraging general-purpose display or
  logging of those raw values.
- On create, the response reveals raw `share_token`,
  `draft_session_token`, and `claim_token` once.
- On update, those raw token fields are omitted and the response returns
  continuity metadata plus the current draft/share state only.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "requested_locale_base": "en",
  "resolved_locale_base": "en",
  "owner_answers": {
    "fit_cleanliness": 0,
    "fit_rhythm": 1,
    "fit_chores": 0,
    "fit_conflict": 0
  },
  "summary": {
    "labels": [
      "Cleans straight away",
      "Chill - TV or music",
      "Roster system",
      "Brings it up early"
    ]
  },
  "share": {
    "share_token": "text",
    "share_url": "text",
    "expires_at": "timestamptz"
  },
  "draft_session": {
    "resume_available": true
  },
  "claim": {
    "claim_required": true,
    "continue_in_app_url": "text"
  }
}
```

### 4.2 `fit_check_get_public_by_token(p_share_token text, p_locale text) -> jsonb`

Caller: public.

Behavior:
- Resolves the candidate flow for a public share token.
- Returns scenario metadata, template keys, and owner-safe UI chrome
  only.
- MUST NOT return owner answers, owner summary, or owner briefing.
- Returns unavailable/null payload for invalid, expired, revoked, or
  exhausted tokens.

Response shape (available):

```json
{
  "ok": true,
  "available": true,
  "requested_locale_base": "en",
  "resolved_locale_base": "en",
  "token_status": "active",
  "fit_check_public": {
    "entry_prompt_key": "fit_check.candidate.entry_prompt",
    "scenarios": [
      {
        "scenario_id": "fit_cleanliness",
        "prompt_key": "fit_check.scenario.fit_cleanliness.prompt",
        "option_keys": [
          "fit_check.scenario.fit_cleanliness.option.0",
          "fit_check.scenario.fit_cleanliness.option.1",
          "fit_check.scenario.fit_cleanliness.option.2"
        ]
      },
      {
        "scenario_id": "fit_rhythm",
        "prompt_key": "fit_check.scenario.fit_rhythm.prompt",
        "option_keys": [
          "fit_check.scenario.fit_rhythm.option.0",
          "fit_check.scenario.fit_rhythm.option.1",
          "fit_check.scenario.fit_rhythm.option.2"
        ]
      },
      {
        "scenario_id": "fit_chores",
        "prompt_key": "fit_check.scenario.fit_chores.prompt",
        "option_keys": [
          "fit_check.scenario.fit_chores.option.0",
          "fit_check.scenario.fit_chores.option.1",
          "fit_check.scenario.fit_chores.option.2"
        ]
      },
      {
        "scenario_id": "fit_conflict",
        "prompt_key": "fit_check.scenario.fit_conflict.prompt",
        "option_keys": [
          "fit_check.scenario.fit_conflict.option.0",
          "fit_check.scenario.fit_conflict.option.1",
          "fit_check.scenario.fit_conflict.option.2"
        ]
      }
    ]
  }
}
```

Response shape (unavailable):

```json
{
  "ok": true,
  "available": false,
  "requested_locale_base": "en",
  "fit_check_public": null,
  "error": {
    "code": "FIT_CHECK_TOKEN_EXPIRED",
    "message": "Link expired"
  }
}
```

### 4.3 `fit_check_submit_candidate_by_token(p_share_token text, p_locale text, p_display_name text, p_answers jsonb) -> jsonb`

Caller: public.

Behavior:
- Validates active token, submission cap, anonymous session dedupe, and
  payload shape.
- Creates `candidate_fit_submission`.
- Generates one `candidate_fit_briefing` using a frozen owner-answer
  snapshot from comparison time.
- Returns candidate-safe confirmation payload only.
- Returns a candidate-specific post-submit payload for that submission.
- MUST NOT return owner answers, compatibility results, or the owner
  briefing.

Response shape:

```json
{
  "ok": true,
  "submission_id": "uuid",
  "requested_locale_base": "en",
  "resolved_locale_base": "en",
  "candidate": {
    "display_name": "Alex"
  },
  "confirmation": {
    "message_key": "fit_check.candidate.submitted",
    "reflection": {
      "show": true,
      "text_key": "fit_check.candidate.reflection.flexible"
    },
    "cta": {
      "text_key": "fit_check.candidate.create_own_cta",
      "target_url": "text"
    }
  }
}
```

### 4.4 `fit_check_claim_draft(p_claim_token text) -> jsonb`

Caller: authenticated user in app.

Behavior:
- Validates the claim token.
- Atomically attaches ownership of the draft to the authenticated owner.
- Does not attach the draft to any home.
- Returns whether the owner currently has homes and whether home
  attachment is still required.
- Invalidates the claim token after successful claim.
- Does not create or attach a home automatically.
- MAY indicate whether downstream setup should be offered immediately
  after the next explicit home create or attach step.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "owner_user_id": "uuid",
  "home_attachment_required": true,
  "owner_home_count": 1,
  "seed_house_norms_prefill_available": true,
  "seed_preferences_prefill_available": false,
  "setup_handoff_recommended": true,
  "submission_count": 3
}
```

### 4.5 `fit_check_attach_draft_to_home(p_draft_id uuid, p_home_id uuid) -> jsonb`

Caller: authenticated owner of the draft and target home.

Behavior:
- Explicitly attaches a claimed draft to a target home.
- MUST fail if the caller does not own the draft.
- MUST fail if the caller is not the owner of `p_home_id`.
- MUST NOT silently merge multiple drafts.
- If the home already has another attached fit-check draft, the backend
  MAY reject with a structured conflict error rather than guessing which
  draft should win.
- On success, the backend SHOULD make the downstream prefill payload
  available immediately for seeded setup flows.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "home_id": "uuid",
  "attached_at": "timestamptz",
  "setup_prefill_ready": true
}
```

### 4.6 `fit_check_get_owner_review(p_draft_id uuid, p_locale text) -> jsonb`

Caller: authenticated owner of the draft/home.

Behavior:
- Returns the owner summary plus the list of candidate submissions.
- One row per submission.
- Submission list MUST NOT be ranked by fit score.
- Default ordering SHOULD be newest first.
- Each list item includes only the preview metadata needed for the owner
  review surface.
- This response is the canonical app inbox payload for the owner review
  surface.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "home_id": "uuid|null",
  "requested_locale_base": "en",
  "resolved_locale_base": "en",
  "owner_summary": {
    "labels": [
      "Cleans straight away",
      "Quiet early nights",
      "Roster system",
      "Brings it up early"
    ]
  },
  "share": {
    "share_token_status": "active",
    "share_url": null,
    "link_reveal_requires_rotation": true,
    "expires_at": "timestamptz",
    "submissions_remaining": 17
  },
  "submissions": [
    {
      "submission_id": "uuid",
      "display_name": "Alex",
      "review_label": "Alex · 2026-03-25 14:14",
      "submitted_at": "timestamptz",
      "preview": {
        "top_watchouts": [
          "fit_cleanliness",
          "fit_rhythm"
        ],
        "summary_label": "A few things to discuss"
      }
    }
  ]
}
```

### 4.7 `fit_check_get_owner_briefing(p_submission_id uuid, p_locale text) -> jsonb`

Caller: authenticated owner of the parent draft/home.

Behavior:
- Returns the full owner-facing pre-interview briefing for one candidate
  submission.
- Uses the frozen owner-answer snapshot stored with the generated
  briefing.
- Includes alignments, watchouts, suggested questions, limitation copy,
  and interview-focus copy.
- MAY expose raw candidate structured answers to the owner as supporting
  detail.

Response shape:

```json
{
  "ok": true,
  "submission_id": "uuid",
  "draft_id": "uuid",
  "requested_locale_base": "en",
    "resolved_locale_base": "en",
    "candidate": {
      "display_name": "Alex",
      "submitted_at": "timestamptz",
      "answers": {
      "fit_cleanliness": 2,
      "fit_rhythm": 1,
      "fit_chores": 0,
      "fit_conflict": 1
    }
  },
  "briefing": {
    "context_key": "fit_check.briefing.context",
    "limitation_key": "fit_check.briefing.limitation",
    "focus_key": "fit_check.briefing.focus",
    "alignments": [
      { "scenario_id": "fit_chores" }
    ],
    "watchouts": [
      {
        "scenario_id": "fit_cleanliness",
        "distance": 2,
        "direction": "candidate_higher",
        "watchout_key": "fit_check.watchout.fit_cleanliness.candidate_higher.2",
        "question_keys": [
          "fit_check.question.fit_cleanliness.q1",
          "fit_check.question.fit_cleanliness.q2"
        ],
        "is_primary_focus": true
      }
    ]
  }
}
```

### 4.8 `fit_check_rotate_share_token(p_draft_id uuid) -> jsonb`

Caller: authenticated owner of the draft/home.

Behavior:
- Revokes the current active share token.
- Creates a new active share token for the same draft.
- Existing submissions and briefings remain unchanged.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "share_token_status": "active",
  "share_url": "text",
  "expires_at": "timestamptz"
}
```

### 4.9 `fit_check_revoke_share_token(p_draft_id uuid) -> jsonb`

Caller: authenticated owner of the draft/home.

Behavior:
- Revokes the current active share token.
- Does not create a replacement token.
- Existing submissions and briefings remain unchanged.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "share_token_status": "revoked"
}
```

### 4.10 `fit_check_get_prefill_payload(p_draft_id uuid) -> jsonb`

Caller: authenticated owner of the draft/home.

Behavior:
- Returns the canonical downstream prefill payload derived from the
  owner’s fit-check answers.
- Returns House Norms prefill values for the four mapped dimensions.
- MAY return bounded preference-flow hint values where a supported
  crosswalk exists.
- MUST NOT create or mutate downstream records.
- SHOULD return onboarding seed payloads in index form so mobile flows
  can start at the first unanswered question rather than from a blank
  form.

Response shape:

```json
{
  "ok": true,
  "draft_id": "uuid",
  "house_norms_prefill": {
    "norms_shared_spaces": "clear_now",
    "norms_rhythm_quiet": "variable",
    "norms_responsibility_flow": "clear_agreements",
    "norms_repair_style": "talk_soon"
  },
  "onboarding_seed": {
    "house_norms": {
      "initial_responses": {
        "norms_shared_spaces": 0,
        "norms_rhythm_quiet": 1,
        "norms_responsibility_flow": 0,
        "norms_repair_style": 0
      }
    },
    "preferences": {
      "initial_responses": {}
    }
  },
  "preference_flow_hints": {
    "supported": false,
    "answers": {}
  }
}
```

## 5. Storage and Security (Proposed)

Tables:
- `fit_check_drafts`
- `fit_check_share_tokens`
- `candidate_fit_submissions`
- `candidate_fit_briefings`

`fit_check_drafts` required fields:
- `id uuid pk`
- `owner_user_id uuid null`
- `home_id uuid null`
- `owner_answers jsonb`
- `draft_session_token_hash text`
- `claim_token_hash text`
- `requested_locale_base text`
- `claimed_at timestamptz null`
- `created_at timestamptz`
- `updated_at timestamptz`

`fit_check_share_tokens` required fields:
- `id uuid pk`
- `draft_id uuid fk fit_check_drafts(id)`
- `token_hash text`
- `status text`
- `expires_at timestamptz`
- `revoked_at timestamptz null`
- `created_at timestamptz`

Required token status values:
- `active`
- `revoked`
- `expired`

`candidate_fit_submissions` required fields:
- `id uuid pk`
- `draft_id uuid fk fit_check_drafts(id)`
- `share_token_id uuid fk fit_check_share_tokens(id)`
- `display_name text`
- `answers jsonb`
- `anonymous_session_hash text`
- `submitted_at timestamptz`

Required constraints:
- max one submission per `(share_token_id, anonymous_session_hash)`
- structured answer payload only; no open-text answers beyond `display_name`

`candidate_fit_briefings` required fields:
- `id uuid pk`
- `submission_id uuid fk candidate_fit_submissions(id) unique`
- `draft_id uuid fk fit_check_drafts(id)`
- `owner_answers_snapshot jsonb`
- `briefing_payload jsonb`
- `generated_at timestamptz`

Security requirements:
- Private fit-check mutations are RPC-only.
- Direct client DML on fit-check tables denied.
- Claim/review/token mutation RPCs run as `SECURITY DEFINER` and assert
  ownership.
- Public RPCs return only candidate-safe projections.

Ownership/claim invariants:
- `fit_check_drafts.owner_user_id` is nullable before claim and immutable
  after successful claim except for admin/data-repair operations outside
  this API contract.
- `draft_session_token_hash` governs anonymous draft updates and is
  distinct from `claim_token_hash`.
- A successful claim consumes the `claim_token` permanently.
- Multiple draft rows MAY share the same `owner_user_id`.
- Attaching multiple claimed drafts to the same `home_id` requires an
  explicit product decision; this API MUST NOT silently merge drafts.

## 6. Error Model

Private/public RPC errors follow `{ code, message, details }` envelope
conventions when throwing.

Required private/public codes:
- `UNAUTHORIZED`
- `FORBIDDEN_OWNER_ONLY`
- `FIT_CHECK_NOT_FOUND`
- `FIT_CHECK_INVALID_INPUTS`
- `FIT_CHECK_INVALID_LOCALE`
- `FIT_CHECK_INVALID_TOKEN`
- `FIT_CHECK_TOKEN_EXPIRED`
- `FIT_CHECK_TOKEN_REVOKED`
- `FIT_CHECK_TOKEN_SUBMISSION_LIMIT_REACHED`
- `FIT_CHECK_DUPLICATE_SUBMISSION`
- `FIT_CHECK_RATE_LIMITED`
- `FIT_CHECK_INVALID_CLAIM_TOKEN`
- `FIT_CHECK_INVALID_OR_USED_CLAIM_TOKEN`
- `FIT_CHECK_INVALID_DRAFT_SESSION`
- `FIT_CHECK_HOME_ATTACHMENT_CONFLICT`

Public token read behavior:
- `fit_check_get_public_by_token` SHOULD prefer `available=false` for
  invalid/expired/revoked/unavailable token states.

Public submission behavior:
- `fit_check_submit_candidate_by_token` MAY throw structured errors for
  duplicate, limit, rate-limit, or invalid payload failures.

## 7. Invariants

- API outputs MUST NOT rank or sort candidates by fit.
- API outputs MUST NOT return a numeric fit score.
- Owner review is one submission at a time plus an unranked list view.
- Candidate responses remain anonymous apart from required
  `display_name`.
- Duplicate `display_name` values are allowed and must be disambiguated
  in owner review via `submission_id`, `submitted_at`, or a derived
  review label.
- Claim links a pre-existing server-side draft; it does not recreate the
  draft from browser-only state.
- Claim establishes ownership only; home attachment is a separate
  explicit API action.
- One owner may own multiple drafts; one draft may be claimed only once.
- Share-token rotation/revocation MUST NOT delete existing submissions or
  briefings.
- House Norms and preference downstream artifacts are prefill-only in
  this API; no canonical writes occur here.

## 8. Contract Test Scenarios

- Anonymous owner creates a new draft and receives `draft_id`,
  `share_token`, draft edit continuity, and app continuation metadata.
- Anonymous owner updates the same draft and receives the same
  `draft_id`.
- Anonymous owner update with missing/invalid `draft_session_token`
  fails with `FIT_CHECK_INVALID_DRAFT_SESSION`.
- Public token read returns candidate-safe scenario template keys only.
- Public token read returns `available=false` for expired token.
- Candidate submission with missing `display_name` fails.
- Candidate submission from the same anonymous session for the same token
  fails with `FIT_CHECK_DUPLICATE_SUBMISSION`.
- Candidate submission after submission cap fails with
  `FIT_CHECK_TOKEN_SUBMISSION_LIMIT_REACHED`.
- Candidate submission generates one frozen briefing.
- Successful claim attaches draft to authenticated owner and invalidates
  the `claim_token`.
- Successful claim does not attach the draft to a home.
- Explicit attach RPC links a claimed draft to a chosen home.
- Successful attach makes setup prefill immediately available for the
  next onboarding step.
- Successful claim of multiple different drafts by the same owner
  account is allowed.
- Owner review returns an unranked submissions list with preview
  metadata.
- Owner review disambiguates duplicate candidate names using
  `submission_id`, `submitted_at`, or `review_label`.
- Owner briefing returns watchout keys using canonical
  `owner_higher|candidate_higher` directions.
- Share-token rotation creates a new active token without deleting prior
  submissions.
- Prefill payload returns House Norms mappings but performs no downstream
  writes.

## 9. References

- [Flatmate Fit Check Contract v3.6](../../../product/kinly/shared/flatmate_fit_check_v1.md)
- [House Norms v1](../../../product/kinly/shared/house_norms_v1.md)
- [House Norms API v1.1](./house_norms_api_v1.md)
- [Homes v2](./homes_v2.md)

```contracts-json
{
  "domain": "flatmate_fit_check_api",
  "version": "v1",
  "entities": {
    "FitCheckDraft": {
      "id": "uuid",
      "ownerUserId": "uuid|null",
      "homeId": "uuid|null",
      "ownerAnswers": "jsonb",
      "claimTokenHash": "text",
      "requestedLocaleBase": "text",
      "claimedAt": "timestamptz|null",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "FitCheckShareToken": {
      "id": "uuid",
      "draftId": "uuid",
      "tokenHash": "text",
      "status": "text",
      "expiresAt": "timestamptz",
      "revokedAt": "timestamptz|null"
    },
    "CandidateFitSubmission": {
      "id": "uuid",
      "draftId": "uuid",
      "displayName": "text",
      "answers": "jsonb",
      "anonymousSessionHash": "text",
      "submittedAt": "timestamptz"
    },
    "CandidateFitBriefing": {
      "id": "uuid",
      "submissionId": "uuid",
      "draftId": "uuid",
      "ownerAnswersSnapshot": "jsonb",
      "briefingPayload": "jsonb",
      "generatedAt": "timestamptz"
    }
  },
  "functions": {
    "fitCheck.upsertDraft": {
      "type": "rpc",
      "caller": "public",
      "impl": "public.fit_check_upsert_draft",
      "args": {
        "p_draft_id": "uuid|null",
        "p_draft_session_token": "text|null",
        "p_locale": "text",
        "p_answers": "jsonb"
      },
      "returns": "jsonb"
    },
    "fitCheck.getPublicByToken": {
      "type": "rpc",
      "caller": "public",
      "impl": "public.fit_check_get_public_by_token",
      "args": {
        "p_share_token": "text",
        "p_locale": "text"
      },
      "returns": "jsonb"
    },
    "fitCheck.submitCandidateByToken": {
      "type": "rpc",
      "caller": "public",
      "impl": "public.fit_check_submit_candidate_by_token",
      "args": {
        "p_share_token": "text",
        "p_locale": "text",
        "p_display_name": "text",
        "p_answers": "jsonb"
      },
      "returns": "jsonb"
    },
    "fitCheck.claimDraft": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.fit_check_claim_draft",
      "args": {
        "p_claim_token": "text"
      },
      "returns": "jsonb"
    },
    "fitCheck.attachDraftToHome": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_attach_draft_to_home",
      "args": {
        "p_draft_id": "uuid",
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    },
    "fitCheck.getOwnerReview": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_get_owner_review",
      "args": {
        "p_draft_id": "uuid",
        "p_locale": "text"
      },
      "returns": "jsonb"
    },
    "fitCheck.getOwnerBriefing": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_get_owner_briefing",
      "args": {
        "p_submission_id": "uuid",
        "p_locale": "text"
      },
      "returns": "jsonb"
    },
    "fitCheck.rotateShareToken": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_rotate_share_token",
      "args": {
        "p_draft_id": "uuid"
      },
      "returns": "jsonb"
    },
    "fitCheck.revokeShareToken": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_revoke_share_token",
      "args": {
        "p_draft_id": "uuid"
      },
      "returns": "jsonb"
    },
    "fitCheck.getPrefillPayload": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.fit_check_get_prefill_payload",
      "args": {
        "p_draft_id": "uuid"
      },
      "returns": "jsonb"
    }
  },
  "rls": []
}
```
