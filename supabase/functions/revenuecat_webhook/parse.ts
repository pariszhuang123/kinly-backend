// supabase/functions/revenue_webhook/parse.ts
export type RcPayload = Record<string, unknown>;

export type Store = "app_store" | "play_store" | "stripe" | "promotional" | "unknown";
export type SubscriptionStatus = "active" | "cancelled" | "expired" | "inactive";

export type ParsedWebhook = {
  payload: RcPayload;
  event: Record<string, unknown> | undefined;

  rcEventId: string | null;
  rcAppUserId: string | null;

  // SAFETY: This must come ONLY from subscriber_attributes.user_id (Supabase UUID)
  rcUserId: string | null;

  aliases: string[];

  entitlementIds: string[];
  primaryEntitlementId: string | null;

  productId: string | null;

  store: Store;
  storeRaw: string | null;
  isTestStore: boolean;

  status: SubscriptionStatus;

  // event type diagnostics
  eventTypeRaw: string;
  unknownEventType: boolean;

  environment: string; // normalized to non-null
  homeId: string | null;

  latestTransactionId: string | null;
  originalTransactionId: string | null;

  eventTimestamp: string | null;
  currentPeriodEndAt: string | null;
  originalPurchaseAt: string | null;
  lastPurchaseAt: string | null;

  missingLatestTransactionId: boolean;
};

const KNOWN_EVENT_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "CANCELLATION",
  "BILLING_ISSUE",
  "EXPIRATION",
]);

export const statusFromEvent = (
  eventType?: string,
): { status: SubscriptionStatus; unknown: boolean; normalized: string } => {
  const normalized = (eventType ?? "").toUpperCase().trim();
  const unknown = normalized.length > 0 && !KNOWN_EVENT_TYPES.has(normalized);

  switch (normalized) {
    case "INITIAL_PURCHASE":
    case "RENEWAL":
    case "PRODUCT_CHANGE":
    case "UNCANCELLATION":
      return { status: "active", unknown: false, normalized };

    case "CANCELLATION":
      return { status: "cancelled", unknown: false, normalized };

    case "BILLING_ISSUE":
      return { status: "inactive", unknown: false, normalized };

    case "EXPIRATION":
      return { status: "expired", unknown: false, normalized };

    default:
      return {
        status: "inactive",
        unknown: unknown || normalized.length === 0,
        normalized,
      };
  }
};

export const storeFromPayload = (
  value?: string | null,
): { store: Store; isTestStore: boolean; normalizedRaw: string } => {
  const raw = (value ?? "").trim();
  const normalized = raw.toLowerCase();

  // ✅ Treat RevenueCat sandbox transport as a real store mapping (do NOT add enum value)
  if (normalized === "test_store") return { store: "play_store", isTestStore: true, normalizedRaw: normalized };

  if (normalized.includes("app_store") || normalized === "apple") {
    return { store: "app_store", isTestStore: false, normalizedRaw: normalized };
  }
  if (normalized.includes("play_store") || normalized === "google") {
    return { store: "play_store", isTestStore: false, normalizedRaw: normalized };
  }
  if (normalized.includes("stripe")) {
    return { store: "stripe", isTestStore: false, normalizedRaw: normalized };
  }
  if (normalized.includes("promotional")) {
    return { store: "promotional", isTestStore: false, normalizedRaw: normalized };
  }

  return { store: "unknown", isTestStore: false, normalizedRaw: normalized };
};

export const parseDate = (value: unknown): string | null => {
  if (value === null || value === undefined) return null;

  if (typeof value === "number") {
    const asMs = value < 1e12 ? value * 1000 : value;
    const d = new Date(asMs);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }

  if (typeof value === "string" && /^\d+$/.test(value)) {
    const num = Number(value);
    const asMs = value.length === 10 ? num * 1000 : num;
    const d = new Date(asMs);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }

  const d = new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
};

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

export const asUuid = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return UUID_REGEX.test(trimmed) ? trimmed : null;
};

const asStringArray = (value: unknown): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .map((entry) => (typeof entry === "string" ? entry : null))
    .filter((entry): entry is string => Boolean(entry));
};

const uniquePreserveOrder = (values: string[]): string[] => {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    const s = v.trim();
    if (!s) continue;
    if (seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
};

const normalizeEntitlementIds = (
  payload: RcPayload,
  event: Record<string, unknown> | undefined,
) => {
  const candidateLists: Array<string[]> = [];

  const eventEntitlementIds = asStringArray(event?.entitlement_ids as unknown);
  if (eventEntitlementIds.length > 0) candidateLists.push(eventEntitlementIds);

  const payloadEntitlementIds = asStringArray(payload?.entitlement_ids as unknown);
  if (payloadEntitlementIds.length > 0) candidateLists.push(payloadEntitlementIds);

  const eventSingle = typeof event?.entitlement_id === "string" ? [event.entitlement_id] : [];
  if (eventSingle.length > 0) candidateLists.push(eventSingle);

  const payloadSingle = typeof payload?.entitlement_id === "string" ? [payload.entitlement_id] : [];
  if (payloadSingle.length > 0) candidateLists.push(payloadSingle);

  const entitlementIds = uniquePreserveOrder(candidateLists.flat());
  return { entitlementIds, primary: entitlementIds[0] ?? null };
};

const extractSubscriberAttrValue = (
  subscriberAttributes: Record<string, unknown> | undefined,
  key: string,
): unknown => {
  const raw = subscriberAttributes?.[key] as Record<string, unknown> | string | number | null | undefined;
  if (typeof raw === "object" && raw !== null && "value" in raw) {
    return (raw as { value?: unknown }).value;
  }
  return raw;
};

const extractHomeId = (
  payload: RcPayload,
  event: Record<string, unknown> | undefined,
): string | null => {
  const subscriberAttributes = (event?.subscriber_attributes ??
    payload?.subscriber_attributes) as Record<string, unknown> | undefined;

  const homeIdValue = extractSubscriberAttrValue(subscriberAttributes, "home_id");
  return asUuid(homeIdValue);
};

export const parseWebhookPayload = (payload: RcPayload): ParsedWebhook => {
  const event = payload?.event as Record<string, unknown> | undefined;
  const transaction = payload?.transaction as Record<string, unknown> | undefined;

  const rcEventId = typeof event?.id === "string" ? event.id : null;

  const eventType =
    (event?.type as string | undefined) ??
    (payload?.event_type as string | undefined) ??
    (payload?.type as string | undefined) ??
    "";

  const { status, unknown: unknownEventType, normalized: eventTypeNorm } = statusFromEvent(eventType);

  const rcAppUserId =
    (event?.app_user_id as string | undefined) ??
    (payload?.app_user_id as string | undefined) ??
    null;

  const subscriberAttributes = (event?.subscriber_attributes ??
    payload?.subscriber_attributes) as Record<string, unknown> | undefined;

  // SAFETY: Only accept subscriber_attributes.user_id
  const userIdValue = extractSubscriberAttrValue(subscriberAttributes, "user_id");
  const rcUserId = asUuid(userIdValue);

  const aliases = asStringArray((event?.aliases as unknown) ?? (payload?.aliases as unknown) ?? []);

  const { entitlementIds, primary } = normalizeEntitlementIds(payload, event);

  const productId =
    (event?.product_id as string | undefined) ??
    (payload?.product_id as string | undefined) ??
    (transaction?.product_id as string | undefined) ??
    null;

  const storeRaw =
    (event?.store as string | undefined) ??
    (payload?.store as string | undefined) ??
    (payload?.platform as string | undefined) ??
    null;

  const storeParsed = storeFromPayload(storeRaw);

  const environmentRaw =
    (event?.environment as string | undefined) ??
    (payload?.environment as string | undefined) ??
    null;

  const environment = (environmentRaw ?? "unknown").toLowerCase().trim();

  const currentPeriodEndAt = parseDate(
    event?.expiration_at_ms ?? payload?.expiration_at_ms ?? event?.expiration_at ?? payload?.expiration_at,
  );

  const originalPurchaseAt = parseDate(
    event?.original_purchase_at_ms ??
      payload?.original_purchase_at_ms ??
      event?.original_purchase_at ??
      payload?.original_purchase_at,
  );

  const lastPurchaseAt = parseDate(
    event?.purchased_at_ms ?? payload?.purchased_at_ms ?? event?.purchased_at ?? payload?.purchased_at,
  );

  const latestTransactionId =
    (event?.transaction_id as string | undefined) ??
    (event?.latest_transaction_id as string | undefined) ??
    (payload?.transaction_id as string | undefined) ??
    (payload?.latest_transaction_id as string | undefined) ??
    (transaction?.transaction_id as string | undefined) ??
    null;

  const originalTransactionId =
    (event?.original_transaction_id as string | undefined) ??
    (payload?.original_transaction_id as string | undefined) ??
    null;

  const eventTimestamp = parseDate(
    event?.event_timestamp_ms ?? payload?.event_timestamp_ms ?? event?.sent_at_ms ?? payload?.sent_at_ms,
  );

  const homeId = extractHomeId(payload, event);

  return {
    payload,
    event,

    rcEventId,
    rcAppUserId,
    rcUserId,

    aliases,

    entitlementIds,
    primaryEntitlementId: primary,

    productId,

    store: storeParsed.store,
    storeRaw,
    isTestStore: storeParsed.isTestStore,

    status,

    eventTypeRaw: eventTypeNorm || "(empty)",
    unknownEventType,

    environment,
    homeId,

    latestTransactionId,
    originalTransactionId,

    eventTimestamp,
    currentPeriodEndAt,
    originalPurchaseAt,
    lastPurchaseAt,

    missingLatestTransactionId: !latestTransactionId,
  };
};

/**
 * Compute a stable idempotency key with hierarchy:
 * 1) rc_event_id
 * 2) latest_transaction_id + event_timestamp
 * 3) original_transaction_id + event_timestamp
 * 4) sha256 fallback over stable subset
 */
export const computeIdempotencyKey = async (p: ParsedWebhook): Promise<string> => {
  const env = p.environment;

  if (p.rcEventId) return `rc_event_id:${p.rcEventId}`;

  if (p.latestTransactionId && p.eventTimestamp) {
    return `latest_txn_ts:${p.latestTransactionId}:${p.eventTimestamp}`;
  }

  if (p.originalTransactionId && p.eventTimestamp) {
    return `orig_txn_ts:${p.originalTransactionId}:${p.eventTimestamp}`;
  }

  const stable = JSON.stringify({
    environment: env,
    rcAppUserId: p.rcAppUserId ?? null,
    rcUserId: p.rcUserId ?? null,
    productId: p.productId ?? null,
    entitlementId: p.primaryEntitlementId ?? null,
    store: p.store,
    status: p.status,
    eventTimestamp: p.eventTimestamp ?? null,
  });

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(stable));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
  return `sha256:${b64}`;
};
