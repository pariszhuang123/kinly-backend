---
Domain: Command
Capability: AI Command Quota
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Relates-To: contracts/api/kinly/command/command_router_contract_v1_1.md, contracts/api/kinly/homes/paywall_status_get_v1.md
---

# Command AI Quota Contract v1.0

## 1. Purpose

This contract defines the backend quota rules for AI-powered command requests before the router classifier LLM is invoked.

This contract owns:

- what metric is counted
- when requests count
- what does not count
- premium-home bypass behavior
- idempotency and replay behavior
- the minimum backend state that status surfaces must expose

---

## 2. Metric

| Field | Value |
|-------|-------|
| Metric name | `ai_command_requests` |
| Scope | per user |
| Window | UTC calendar day |
| Reset boundary | `00:00:00 UTC` |
| Allowance | backend-configured integer |

Free-tier users MAY create up to `N` `ai_command_requests` per UTC calendar day, where `N` is backend-configured.

If the caller's current home is premium, the free-tier AI quota MUST NOT block access.

Premium-home bypass does not remove the need for separate abuse or service-protection limits.

When premium-home bypass is active:

- usage MAY still be observed and surfaced for analytics or UI reference
- the free-tier allowance remains the reference value exposed in status surfaces
- the reference allowance MUST NOT be treated as an enforced premium cap

---

## 3. Counting Rules

An AI command request counts when the backend accepts it into the classifier pipeline.

An AI command request MUST NOT count when:

- auth fails before the request reaches the classifier stage
- home-context validation fails before the classifier stage
- the request is empty or malformed before classifier invocation
- transport failure, timeout, or internal failure happens before classifier completion
- the request is a `module_continue` follow-up that bypasses the router/classifier
- a routed module performs additional scoped LLM parsing within the same command thread after the original request was already charged

Low-confidence unknown requests still count when they consumed the classifier call.

---

## 4. Idempotency

Quota charging MUST be idempotent on `request_id` within the same UTC calendar day.

Rules:

- the same `request_id` received multiple times in the same UTC day MUST charge quota at most once
- post-upgrade replay of a previously blocked AI request SHOULD reuse the original `request_id`
- if the replay reuses the original `request_id`, the backend MUST NOT charge quota twice

This rule exists to protect against flaky clients, duplicate submissions, and deterministic replay after the paywall flow.

---

## 5. Enforcement

Quota enforcement MUST happen server-side before the router classifier LLM call.

The backend MUST:

- be source-of-truth for allowance, usage, and reset timing
- reject over-quota requests even if the client fails to pre-check status
- handle concurrent requests without double-charging
- expose enough state for the client to show current usage and next reset time

When quota is exhausted for a free-tier user, the backend MUST return a machine-readable error indicating daily AI quota exhaustion.

Canonical backend error code:

`paywall_ai_command_daily_limit`

Client/app-layer mapping MAY translate this to local constants such as `paywallAiCommandDailyLimit`, but the mapping MUST be explicit and stable.

---

## 6. Minimum Status Shape

Any canonical paywall/quota status surface that supports command entry MUST be able to return:

```json
{
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

Field rules:

- `used` is the number of charged requests in the current UTC day
- `limit` is the effective configured free-tier allowance
- `resets_at` is the next reset boundary in UTC
- `window` MUST equal `"utc_calendar_day"`
- `bypassed_by_premium_home` is `true` when current entitlement bypasses the free-tier cap

---

## 7. Backend LLM Requirements

The router classifier LLM call is backend-owned and MUST follow these rules:

- gate the LLM call behind auth, home-context validation, and quota enforcement
- use the router contract as the canonical output schema
- pass a stable `request_id` through quota, logging, and downstream module invocations
- log classifier failures, timeouts, and low-confidence unknowns for observability and feature discovery
- reject any attempt for the client to bypass server classification by supplying a claimed intent result
- bound cost and latency with a lightweight intent-only prompt

The backend SHOULD:

- record model/provider version metadata in audit logs
- apply abuse controls separately from entitlement quota

### Interpretation notes

- `ai_command_requests` is a user-visible quota for entering the command pipeline, not a raw count of every backend model invocation
- one command thread identified by its original `request_id` MUST charge at most once
- modules SHOULD prefer deterministic parsing for follow-up turns and only use a scoped module-specific LLM when deterministic resolution is not safe enough
