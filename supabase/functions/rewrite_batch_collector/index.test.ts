import {
  getPowerMode,
  mapOpenAIStatus,
  parseInvocationPayload,
  rejectHugeBodies,
  safeShort,
} from "./index.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

Deno.test("mapOpenAIStatus normalizes provider states", () => {
  expect(
    mapOpenAIStatus("completed") === "completed",
    "completed passes through",
  );
  expect(
    mapOpenAIStatus("in_progress") === "running",
    "non-terminal -> running",
  );
  expect(mapOpenAIStatus("cancelled") === "canceled", "cancelled normalized");
  expect(
    mapOpenAIStatus(undefined) === "running",
    "missing status defaults to running",
  );
});

Deno.test("getPowerMode falls back to peer and respects valid power_mode", () => {
  expect(
    getPowerMode({ power: { power_mode: "higher_sender" } }) ===
      "higher_sender",
    "valid power mode used",
  );
  expect(
    getPowerMode({ power: { power_mode: "invalid" } }) === "peer",
    "invalid power mode defaults",
  );
  expect(getPowerMode({}) === "peer", "missing power mode defaults");
});

Deno.test("safeShort stringifies objects and trims length", () => {
  const longObj = { message: "x".repeat(400) };
  const shortened = safeShort(longObj);
  expect(shortened.length <= 300, "safeShort caps length");
  expect(shortened.includes("message"), "contains keys when json stringified");
});

Deno.test("rejectHugeBodies throws on large content-length", () => {
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

Deno.test("parseInvocationPayload accepts empty object payload", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  });
  const parsed = await parseInvocationPayload(req);
  expect(parsed.ok, "payload should parse");
  if (parsed.ok) {
    expect(
      parsed.payload.pending_count === null,
      "pending_count defaults null",
    );
  }
});

Deno.test("parseInvocationPayload returns pending_count when present", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ pending_count: 0 }),
  });
  const parsed = await parseInvocationPayload(req);
  expect(parsed.ok, "payload should parse");
  if (parsed.ok) {
    expect(parsed.payload.pending_count === 0, "pending_count parsed");
  }
});

Deno.test("parseInvocationPayload rejects malformed json", async () => {
  const req = new Request("http://localhost", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{",
  });
  const parsed = await parseInvocationPayload(req);
  expect(!parsed.ok, "malformed payload rejected");
  if (!parsed.ok) {
    expect(parsed.status === 400, "malformed json is 400");
  }
});
