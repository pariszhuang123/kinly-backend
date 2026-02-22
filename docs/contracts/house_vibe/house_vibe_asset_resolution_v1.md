# House Vibe Asset Resolution v1
# Instruction: Do not invent new behavior. If something is ambiguous, ask rather than assume.

Status: Draft (implementation-ready)  
Audience: Engineering, Agents  
Scope: Client-only resolution of House Vibe illustration assets.

## Purpose

Define a deterministic, offline asset resolution rule for House Vibe illustrations. The backend returns only `image_key` and `mapping_version`; it never returns URLs or paths. The client resolves the asset locally.

## Resolution Rule

```
assets/house_vibes/{mapping_version}/{image_key}.webp
```

Example:
- `mapping_version = v1`
- `image_key = vibe_social_v1`
- Resolved asset: `assets/house_vibes/v1/vibe_social_v1.webp`

## Constraints

- `image_key` is a stable identifier, not a URL.
- No network calls are allowed for vibe illustrations.
- Backend never returns asset paths or URLs.
- Client is responsible for resolving assets using the rule above and bundling them with the app.
- Asset bundle must include `assets/house_vibes/` in `pubspec.yaml`.
- Mapping version is explicit; switching versions requires new assets in the corresponding folder.
