---
Domain: Norms
Capability: Public norms
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.1
---

# Norms - Public Norms v1.1

Status: Proposed (MVP)

Scope: Public web visibility and delivery rules for published House Norms
snapshots.

Audience: Product, design, engineering, AI agents.

Depends on:
- House Norms v1
- House Norms API v1
- Kinly Web links contracts

1. Purpose

Public Norms provides a read-only web page that can display a home's published
House Norms snapshot when the owner explicitly publishes.

This contract adds a DB-light delivery model so high public traffic is served
from cached web output and storage artifacts, not repeated per-view DB reads.

2. Visibility model

2.1 Published snapshot only
- Public page MUST render only `published_content`.
- Draft content (`generated_content`) MUST NEVER be rendered publicly.

2.2 Publish precondition
- Public visibility is available only after owner-triggered
  `house_norms_publish_for_home(home_id, locale)`.
- Before publish, the public page MUST be unavailable.
- Public URL identity uses stable `home_public_id`; republish keeps the same id
  and same URL.
- Because publish delivery is asynchronous, first publish MAY briefly return
  success before the public page becomes available.

2.3 Inactive/unavailable states
- If home is inactive, public norms page MUST be unavailable.
- If no published content exists, public norms page MUST be unavailable.
- Unavailable responses MAY be represented as not-found/unavailable UX.

3. Content and controls

3.1 Read-only content
- Public page shows descriptive norms content only.
- No owner/member controls are rendered on public web.
- No edit, publish, comment, suggest-change, or moderation controls are exposed.

3.2 Non-enforcement semantics
- Public page copy must preserve House Norms intent:
  - shared understanding
  - non-enforceable
  - not a rulebook

4. Routing and sharing

- Public route shape follows active web link contract for norms pages:
  `/kinly/norms/:homePublicId`.
- `home_public_id` is the canonical persisted identifier for public norms
  routing.
- `public_url` is derived from canonical host + route template + `home_public_id`
  and is not persisted as a storage column.
- `home_public_id` is stable across republishes and remains the copy/share
  identity in v1.
- Share links to norms should resolve only when the published snapshot is
  available.
- v1 has no disable/unpublish/rotation feature for published public norms
  links.

5. Delivery and cache model

5.1 Primary render source
- For web cache fills, Vercel SHOULD read storage artifacts via the manifest
  pointer path defined by House Norms API publish semantics:
  - `public_norms/home/{home_public_id}/manifest.json`
  - versioned snapshot:
    `public_norms/home/{home_public_id}/published_{published_version}.json`
- Storage artifact paths MUST use `home_public_id` (never `home_id`).

5.2 API compatibility path
- `house_norms_get_public_by_home_public_id(home_public_id, locale)` remains a
  compatible public read API.
- This API path MUST still return published-only content and unavailable/null
  for unknown, unpublished, or inactive homes.

5.3 No per-view DB dependency target
- Public requests should be served from Vercel cache and/or storage artifact
  fetches.
- DB work is expected during publish and occasional cache fills, not on each
  public page view.

5.4 Freshness model
- Correctness MUST be driven by explicit owner publish actions and backend
  on-demand revalidation for `/kinly/norms/{home_public_id}`.
- Republish MAY briefly serve the previous published snapshot until the async
  delivery job finishes successfully.
- Freshness MUST NOT depend on fixed time-based TTL expiry.

6. Non-goals

- Exposing draft norms publicly.
- Enabling public editing or discussion threads.
- Converting norms into policy/compliance pages.

7. Invariant

Public Norms is a read-only projection of published House Norms. If content is
not published and available, the public page must not display norms text.
