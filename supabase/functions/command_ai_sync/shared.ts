export function dedupeBy<T>(items: T[], getKey: (value: T) => string): T[] {
  const out: T[] = [];
  const seen = new Set<string>();

  for (const item of items) {
    const key = getKey(item);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }

  return out;
}

export function extractOutputText(payload: unknown): string {
  if (!payload || typeof payload !== "object") return "";

  const obj = payload as Record<string, unknown>;

  if (typeof obj.output_text === "string" && obj.output_text.trim()) {
    return obj.output_text.trim();
  }

  const output = Array.isArray(obj.output) ? obj.output : [];
  for (const item of output) {
    if (!item || typeof item !== "object") continue;

    const content = Array.isArray((item as Record<string, unknown>).content)
      ? (item as Record<string, unknown>).content as Array<
        Record<string, unknown>
      >
      : [];

    for (const part of content) {
      if (
        part?.type === "output_text" && typeof part.text === "string" &&
        part.text.trim()
      ) {
        return part.text.trim();
      }
    }
  }

  return "";
}
