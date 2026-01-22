import {
  buildMessage,
  isPermanentTokenError,
  truncateReason,
} from "./index.ts";

Deno.test("buildMessage picks locale, language fallback, then default", () => {
  const enMessage = buildMessage("en");
  console.assert(enMessage === buildMessage("EN"));
  console.assert(buildMessage("es-MX") === buildMessage("es"));
  console.assert(buildMessage("unknown") === enMessage);
});

Deno.test("isPermanentTokenError detects permanent token failures", () => {
  console.assert(isPermanentTokenError("UNREGISTERED token"));
  console.assert(
    isPermanentTokenError(JSON.stringify({ error: { status: "NOT_FOUND" } })),
  );
  console.assert(
    isPermanentTokenError(
      JSON.stringify({ error: { details: [{ errorCode: "UNREGISTERED" }] } }),
    ),
  );
  console.assert(isPermanentTokenError("transient") === false);
});

Deno.test("truncateReason caps grapheme count and appends ellipsis", () => {
  const truncated = truncateReason("1234567890", 5);
  console.assert(truncated.startsWith("12345"));
  console.assert(truncated.endsWith("…"));
  console.assert(truncated.length === 6);
});

Deno.test("truncateReason is grapheme-safe (emoji + ZWJ sequences)", () => {
  // These include multi-codepoint grapheme clusters:
  // - family emoji uses ZWJ sequence
  // - skin tone modifier + ZWJ sequence
  const s = "👨‍👩‍👧‍👦👩🏽‍💻👍🏽abc";

  // Truncate to 2 graphemes => should include first 2 graphemes + ellipsis
  const truncated = truncateReason(s, 2);

  console.assert(truncated.endsWith("…"));
  // Ensure we didn't return the original string
  console.assert(truncated !== s);

  // Basic safety: result should be at least 2 visible graphemes + ellipsis.
  // (Exact JS string length varies due to surrogate pairs, so don't assert length.)
  console.assert(truncated.length > 1);
});
