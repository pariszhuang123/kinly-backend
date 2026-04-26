import type { NormalizedInput, TaskParseResult } from "../types.ts";
import { isConfidence, isRecurrenceUnit } from "../types.ts";

export function parseTask(
  text: string,
  normalizedInput: NormalizedInput,
): TaskParseResult {
  const cleaned = text
    .replace(/^\s*(please\s+)?(can you\s+)?/i, "")
    .replace(
      /^\s*(create\s+task|add\s+task|task|todo|to-do|chore|remind(?:\s+me)?\s+to)\s+/i,
      "",
    )
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[.]+$/g, "");

  const assigneeMatch = cleaned.match(
    /\bassign(?:ed)?\s+to\s+([a-z0-9 .'-]+)$/i,
  );
  const assigneeHint = assigneeMatch?.[1]?.trim() ?? null;
  const withoutAssignee = assigneeMatch
    ? cleaned.slice(0, assigneeMatch.index).trim()
    : cleaned;

  const recurrence = extractRecurrence(withoutAssignee);
  const startDate = extractStartDate(withoutAssignee, normalizedInput);
  const notes = extractTaskNotes(withoutAssignee);

  const taskTitle = stripTaskDecorators(withoutAssignee)
    .replace(/\s+/g, " ")
    .trim() || null;

  return {
    task_title: taskTitle,
    notes,
    recurrence_every: recurrence.recurrence_every,
    recurrence_unit: recurrence.recurrence_unit,
    assignee_hint: assigneeHint,
    start_date: startDate,
    confidence: taskTitle ? "medium" : "low",
  };
}

function stripTaskDecorators(input: string): string {
  return input
    .replace(/\b(every\s+\d+\s+(day|week|month|year)s?)\b/gi, "")
    .replace(/\b(daily|weekly|monthly|yearly)\b/gi, "")
    .replace(/\b(today|tomorrow|next week|next month)\b/gi, "")
    .replace(/\b(starting\s+.+)$/gi, "")
    .replace(/\b(notes?:\s+.+)$/gi, "")
    .trim();
}

function extractTaskNotes(input: string): string | null {
  const match = input.match(/\bnotes?:\s+(.+)$/i);
  return match?.[1]?.trim() ?? null;
}

function extractRecurrence(
  input: string,
): Pick<TaskParseResult, "recurrence_every" | "recurrence_unit"> {
  const everyMatch = input.match(
    /\bevery\s+(\d+)\s+(day|week|month|year)s?\b/i,
  );
  if (everyMatch) {
    return {
      recurrence_every: Number(everyMatch[1]),
      recurrence_unit: normalizeRecurrenceUnit(everyMatch[2]),
    };
  }

  const singleWord = input.match(/\b(daily|weekly|monthly|yearly)\b/i)?.[1]
    ?.toLowerCase();
  switch (singleWord) {
    case "daily":
      return { recurrence_every: 1, recurrence_unit: "day" };
    case "weekly":
      return { recurrence_every: 1, recurrence_unit: "week" };
    case "monthly":
      return { recurrence_every: 1, recurrence_unit: "month" };
    case "yearly":
      return { recurrence_every: 1, recurrence_unit: "year" };
    default:
      return { recurrence_every: null, recurrence_unit: null };
  }
}

function normalizeRecurrenceUnit(
  unit: string,
): "day" | "week" | "month" | "year" {
  switch (unit.toLowerCase()) {
    case "day":
    case "days":
      return "day";
    case "week":
    case "weeks":
      return "week";
    case "month":
    case "months":
      return "month";
    default:
      return "year";
  }
}

function extractStartDate(
  input: string,
  normalizedInput: NormalizedInput,
): string | null {
  const lower = input.toLowerCase();
  const base = new Date(normalizedInput.resolved_now_utc);

  if (Number.isNaN(base.getTime())) {
    return null;
  }

  if (lower.includes("today")) {
    return localDateFromUtcInstant(base, normalizedInput.timezone, 0);
  }

  if (lower.includes("tomorrow")) {
    return localDateFromUtcInstant(base, normalizedInput.timezone, 1);
  }

  return null;
}

function localDateFromUtcInstant(
  instant: Date,
  timezone: string,
  dayOffset: number,
): string | null {
  try {
    const formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });

    const parts = formatter.formatToParts(instant);
    const year = Number(parts.find((part) => part.type === "year")?.value);
    const month = Number(parts.find((part) => part.type === "month")?.value);
    const day = Number(parts.find((part) => part.type === "day")?.value);

    if (!year || !month || !day) {
      return null;
    }

    const adjusted = new Date(Date.UTC(year, month - 1, day + dayOffset));
    return adjusted.toISOString().slice(0, 10);
  } catch {
    return null;
  }
}

export function normalizeTaskParseResult(input: unknown): TaskParseResult {
  const obj = input && typeof input === "object"
    ? input as Record<string, unknown>
    : {};

  return {
    task_title: typeof obj.task_title === "string" && obj.task_title.trim()
      ? obj.task_title.trim()
      : null,
    notes: typeof obj.notes === "string" && obj.notes.trim()
      ? obj.notes.trim()
      : null,
    recurrence_every: typeof obj.recurrence_every === "number"
      ? obj.recurrence_every
      : null,
    recurrence_unit: isRecurrenceUnit(obj.recurrence_unit)
      ? obj.recurrence_unit
      : null,
    assignee_hint:
      typeof obj.assignee_hint === "string" && obj.assignee_hint.trim()
        ? obj.assignee_hint.trim()
        : null,
    start_date: typeof obj.start_date === "string" && obj.start_date.trim()
      ? obj.start_date.trim()
      : null,
    confidence: isConfidence(obj.confidence) ? obj.confidence : "medium",
  };
}
