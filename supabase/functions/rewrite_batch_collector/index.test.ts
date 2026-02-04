import {
  getPowerMode,
  mapOpenAIStatus,
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
