---
Domain: withYou
Capability: System Overview
Scope: platform
Artifact-Type: architecture
Stability: evolving
Status: draft
Version: v1.0
---

# withYou System Overview (v1)

## Purpose

withYou helps users manage uncomfortable moments through believable audio call
flows. The system spans two surfaces:

- **Web** (`go.makinglifeeasie.com/withyou`): scenario landings, preview audio,
  app-install CTAs, lead capture, and QR-friendly public entry
- **Flutter app**: downloads offline audio packs, caches them locally, and
  plays them offline

## Architecture Layers

### 1. Vercel - Public delivery layer

Owns all public-facing content and static hosting:

- public routes under `/withyou`
- shared landing template rendering
- language switching for preview UI
- preview audio assets
- static app config files (`version.json`, `audio-manifest.json`)
- static offline ZIP pack hosting
- tracked download entry routes that redirect to static ZIPs

### 2. Kinly backend - Narrow shared utility

Owns only durable business-event persistence:

- lead persistence (`leads_upsert_v1` -> `public.leads`)
- durable pack-download tracking
- future QR generation and metadata utilities

The Kinly backend MUST NOT become the main withYou backend. It is reused
narrowly for shared utilities only.

### 3. Flutter app - Offline pack lifecycle

Owns the full offline audio experience:

- reading `audio-manifest.json`
- choosing language pack
- requesting tracked pack download routes
- downloading ZIPs from redirect targets
- extracting ZIPs to local storage
- local caching
- offline playback

## Canonical Scenario Model

withYou v1 uses three canonical scenario families:

- `presence` - passive safety, social buffering, occupied appearance, boundary
  signaling
- `social_pull` - gradual movement away through a believable alternative or
  anchor
- `exit_pressure` - stronger interruption or extraction when the user wants out
  quickly

Public route slugs are user-situation entries, not canonical audio keys.
Multiple public routes MAY map to one scenario family.

## Ownership Boundaries

| Owner | Responsibilities |
|---|---|
| Vercel | Public routes, shared landing template, language switching, preview audio, static config, static ZIPs, tracked download routes |
| Kinly backend | Durable lead records, durable pack-download records, future QR utilities |
| Flutter app | Language-pack selection, tracked download request, ZIP download and extraction, local cache, offline playback |

## Key Architectural Rules

1. **Public route slug and scenario family are different concerns** - route slugs
   are for public discovery; canonical families are for audio packs, manifest
   keys, and playback rules.
2. **Scenario family and language define the audio experience** - family defines
   the clip model; language defines which localized preview assets or offline
   pack is used.
3. **Preview audio is separate from offline packs** - preview clips are Vercel
   static assets; offline packs are downloaded ZIPs. They MUST NOT be
   conflated.
4. **Static assets stay on Vercel** - audio files, config JSON, and ZIPs MUST
   be served from Vercel, not Supabase Storage.
5. **Durable business events go to Supabase** - lead captures and pack-download
   events MUST be persisted via Kinly backend RPCs.
6. **Kinly backend is reused narrowly, not broadly** - only lead persistence,
   download tracking, and future QR utilities. No withYou-specific business
   logic SHOULD live in the Kinly backend.

## Non-Goals

- no locale-based route tree
- no video in v1
- no static audio hosting in Supabase
- no full withYou backend in Kinly

## Public Route Map

| Route | Purpose |
|---|---|
| `/withyou` | Redirect -> `/withyou/uber` |
| `/withyou/get` | Lead capture |
| `/withyou/uber` | `presence` landing |
| `/withyou/walk-home` | `presence` landing |
| `/withyou/bus-stop` | `presence` landing |
| `/withyou/party-exit` | `social_pull` landing |
| `/withyou/date-fading` | `social_pull` landing |
| `/withyou/new-place` | `social_pull` landing |
| `/withyou/trapped-conversation` | `exit_pressure` landing |
| `/withyou/they-wont-let-me-leave` | `exit_pressure` landing |
| `/withyou/bad-date-exit` | `exit_pressure` landing |
| `/withyou/download/audio/{language}` | Tracked download -> redirect to `/withyou/audio/{language}/core.zip` |
| `/withyou/config/version.json` | App version config |
| `/withyou/config/audio-manifest.json` | Available packs manifest |

## Route-to-Family Mapping

| Route slug | Canonical family |
|---|---|
| `uber` | `presence` |
| `walk-home` | `presence` |
| `bus-stop` | `presence` |
| `party-exit` | `social_pull` |
| `date-fading` | `social_pull` |
| `new-place` | `social_pull` |
| `trapped-conversation` | `exit_pressure` |
| `they-wont-let-me-leave` | `exit_pressure` |
| `bad-date-exit` | `exit_pressure` |

## Data Flow Summary

### Web visitor -> preview experience

```text
Web visitor -> Vercel scenario page -> preview audio (Vercel static) -> app store links
```

### Web visitor -> lead capture

```text
Web visitor -> /withyou/get -> leads_upsert_v1 RPC -> Supabase public.leads
```

### Flutter app -> offline pack download

```text
Flutter app
  -> /withyou/config/audio-manifest.json
  -> language pack selection
  -> /withyou/download/audio/{lang}
  -> Vercel route handler
  -> Supabase event write (pack-download record)
  -> redirect to /withyou/audio/{lang}/core.zip
```
