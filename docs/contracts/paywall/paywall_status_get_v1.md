---
Domain: Monetization
Capability: Paywall Status Query
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Relates-To: contracts/api/kinly/homes/get_plan_status_v1.md, contracts/api/kinly/command/command_ai_quota_v1.md
---

# paywall_status_get RPC v1.0

## 1. Purpose

Return the effective paywall status for a home, including home-scoped usage/limits and any required user-scoped quota state needed by paywall-triggered features.

This RPC exists for paywall-aware UI flows. It is broader than `get_plan_status()`, which returns plan identity only.

---

## 2. Signature

```sql
paywall_status_get(p_home_id uuid) -> jsonb
```

---

## 3. Response Shape

```json
{
  "plan": "free",
  "expires_at": null,
  "is_premium": false,
  "usage": {
    "active_chores": 3,
    "expense_photos": 1
  },
  "limits": [
    { "metric": "active_chores", "max_value": 20 },
    { "metric": "expense_photos", "max_value": 15 }
  ],
  "userQuotas": {
    "ai_command_requests": {
      "used": 3,
      "limit": 5,
      "resets_at": "2026-04-12T00:00:00Z",
      "window": "utc_calendar_day",
      "bypassed_by_premium_home": false
    }
  }
}
```

### Required fields

- `plan`
- `expires_at`
- `usage`
- `limits`

### Conditional fields

- `is_premium` MAY be returned as a deprecated compatibility field derived from `plan` and `expires_at`
- `userQuotas.ai_command_requests` MUST be present whenever the authenticated caller is eligible to use the command feature under current server-side feature configuration

---

## 4. Semantics

- `plan` reflects the effective home entitlement state
- `expires_at` reflects the effective home entitlement expiry when applicable
- `usage` contains current home-scoped paywall counters
- `limits` contains the effective plan limits for home-scoped metrics
- `userQuotas.ai_command_requests` reflects the caller's current per-user AI quota state for the UTC calendar day
- `bypassed_by_premium_home` is `true` when the current home entitlement bypasses the free-tier AI cap
- `is_premium`, when returned, is deprecated convenience output only. Clients SHOULD derive premium state from `plan` and `expires_at` instead of depending on this field long-term.

When `bypassed_by_premium_home == true`:

- `used` MAY still reflect observed usage for the current UTC day
- `limit` MUST remain the configured free-tier allowance for reference, not an enforced premium cap
- clients MUST treat the quota as informational only, not blocking

This RPC is a status surface only. It MUST NOT itself charge usage.

---

## 5. AI Quota Rules

When present, `userQuotas.ai_command_requests` MUST align with `command_ai_quota_v1.md`.

Specifically:

- `used` is charged request count for the current UTC day
- `limit` is backend-configured free-tier allowance
- `resets_at` is the next UTC reset boundary
- `window` MUST equal `"utc_calendar_day"`
- premium-home bypass MUST be reflected via `bypassed_by_premium_home`
- field presence MUST be determined server-side, not by client-specific heuristics

---

## 6. Error Codes

| Code | Meaning |
|------|---------|
| `NO_CURRENT_HOME` | Caller has no current home |
| `HOME_INACTIVE` | Home is inactive |
| `HOME_ACCESS_DENIED` | Caller cannot query paywall state for the supplied home |

---

## 7. Consumer Notes

- Paywall UI uses this RPC to render cap state and reset timing
- Command surfaces use this RPC to preflight user-visible AI quota messaging, but backend enforcement still occurs inside the command entrypoint
- This RPC is a status surface for both home-scoped caps and user-scoped command AI quota. It is not the enforcement surface for either.
- Clients MAY map backend error/status fields into local enums or constants, but those mappings MUST remain explicit
