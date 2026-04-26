import type {
  InvocationPayload,
  NormalizedInput,
  ResolvedUserContext,
  UserContextDefaults,
} from "./types.ts";
import { FALLBACK_LOCALE, FALLBACK_TIMEZONE } from "./types.ts";

export type UserContextDefaultsLookup = (
  userId: string,
) => Promise<UserContextDefaults>;

export async function buildNormalizedInput(args: {
  invocation: InvocationPayload;
  getUserContextDefaults: UserContextDefaultsLookup;
}): Promise<NormalizedInput> {
  const { invocation, getUserContextDefaults } = args;
  const payload = invocation.payload;
  const text = String(payload.effective_input ?? "").trim();

  if (!text) {
    throw new Error("payload.effective_input is required");
  }

  const actorUserId = optionalString(payload, "actor_user_id") ??
    optionalString(payload, "user_id");
  const defaults = actorUserId
    ? await getUserContextDefaults(actorUserId)
    : { timezone: null, locale: null };

  const timezoneFromRequest = optionalString(payload, "timezone");
  const localeFromRequest = optionalString(payload, "locale");
  const clientTimestamp = optionalString(payload, "client_timestamp");

  const resolvedContext: ResolvedUserContext = {
    actor_user_id: actorUserId,
    timezone: timezoneFromRequest ?? defaults.timezone ?? FALLBACK_TIMEZONE,
    locale: localeFromRequest ?? defaults.locale ?? FALLBACK_LOCALE,
    client_timestamp: clientTimestamp,
    resolved_now_utc: resolveNowUtc(clientTimestamp),
    context_source: {
      timezone: timezoneFromRequest
        ? "request"
        : defaults.timezone
        ? "notification_preferences"
        : "fallback",
      locale: localeFromRequest
        ? "request"
        : defaults.locale
        ? "notification_preferences"
        : "fallback",
    },
  };

  return {
    modality: "text",
    text,
    language_code: resolvedContext.locale,
    timezone: resolvedContext.timezone,
    client_timestamp: resolvedContext.client_timestamp,
    resolved_now_utc: resolvedContext.resolved_now_utc,
    metadata: {
      actor_user_id: resolvedContext.actor_user_id,
      input_mode: optionalString(payload, "input_mode"),
      context_source: resolvedContext.context_source,
    },
  };
}

export function resolveNowUtc(clientTimestamp: string | null): string {
  if (clientTimestamp) {
    const parsed = new Date(clientTimestamp);
    if (!Number.isNaN(parsed.getTime())) {
      return parsed.toISOString();
    }
  }
  return new Date().toISOString();
}

function optionalString(
  obj: Record<string, unknown>,
  key: string,
): string | null {
  const value = obj[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}
