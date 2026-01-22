import {
  parseDate,
  parseWebhookPayload,
  statusFromEvent,
  storeFromPayload,
} from "./parse.ts";
import { extractBearerTokenStrict, handleRevenueCatWebhook, SupabaseLike } from "./index.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

const env = {
  SUPABASE_URL: "http://localhost",
  SUPABASE_SERVICE_ROLE_KEY: "service",
  RC_WEBHOOK_SECRET: "secret",
};

const createMockSupabase = (overrides: Partial<SupabaseLike> = {}): SupabaseLike => ({
  rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) =>
    Promise.resolve({ error: null } as { error: null; data?: T }),
  from: (_table: string) => ({
    upsert: (
      _row: Record<string, unknown>,
      _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
    ) => Promise.resolve({ error: null, data: [] }),
  }),
  ...overrides,
});

Deno.test("statusFromEvent maps RevenueCat events", () => {
  expect(statusFromEvent("INITIAL_PURCHASE").status === "active", "initial purchase should be active");
  expect(statusFromEvent("CANCELLATION").status === "cancelled", "cancellation should be cancelled");
  expect(statusFromEvent("EXPIRATION").status === "expired", "expiration should be expired");
  expect(statusFromEvent("UNKNOWN").status === "inactive", "unknown should be inactive");
});

Deno.test("storeFromPayload normalizes store", () => {
  expect(storeFromPayload("app_store").store === "app_store", "app_store stays app_store");
  expect(storeFromPayload("google").store === "play_store", "google -> play_store");
  expect(storeFromPayload("stripe").store === "stripe", "stripe stays stripe");
  expect(storeFromPayload("something").store === "unknown", "fallback -> unknown");

  const testStore = storeFromPayload("test_store");
  expect(testStore.store === "play_store", "test_store treated as play_store");
  expect(testStore.isTestStore === true, "test_store flagged as test");
});

Deno.test("parseDate accepts ms / seconds / iso", () => {
  const iso = parseDate("2025-01-01T00:00:00Z");
  if (iso === null) throw new Error("parseDate(iso) returned null");
  expect(iso.startsWith("2025-01-01"), "iso parse should start with date");

  const fromSeconds = parseDate("1735689600"); // seconds for 2025-01-01
  if (fromSeconds === null) throw new Error("parseDate(seconds) returned null");
  expect(fromSeconds.startsWith("2025-01-01"), "seconds parse should start with date");

  const fromMs = parseDate(1735689600000);
  if (fromMs === null) throw new Error("parseDate(ms) returned null");
  expect(fromMs.startsWith("2025-01-01"), "ms parse should start with date");
});

Deno.test("parseWebhookPayload resolves entitlements and subscriber_attributes first", () => {
  const parsed = parseWebhookPayload({
    event: {
      id: "evt-1",
      entitlement_ids: ["ent_one", "ent_two"],
      subscriber_attributes: {
        user_id: { value: "00000000-0000-4000-8000-000000000abc" },
        home_id: { value: "00000000-0000-4000-8000-000000000def" },
      },
      aliases: ["anon", "00000000-0000-4000-8000-000000000999"],
    },
    entitlement_ids: ["should_not_pick"],
  });

  expect(parsed.rcEventId === "evt-1", "rc_event_id parsed");
  expect(parsed.primaryEntitlementId === "ent_one", "primary entitlement from event.entitlement_ids");
  expect(parsed.rcUserId === "00000000-0000-4000-8000-000000000abc", "user_id from subscriber_attributes");
  expect(parsed.homeId === "00000000-0000-4000-8000-000000000def", "home_id from subscriber_attributes");
});

Deno.test("parseWebhookPayload falls back to alias UUID if app_user_id is not uuid", () => {
  const parsed = parseWebhookPayload({
    event: {
      app_user_id: "rc_anon_user",
      aliases: ["alias", "00000000-0000-4000-8000-00000000aaaa"],
      entitlement_ids: ["ent"],
    },
  });
  expect(parsed.rcUserId === null, "subscriber_attributes.user_id is required; aliases ignored");
});

Deno.test("parseWebhookPayload tolerates missing event and home", () => {
  const parsed = parseWebhookPayload({});
  expect(parsed.rcUserId === null, "no user without data");
  expect(parsed.homeId === null, "home null when missing");
});

Deno.test("extractBearerToken handles bearer and raw tokens", () => {
  expect(extractBearerTokenStrict("Bearer abc") === "abc", "capitalized bearer should strip prefix");
  expect(extractBearerTokenStrict("bearer abc") === "abc", "lowercase bearer should strip prefix");
  expect(extractBearerTokenStrict("abc") === null, "raw token rejected");
  expect(extractBearerTokenStrict(null) === null, "null token returns null");
});

Deno.test("handleRevenueCatWebhook rejects unauthorized", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer nope" },
    body: JSON.stringify({}),
  });

  const calls: string[] = [];
  const res = await handleRevenueCatWebhook(
    req,
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        calls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          calls.push("upsert");
          return Promise.resolve({ error: null });
        },
        select: (_columns: string) => ({
          eq: (_col: string, _val: unknown) => {
            calls.push("select");
            return Promise.resolve({ error: null, count: 0 });
          },
        }),
      }),
    }),
  );

  expect(res.status === 401, "unauthorized should return 401");
  expect(calls.length === 0, "no db calls on unauthorized");
});

Deno.test("missing user uuid returns fatal 400", async () => {
  const upserts: Array<{ row: Record<string, unknown> }> = [];

  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer secret" },
    body: JSON.stringify({
      event: {
        id: "evt-user-missing",
        entitlement_ids: ["ent_a"],
      },
      product_id: "prod",
    }),
  });

  const res = await handleRevenueCatWebhook(
    req,
    env,
    (_url, _key) =>
      createMockSupabase({
        from: (_table) => ({
          upsert: (
            row: Record<string, unknown>,
            _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
          ) => {
            upserts.push({ row });
            return Promise.resolve({ error: null });
          },
        }),
      }),
  );

  expect(res.status === 400, "missing user returns 400");
  const body = await res.json();
  expect(body.error_code === "missing_user_uuid", "error code surfaced");
  expect(upserts.length === 1, "audit row inserted");
  expect(upserts[0].row.fatal_error_code === "missing_user_uuid", "fatal error stored");
});

Deno.test("missing entitlement/product returns fatal 400", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer secret" },
    body: JSON.stringify({
      event: {
        id: "evt-ent-missing",
        app_user_id: "00000000-0000-4000-8000-000000000555",
        product_id: "prod",
        store: "google",
        subscriber_attributes: {
          user_id: { value: "00000000-0000-4000-8000-000000000555" },
          home_id: { value: "00000000-0000-4000-8000-000000000444" },
        },
      },
    }),
  });

  const upserts: Array<Record<string, unknown>> = [];
  const rpcs: Array<Record<string, unknown>> = [];

  const res = await handleRevenueCatWebhook(
    req,
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, args: Record<string, unknown>) => {
        rpcs.push(args);
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        insert: (row: Record<string, unknown>) => Promise.resolve({ error: null, data: [row] }),
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          upserts.push(row);
          return Promise.resolve({ error: null });
        },
        select: (_columns: string) => ({
          eq: (_col: string, _val: unknown) => Promise.resolve({ error: null, count: 0 }),
        }),
      }),
    }),
  );

  expect(res.status === 400, "missing entitlement returns 400");
  const body = await res.json();
  expect(body.error_code === "missing_entitlement", "error recorded");
  expect(rpcs.length === 0, "no rpc call");
  expect(upserts.length === 1, "audit row stored");
});

Deno.test("dedupes by rc_event_id and skips rpc on duplicate", async () => {
  const rpcs: Array<Record<string, unknown>> = [];
  let rpcCallCount = 0;

  const payload = {
    event: {
      id: "evt-dedupe",
      app_user_id: "00000000-0000-4000-8000-000000000111",
      entitlement_ids: ["ent_a"],
      product_id: "prod_a",
      store: "google",
      subscriber_attributes: {
        user_id: { value: "00000000-0000-4000-8000-000000000111" },
        home_id: { value: "00000000-0000-4000-8000-000000000222" },
      },
    },
  };

  const requestFactory = () =>
    new Request("http://localhost", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer secret" },
      body: JSON.stringify(payload),
    });

  const supabaseFactory = (_url: string, _key: string) =>
    createMockSupabase({
      rpc: <T = unknown>(_fn: string, args: Record<string, unknown>) => {
        rpcCallCount += 1;
        const deduped = rpcCallCount > 1 ? true : false;
        rpcs.push(args);
        return Promise.resolve({ error: null, data: deduped as unknown as T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => Promise.resolve({ error: null }),
      }),
    });

  const res1 = await handleRevenueCatWebhook(requestFactory(), env, supabaseFactory);
  expect(res1.status === 200, "first call 200");
  const body1 = await res1.json();
  expect(body1.ok === true, "first call ok");
  expect(rpcs.length === 2, "two rpcs on first call (subscription + status)");

  const res2 = await handleRevenueCatWebhook(requestFactory(), env, supabaseFactory);
  expect(res2.status === 200, "second call 200");
  const body2 = await res2.json();
  expect(body2.deduped === true, "deduped flag set");
  expect(rpcs.length === 4, "two more rpcs on retry (deduped + status refresh)");
});

Deno.test("calls paywall_record_subscription on valid payload", async () => {
  const payload = {
    event: {
      id: "evt-valid",
      app_user_id: "00000000-0000-4000-8000-000000000000",
      entitlement_ids: ["kinly_premium"],
      product_id: "com.example.kinly.premium.monthly",
      type: "INITIAL_PURCHASE",
      subscriber_attributes: {
        user_id: { value: "00000000-0000-4000-8000-000000000000" },
        home_id: { value: "00000000-0000-4000-8000-000000000123" },
      },
    },
    store: "google",
  };

  const rpcs: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer secret" },
    body: JSON.stringify(payload),
  });

  const res = await handleRevenueCatWebhook(
    req,
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(fn: string, args: Record<string, unknown>) => {
        rpcs.push({ fn, args });
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => Promise.resolve({ error: null }),
      }),
    }),
  );

  expect(res.status === 200, "valid payload returns 200");
  const body = await res.json();
  expect(body.ok === true, "body ok true");
  expect(rpcs.length === 2, "two rpc calls (record subscription + refresh status)");
  expect(rpcs[0]?.fn === "paywall_record_subscription", "first rpc name correct");
  expect(rpcs[0]?.args.p_store === "play_store", "store normalized to play_store");
  expect(rpcs[0]?.args.p_status === "active", "status normalized");
  expect(rpcs[0]?.args.p_home_id === "00000000-0000-4000-8000-000000000123", "home id provided");
  expect(rpcs[1]?.fn === "paywall_status_get", "second rpc refreshes status");
});

Deno.test("logs missing_latest_transaction_id but still calls rpc", async () => {
  const payload = {
    event: {
      id: "evt-missing-txn",
      app_user_id: "00000000-0000-4000-8000-000000000222",
      entitlement_ids: ["ent_x"],
      product_id: "prod_x",
      type: "RENEWAL",
      store: "google",
      subscriber_attributes: {
        user_id: { value: "00000000-0000-4000-8000-000000000222" },
        home_id: { value: "00000000-0000-4000-8000-000000000333" },
      },
    },
  };

  const rpcs: Array<Record<string, unknown>> = [];
  const upserts: Array<Record<string, unknown>> = [];

  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer secret" },
    body: JSON.stringify(payload),
  });

  const res = await handleRevenueCatWebhook(
    req,
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, args: Record<string, unknown>) => {
        rpcs.push(args);
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        insert: (_row: Record<string, unknown>) => Promise.resolve({ error: null, data: [] }),
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          upserts.push(row);
          return Promise.resolve({ error: null });
        },
        select: (_columns: string) => ({
          eq: (_col: string, _val: unknown) => Promise.resolve({ error: null, count: 0 }),
        }),
      }),
    }),
  );

  expect(res.status === 200, "returns 200 even when txn missing");
  const body = await res.json();
  expect(body.ok === true, "ok true");
  expect(rpcs.length === 2, "two rpcs (subscription + status refresh)");
  const warnings = (upserts[0] as { warnings?: string[] } | undefined)?.warnings ?? [];
  expect(warnings.includes("missing_latest_transaction_id"), "missing txn logged");
});

Deno.test("rejects non-POST without touching Supabase", async () => {
  const calls: string[] = [];
  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", { method: "GET" }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        calls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          calls.push("upsert");
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 405, "GET should be rejected");
  expect(calls.length === 0, "no supabase calls on method guard");
});

Deno.test("payload over limit returns 413 and skips Supabase", async () => {
  const bigBody = JSON.stringify({ big: "a".repeat(300_000) });
  const calls: string[] = [];

  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: {
        authorization: "Bearer secret",
        "content-type": "application/json",
        "content-length": String(bigBody.length),
      },
      body: bigBody,
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        calls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          calls.push("upsert");
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 413, "over-limit payload should be rejected");
  expect(calls.length === 0, "no supabase calls when payload too large");
});

Deno.test("non-object body returns 400 invalid_body and skips Supabase", async () => {
  const calls: string[] = [];
  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: JSON.stringify(["not", "an", "object"]),
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        calls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          _row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          calls.push("upsert");
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 400, "non-object body should return 400");
  const body = await res.json();
  expect(body.error_code === "invalid_body", "invalid_body surfaced");
  expect(calls.length === 0, "no supabase calls for invalid body");
});

Deno.test("audit write failure returns 500 retryable and skips rpc", async () => {
  const upserts: Array<Record<string, unknown>> = [];
  const rpcs: string[] = [];

  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: JSON.stringify({
        event: {
          id: "evt-audit-fail",
          entitlement_ids: ["ent_a"],
          product_id: "prod_a",
          store: "google",
          subscriber_attributes: {
            user_id: { value: "00000000-0000-4000-8000-000000000111" },
            home_id: { value: "00000000-0000-4000-8000-000000000222" },
          },
        },
      }),
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        rpcs.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          upserts.push(row);
          return Promise.resolve({ error: { message: "audit fail" } });
        },
      }),
    }),
  );

  expect(res.status === 500, "audit failure should return 500");
  const body = await res.json();
  expect(body.retryable === true, "audit failure marked retryable");
  expect(rpcs.length === 0, "rpc not called when audit fails");
  expect(upserts.length === 1, "one audit attempt");
});

Deno.test("transient rpc failure marks retryable and updates audit", async () => {
  const auditUpserts: Array<Record<string, unknown>> = [];
  const rpcArgs: Array<Record<string, unknown>> = [];

  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: JSON.stringify({
        event: {
          id: "evt-rpc-fail",
          entitlement_ids: ["ent_a"],
          product_id: "prod_a",
          store: "google",
          subscriber_attributes: {
            user_id: { value: "00000000-0000-4000-8000-000000000333" },
            home_id: { value: "00000000-0000-4000-8000-000000000444" },
          },
        },
      }),
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, args: Record<string, unknown>) => {
        rpcArgs.push(args);
        return Promise.resolve({ error: { message: "deadlock", code: "40001" } });
      },
      from: (_table) => ({
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          auditUpserts.push(row);
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 500, "transient rpc failure should return 500");
  const body = await res.json();
  expect(body.retryable === true, "retryable flagged true");
  expect(rpcArgs.length === 1, "rpc called once");
  expect(auditUpserts.length === 2, "audit written and then updated with rpc error");
  expect(auditUpserts[1].rpc_error_code === "rpc_failure", "rpc error recorded on audit");
});

Deno.test("unknown store returns fatal 400 and skips rpc", async () => {
  const upserts: Array<Record<string, unknown>> = [];
  const rpcCalls: string[] = [];

  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: JSON.stringify({
        event: {
          id: "evt-unknown-store",
          entitlement_ids: ["ent_a"],
          product_id: "prod_a",
          store: "mystery_store",
          subscriber_attributes: {
            user_id: { value: "00000000-0000-4000-8000-000000000555" },
            home_id: { value: "00000000-0000-4000-8000-000000000666" },
          },
        },
      }),
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        rpcCalls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          upserts.push(row);
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 400, "unknown store should return 400");
  const body = await res.json();
  expect(body.error_code === "unknown_store", "unknown_store surfaced");
  expect(upserts.length === 1, "audit still written");
  expect((upserts[0] as { fatal_error_code?: string }).fatal_error_code === "unknown_store", "fatal stored");
  expect(rpcCalls.length === 0, "no rpc when fatal validation fails");
});

Deno.test("missing home_id is fatal 400 and does not call rpc", async () => {
  const upserts: Array<Record<string, unknown>> = [];
  const rpcCalls: string[] = [];

  const res = await handleRevenueCatWebhook(
    new Request("http://localhost", {
      method: "POST",
      headers: { authorization: "Bearer secret", "content-type": "application/json" },
      body: JSON.stringify({
        event: {
          id: "evt-home-missing",
          entitlement_ids: ["ent_a"],
          product_id: "prod_a",
          store: "google",
          subscriber_attributes: {
            user_id: { value: "00000000-0000-4000-8000-000000000777" },
          },
        },
      }),
    }),
    env,
    (_url, _key) => ({
      rpc: <T = unknown>(_fn: string, _args: Record<string, unknown>) => {
        rpcCalls.push("rpc");
        return Promise.resolve({ error: null } as { error: null; data?: T });
      },
      from: (_table) => ({
        upsert: (
          row: Record<string, unknown>,
          _options?: { onConflict?: string; ignoreDuplicates?: boolean; returning?: "minimal" | "representation" },
        ) => {
          upserts.push(row);
          return Promise.resolve({ error: null });
        },
      }),
    }),
  );

  expect(res.status === 400, "missing home returns 400");
  const body = await res.json();
  expect(body.error_code === "missing_home_id", "error code missing_home_id");
  expect(upserts.length === 1, "audit stored once");
  expect((upserts[0] as { fatal_error_code?: string }).fatal_error_code === "missing_home_id", "fatal stored");
  expect(rpcCalls.length === 0, "rpc not called");
});
