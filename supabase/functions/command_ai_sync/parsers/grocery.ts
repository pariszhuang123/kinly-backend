import type { GroceryItem, GroceryParseResult } from "../types.ts";
import { dedupeBy } from "../shared.ts";

export function parseGrocery(text: string): GroceryParseResult {
  const protectedPhrases = [
    "fish and chips",
    "mac and cheese",
    "peanut butter and jelly",
  ];

  let working = text.toLowerCase().replace(
    /^\s*(please\s+)?(can you\s+)?/i,
    "",
  );

  protectedPhrases.forEach((phrase, index) => {
    working = working.replaceAll(phrase, `__protected_${index}__`);
  });

  working = working
    .replace(/\b(and then|then|plus)\b/gi, ",")
    .replace(/[;|/]+/g, ",")
    .replace(/\n+/g, ",");

  const items = working.split(",")
    .map((token) => {
      let value = token.trim();

      protectedPhrases.forEach((phrase, index) => {
        value = value.replaceAll(`__protected_${index}__`, phrase);
      });

      value = value
        .replace(/^(add|buy|get|grab|pick up|put|put on|put on the)\s+/i, "")
        .replace(/^for\s+(the\s+)?(shopping list|groceries?)\s*/i, "")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/[,.]+$/g, "");

      if (!value) return null;

      const quantityMatch = value.match(
        /^((?:\d+(?:[./]\d+)?)\s*(?:x|kg|g|l|ml|packs?|bottles?|cans?|loaves?)?)\s+(.+)$/i,
      );

      let quantityText: string | null = null;
      if (quantityMatch) {
        quantityText = quantityMatch[1].trim();
        value = quantityMatch[2].trim();
      }

      const noteMatch = value.match(/^(.+?)\s+(for\s+.+)$/i);
      let notes: string | null = null;
      if (noteMatch) {
        value = noteMatch[1].trim();
        notes = noteMatch[2].trim();
      }

      const canonicalName = value
        .replace(/\b(the|my|our|a|an|some)\b/gi, " ")
        .replace(/\s+/g, " ")
        .trim();

      if (!canonicalName) return null;

      return {
        raw_text: token.trim(),
        canonical_name: canonicalName,
        quantity_text: quantityText,
        notes,
      };
    })
    .filter((item): item is NonNullable<typeof item> => Boolean(item));

  return {
    items: dedupeBy(
      items,
      (item) =>
        `${item.canonical_name}|${item.quantity_text ?? ""}|${
          item.notes ?? ""
        }`,
    ),
  };
}

export function normalizeGroceryParseResult(
  input: unknown,
): GroceryParseResult {
  const obj = input && typeof input === "object"
    ? input as Record<string, unknown>
    : {};
  const itemsRaw = Array.isArray(obj.items) ? obj.items : [];

  const items: GroceryItem[] = itemsRaw
    .map((row) => {
      if (!row || typeof row !== "object") return null;
      const item = row as Record<string, unknown>;

      const rawText = typeof item.raw_text === "string"
        ? item.raw_text.trim()
        : "";
      const canonicalName = typeof item.canonical_name === "string"
        ? item.canonical_name.trim()
        : "";

      if (!rawText && !canonicalName) return null;

      return {
        raw_text: rawText || canonicalName,
        canonical_name: canonicalName || rawText,
        quantity_text:
          typeof item.quantity_text === "string" && item.quantity_text.trim()
            ? item.quantity_text.trim()
            : null,
        notes: typeof item.notes === "string" && item.notes.trim()
          ? item.notes.trim()
          : null,
      };
    })
    .filter((item): item is GroceryItem => Boolean(item));

  return {
    items: dedupeBy(
      items,
      (item) =>
        `${item.canonical_name}|${item.quantity_text ?? ""}|${
          item.notes ?? ""
        }`,
    ),
  };
}
