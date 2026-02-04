import {
  buildOpenAIBatchJsonlLine,
  extractRewrittenTextFromOpenAIResponseBody,
} from "./providers.ts";

const expect = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message);
};

Deno.test("buildOpenAIBatchJsonlLine keeps job_id as custom_id and structured output", () => {
  const line = buildOpenAIBatchJsonlLine({
    job_id: "00000000-0000-4000-8000-000000000010",
    input: {
      model: "gpt-5-nano",
      promptVersion: "v2",
      targetLocale: "en",
      intent: "request",
      contextPack: { power: { power_mode: "peer" } },
      policy: { directness: "soft" },
      originalText: "hello",
      routingDecision: { provider: "openai", adapter_kind: "openai_responses" },
    },
  });

  expect(
    line.custom_id === "00000000-0000-4000-8000-000000000010",
    "custom_id matches job_id",
  );
  const body = line.body as {
    text?: { format?: { type?: string; schema?: unknown } };
  };
  expect(
    body.text?.format?.type === "json_schema",
    "uses structured output json_schema",
  );
  expect(line.url === "/v1/responses", "url set to responses endpoint");
});

Deno.test("extractRewrittenTextFromOpenAIResponseBody handles structured and plain output", () => {
  const structured = extractRewrittenTextFromOpenAIResponseBody({
    rewritten_text: '  "Hi there" ',
  });
  expect(structured === "Hi there", "structured rewritten_text cleaned");

  const plain = extractRewrittenTextFromOpenAIResponseBody({
    output_text: 'Here is a rewritten message: "Thanks!"',
  });
  expect(
    plain === 'Here is a rewritten message: "Thanks!"',
    "plain output_text cleaned (prefix kept, inner quotes retained)",
  );
});
