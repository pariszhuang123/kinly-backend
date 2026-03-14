import { assert, assertEquals } from "jsr:@std/assert@0.224.0";

import {
  buildComplaintRewriteEnqueueArgs,
  buildSnapshotPreferences,
  normalizePreferencePayload,
  rpcSingleRow,
} from "./index.ts";

Deno.test("normalizePreferencePayload handles resolved prefs", () => {
  const input = {
    resolved: {
      communication_directness: { value_key: "gentle" },
      communication_channel: { value_key: "text" },
      conflict_resolution_style: { value_key: "cool_off" },
      other_pref: { value_key: "x" },
    },
  };

  const out = normalizePreferencePayload(input);
  assertEquals(out.communication_directness, "gentle");
  assertEquals(out.communication_channel, "text");
  assertEquals(out.conflict_resolution_style, "cool_off");
  assertEquals(out.other_pref, "x");
});

Deno.test("buildSnapshotPreferences keeps communication prefs even when alone", () => {
  const normalized = {
    communication_directness: "gentle",
    communication_channel: "text",
    conflict_resolution_style: "cool_off",
  };

  const prefs = buildSnapshotPreferences(normalized);
  assertEquals(prefs.communication_directness, "gentle");
  assertEquals(prefs.communication_channel, "text");
  assertEquals(prefs.conflict_resolution_style, "cool_off");
  // no unintended additions
  assertEquals(Object.keys(prefs).length, 3);
});

Deno.test("buildSnapshotPreferences merges communication prefs with other sections", () => {
  const normalized = {
    communication_directness: "balanced",
    communication_channel: "in_person",
    conflict_resolution_style: "talk_soon",
    environment_noise_tolerance: "medium",
  };

  const prefs = buildSnapshotPreferences(normalized);
  assertEquals(prefs.environment_noise_tolerance, "medium");
  assertEquals(prefs.communication_directness, "balanced");
  assertEquals(Object.keys(prefs).length, 4);
});

Deno.test("rpcSingleRow unwraps first row from RETURNS TABLE rpc results", async () => {
  const supabase = {
    rpc: () =>
      Promise.resolve({
        data: [{ home_id: "h1", author_user_id: "u1" }],
        error: null,
      }),
  };

  const row = await rpcSingleRow<{
    home_id: string;
    author_user_id: string;
  }>(supabase as never, "complaint_fetch_entry_locales", {
    p_entry_id: "11111111-1111-4111-8111-111111111111",
    p_recipient_user_id: "22222222-2222-4222-8222-222222222222",
  });

  assertEquals(row, { home_id: "h1", author_user_id: "u1" });
});

Deno.test("rpcSingleRow returns null for empty RETURNS TABLE rpc results", async () => {
  const supabase = {
    rpc: () => Promise.resolve({ data: [], error: null }),
  };

  const row = await rpcSingleRow(
    supabase as never,
    "complaint_fetch_entry_locales",
    {
      p_entry_id: "11111111-1111-4111-8111-111111111111",
      p_recipient_user_id: "22222222-2222-4222-8222-222222222222",
    },
  );

  assertEquals(row, null);
});

Deno.test("buildComplaintRewriteEnqueueArgs matches SQL rpc signature", () => {
  const args = buildComplaintRewriteEnqueueArgs({
    rewrite_request_id: "11111111-1111-4111-8111-111111111111",
    home_id: "22222222-2222-4222-8222-222222222222",
    sender_user_id: "33333333-3333-4333-8333-333333333333",
    recipient_user_id: "44444444-4444-4444-8444-444444444444",
    surface: "weekly_harmony",
    original_text: "please keep it down",
    rewrite_request: { ok: true },
    classifier_result: {
      classifier_version: "v1",
      detected_language: "en",
      topics: ["noise"],
      intent: "concern",
      rewrite_strength: "full_reframe",
      safety_flags: [],
    },
    context_pack: { tone: "gentle" },
    source_locale: "en",
    target_locale: "es",
    lane: "cross_language",
    routing_decision: {
      provider: "openai",
      model: "gpt-5-mini",
      prompt_version: "v1",
      policy_version: "v1",
      max_retries: 2,
    },
    snapshotPayload: {
      preferences: {
        communication_directness: "gentle",
      },
    },
    maxAttempts: 2,
  });

  assertEquals(args.p_preference_payload, {
    preferences: { communication_directness: "gentle" },
  });
  assertEquals(args.p_topics, ["noise"]);
  assertEquals(args.p_language_pair, { from: "en", to: "es" });
  assert(!("p_recipient_snapshot_id" in args));
  assert(!("p_recipient_preference_snapshot_id" in args));
  assert(!("p_request_id" in args));
});
