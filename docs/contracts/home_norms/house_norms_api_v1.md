---
Domain: Homes
Capability: House Norms API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.1
---

# House Norms API v1.1

Status: Proposed (Home MVP)

Scope: Member read, owner write, and public read RPCs for House Norms
generation, publishing, and public route rendering, plus publish-time artifact
delivery contracts for DB-light public web traffic.

Audience: Product, design, engineering, AI agents.

Depends on:
- Homes v2 (memberships + roles)
- House Norms v1
- House Norms Scenarios v1
- House Norms Taxonomy v1
- Links share links v1.3

1. Purpose

Define server-side contracts for reading and mutating House Norms. House Norms
are descriptive and non-enforceable. APIs in this contract must not create
permissions, automation, or compliance behavior.

This contract also defines public norms route resolution using stable
`home_public_id` with ID-only persistence.

2. Access Model

- Member read:
  - `house_norms_get_for_home`
- Owner write:
  - `house_norms_generate_for_home`
  - `house_norms_publish_for_home`
  - `house_norms_edit_section_text`
- Public read (web route):
  - `house_norms_get_public_by_home_public_id`

Private RPC requirements (`get_for_home`, `generate`, `publish`, `edit`):
- Caller MUST be authenticated.
- Caller membership MUST be current for `p_home_id`.
- Home MUST be active.

Owner write requirements:
- Caller MUST have role `owner`.

3. Canonical Inputs

3.1 Template and locale
- `p_template_key` identifies the generation template (for example
  `house_norms_v1`).
- `p_locale` accepts base or region forms (for example `en`, `en-NZ`).
- Server normalizes locale to lowercase base locale (`locale_base`).
- Generation resolves template locale by:
  - exact match on `(template_key, locale_base)` in `house_norm_templates`
  - fallback to `en` when requested locale template is missing
- Current seeded v1 template locales: `en`, `es`, `ar`.
- Private responses include locale metadata (`requested_locale_base`,
  `doc_locale_base`) for deterministic rendering.

3.2 Scenario input payload (`p_inputs`)
`p_inputs` is a JSON object with required keys and integer values `0..2`.

Required keys:
- `norms_property_context`
- `norms_relationship_model`
- `norms_rhythm_quiet`
- `norms_shared_spaces`
- `norms_guests_social`
- `norms_responsibility_flow`
- `norms_repair_style`
- `norms_home_identity`

Validation:
- Missing keys MUST fail.
- Values outside `0..2` MUST fail.
- Unknown keys MUST fail to avoid semantic drift.
- Payload size above guardrails (2KB) MUST fail.

3.3 Public route id
- `p_home_public_id` is the route identity value for `/kinly/norms/:homePublicId`.
- Stored as CITEXT.
- Case-insensitive for lookup; canonical casing MAY be normalized in responses.

4. RPC Contracts

4.1 `house_norms_get_for_home(p_home_id uuid, p_locale text) -> jsonb`

Caller: current member.

Behavior:
- Returns draft + published metadata when present.
- Returns null payload when no document exists yet.
- Returns both requested locale base and stored document locale base.
- `house_norms: null` is the canonical frontend signal for owner-only Today
  prompt eligibility.
- Owner-facing URL/control metadata is included only for owner callers.
- Owner-facing `public_url` is derived from canonical host +
  `/kinly/norms/{home_public_id}` and is never persisted as a DB column.
- Owner-facing publish delivery metadata is included only for owner callers and
  reflects async public-web delivery for the current `published_version`.
- Member-review visibility is backend-computed and returned as
  `show_member_review_card` for non-owner callers.

Response shape (member baseline):

```json
{
  "ok": true,
  "home_id": "uuid",
  "requested_locale_base": "en",
  "doc_locale_base": "en",
  "house_norms": {
    "template_key": "house_norms_v1",
    "status": "published|out_of_date",
    "inputs": {},
    "draft_content": {},
    "draft_updated_at": "timestamptz",
    "published_content": {},
    "published_at": "timestamptz|null",
    "published_version": "text|null",
    "is_published": true,
    "has_unpublished_changes": false,
    "last_edited_at": "timestamptz|null",
    "last_edited_by": "uuid|null"
  }
}
```

Owner metadata extension (owner callers only):

```json
{
  "house_norms": {
    "home_public_id": "text|null",
    "public_url": "text|null",
    "published_version": "text|null",
    "publish_sync_status": "queued|processing|succeeded|failed|null",
    "publish_sync_error": {
      "code": "text",
      "message": "text",
      "stage": "text",
      "at": "timestamptz"
    },
    "show_publish_button": true,
    "show_republish_button": false,
    "show_public_url": false
  }
}
```

Member metadata extension (non-owner callers only):

```json
{
  "house_norms": {
    "member_viewed_at": "timestamptz|null",
    "show_member_review_card": false
  }
}
```

When absent:

```json
{
  "ok": true,
  "home_id": "uuid",
  "requested_locale_base": "en",
  "house_norms": null
}
```

4.1.1 Deterministic owner UI states

For owner callers:
- `house_norms == null`:
  - `show_publish_button=false`
  - `show_republish_button=false`
  - `show_public_url=false`
- draft exists, never published:
  - `show_publish_button=true`
  - `show_republish_button=false`
  - `show_public_url=false`
- published and current:
  - `show_publish_button=false`
  - `show_republish_button=false`
  - `show_public_url=true`
- published and out_of_date:
  - `show_publish_button=false`
  - `show_republish_button=true`
  - `show_public_url=true`

4.1.2 Publish sync status

For owner callers:
- `publish_sync_status` is scoped to the current `published_version`.
- Allowed values:
  - `queued`
  - `processing`
  - `succeeded`
  - `failed`
  - `null` when no publish has happened yet
- `publish_sync_error` is null unless `publish_sync_status='failed'`.
- Older published records created before async job tracking MAY surface
  `publish_sync_status='succeeded'` without a stored job row.

4.2 `house_norms_generate_for_home(p_home_id uuid, p_template_key text, p_locale text, p_inputs jsonb, p_force boolean) -> jsonb`

Caller: current owner.

Behavior:
- Validates owner role, template, locale, and `p_inputs`.
- Generates draft content (`generated_content`) from template + taxonomy-backed
  inputs.
- Does not update `published_content`.
- When `p_force = false`, implementation MAY short-circuit if equivalent inputs
  are already in the existing document.
- When `p_force = true`, implementation overwrites draft state.
- Returned `status` and `has_unpublished_changes` are canonical owner publish
  CTA signals.

Response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "template_key": "house_norms_v1",
  "locale_base": "en",
  "status": "published|out_of_date",
  "draft_content": {},
  "draft_updated_at": "timestamptz",
  "published_content": {},
  "published_at": "timestamptz|null",
  "short_circuited": false
}
```

4.3 `house_norms_publish_for_home(p_home_id uuid, p_locale text) -> jsonb`

Caller: current owner.

Behavior:
- Explicit publish RPC for web/share snapshot updates.
- Copies `generated_content` to `published_content`.
- Marks status as `published`.
- First publish:
  - generates immutable unique `home_public_id` (CITEXT) if absent.
- Republish:
  - reuses existing `home_public_id`.
- Generates a new monotonic `published_version` on every publish.
- Computes `public_url` from canonical host + route template + `home_public_id`.
- `public_url` is derived and returned, not persisted.
- Enqueues async public delivery work after canonical publish update:
  - versioned snapshot:
    `public_norms/home/{home_public_id}/published_{published_version}.json`
  - manifest pointer:
    `public_norms/home/{home_public_id}/manifest.json`
- Artifact payload MUST include only:
  - `home_public_id`
  - `published_at` (canonical UTC ISO string, same shape as JS `Date(...).toISOString()`)
  - `published_version`
  - `template_key`
  - `locale_base`
  - `published_content`
- Cache headers:
  - versioned snapshot:
    `public, max-age=31536000, immutable`
  - manifest:
    `no-store`
- Publish response timing:
  - publish RPC MUST return success once canonical DB publish state and the
    publish job row are committed.
  - publish RPC MUST NOT wait on artifact upload or Vercel revalidation.
- Delivery observability:
  - response includes `publish_sync_status` for the new `published_version`.
  - normal path returns `publish_sync_status='queued'`.
  - if enqueue/dispatch fails before the RPC returns, response returns
    `publish_sync_status='failed'` with `publish_sync_error`.
- Delivery guarantees:
  - async worker writes versioned artifact + manifest and then triggers Vercel
    on-demand revalidation for `/kinly/norms/{home_public_id}`.
  - failed delivery does not roll back canonical publish state; failure is
    surfaced through owner-facing publish sync metadata.
- Returned `has_unpublished_changes=false` confirms canonical publish complete.

Response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "requested_locale_base": "en",
  "doc_locale_base": "en",
  "status": "published",
  "published_content": {},
  "published_at": "timestamptz",
  "published_version": "text",
  "has_unpublished_changes": false,
  "home_public_id": "text",
  "public_url": "https://go.makinglifeeasie.com/kinly/norms/{homePublicId}",
  "publish_sync_status": "queued|failed",
  "publish_sync_error": null
}
```

4.4 `house_norms_edit_section_text(p_home_id uuid, p_locale text, p_section_key text, p_new_text text, p_change_summary text default null) -> jsonb`

Caller: current owner.

Behavior:
- Edits only the target editable field in `generated_content` (draft).
- Creates a revision row in `house_norms_revisions`.
- Must reject unsafe language (enforcement, punishment, threat framing).
- Must reject unknown `p_section_key`.

Allowed `p_section_key` values:
- `summary_framing`
- `norms_rhythm_quiet`
- `norms_shared_spaces`
- `norms_guests_social`
- `norms_responsibility_flow`
- `norms_repair_style`
- `norms_home_identity`

Validation requirements:
- Unknown section -> `HOUSE_NORMS_INVALID_SECTION`.
- Empty edited text -> `HOUSE_NORMS_INVALID_INPUTS`.
- Edited text > 2000 chars -> `HOUSE_NORMS_INVALID_INPUTS`.
- `summary_framing` > 500 chars -> `HOUSE_NORMS_INVALID_INPUTS`.
- `p_change_summary` > 280 chars -> `HOUSE_NORMS_INVALID_INPUTS`.
- Unsafe text (English) -> `HOUSE_NORMS_UNSAFE_TEXT`.

Response shape:

```json
{
  "ok": true,
  "home_id": "uuid",
  "requested_locale_base": "en",
  "doc_locale_base": "en",
  "section_key": "norms_shared_spaces",
  "draft_content": {},
  "draft_updated_at": "timestamptz",
  "published_at": "timestamptz|null",
  "status": "published|out_of_date",
  "has_unpublished_changes": true,
  "last_edited_at": "timestamptz",
  "last_edited_by": "uuid"
}
```

4.5 `house_norms_get_public_by_home_public_id(p_home_public_id text, p_locale text) -> jsonb`

Caller: public (anon or authenticated).

Behavior:
- Resolves public route `/kinly/norms/:homePublicId`.
- Returns only published norms snapshot (never draft).
- This RPC is the public API compatibility/fallback path; primary web delivery
  for scale is storage artifact + Vercel cache.
- Must not return draft content.
- Returns unavailable/null payload when:
  - unknown `home_public_id`
  - home inactive
  - no published content

Response shape (available):

```json
{
  "ok": true,
  "available": true,
  "home_public_id": "text",
  "requested_locale_base": "en",
  "doc_locale_base": "en",
  "house_norms_public": {
    "status": "published|out_of_date",
    "published_content": {},
    "published_at": "timestamptz",
    "published_version": "text"
  }
}
```

Response shape (unavailable):

```json
{
  "ok": true,
  "available": false,
  "home_public_id": "text",
  "requested_locale_base": "en",
  "house_norms_public": null
}
```

5. Storage and Security (Proposed)

Tables:
- `house_norms`
- `house_norms_revisions`
- `house_norm_templates`

`house_norms` additions:
- `home_public_id` (CITEXT, unique, nullable until first publish)
- `published_version` (text, nullable before first publish; monotonic per
  norms document)

`house_norm_templates`:
- One row per `(template_key, locale_base)`.
- Stores structured generation copy in `body` for summary/context/sections.
- Template rows are backend-managed (not client writable).

ID-only persistence rules:
- Persist `home_public_id` only.
- Do not persist `public_url` column.
- `public_url` is derived from:
  - host: `https://go.makinglifeeasie.com`
  - path template: `/kinly/norms/{home_public_id}`

Derived delivery artifacts:
- Storage artifacts are derived from canonical DB publish state.
- Public artifact paths MUST use `home_public_id` (never `home_id`):
  - `public_norms/home/{home_public_id}/published_{published_version}.json`
  - `public_norms/home/{home_public_id}/manifest.json`
    - Public web storage URL derivation (for web reads) is environment-based:
  - base: `${NEXT_PUBLIC_SUPABASE_URL}/storage/v1/object/public/households`
  - manifest: `${base}/public_norms/home/{home_public_id}/manifest.json`
  - snapshot: `${base}/{latest_snapshot_path}` from manifest
- Artifacts MUST contain only published-safe fields and no draft/private data.
- v1 does not support disable/unpublish/rotation of public norms links; once
  published, `home_public_id` remains the stable public identity.

Constraints:
- One active House Norms record per `home_id`.
- `status` in `published|out_of_date`.
- `home_public_id` immutable once assigned.
- Revision rows append-only.

RLS/privileges:
- Private write model is RPC-only.
- Direct client DML on norms tables denied.
- Write RPCs run as `SECURITY DEFINER` and assert membership/owner role.
- Public read RPC returns only published-safe projection.

6. Error Model

Private RPC errors follow `{ code, message, details }` envelope conventions.

Required private codes:
- `UNAUTHORIZED`
- `NOT_HOME_MEMBER`
- `INVALID_LOCALE`
- `FORBIDDEN_OWNER_ONLY`
- `HOME_INACTIVE`
- `HOUSE_NORMS_NOT_FOUND`
- `HOUSE_NORMS_INVALID_INPUTS`
- `HOUSE_NORMS_INVALID_TEMPLATE`
- `HOUSE_NORMS_TEMPLATE_NOT_FOUND`
- `HOUSE_NORMS_INVALID_SECTION`
- `HOUSE_NORMS_UNSAFE_TEXT`

Public read RPC:
- Prefer unavailable/null payload over throw for unpublished/inactive/not found.

7. Invariants

- House Norms APIs MUST NOT gate unrelated features.
- House Norms text remains descriptive, not enforceable.
- Non-owners can read but cannot mutate.
- Template updates MUST NOT silently overwrite published content.
- `home_public_id` is stable across republishes.
- `public_url` is computed, not persisted.
- Public norms links remain permanent in v1 (no disable/unpublish/rotation).
- Public route traffic should be served via Vercel cache and storage artifacts;
  DB reads are expected on publish and occasional cache fill only.

8. Contract Test Scenarios

- Owner with no norms: `house_norms == null` (Today prompt eligible).
- First publish:
  - generates `home_public_id`
  - generates `published_version`
  - returns derived `public_url`
  - enqueues versioned artifact + manifest delivery job
  - returns `publish_sync_status='queued'` on the normal path
- Republish:
  - reuses same `home_public_id` and `public_url`
  - increments `published_version`
  - enqueues a new delivery job for the new `published_version`
- Out-of-date after edit: `show_republish_button=true` and `show_public_url=true`.
- Never-published draft: `show_publish_button=true`, `show_public_url=false`.
- Non-owner member read succeeds without owner URL controls.
- Public route read resolves published snapshot only when published and active.
- Public route read returns unavailable for unpublished/inactive/unknown id.
- Async delivery failure surfaces `publish_sync_status='failed'` without
  rolling back canonical publish state.
- Successful async delivery triggers route revalidation; next public render
  resolves new `published_version`.
- High-traffic public reads are served through cache/artifact path without
  repeated DB reads per view.
- Unknown `p_section_key` fails with `HOUSE_NORMS_INVALID_SECTION`.
- Unsafe text fails with `HOUSE_NORMS_UNSAFE_TEXT` for English locale.

9. References

- [House Norms v1](../../../product/kinly/shared/house_norms_v1.md)
- [House Norms Scenarios v1](../../../product/kinly/shared/house_norms_scenarios_v1.md)
- [House Norms Taxonomy v1](../../../product/kinly/shared/house_norms_taxonomy_v1.md)
- [Today House Norms Prompt v1](../../../product/kinly/mobile/today_house_norms_prompt_v1.md)
- [Public Norms v1](../../../product/kinly/web/norms/norms_public_norms_v1.md)
- [Homes v2](./homes_v2.md)

```contracts-json
{
  "domain": "house_norms_api",
  "version": "v1",
  "entities": {
    "HouseNorms": {
      "homeId": "uuid",
      "homePublicId": "citext|null",
      "templateKey": "text",
      "localeBase": "text",
      "status": "text",
      "inputs": "jsonb",
      "generatedContent": "jsonb",
      "publishedContent": "jsonb|null",
      "publishedVersion": "text|null",
      "generatedAt": "timestamptz",
      "publishedAt": "timestamptz|null",
      "lastEditedAt": "timestamptz|null",
      "lastEditedBy": "uuid|null"
    },
    "HouseNormsRevision": {
      "id": "uuid",
      "homeId": "uuid",
      "editorUserId": "uuid",
      "editedAt": "timestamptz",
      "content": "jsonb",
      "changeSummary": "text|null"
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
    "houseNorms.getPublicByHomePublicId": {
      "type": "rpc",
      "caller": "public",
      "impl": "public.house_norms_get_public_by_home_public_id",
      "args": {
        "p_home_public_id": "text",
        "p_locale": "text"
      },
      "returns": "jsonb"
    }
  },
  "rls": []
}
```
