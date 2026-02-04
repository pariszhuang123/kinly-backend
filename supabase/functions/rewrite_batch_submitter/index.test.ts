import {
  env,
  rejectHugeBodies,
  requireInternalSecret,
  truncate,
} from "./index.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

Deno.test("requireInternalSecret enforces x-internal-secret header", () => {
  const prev = Deno.env.get("WORKER_SHARED_SECRET");
  Deno.env.set("WORKER_SHARED_SECRET", "secret");

  const okReq = new Request("http://localhost", {
    headers: { "x-internal-secret": "secret" },
  });
  requireInternalSecret(okReq); // should not throw

  try {
    const badReq = new Request("http://localhost", {
      headers: { "x-internal-secret": "nope" },
    });
    requireInternalSecret(badReq);
    throw new Error("expected unauthorized");
  } catch (e) {
    expect(String(e).includes("unauthorized"), "rejects wrong secret");
  } finally {
    if (prev === undefined) {
      Deno.env.delete("WORKER_SHARED_SECRET");
    } else {
      Deno.env.set("WORKER_SHARED_SECRET", prev);
    }
  }
});

Deno.test("rejectHugeBodies blocks when content-length exceeds cap", () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-length": "300000" },
    body: "a",
  });

  try {
    rejectHugeBodies(req);
    throw new Error("expected payload_too_large");
  } catch (e) {
    expect(String(e).includes("payload_too_large"), "payload too large error");
  }
});

Deno.test("truncate appends ellipsis when string exceeds limit", () => {
  expect(truncate("short", 10) === "short", "short string unchanged");
  expect(
    truncate("abcdefghij", 5) === "abcde…",
    "long string truncated with ellipsis",
  );
});

Deno.test("env returns variables or throws", () => {
  Deno.env.set("SUBMIT_TEST_VAR", "present");
  expect(env("SUBMIT_TEST_VAR") === "present", "env reads variable");
  try {
    env("MISSING_SUBMIT_VAR");
    throw new Error("expected missing env error");
  } catch (e) {
    expect(String(e).includes("Missing"), "missing env throws");
  }
  Deno.env.delete("SUBMIT_TEST_VAR");
});
