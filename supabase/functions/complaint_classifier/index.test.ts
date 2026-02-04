import {
  extractOutputText,
  normalizeClassifier,
  safeJson,
  validate,
} from "./index.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

const uuid = "00000000-0000-4000-8000-000000000001";

Deno.test("safeJson enforces byte cap and invalid JSON", async () => {
  const tooBig = new Request("http://localhost", {
    method: "POST",
    body: "a".repeat(65_000),
  });
  await safeJson(tooBig, 64_000).then(
    () => {
      throw new Error("expected payload_too_large");
    },
    (e) =>
      expect(
        e.code === "payload_too_large",
        "should reject oversized payloads",
      ),
  );

  const badJson = new Request("http://localhost", {
    method: "POST",
    body: "{ not json",
  });
  await safeJson(badJson, 10_000).then(
    () => {
      throw new Error("expected invalid_json_payload");
    },
    (e) =>
      expect(e.code === "invalid_json_payload", "should reject invalid json"),
  );
});

Deno.test("validate accepts good payload and rejects bad uuid", () => {
  const valid = validate({
    original_text: "hello",
    surface: "weekly_harmony",
    sender_user_id: uuid,
  });
  expect(valid.original_text === "hello", "original_text returned");
  expect(valid.sender_user_id === uuid, "uuid preserved");

  try {
    validate({
      original_text: "hi",
      surface: "wh",
      sender_user_id: "not-a-uuid",
    });
    throw new Error("expected invalid_sender_user_id");
  } catch (e) {
    expect(
      (e as { code?: string }).code === "invalid_sender_user_id",
      "invalid uuid detected",
    );
  }
});

Deno.test("normalizeClassifier applies defaults and clamps topics", () => {
  const normalized = normalizeClassifier({
    detected_language: "EN-US",
    topics: ["noise", "unknown", "communication", "extra"],
    intent: "request",
    rewrite_strength: "light_touch",
    safety_flags: [],
  });

  expect(normalized.detected_language === "en-us", "locale lowercased");
  expect(
    normalized.topics.length === 2 && normalized.topics[0] === "noise",
    "allowed topics kept",
  );
  expect(
    normalized.safety_flags[0] === "none",
    "empty safety flags default to none",
  );

  const fallback = normalizeClassifier({});
  expect(fallback.intent === "concern", "missing intent defaults to concern");
  expect(
    fallback.rewrite_strength === "full_reframe",
    "missing rewrite_strength defaults to full_reframe",
  );
});

Deno.test("extractOutputText prefers output_text then output chunk", () => {
  const direct = extractOutputText({ output_text: "  value " });
  expect(direct === "value", "output_text trimmed");

  const nested = extractOutputText({
    output: [
      {
        content: [
          { type: "other", text: "" },
          { type: "output_text", text: " nested " },
        ],
      },
    ],
  });
  expect(nested === "nested", "found nested output_text");
});
