---
Domain: Shared
Capability: House Norms
Scope: shared
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
---

# Kinly House Norms Contract v1

Status: Proposed (Home MVP)

Scope: Scenario-based capture and generation of a home-level House Norms
document (non-enforceable), owner-governed edits, and member read-only
visibility.

Audience: Product, design, engineering, AI agents.

Depends on:
- Homes v2 (memberships + roles)
- House Norms Scenarios v1
- House Norms Taxonomy v1
- Kinly product philosophy (care, not control)
- Kinly Project Brief

1. Purpose

House Norms help a home align on everyday defaults that prevent tension:
rhythm, shared spaces, guests, responsibility flow, repair style, and home
identity.

House Norms are:
- Descriptive ("how we want this home to feel").
- Light ("starting point, not a rulebook").
- Editable by the owner ("stewardship, not policing").

House Norms are not:
- Rules, enforcement, permissions, or compliance checks.
- A scoring system.
- A replacement for conversation.

2. Core Principles

- Harmony over enforcement.
- Recognition over configuration (scenario moments, not surveys).
- Transparency without pressure (everyone can view; only owner can change).
- Calm UX (no guilt, no setup-required framing, no progress metaphors).
- Safe language in generated text (no "must/always/never", no blame, no
  consequences).

3. Ownership and Permissions

3.1 Viewing
- All current home members MAY view House Norms.

3.2 Create, regenerate, and edit (owner-only)
- Only the home owner MAY:
  - Create House Norms.
  - Regenerate House Norms.
  - Edit House Norms content.
- Non-owner members MUST NOT:
  - Edit.
  - Propose changes.
  - Comment.
  - Request edits through an in-product channel in v1.

Rationale:
House Norms reflect stewardship of the home. Read-only visibility preserves
shared understanding without politicizing language or creating social pressure.

3.3 Norms vs Rules
- House Norms remain descriptive and non-enforceable.
- Policy-like constraints (for example smoking policy, pets policy, severe
  shared allergen restrictions) are out-of-scope for House Norms v1.
- House Norms MUST NOT be used as a hidden rules engine.

4. Lifecycle

4.1 Creation moment
- House Norms are owner-triggered from mobile surfaces (for example, a Today
  prompt card) when no House Norms document exists yet for the home.
- In v1, owner-triggered creation from Today is the default creation entry
  point.
- Generation requires completion of:
  - 2 required context anchors.
  - 6 required directional scenarios.
- In v1 backend semantics, generation creates/updates draft content.
- Publishing to web/share is explicit and owner-triggered.

4.1.1 Today prompt visibility rule (owner-only)
- A Today "Create House Norms" prompt MAY be shown only when all of the
  following are true:
  - Caller is a current member with role `owner`.
  - `house_norms_get_for_home(home_id, locale)` returns
    `house_norms = null`.
- Non-owner members MUST NOT see a House Norms creation prompt.
- The prompt MUST be calm and low-pressure, not styled as a required setup
  step.

4.2 Status
- `published`: draft and published snapshots match.
- `out_of_date`: draft differs from published snapshot, or no published snapshot
  exists yet.
- Template updates MUST NOT auto-overwrite published content.

4.3 Regeneration rules
- Regenerate only when the owner explicitly requests it.
- Regeneration replaces `generated_content`.
- Regeneration updates draft only (`generated_content`).
- `published_content` updates only when owner explicitly publishes.
- Regeneration copy is resolved from `house_norm_templates` by locale:
  requested locale first, fallback to `en` when missing.

5. Generated Output Model

5.1 Output intent
- Title: "House norms"
- Subtitle: "A shared starting point - not a rulebook."
- Tone constraints:
  - Use "we" language.
  - Use "aim", "try", "usually", and "prefer".
  - Avoid "must", "always", and "never".
  - Avoid naming individuals or assigning fault.

5.2 Required structure (v1)
Generated content MUST include:
- `summary` (`title_key`, `subtitle_key`, framing paragraph)
- `context` (anchors rendered as neutral context line)
- `sections` (6 sections aligned to scenario IDs; each section includes
  `title_key` and `text`)

Optional:
- Owner-facing footer note: "You can revisit these anytime."

5.3 Anchor-aware phrasing
- Output MAY adjust wording based on anchors (property context and relationship
  model), but MUST NOT change permissions or imply enforcement.

6. Editing and Revisions (owner-only)

6.1 Edit scope
- Owner edits MAY update:
  - `summary.framing` narrative tone text only.
  - Section text for:
    - `norms_rhythm_quiet`
    - `norms_shared_spaces`
    - `norms_guests_social`
    - `norms_responsibility_flow`
    - `norms_repair_style`
    - `norms_home_identity`
- Owner edits MUST NOT update:
  - `summary.title`
  - `summary.subtitle`
  - Content structure/schema.
- Owner edits MUST NOT:
  - Add enforceable language.
  - Add monitoring or tracking language.
  - Add punishments or consequences.
  - Name individuals.
  - Introduce permissions.

6.2 Revision tracking
- All edits create a revision row.
- Store draft snapshot (`generated_content`) after each edit.
- Allow owner revert-to-generated for any section.

7. Data Access and APIs (Proposed RPCs)

7.1 Read (member)
- `house_norms_get_for_home(p_home_id uuid, p_locale text) -> jsonb`
  - Caller MUST be authenticated.
  - Caller MUST be a current home member.
  - Returns draft + published snapshot metadata when document exists, else null.
  - For non-owner callers, response includes:
    - `member_viewed_at` (timestamptz | null)
    - `show_member_review_card` (boolean, backend-computed with 24-hour
      debounce and `viewed_at` comparison against latest norms change).

7.2 Generate (owner-only)
- `house_norms_generate_for_home(p_home_id uuid, p_template_key text, p_locale text, p_inputs jsonb, p_force boolean) -> jsonb`
  - Caller MUST be authenticated.
  - Caller MUST be a current home member.
  - Caller MUST have role `owner`.
  - Generates/updates draft (`generated_content`).
  - Never updates `published_content`.
  - If `p_force = true`, MAY overwrite prior generated draft.

7.3 Publish (owner-only)
- `house_norms_publish_for_home(p_home_id uuid, p_locale text) -> jsonb`
  - Owner-only.
  - Copies `generated_content` to `published_content`.
  - Marks document `published`.

7.4 Edit section text (owner-only)
- `house_norms_edit_section_text(p_home_id uuid, p_locale text, p_section_key text, p_new_text text, p_change_summary text default null) -> jsonb`
  - Owner-only.
  - Edits `generated_content.summary.framing` when `p_section_key=summary_framing`.
  - Edits draft section text for the six norms section keys.
  - Does not mutate `published_content`.
  - Records a revision.

7.5 Record member view
- `house_norms_record_view(p_home_id uuid) -> jsonb`
  - Caller MUST be authenticated.
  - Caller MUST be a current home member.
  - Upserts `house_norms_member_views` with `viewed_at = now()`.
  - Returns `{ "ok": true, "viewed_at": "<timestamptz>" }`.

8. Storage Model (Supabase, Proposed)

8.1 Tables

`house_norms`
- `home_id` (uuid, PK, FK homes)
- `template_key` (text)
- `locale_base` (text, lowercase ISO 639-1)
- `status` (text: `published` | `out_of_date`)
- `inputs` (jsonb) // anchors + scenario option indices
- `generated_content` (jsonb)
- `published_content` (jsonb|null)
- `generated_at` (timestamptz)
- `published_at` (timestamptz|null)
- `home_public_id` (citext|null, unique, immutable once assigned)
- `published_version` (text|null, monotonic `vNNNNNN` per publish)
- `last_edited_at` (timestamptz|null)
- `last_edited_by` (uuid|null)
- `updated_at` (timestamptz)

`house_norms_revisions`
- `id` (uuid, PK)
- `home_id` (uuid, FK)
- `editor_user_id` (uuid)
- `edited_at` (timestamptz)
- `content` (jsonb)
- `change_summary` (text|null)

`house_norm_templates`
- `id` (uuid, PK)
- `template_key` (text)
- `locale_base` (text, lowercase ISO 639-1)
- `body` (jsonb; structured summary/context/section option copy)
- `created_at` (timestamptz)
- `updated_at` (timestamptz)

`house_norms_member_views`
- `home_id` (uuid, FK homes)
- `user_id` (uuid, FK auth.users)
- `viewed_at` (timestamptz)
- PK: (`home_id`, `user_id`)

8.2 RLS
- RPC-only model.
- Direct table DML denied for `authenticated`.
- `SECURITY DEFINER` RPCs must assert:
  - Authenticated caller.
  - Current home membership.
  - Role-appropriate authorization:
    - `owner` for generate/publish/edit writes.
    - current member for `house_norms_record_view`.

9. Safety and Non-Goals

9.1 Forbidden outcomes
- Turning norms into policing or threats.
- Showing who caused a norm.
- Prompting non-owners to negotiate wording inside the product.

9.2 Non-goals (v1)
- Voting and approvals.
- Comment threads.
- Suggest-an-edit workflows.
- Auto-reminders based on norm content (e.g., behavioral nudges). Member
  awareness of norm updates is covered by the Today House Norms Member
  Review contract.
- Policy enforcement workflows (belongs to House Rules track).

10. Invariants

- House Norms increase shared understanding, not compliance.
- Only owners can create, regenerate, and edit; all members can view.
- Generated and published text must avoid enforcement language
  ("must/always/never").
- No Kinly feature may be gated by House Norms.

11. Assumptions and Defaults (v1)

- Owner is the only editor in v1.
- `summary.framing` is text-only personalization, not policy.
- `summary.title` and `summary.subtitle` remain template-controlled.
- Draft and published snapshots are intentionally separate.

```contracts-json
{
  "domain": "house_norms",
  "version": "v1",
  "entities": {
    "HouseNorms": {
      "homeId": "uuid",
      "templateKey": "text",
      "localeBase": "text",
      "status": "text",
      "inputs": "jsonb",
      "generatedContent": "jsonb",
      "publishedContent": "jsonb|null",
      "generatedAt": "timestamptz",
      "publishedAt": "timestamptz|null",
      "homePublicId": "citext|null",
      "publishedVersion": "text|null",
      "lastEditedAt": "timestamptz|null",
      "lastEditedBy": "uuid|null",
      "updatedAt": "timestamptz"
    },
    "HouseNormsRevision": {
      "id": "uuid",
      "homeId": "uuid",
      "editorUserId": "uuid",
      "editedAt": "timestamptz",
      "content": "jsonb",
      "changeSummary": "text|null"
    },
    "HouseNormTemplate": {
      "id": "uuid",
      "templateKey": "text",
      "localeBase": "text",
      "body": "jsonb",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "HouseNormsMemberView": {
      "homeId": "uuid",
      "userId": "uuid",
      "viewedAt": "timestamptz"
    }
  },
  "functions": {
    "houseNorms.getForHome": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.house_norms_get_for_home",
      "args": {
        "p_home_id": "uuid",
        "p_locale": "text"
      },
      "returns": "jsonb"
    },
    "houseNorms.generateForHome": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.house_norms_generate_for_home",
      "args": {
        "p_home_id": "uuid",
        "p_template_key": "text",
        "p_locale": "text",
        "p_inputs": "jsonb",
        "p_force": "boolean"
      },
      "returns": "jsonb"
    },
    "houseNorms.publishForHome": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.house_norms_publish_for_home",
      "args": {
        "p_home_id": "uuid",
        "p_locale": "text"
      },
      "returns": "jsonb"
    },
    "houseNorms.editSectionText": {
      "type": "rpc",
      "caller": "owner-only",
      "impl": "public.house_norms_edit_section_text",
      "args": {
        "p_home_id": "uuid",
        "p_locale": "text",
        "p_section_key": "text",
        "p_new_text": "text",
        "p_change_summary": "text|null"
      },
      "returns": "jsonb"
    },
    "houseNorms.recordView": {
      "type": "rpc",
      "caller": "member",
      "impl": "public.house_norms_record_view",
      "args": {
        "p_home_id": "uuid"
      },
      "returns": "jsonb"
    }
  },
  "rls": []
}
```
