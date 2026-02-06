import { assert, assertEquals, assertRejects } from "jsr:@std/assert@0.224.0";

import {
  ApiError,
  postJsonWithTimeout,
  processClaimedJob,
  rpcJson,
} from "./index.ts";

type RpcCall = {
  fn: string;
  args: Record<string, unknown>;
};

Deno.test("rpcJson returns claimed rows", async () => {
  const supabase = {
    rpc: () => Promise.resolve({ data: [{ entry_id: "e1" }], error: null }),
  };

  const out = await rpcJson<{ entry_id: string }[]>(
    supabase,
    "complaint_trigger_pop_pending",
    { p_limit: 1 },
  );

  assertEquals(out, [{ entry_id: "e1" }]);
});

Deno.test("rpcJson throws on claim rpc error", async () => {
  const supabase = {
    rpc: () =>
      Promise.resolve({
        data: null,
        error: { message: "boom" },
      }),
  };

  await assertRejects(
    () => rpcJson(supabase, "complaint_trigger_pop_pending", { p_limit: 1 }),
    ApiError,
    "complaint_trigger_pop_pending_failed:boom",
  );
});

Deno.test("processClaimedJob retries on non-2xx orchestrator response", async () => {
  const calls: RpcCall[] = [];
  const supabase = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: null, error: null });
    },
  };

  const out = await processClaimedJob({
    supabase,
    job: {
      entry_id: "11111111-1111-4111-8111-111111111111",
      home_id: "22222222-2222-4222-8222-222222222222",
      author_user_id: "33333333-3333-4333-8333-333333333333",
      recipient_user_id: "44444444-4444-4444-8444-444444444444",
      request_id: "55555555-5555-4555-8555-555555555555",
    },
    orchestratorUrl: "https://example.test/orchestrator",
    orchestratorSecret: "secret",
    orchestratorTimeoutMs: 1000,
    retryAfter: "00:10:00",
    postJson: () =>
      Promise.resolve({ ok: false, status: 500, bodyText: "internal" }),
  });

  assertEquals(out, {
    ok: false,
    entry_id: "11111111-1111-4111-8111-111111111111",
    status: 500,
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "complaint_trigger_mark_retry");
  assertEquals(calls[0].args.p_note, "runner_requeue_orchestrator_http_error");
  assert(String(calls[0].args.p_error).startsWith("orchestrator_http_500:"));
});

Deno.test("processClaimedJob retries on timeout/error path", async () => {
  const calls: RpcCall[] = [];
  const supabase = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: null, error: null });
    },
  };

  const out = await processClaimedJob({
    supabase,
    job: {
      entry_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      home_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      author_user_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      recipient_user_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      request_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    },
    orchestratorUrl: "https://example.test/orchestrator",
    orchestratorSecret: "secret",
    orchestratorTimeoutMs: 1000,
    retryAfter: "00:10:00",
    postJson: () => {
      throw new DOMException("The operation was aborted.", "AbortError");
    },
  });

  assertEquals(out, {
    ok: false,
    entry_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    status: 0,
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "complaint_trigger_mark_retry");
  assertEquals(calls[0].args.p_note, "runner_requeue_orchestrator_call_failed");
  assert(String(calls[0].args.p_error).startsWith("orchestrator_call_failed:"));
});

Deno.test("postJsonWithTimeout aborts long request", async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = (
      _input: RequestInfo | URL,
      init?: RequestInit,
    ): Promise<Response> =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("The operation was aborted.", "AbortError"));
        });
      });

    await assertRejects(
      () =>
        postJsonWithTimeout({
          url: "https://example.test/orchestrator",
          secret: "secret",
          payload: { ok: true },
          timeoutMs: 10,
        }),
      DOMException,
      "aborted",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});
