# House Vibe Share Contract v1 (Social Sharing Image)
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Social sharing of the House Vibe Card as an image (e.g., gratitude wall share), not a public browseable link. Rendered client-side in Flutter, captured to an image buffer, and passed to the platform share sheet.

## Purpose

Enable members to share the Vibe Card to social platforms as an image that contains only safe data:
- House vibe type (title via `S.of(context)` key)
- Summary (via `S.of(context)` key)
- Vibe illustration (image key)
- `gratitudeWallFooter` treatment

No public listing, screening, or comparison use cases. Payload stays vibe-only.

## Data Flow

- Client fetches the latest render payload via `house_vibe_compute` (or cached snapshot): `label_id`, `title_key`, `summary_key`, `image_key`, `ui`, `coverage`.
- Client resolves copy via `S.of(context)` and renders the Vibe Card in Flutter.
- Client captures the rendered widget to an image buffer (similar to gratitude wall screenshot pattern).
- Client shares the image via the platform share sheet (no backend signed URL).

## Allowed Share Payload (render inputs)

- `label_id`
- `title_key`
- `summary_key`
- `image_key`
- `ui` (tokens for styling)
- `coverage` (answered/total)
- No member data, no axes, no per-axis counts.

## Share Operation (v1, client-side)

1) User taps Share on the Vibe Card.
2) App requests/refreshes vibe via `house_vibe_compute` (service role recompute if `out_of_date=true`).
3) App renders the Vibe Card with:
   - Vibe title (i18n via `title_key` / `S.of(context)`)
   - Vibe summary (i18n via `summary_key`)
   - Vibe illustration (from `image_key`)
   - `gratitudeWallFooter` artwork
   - Optional coverage note “Based on X of Y members”
4) App captures the widget as an image buffer and passes it to the platform share sheet.
5) No URL or slug is generated; the shared asset is the captured image.

## Privacy & Safety

- Image contains no member identities, preference details, per-axis member counts, or per-question text.
- No stable public URLs or slugs; each request signs a new URL with short TTL.
- Sharing is vibe-only; not intended for screening/listing/comparison.
- Share logging: use `share_events` with `feature = 'house_vibe'` (Option 1 only).

## Out-of-date Handling

- Social share uses the latest computed vibe. If `out_of_date=true`, trigger recompute via `house_vibe_compute` before rendering. No cache TTL applies to the captured image; freshness is ensured at capture time.

## Prohibited

- No public GET endpoints, slugs, or signed URLs.
- No leakage of member ids, preference ids, per-axis member counts, or per-user answers.
- No additional metadata beyond the Vibe Card + coverage note in the captured image.
