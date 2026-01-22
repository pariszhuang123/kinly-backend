# App Contracts v1 — Versioning and Update Policy

Status: Draft for MVP (home-only)

Scope: Client app version checks at startup to determine hard block or soft update recommendation.

```contracts-json
{
  "domain": "app",
  "version": "v1",
  "entities": {
    "AppVersion": {
      "id": "uuid",
      "versionNumber": "text",
      "minSupportedVersion": "text",
      "isCurrent": "boolean",
      "releaseDate": "timestamptz",
      "notes": "text|null"
    },
    "SharedPreference": {
      "userId": "uuid",
      "prefKey": "text",
      "prefValue": "jsonb",
      "createdAt": "timestamptz",
      "updatedAt": "timestamptz"
    },
    "AnalyticsEvent": {
      "id": "uuid",
      "userId": "uuid",
      "homeId": "uuid|null",
      "eventType": "text",
      "occurredAt": "timestamptz",
      "metadata": "jsonb"
    }
  },
  "functions": {
    "app.checkVersion": {
      "type": "rpc",
      "auth": "anonymous",
      "impl": "public.check_app_version",
      "args": {"client_version": "text"},
      "returns": "jsonb",
      "semantics": [
        "hardBlocked: client < minSupportedVersion",
        "updateRecommended: client < currentVersion and not hardBlocked"
      ]
    }
  },
  "db": {
    "extensions": ["pgcrypto"],
    "tables": {
      "public.app_version": {
        "indexes": [
          "uq_app_version(version_number)",
          "uq_app_version_is_current_true((true)) WHERE is_current"
        ],
        "constraints": [
          "chk_version_number",
          "chk_min_supported"
        ]
      },
      "public.shared_preferences": {
        "indexes": [
          "pk_shared_preferences(user_id, pref_key)"
        ],
        "constraints": []
      },
      "public.analytics_events": {
        "indexes": [
          "idx_analytics_events_user_event_time(user_id, event_type, occurred_at)",
          "idx_analytics_events_home_event_time(home_id, event_type, occurred_at)"
        ],
        "constraints": []
      }
    },
    "functions": {
      "public.check_app_version": {
        "type": "rpc",
        "args": {"client_version": "text"},
        "returns": "jsonb",
        "security": "definer",
        "owner": "postgres",
        "volatility": "stable",
        "nullInput": "returns null on null input",
        "grants": {
          "schemaUsage": ["anon", "authenticated"],
          "execute": ["anon", "authenticated"]
        }
      }
    }
  },
  "rls": [
    {"table": "public.app_version", "rule": "no client access; function-only (RLS enabled; anon/auth revoked)"},
    {"table": "public.shared_preferences", "rule": "RPC-only access; rows scoped by user_id"},
    {"table": "public.analytics_events", "rule": "append-only via RPCs; no direct client access"}
  ]
}
```

## Entities

AppVersion
- id (uuid, PK)
- versionNumber (text, unique; semver x.y.z numeric-only)
- minSupportedVersion (text; semver x.y.z)
- isCurrent (boolean; only one row allowed via partial unique index)
- releaseDate (timestamptz)
- notes (text|null)

SharedPreference
- userId (uuid, PK part)
- prefKey (text, PK part) — namespaced key such as `legal.consent.v1`
- prefValue (jsonb) — arbitrary structured preference payload
- createdAt / updatedAt (timestamptz) — managed by RPCs, not direct client writes

AnalyticsEvent
- id (uuid, PK)
- userId (uuid) — actor
- homeId (uuid|null) — optional context for home-scoped events
- eventType (text) — e.g., `home.created`, `legal.consent.accepted`
- occurredAt (timestamptz)
- metadata (jsonb) — structured payload (validated per event by server logic)

## RPCs

app.checkVersion(client_version: text) -> jsonb
- Caller: anonymous or authenticated (public check at startup).
- Returns JSON with keys: clientVersion, currentVersion, minSupportedVersion, hardBlocked, updateRecommended, notes, releasedAt.

## RLS
- public.app_version: no direct client reads/writes; managed by admins and read via RPC only.
