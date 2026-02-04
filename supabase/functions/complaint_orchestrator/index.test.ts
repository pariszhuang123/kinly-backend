import { assertEquals } from "jsr:@std/assert@0.224.0";

import {
  buildSnapshotPreferences,
  normalizePreferencePayload,
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
