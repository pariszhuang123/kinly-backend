import type { ParserExecutor } from "./providers.ts";
import type {
  Confidence,
  ExecutionReadiness,
  GroceryParseResult,
  Intent,
  IntentClassificationResult,
  NormalizedInput,
  ParsedIntentWorkItem,
  ParseStatus,
  ResolvedRoute,
  TaskParseResult,
} from "./types.ts";
import { EXECUTABLE_INTENT_TO_PARSER } from "./types.ts";
import { parseGrocery } from "./parsers/grocery.ts";
import { parseTask } from "./parsers/task.ts";

export async function buildIntentWorkItems(args: {
  normalizedInput: NormalizedInput;
  classification: IntentClassificationResult;
  resolveConfiguredRoute: (roleKey: string) => Promise<ResolvedRoute | null>;
  executeParserProvider: ParserExecutor;
}): Promise<ParsedIntentWorkItem[]> {
  const {
    normalizedInput,
    classification,
    resolveConfiguredRoute,
    executeParserProvider,
  } = args;

  const workItems: ParsedIntentWorkItem[] = [];

  for (const intent of classification.intents_detected) {
    if (intent === "unknown") continue;

    const parserRoleKey = EXECUTABLE_INTENT_TO_PARSER[intent];
    const extraction = extractIntentSpecificInput(
      intent,
      normalizedInput.text,
      classification.intents_detected,
    );
    const rawInput = extraction.raw_input;

    if (!parserRoleKey) {
      workItems.push(
        buildNonParsedWorkItem(intent, rawInput, extraction.extracted_span),
      );
      continue;
    }

    const parserRoute = await resolveConfiguredRoute(parserRoleKey);
    if (!parserRoute) {
      workItems.push({
        intent,
        parser_role_key: parserRoleKey,
        raw_input: rawInput,
        extracted_span: extraction.extracted_span,
        parse_status: "failed",
        parse_confidence: "low",
        parsed: null,
        validation_errors: [`No configured parser route for ${parserRoleKey}.`],
        warnings: [
          "Parser route not configured; deterministic fallback was not permitted.",
        ],
        execution_readiness: "needs_review",
      });
      continue;
    }

    const parsedItem = await executeHybridExtraction({
      route: parserRoute,
      normalizedInput,
      classification,
      intent,
      rawInput,
      extractedSpan: extraction.extracted_span,
      extractionAmbiguous: extraction.ambiguous,
      executeParserProvider,
    });

    workItems.push(parsedItem);
  }

  return workItems;
}

export async function executeHybridExtraction(args: {
  route: ResolvedRoute;
  normalizedInput: NormalizedInput;
  classification: IntentClassificationResult;
  intent: Intent;
  rawInput: string;
  extractedSpan: string | null;
  extractionAmbiguous: boolean;
  executeParserProvider: ParserExecutor;
}): Promise<ParsedIntentWorkItem> {
  const {
    route,
    normalizedInput,
    classification,
    intent,
    rawInput,
    extractedSpan,
    extractionAmbiguous,
    executeParserProvider,
  } = args;

  const localParsed = executeDeterministicParser(
    route.role_key,
    rawInput,
    normalizedInput,
  );
  const localAssessment = assessParsedIntent(
    intent,
    localParsed,
    normalizedInput,
  );

  if (
    !shouldFallbackToProviderParser(
      intent,
      rawInput,
      localAssessment,
      extractionAmbiguous,
    )
  ) {
    return {
      intent,
      parser_role_key: route.role_key as "grocery_parser" | "task_parser",
      raw_input: rawInput,
      extracted_span: extractedSpan,
      parse_status: localAssessment.parse_status,
      parse_confidence: localAssessment.parse_confidence,
      parsed: localParsed,
      validation_errors: localAssessment.validation_errors,
      warnings: localAssessment.warnings,
      execution_readiness: localAssessment.execution_readiness,
    };
  }

  try {
    const providerResult = await executeParserProvider(
      route,
      {
        ...normalizedInput,
        text: extractionAmbiguous ? normalizedInput.text : rawInput,
      },
      route.role_key as "grocery_parser" | "task_parser",
      {
        intent,
        detectedIntents: classification.intents_detected,
        extractedSpan,
        fullText: normalizedInput.text,
      },
    );

    const providerAssessment = assessParsedIntent(
      intent,
      providerResult.result,
      normalizedInput,
    );

    return {
      intent,
      parser_role_key: route.role_key as "grocery_parser" | "task_parser",
      raw_input: rawInput,
      extracted_span: extractedSpan,
      parse_status: providerAssessment.parse_status,
      parse_confidence: providerAssessment.parse_confidence,
      parsed: providerResult.result,
      validation_errors: providerAssessment.validation_errors,
      warnings: [
        extractionAmbiguous
          ? "Provider rescue used after deterministic extraction found ambiguous clause boundaries."
          : "Provider rescue used after deterministic parse was weak.",
        ...providerAssessment.warnings,
      ],
      execution_readiness: providerAssessment.execution_readiness,
    };
  } catch {
    return {
      intent,
      parser_role_key: route.role_key as "grocery_parser" | "task_parser",
      raw_input: rawInput,
      extracted_span: extractedSpan,
      parse_status: localAssessment.parse_status,
      parse_confidence: localAssessment.parse_confidence,
      parsed: localParsed,
      validation_errors: localAssessment.validation_errors,
      warnings: [
        ...localAssessment.warnings,
        "Provider rescue failed; using deterministic result.",
      ],
      execution_readiness: localAssessment.execution_readiness,
    };
  }
}

export function assessParsedIntent(
  intent: Intent,
  parsed: GroceryParseResult | TaskParseResult | null,
  normalizedInput: NormalizedInput,
): {
  parse_status: ParseStatus;
  parse_confidence: Confidence | null;
  validation_errors: string[];
  warnings: string[];
  execution_readiness: ExecutionReadiness;
} {
  const validation_errors: string[] = [];
  const warnings: string[] = [];

  switch (intent) {
    case "add_grocery_items": {
      const grocery = parsed as GroceryParseResult | null;

      if (
        !grocery || !Array.isArray(grocery.items) || grocery.items.length === 0
      ) {
        return {
          parse_status: "failed",
          parse_confidence: "low",
          validation_errors: ["No grocery items were extracted."],
          warnings,
          execution_readiness: "not_ready",
        };
      }

      const invalidItems = grocery.items.filter((item) =>
        !item.canonical_name.trim()
      );
      if (invalidItems.length > 0) {
        validation_errors.push(
          "One or more grocery items were missing canonical_name.",
        );
      }

      const contaminatedItems = grocery.items.filter((item) =>
        containsCrossIntentMarkers(`${item.canonical_name} ${item.notes ?? ""}`)
      );
      if (contaminatedItems.length > 0) {
        validation_errors.push(
          "One or more grocery items contained task/reminder or other command markers.",
        );
      }

      return {
        parse_status: validation_errors.length > 0 ? "partial" : "parsed",
        parse_confidence: grocery.items.length >= 2 ? "high" : "medium",
        validation_errors,
        warnings,
        execution_readiness: validation_errors.length > 0
          ? "needs_review"
          : "ready",
      };
    }

    case "create_task":
    case "create_reminder": {
      const task = parsed as TaskParseResult | null;

      if (!task || !task.task_title) {
        return {
          parse_status: "failed",
          parse_confidence: "low",
          validation_errors: ["Task/reminder title could not be extracted."],
          warnings,
          execution_readiness: "not_ready",
        };
      }

      if (!normalizedInput.timezone) {
        validation_errors.push("Resolved timezone is missing.");
      }

      if (task.start_date && !/^\d{4}-\d{2}-\d{2}$/.test(task.start_date)) {
        validation_errors.push("start_date must be YYYY-MM-DD.");
      }

      if (
        task.recurrence_every !== null &&
        (!Number.isInteger(task.recurrence_every) || task.recurrence_every <= 0)
      ) {
        validation_errors.push("recurrence_every must be a positive integer.");
      }

      if (
        (task.recurrence_every === null) !== (task.recurrence_unit === null)
      ) {
        validation_errors.push(
          "recurrence_every and recurrence_unit must either both be set or both be null.",
        );
      }

      if (
        containsCrossIntentMarkers(
          [task.task_title, task.notes, task.assignee_hint].filter(Boolean)
            .join(" "),
        )
      ) {
        validation_errors.push(
          "Task/reminder output contained grocery or unrelated command markers.",
        );
      }

      return {
        parse_status: validation_errors.length === 0 ? "parsed" : "partial",
        parse_confidence: task.confidence ?? "medium",
        validation_errors,
        warnings,
        execution_readiness: validation_errors.length === 0
          ? "ready"
          : "needs_review",
      };
    }

    default:
      return {
        parse_status: "not_needed",
        parse_confidence: null,
        validation_errors,
        warnings,
        execution_readiness: "needs_review",
      };
  }
}

function executeDeterministicParser(
  roleKey: string,
  input: string,
  normalizedInput: NormalizedInput,
): GroceryParseResult | TaskParseResult {
  switch (roleKey) {
    case "grocery_parser":
      return parseGrocery(input);
    case "task_parser":
      return parseTask(input, normalizedInput);
    default:
      throw new Error(`unsupported parser role ${roleKey}`);
  }
}

function shouldFallbackToProviderParser(
  intent: Intent,
  rawInput: string,
  assessment: {
    parse_status: ParseStatus;
    execution_readiness: ExecutionReadiness;
    validation_errors: string[];
  },
  extractionAmbiguous: boolean,
): boolean {
  if (extractionAmbiguous) return true;
  if (assessment.parse_status === "failed") return true;
  if (assessment.execution_readiness === "not_ready") return true;
  if (assessment.validation_errors.length > 0) return true;
  if (containsNonAscii(rawInput)) return true;
  if (rawInput.length > 80 && assessment.parse_status !== "parsed") return true;

  if (intent === "create_task" || intent === "create_reminder") {
    if (assessment.execution_readiness !== "ready") return true;
  }

  return false;
}

function buildNonParsedWorkItem(
  intent: Intent,
  rawInput: string,
  extractedSpan: string | null,
): ParsedIntentWorkItem {
  const safeInformationalIntent = intent === "open_house_norms" ||
    intent === "view_due_items" ||
    intent === "view_service";

  return {
    intent,
    parser_role_key: null,
    raw_input: rawInput,
    extracted_span: extractedSpan,
    parse_status: "not_needed",
    parse_confidence: null,
    parsed: null,
    validation_errors: [],
    warnings: [],
    execution_readiness: safeInformationalIntent ? "ready" : "needs_review",
  };
}

function extractIntentSpecificInput(
  intent: Intent,
  input: string,
  detectedIntents: Intent[],
): {
  raw_input: string;
  extracted_span: string | null;
  ambiguous: boolean;
} {
  const text = input.trim();
  const clauses = splitIntentClauses(text);
  const matchingClauses = clauses.filter((clause) =>
    clauseMatchesIntent(intent, clause)
  );

  if (matchingClauses.length === 1) {
    const clause = matchingClauses[0];
    return {
      raw_input: stripIntentLeadIn(intent, clause),
      extracted_span: clause,
      ambiguous: false,
    };
  }

  if (matchingClauses.length > 1) {
    const combined = matchingClauses.join(", ");
    return {
      raw_input: combined,
      extracted_span: combined,
      ambiguous: true,
    };
  }

  if (detectedIntents.length > 1) {
    return {
      raw_input: text,
      extracted_span: null,
      ambiguous: true,
    };
  }

  return {
    raw_input: stripIntentLeadIn(intent, text),
    extracted_span: text,
    ambiguous: false,
  };
}

function containsNonAscii(input: string): boolean {
  for (const char of input) {
    if ((char.codePointAt(0) ?? 0) > 0x7f) {
      return true;
    }
  }
  return false;
}

function splitIntentClauses(input: string): string[] {
  const normalized = input
    .replace(/\b(and then|then|plus)\b/gi, ",")
    .replace(
      /\band\b(?=\s+(remind(?:\s+me)?\s+to|remember to|create\s+task|add\s+task|task\b|todo\b|to-do\b|chore\b|i paid\b|paid\b|spent\b|owe\b|bill\b|what'?s due\b|what is due\b|house norms\b|house rules\b|service\b|services\b|buy\b|get\b|grab\b|pick up\b|add\s+[a-z]))/gi,
      ",",
    );

  return normalized
    .split(/\s*(?:,|;|\n+)\s*/i)
    .map((clause) => clause.trim())
    .filter(Boolean);
}

function clauseMatchesIntent(intent: Intent, clause: string): boolean {
  const text = clause.toLowerCase();

  switch (intent) {
    case "add_grocery_items":
      return /\b(milk|eggs|bread|shopping|grocery|groceries|buy|get|grab|pick up)\b/
        .test(text) ||
        /\badd\s+(milk|eggs|bread|groceries?|shopping list|apples?|bananas?|rice|cheese|butter)\b/
          .test(text);
    case "create_task":
      return /\b(create\s+task|add\s+task|task|todo|to-do|chore|clean|take out|vacuum|wash)\b/
        .test(text) &&
        !/\bremind(?:\s+me)?\s+to\b/.test(text);
    case "create_reminder":
      return /\b(remind|reminder|remember to)\b/.test(text);
    case "create_expense":
      return /\b(expense|spent|paid|split|owe|bill)\b|\$/.test(text);
    case "mark_task_done":
      return /\b(done|finished|completed|complete)\b/.test(text);
    case "open_house_norms":
      return /\b(house norms|house rules|norms|rules of the house)\b/.test(
        text,
      );
    case "view_due_items":
      return /\b(what'?s due|what is due|due today|due this week)\b/.test(text);
    case "view_service":
      return /\b(service|services|plumber|cleaner|electrician|internet provider|wifi)\b/
        .test(text);
    default:
      return false;
  }
}

function stripIntentLeadIn(intent: Intent, input: string): string {
  switch (intent) {
    case "add_grocery_items":
      return input
        .replace(/^\s*(please\s+)?(can you\s+)?/i, "")
        .replace(/^\s*(add|buy|get|grab|pick up)\s+/i, "")
        .trim();
    case "create_task":
      return input
        .replace(/^\s*(please\s+)?(can you\s+)?/i, "")
        .replace(/^\s*(create\s+task|add\s+task|task|todo|to-do|chore)\s+/i, "")
        .trim();
    case "create_reminder":
      return input
        .replace(/^\s*(please\s+)?(can you\s+)?/i, "")
        .replace(/^\s*(remind(?:\s+me)?\s+to|remember to)\s+/i, "")
        .trim();
    default:
      return input.trim();
  }
}

function containsCrossIntentMarkers(input: string): boolean {
  return /\b(remind(?:\s+me)?\s+to|remember to|create\s+task|add\s+task|todo|to-do|task\b|chore\b|paid\b|spent\b|owe\b|bill\b|what'?s due\b|what is due\b|house norms\b|house rules\b|service\b|services\b|shopping list\b|groceries?\b)\b/i
    .test(input);
}

export { extractIntentSpecificInput };
