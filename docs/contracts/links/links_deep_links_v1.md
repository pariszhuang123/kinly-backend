# Contract — Deep Link Mapping & App Handoff v1.0

Domain: Links  
Capability: Deep Link Mapping  
Status: Active  
Registry: `contracts/contracts_registry.md`

---

## Purpose

This contract defines:
- how Kinly Web offers deep links into the Kinly app
- how web routes map to in-app destinations
- how join intent is safely handed off to the app
- required fallback behavior when deep links fail

The goal is to ensure:
- no deep link assumes install, authentication, or membership
- all failures resolve safely
- onboarding remains resilient and non-surprising

---

## Core Principles

1. **Deep links are always user-initiated**
2. **Web never assumes the app is installed**
3. **Deep links never assume authentication**
4. **Deep links never assume membership**
5. **Fallback destinations are auth-aware**
6. **Welcome is the safe destination when unauthenticated**
7. **Start is the safe destination when authenticated but not a member**
8. **Today is reachable only after a successful join**

---
## Definitions

### Deep Link
A URI that attempts to open the Kinly app and pass contextual intent.

Example scheme (illustrative only):

kinly://...


---

### User-Initiated Action

A deep link may only be triggered by:
- an explicit tap or click
- a clearly labeled CTA (e.g. “Open in Kinly”)

Deep links MUST NOT be triggered:
- on page load
- via redirects
- via timers or background scripts

---

## Capability Preconditions (Web)

Before offering a deep link CTA, the web layer MUST confirm:

1. The visitor is in a **supported region**
2. The route context allows capability

If capability is unavailable:
- deep links MUST NOT be offered
- store CTAs MUST NOT be shown

Region gating rules are defined in:
`links_region_gate_v1_1.md`

---
## App Entry Surfaces (Authoritative)

The Kinly app has three distinct entry surfaces:

| Surface | Preconditions |
|------|---------------|
| **Welcome** | App installed, user NOT authenticated |
| **Start** | User authenticated, NOT yet a home member |
| **Today** | User authenticated AND home membership resolved |

Deep link handling MUST respect this ordering.

---

## Web → App Route Mapping

### Preview Routes

| Web Route | App Destination |
|---------|----------------|
| `/` | Welcome or Start (auth-aware) |
| `/norms/:homePublicId` | Welcome or Start (auth-aware) |

Preview routes:
- MUST NOT deep link automatically
- MAY offer a deep link CTA if capability is available
- MUST fall back to **Start**

---

### Join Routes

| Web Route | App Destination |
|---------|----------------|
| `/join/:inviteCode` | Start → Pending Join |

Join routes:
- MAY offer deep link CTA if region is supported
- MUST pass invite code as join intent
- MUST NOT complete join on the web

---

## Deep Link Payload Rules

Deep link payloads MUST be minimal.

Allowed:
- invite code (join routes only)
- optional source identifier

MUST NOT include:
- authentication tokens
- user identifiers
- private home data
- membership assumptions

---

## Pending Join Intent Handling (App)

When a deep link includes an invite code:

1. The app MUST persist the invite code as a **pending join intent**
2. The join MUST NOT be executed until:
   - the user is authenticated
   - required app state is available

After authentication:
- attempt join resolution
- if join succeeds → navigate to **Today**
- if join fails → navigate to **Start**

Pending join intent MUST be cleared after resolution attempt.

---

## App-Side Responsibilities

When the app receives a deep link:

1. Validate the payload
2. Persist intent if present
3. Resolve authentication state
4. Attempt intent resolution (if applicable)

If ANY step fails:
- determine authentication state
- navigate to **Welcome** if unauthenticated
- navigate to **Start** if authenticated
- do not crash
- do not block the user

---

## Failure Scenarios & Required Behavior

| Scenario | Required Outcome |
|--------|------------------|
| App not installed | User remains on web |
| App installed but cannot parse link | Apply auth-aware fallback |
| Invite invalid or expired | Apply auth-aware fallback |
| Join resolution fails | Apply auth-aware fallback |
| App routing error | Apply auth-aware fallback |

No failure may strand the user or assume membership.

### Auth-Aware Fallback Logic

| Auth State | Fallback Destination |
|---------|---------------------|
| Not authenticated | **Welcome** |
| Authenticated, no home | **Start** |
| Authenticated, home exists | **Start** (never Today) |

---

## Region Gating Interaction

Deep links MUST:
- respect `links_region_gate_v1_1.md`
- never be offered outside supported regions
- never imply install or join capability where unavailable

Region gating decisions are authoritative.

---

## Analytics & Logging

- Deep link attempts MAY be logged
- Logs MUST NOT include:
  - invite codes
  - personal identifiers
  - raw deep link URIs

Failure reasons MAY be logged using reason codes only.

---

## Non-Goals

This contract does NOT define:
- URI scheme registration
- platform-specific deep link handlers
- deferred deep linking after install
- attribution or analytics strategy

Those concerns belong to the mobile app.

---

## Version History

| Version | Change |
|------|--------|
| v1.0 | Initial deep link mapping with Start-screen fallback |

---

## Final Assertion

A Kinly deep link must:
- never assume install, auth, or membership
- always be intentional
- always fail safely
- land on Welcome or Start based on authentication state
- reach Today only after a successful join

Any deep link behavior violating these principles
is a contract breach.
