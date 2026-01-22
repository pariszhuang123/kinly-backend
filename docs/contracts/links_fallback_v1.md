# Contract — Fallback Routing & Failure Handling v1.0

Domain: Links  
Capability: Fallback Behavior  
Status: Active  
Registry: `contracts/contracts_registry.md`

---

## Purpose

This contract defines:
- what constitutes a routing or resolution failure
- how Kinly Web and the Kinly app must recover from failures
- the correct fallback destinations based on authentication state

The goal is to ensure:
- users are never stranded
- fallbacks never assume state that does not exist
- onboarding remains calm, safe, and reversible

---

## Core Invariant

> **A fallback must never assume authentication or membership.**  
> The deepest assumption a fallback may make is the one already proven.

---

## App Entry Surfaces (Authoritative)

The Kinly app has three distinct entry surfaces:

| Surface | Preconditions |
|------|---------------|
| **Welcome** | App installed, user NOT authenticated |
| **Start** | User authenticated, NOT yet a home member |
| **Today** | User authenticated AND home membership resolved |

Fallbacks MUST respect this ordering.

---

## Failure Classes

A failure is any condition where the intended outcome cannot be safely
completed.

### Web-Level Failures

- unknown or malformed route
- missing or invalid invite code
- region capability unavailable
- required data missing
- internal routing error

---

### App-Level Failures

- deep link payload invalid or unparsable
- user not authenticated when required
- join resolution fails
- invite invalid or expired
- app routing error

---

## Web Fallback Behavior

### Universal Web Fallback Route


The `/fallback` route MUST:
- always render successfully
- be readable in all regions
- never imply install or join capability
- explain next safe actions clearly

---

### Web Fallback Rules

When a web-level failure occurs:

1. Route to `/fallback`
2. Preserve context where safe (e.g. source path)
3. Do NOT expose internal errors
4. Do NOT imply availability where unavailable
5. Offer preview-level navigation only

---

## App Fallback Behavior

### Universal App Fallback Logic

The app MUST determine fallback destination based on authentication state.

---

### App Fallback Rules

When an app-level failure occurs:

1. Determine authentication state
2. Route accordingly:

| Auth State | Fallback Destination |
|---------|---------------------|
| Not authenticated | **Welcome** |
| Authenticated, no home | **Start** |
| Authenticated, home exists | **Start** (never Today) |

3. Clear any unresolved intent
4. Do NOT block user progression
5. Do NOT crash or loop

---

## Join-Specific Fallback Rules

If a join intent cannot be resolved:

- Clear pending join intent
- Apply universal app fallback logic
- Optionally display calm, non-blocking copy

Join failure MUST NOT strand the user.

---

## Region Gating Interaction

Fallback behavior MUST:
- respect `links_region_gate_v1_1.md`
- never bypass region gating
- never imply install or join where unavailable

---

## Copy & UX Constraints

Fallback copy MUST:
- be calm and non-blaming
- avoid technical language
- offer clear next steps
- avoid exposing error codes

Error codes MAY be logged but MUST NOT be surfaced.

---

## Security & Privacy

Fallback handling MUST NOT:
- leak private identifiers
- expose internal routing or stack traces
- persist invalid state
- log sensitive user data

---

## Non-Goals

This contract does NOT define:
- retry policies beyond safe navigation
- marketing messaging
- analytics or attribution strategy
- platform-specific UI design

---

## Version History

| Version | Change |
|------|--------|
| v1.0 | Initial fallback contract with auth-aware destinations |

---

## Final Assertion

A fallback must:
- always succeed
- assume only proven state
- never escalate user commitment
- never imply unavailable capability

If a fallback assumes authentication or membership incorrectly,
it is a contract breach.
