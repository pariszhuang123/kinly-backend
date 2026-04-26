---
Domain: Command
Capability: Navigation Module
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Depends-On: contracts/api/kinly/command/command_router_contract_v1_1.md
---

# Command Navigation Module v1.0

## 1. Purpose

The navigation module is the simplest module in the command system. It maps navigation intents to stable route keys that the client resolves into concrete deep links.

This module does NOT:

- Parse the effective user input
- Call an LLM
- Resolve entities
- Execute backend actions

It also handles the `unknown` intent as a silent fallback — routing the user home.

---

## 2. Parsing Strategy

None. Intent → route is a static map. No regex, no LLM, no escalation.

---

## 3. Intent → Route Mapping

| Intent | Route Key | Default path example | Description |
|--------|-----------|----------------------|-------------|
| `open_house_norms` | `house_norms` | `/house-norms` | House norms page |
| `view_due_items` | `today_view` | `/today` | Today / due items view |
| `view_service` | `services_home` | `/services` | Services directory |
| `unknown` | `home` | `/home` | Fallback — return to home screen |

---

## 4. Field Schema

| Field | Type | Source | Rule |
|-------|------|--------|------|
| `route_key` | string | Static intent map | Stable client route key from §3 |

---

## 5. Decision Rules

- All navigation intents MUST set `ui_hint.type` = `"route"`
- `risk_level` MUST be `"low"`
- `requires_confirmation` MUST be `false`
- `is_executable_now` MUST be `false` (routing is client-side)
- `executor` MUST be `"none"`
- `resolution.mode` MUST be `"not_applicable"`
- `status` MUST be `"complete"` (navigation always succeeds)
- `missing_fields` MUST be `[]`

---

## 6. Unknown Intent Handling

When intent is `unknown`:

- Module MUST route to `home`
- `summary` MUST be `"I didn't understand that. Taking you home."`
- The fallback SHOULD be silent and non-disruptive — no error toast, no modal

---

## 7. Examples

All examples follow the shared module envelope defined in the [Command Router Contract §9](command_router_contract_v1_1.md#9-module-contract-envelope-shared-shape).

### A. "house norms" → route to /house-norms

```json
{
  "contract_version": "1.1",
  "request_id": "req_nav_001",
  "source_intent": "open_house_norms",
  "module": "navigation",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": { "route_key": "house_norms" },
  "resolution": { "mode": "not_applicable", "entity_type": "none" },
  "ui_hint": {
    "type": "route",
    "component": null,
    "target": "/house-norms",
    "prefill": null,
    "options": []
  },
  "summary": "Open house norms",
  "policy": {
    "suggested_outcome": "route",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "none"
  }
}
```

### B. "what's due" → route to /today

```json
{
  "contract_version": "1.1",
  "request_id": "req_nav_002",
  "source_intent": "view_due_items",
  "module": "navigation",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": { "route_key": "today_view" },
  "resolution": { "mode": "not_applicable", "entity_type": "none" },
  "ui_hint": {
    "type": "route",
    "component": null,
    "target": "/today",
    "prefill": null,
    "options": []
  },
  "summary": "View due items",
  "policy": {
    "suggested_outcome": "route",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "none"
  }
}
```

### C. "what's the weather" → unknown fallback to /home

```json
{
  "contract_version": "1.1",
  "request_id": "req_nav_003",
  "source_intent": "unknown",
  "module": "navigation",
  "status": "complete",
  "missing_fields": [],
  "risk_level": "low",
  "fields": { "route_key": "home" },
  "resolution": { "mode": "not_applicable", "entity_type": "none" },
  "ui_hint": {
    "type": "route",
    "component": null,
    "target": "/home",
    "prefill": null,
    "options": []
  },
  "summary": "I didn't understand that. Taking you home.",
  "policy": {
    "suggested_outcome": "route",
    "requires_confirmation": false,
    "is_executable_now": false,
    "executor": "none"
  }
}
```
