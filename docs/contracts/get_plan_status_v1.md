---
Domain: Monetization
Capability: Plan Status Query
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: active
Version: v1.0
---

# get_plan_status RPC — v1.0

Purpose: Return the effective plan for the caller's current home.

## Signature

```sql
get_plan_status() -> jsonb
```

## Response Shape

```json
{ "plan": "free" | "premium", "home_id": "uuid" }
```

## Semantics

- **Current home**: The membership where `memberships.is_current = TRUE` for `auth.uid()`; at most one row is allowed.
- **Plan evaluation**: Uses `_home_effective_plan(home_id)` which considers subscription-backed entitlements with expiry awareness.

## Error Codes

| Code | SQLSTATE | Meaning |
|------|----------|---------|
| `NO_CURRENT_HOME` | 42501 | Caller has no current home. |
| `HOME_INACTIVE` | P0001 | Current home is inactive (via `_assert_home_active`). |

## Consumers

- [Profile Plan Button (mobile)](../../../product/kinly/mobile/profile_plan_button_v1.md)
