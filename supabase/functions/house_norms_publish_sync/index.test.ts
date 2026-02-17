import {
  assert,
  assertEquals,
  assertRejects,
  assertThrows,
} from "jsr:@std/assert@0.224.0";

import {
  AppError,
  callRevalidate,
  env,
  normalizeError,
  parsePayload,
  requireInternalSecret,
  validateRelativePath,
} from "./index.ts";

function validPayload(overrides: Record<string, unknown> = {}) {
  return {
    home_public_id: "abcd1234",
    published_at: "2026-03-22T09:00:00.000Z",
    published_version: "v123456",
    template_key: "house_norms_v1",
    locale_base: "en",
    published_content: { title: "Clean kitchen after use" },
    ...overrides,
  };
}

Deno.test("parsePayload accepts valid payload", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(validPayload()),
  });

  const out = await parsePayload(req);

  assertEquals(out.home_public_id, "abcd1234");
  assertEquals(out.published_version, "v123456");
  assertEquals(out.public_url_path, null);
});

Deno.test("parsePayload rejects non-canonical published_at", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(
      validPayload({
        published_at: "2026-03-22T09:00:00Z",
      }),
    ),
  });

  await assertRejects(
    () => parsePayload(req),
    AppError,
    "invalid_published_at",
  );
});

Deno.test("parsePayload rejects invalid published_version", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(validPayload({ published_version: "v12345" })),
  });

  await assertRejects(
    () => parsePayload(req),
    AppError,
    "invalid_published_version",
  );
});

Deno.test("parsePayload rejects array published_content", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(validPayload({ published_content: [] })),
  });

  await assertRejects(
    () => parsePayload(req),
    AppError,
    "invalid_published_content",
  );
});

Deno.test("parsePayload enforces payload byte cap", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "x".repeat(300_001),
  });

  await assertRejects(() => parsePayload(req), AppError, "payload_too_large");
});

Deno.test("validateRelativePath accepts clean relative path", () => {
  validateRelativePath("/kinly/norms/abcd1234");
});

Deno.test("validateRelativePath rejects traversal segment", () => {
  assertThrows(
    () => validateRelativePath("/kinly/norms/../oops"),
    AppError,
    "invalid_public_url_path",
  );
});

Deno.test("requireInternalSecret enforces x-internal-secret", async () => {
  const prev = Deno.env.get("WORKER_SHARED_SECRET");
  Deno.env.set("WORKER_SHARED_SECRET", "secret");
  try {
    const okReq = new Request("http://localhost", {
      headers: { "x-internal-secret": "secret" },
    });
    requireInternalSecret(okReq);

    const badReq = new Request("http://localhost", {
      headers: { "x-internal-secret": "wrong" },
    });
    await assertRejects(
      () =>
        Promise.resolve().then(() => {
          requireInternalSecret(badReq);
        }),
      AppError,
      "unauthorized",
    );
  } finally {
    if (prev === undefined) {
      Deno.env.delete("WORKER_SHARED_SECRET");
    } else {
      Deno.env.set("WORKER_SHARED_SECRET", prev);
    }
  }
});

Deno.test("env throws missing_env typed error", async () => {
  Deno.env.delete("HOUSE_NORMS_TEST_MISSING");
  await assertRejects(
    () =>
      Promise.resolve().then(() => {
        env("HOUSE_NORMS_TEST_MISSING");
      }),
    AppError,
    "missing_env:HOUSE_NORMS_TEST_MISSING",
  );
});

Deno.test("callRevalidate returns ok on 2xx response", async () => {
  const prevUrl = Deno.env.get("VERCEL_REVALIDATE_URL");
  const prevSecret = Deno.env.get("VERCEL_REVALIDATE_SECRET");
  const originalFetch = globalThis.fetch;

  Deno.env.set("VERCEL_REVALIDATE_URL", "https://example.test/revalidate");
  Deno.env.set("VERCEL_REVALIDATE_SECRET", "secret");
  globalThis.fetch = (_input: RequestInfo | URL, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body ?? "{}")) as Record<
      string,
      unknown
    >;
    assertEquals(body.path, "/kinly/norms/abcd1234");
    const headers = new Headers(init?.headers);
    assertEquals(headers.get("x-revalidate-secret"), "secret");
    return Promise.resolve(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    );
  };

  try {
    const out = await callRevalidate("/kinly/norms/abcd1234");
    assertEquals(out, { ok: true });
  } finally {
    globalThis.fetch = originalFetch;
    if (prevUrl === undefined) Deno.env.delete("VERCEL_REVALIDATE_URL");
    else Deno.env.set("VERCEL_REVALIDATE_URL", prevUrl);
    if (prevSecret === undefined) Deno.env.delete("VERCEL_REVALIDATE_SECRET");
    else Deno.env.set("VERCEL_REVALIDATE_SECRET", prevSecret);
  }
});

Deno.test("callRevalidate maps non-2xx response to error", async () => {
  const prevUrl = Deno.env.get("VERCEL_REVALIDATE_URL");
  const prevSecret = Deno.env.get("VERCEL_REVALIDATE_SECRET");
  const originalFetch = globalThis.fetch;

  Deno.env.set("VERCEL_REVALIDATE_URL", "https://example.test/revalidate");
  Deno.env.set("VERCEL_REVALIDATE_SECRET", "secret");
  globalThis.fetch = () =>
    Promise.resolve(new Response("bad upstream", { status: 503 }));

  try {
    const out = await callRevalidate("/kinly/norms/abcd1234");
    assert(!out.ok);
    if (!out.ok) {
      assert(out.error.includes("status=503"));
    }
  } finally {
    globalThis.fetch = originalFetch;
    if (prevUrl === undefined) Deno.env.delete("VERCEL_REVALIDATE_URL");
    else Deno.env.set("VERCEL_REVALIDATE_URL", prevUrl);
    if (prevSecret === undefined) Deno.env.delete("VERCEL_REVALIDATE_SECRET");
    else Deno.env.set("VERCEL_REVALIDATE_SECRET", prevSecret);
  }
});

Deno.test("normalizeError maps unknown errors to unexpected_error", () => {
  const out = normalizeError(new Error("boom"));
  assertEquals(out.code, "unexpected_error");
  assertEquals(out.status, 500);
  assertEquals(out.details, "boom");
});

Deno.test("normalizeError preserves missing_env code from plain Error", () => {
  const out = normalizeError(new Error("missing_env:WORKER_SHARED_SECRET"));
  assertEquals(out.code, "missing_env:WORKER_SHARED_SECRET");
  assertEquals(out.status, 500);
});
