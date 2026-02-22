# Contract — Region Gating & Interest Capture v1.1

Domain: Links  
Capability: Region Gating  
Status: Active  
Registry: `contracts/contracts_registry.md`

---

## Purpose

This contract governs:
- how Kinly Web determines regional availability
- what users can do before the app is available in their country
- how install and join capabilities are gated
- how interest is captured ethically and minimally
- how public content remains readable without misleading users

Kinly Web does NOT create homes.  
Home creation occurs only inside the Kinly app after authentication.

---

## Core Invariant

> If a user cannot download the Kinly app in their region,  
> then **both “explore” and “join” capabilities are unavailable**.  
> Only **preview (read-only)** is allowed.

---

## Supported Regions (v1)

Kinly app availability is limited to the following countries
(ISO-3166-1 alpha-2):
- NZ
- SG


Only supported regions may:
- install the app
- open the app
- join a home

---

## Inputs

### Geo Detection (Best Effort)

- Source: Edge / platform geo headers
- Field: `country_code` (ISO-3166-1 alpha-2)

Geo detection is advisory, not authoritative.

---

## Region Classification

| Condition | Classification |
|---------|----------------|
| `country_code ∈ supported` | Supported |
| `country_code ∉ supported` | Unsupported |
| `country_code missing` | Unsupported |

Unknown is treated as unsupported.

---

## Capability Model

Kinly Web recognizes **three capability levels**:

| Level | Meaning |
|-----|--------|
| **Preview** | Read-only access to public content |
| **Capability** | Ability to install and open the app |
| **Join** | Capability + valid invite to a home |

There is **no web-level “create” capability**.

---

## Route Categories

### Preview Routes (Read-only)

Preview routes allow users to understand Kinly without implying availability.

Examples:
- `/`
- generic app share links
- `/norms/:homePublicId` (only if published)
- informational pages

Preview routes:
- are accessible in all regions
- MUST NOT imply app availability
- MUST NOT trigger install, open, or join actions

---

### Capability Routes (Install / Open App)

Routes or CTAs whose primary purpose is to:
- install the app
- open the app
- transition the user into app usage

Capability routes are **region-gated**.

---

### Join Routes

Routes whose primary purpose is to join a specific home via invite code.

Examples:
- `/join/:inviteCode`

Join routes are subject to:
- region gating **and**
- invite validity

---

## Routing Rules

### Preview Routes

- Always render content
- Never blocked by region
- Must not show misleading availability signals

---

### Capability Routes

#### If Supported
- Show App Store and Play Store CTAs
- Allow app deep link (user-initiated only)

#### If Unsupported
- Do NOT show active store CTAs
- Do NOT allow app deep linking
- MAY show “Coming soon” messaging
- MAY offer optional interest capture

---

### Join Routes

#### If Supported
- Allow join flow
- Show store CTAs
- Allow app deep link (user-initiated only)

#### If Unsupported
- Do NOT allow join
- Redirect to `/interest`
- Preserve intent via sanitized `next` parameter
- Copy must not imply current availability

---

## Interest Capture (`/interest`)

Interest capture exists to:
- record regional demand
- notify users when Kinly becomes available
- prevent misleading access

Interest capture MUST NOT bypass region gating.

---

### Required Fields

- `email`
- `selected_country_code` (ISO-3166-1 alpha-2)

---

### Optional Fields

- `detected_country_code`
- `source_path` (sanitized internal path only)
- `user_agent`
- `intent_type` ∈ { `preview`, `capability`, `join` }

`intent_type` is advisory only.

---

### Prohibited Fields

- IP address
- precise location
- demographic attributes
- behavioral tracking identifiers

---

## Country Prepopulation Rules

1. If `detected_country_code` exists:
   - Preselect it in the UI
   - Label as “Detected”
2. User MUST be able to change country
3. If user changes country:
   - Both detected and selected values may be stored
4. If detection is missing:
   - Country selection is required

Suggested countries may be shown but must not restrict selection.

---

## Persistence Rules

All interest data MUST be persisted via:

Web → Edge Function → Postgres RPC (SECURITY DEFINER)


Direct database writes are forbidden.

---

## Failure Handling

If:
- geo detection fails
- routing intent is invalid
- interest submission fails

Then:
- render a safe UI state
- do not dead-end
- route to `/fallback` or `/`

Raw errors must never be exposed.

---

## Security & Privacy Guarantees

- Preview is always allowed
- Capability and join are region-gated
- Join is additionally invite-gated
- Creation is app-only
- Data minimization is mandatory
- Public content must not imply availability

---

## Non-Goals

This contract does NOT cover:
- home creation
- deferred deep linking
- marketing analytics
- payments or waitlists
- feature gating beyond install/join availability

---

## Version History

| Version | Change |
|------|--------|
| v1.0 | Initial region gating |
| v1.1 | Introduced Preview / Capability / Join model; aligned with App Store reality |

---

## Final Assertion

Kinly Web must:
- never imply install capability where unavailable
- never allow joining from unsupported regions
- clearly distinguish preview from capability
- always offer a respectful fallback

Any behavior violating these principles is a contract breach.
