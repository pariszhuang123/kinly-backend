# Contract — Share Links & Canonical URLs v1.0

Domain: Links  
Capability: Share Links  
Status: Active  
Registry: `contracts/contracts_registry.md`

---

## Purpose

This contract defines:
- canonical public URLs for Kinly Web
- how shared links behave across platforms
- how intent is inferred from URLs
- what share links MUST and MUST NOT do

The goal is to ensure that:
- shared links are reliable across Android, iOS, and desktop
- users are never misled about availability
- links never dead-end or auto-trigger unsafe behavior

---

## Core Principles

1. **Links are platform-neutral**
2. **Links never auto-open the app**
3. **Links never imply capability without confirmation**
4. **Links must always resolve to a readable web page**
5. **Capability (install / join) is decided after landing**

---

## Canonical Host

All Kinly share links MUST use a canonical host:
# Contract — Share Links & Canonical URLs v1.0

Domain: Links  
Capability: Share Links  
Status: Active  
Registry: `contracts/contracts_registry.md`

---

## Purpose

This contract defines:
- canonical public URLs for Kinly Web
- how shared links behave across platforms
- how intent is inferred from URLs
- what share links MUST and MUST NOT do

The goal is to ensure that:
- shared links are reliable across Android, iOS, and desktop
- users are never misled about availability
- links never dead-end or auto-trigger unsafe behavior

---

## Core Principles

1. **Links are platform-neutral**
2. **Links never auto-open the app**
3. **Links never imply capability without confirmation**
4. **Links must always resolve to a readable web page**
5. **Capability (install / join) is decided after landing**

---

## Canonical Host

All Kinly share links MUST use a canonical host:
https://go.makinglifeeasie.com


(Future aliases may exist, but must redirect to the canonical host.)

---

## Canonical Routes

### Preview Routes (Read-only)

| Route | Purpose |
|----|--------|
| `/` | Generic Kinly landing |
| `/norms/:homePublicId` | Public house norms (if published) |
| `/fallback` | Safe fallback for invalid links |

Preview routes:
- are readable globally
- MUST NOT imply app availability
- MUST NOT initiate install or join

---

### Join Routes (Invite-based)

| Route | Purpose |
|----|--------|
| `/join/:inviteCode` | Join a specific home |

Join routes:
- imply **intent to join**, not guaranteed success
- are capability-gated by region
- require a valid invite code

---

## Share Context & Intent Inference

Intent is inferred from the route:

| Route Type | Inferred Intent |
|----------|----------------|
| Preview routes | `preview` |
| `/join/:inviteCode` | `join` |

Intent inference:
- is advisory
- MUST NOT override region gating
- MAY be used for copy or interest capture context

---

## Query Parameters

### Allowed Parameters

| Parameter | Purpose |
|---------|--------|
| `src` | Share source identifier (e.g. android, ios, web) |
| `v` | Contract or content version (optional) |
| `next` | Internal continuation path (sanitized) |

---

### Parameter Rules

- `next` MUST:
  - be an internal path only
  - be sanitized server-side
  - never allow open redirects
- Unknown parameters MUST be ignored
- Parameters MUST NOT change gating behavior

---

## Cross-Platform Share Behavior

### Android → Android
- Link opens web landing
- Shows Play Store CTA if region-supported
- Does NOT auto-open app

### iOS → iOS
- Link opens web landing
- Shows App Store CTA if region-supported
- Does NOT auto-open app

### Mixed / Desktop
- Link opens web landing
- Shows appropriate CTAs based on region
- Always safe and readable

---

## Deep Link Interaction

- Deep links MAY be offered via explicit user action
- Deep links MUST NOT be triggered automatically
- Deep link mapping is governed by `links_deep_links_v1.md`

---

## Region Gating Interaction

This contract defers region logic to:
- links_region_gate_v1_1.md


Share links MUST:
- render safely before gating decisions
- never bypass region gating
- never imply install or join capability when unavailable

---

## OG Preview Requirements

All shareable routes MUST:
- provide Open Graph metadata
- use absolute URLs for images
- avoid embedding private data
- avoid region-specific promises

OG previews MUST be:
- neutral
- informational
- non-misleading

---

## Failure Handling

If:
- route is unknown
- invite code is malformed
- required data is missing

Then:
- route to `/fallback`
- provide readable explanation
- never surface raw errors

---

## Security Constraints

Share links MUST NOT:
- expose internal IDs unintentionally
- embed authentication tokens
- leak private home or member data
- enable join or install without explicit user action

---

## Non-Goals

This contract does NOT define:
- deep link URI schemes
- mobile app routing behavior
- analytics attribution models
- SEO optimization strategies

---

## Version History

| Version | Change |
|------|--------|
| v1.0 | Initial share links and canonical URL contract |

---

## Final Assertion

A Kinly share link must:
- always be safe to open
- always be truthful
- always be readable
- never pressure commitment
- never bypass capability checks

If a link does anything else, it violates this contract.
