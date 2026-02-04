---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.1
Audience: internal
Last updated: 2026-02-04
---

# Backend: Recipient Context Pack (complaint_rewrite_backend_context_pack_v1)

## 1. Purpose
- Convert recipient preference answers and role context into a deterministic, topic-scoped instruction pack for complaint rewriting.
- Treat preferences as a translation layer (how to phrase), not profiling; the output message MUST NOT mention preferences or norms.
- Keep power dynamics tone-only (softening), never authority.
- Provide deterministic inputs for the rewriter; no AI is used in this step.

## 2. Inputs
### 2.1 Required from orchestrator
- `home_id` (uuid)
- `recipient_user_id` (uuid)
- `sender_user_id` (uuid)
- `topics[]` (topic_enum[]) from `complaint_rewrite_ai_classifier_v1`
- `target_language` (bcp47) — recipient locale
- `sender_language` (bcp47)
- `surface` (enum; e.g., `weekly_harmony`, `direct_message`) — optional but recommended

### 2.2 Data dependencies (server-side)
- `personal_preferences_responses` (recipient)
- `house_membership` / `home_roles` (role inference)
- Optional: `user_locales`, `user_timezones` (for upstream gating only)

## 3. Output shape: RecipientContextPackV1
```json
{
  "context_version": "v1",
  "recipient_user_id": "uuid",
  "target_language": "bcp47",

  "power": {
    "sender_role": "owner | housemate",
    "recipient_role": "owner | housemate",
    "power_mode": "higher_sender | higher_recipient | peer",
    "tone_multiplier": "extra_gentle | gentle | neutral"
  },

  "topic_scope": {
    "topics": ["noise", "privacy"],
    "included_preference_ids": ["environment_noise_tolerance", "conflict_resolution_style"],
    "excluded_preference_ids": ["cleanliness_shared_space_tolerance"]
  },

  "instructions": {
    "tone": "warm_clear",
    "directness": "soft | balanced",
    "repair_timing": "cool_off | talk_soon | check_in",
    "framing": [
      "use_impact_language",
      "use_optional_requests",
      "use_specific_but_non_accusatory"
    ],
    "avoid": [
      "authority_language",
      "rules_language",
      "enforcement_language",
      "preference_disclosure",
      "norms_reference",
      "medical_or_diagnosis_language"
    ],
    "do_not_add": [
      "new_complaints",
      "new_facts",
      "exact_times_if_not_provided"
    ]
  },

  "recipient_signals": [
    {
      "preference_id": "communication_directness",
      "value_key": "gentle",
      "instruction": "Prefer softer phrasing and good timing; avoid blunt wording."
    }
  ],

  "safety_notes": [
    "Do not imply the recipient is wrong; describe impact.",
    "Do not mention that the tone is tailored to preferences."
  ]
}
```
Notes:
- `instructions.avoid` and `instructions.do_not_add` are open string-code lists; they MUST be non-empty. Recommended codes appear in section 7, and additional codes are allowed.
- Communication preferences (`communication_directness`, `communication_channel`, `conflict_resolution_style`) are always forwarded when present, regardless of classifier topic, so the rewriter can honor per-recipient tone/channel even for off-topic complaints.

## 4. Preference -> instruction mapping (deterministic)
### 4.1 communication_directness
Values: gentle | balanced | direct  
- gentle -> `instructions.directness = soft`; add framing `use_soft_openers`, `avoid_blunt_phrases`.  
- balanced -> `instructions.directness = balanced`; add framing `be_clear_not_harsh`.  
- direct -> `instructions.directness = balanced` (never "hard"); add framing `be_straightforward_without_commands`.

### 4.2 conflict_resolution_style
Values: cool_off | talk_soon | mediate (displayed as check_in)  
- cool_off -> `instructions.repair_timing = cool_off`; include "no need to respond immediately".  
- talk_soon -> `repair_timing = talk_soon`; include "could we chat briefly when you have a moment?".  
- mediate -> `repair_timing = check_in`; include "a gentle check-in later works best"; MUST NOT imply third-party mediation.

### 4.3 environment_noise_tolerance
Values: low | medium | high  
- low -> framing: "quiet request" using impact language; avoid blame.  
- medium -> framing: "mindful hours" phrasing.  
- high -> framing: avoid overstating; focus on specific impact if present.

### 4.4 schedule_quiet_hours_preference
Values: early_evening | late_evening_or_night | none  
- early_evening -> framing: avoid late-night requests; suggest daytime without exact times.  
- late_evening_or_night -> framing: allow later timing; avoid exact times unless provided.  
- none -> no additional timing constraints.

### 4.5 routine_planning_style
Values: planner | mixed | spontaneous  
- planner -> framing: provide heads-up, propose planning; avoid last-minute tone.  
- mixed -> no change.  
- spontaneous -> framing: keep request lightweight; avoid heavy planning language.

### 4.6 privacy_room_entry / privacy_notifications
- privacy_room_entry=always_ask -> framing: "please check first" as a request, not a rule.  
- privacy_notifications=none -> avoid after-hours requests; suggest "tomorrow" without inventing times.

### 4.7 communication_channel
Values: text | call | in_person  
- text -> framing: written request is okay; keep concise and calm.  
- call -> framing: offer a quick call when convenient; avoid urgency.  
- in_person -> framing: offer a brief in-person check-in; avoid pressure.

### 4.8 cleanliness_shared_space_tolerance
- low -> prefer "reset" / "tidy-up" framing; avoid "messy" accusations.  
- high -> keep request minimal; avoid policing tone.

### 4.9 social_togetherness / social_hosting_frequency
social_togetherness values: mostly_solo | balanced | mostly_together  
- mostly_solo -> avoid pushing group talk; keep 1:1 framing.  
- balanced -> no change.  
- mostly_together -> allow optional shared check-in language; do not pressure.  
social_hosting_frequency values: rare | sometimes | often  
- rare -> emphasize heads-up and consent for visitors.  
- sometimes -> gentle heads-up language.  
- often -> avoid judgment; keep request specific and time-bounded.

## 5. Topic-scoped inclusion rules (critical)
### 5.1 Topic -> preference IDs
- noise: `environment_noise_tolerance`, `schedule_quiet_hours_preference`, `conflict_resolution_style`, `communication_directness`.
- privacy: `privacy_room_entry`, `privacy_notifications`, `communication_channel`, `conflict_resolution_style`.
- cleanliness: `cleanliness_shared_space_tolerance`, `routine_planning_style`, `communication_directness`.
- guests: `social_hosting_frequency`, `social_togetherness`, `communication_directness`, `conflict_resolution_style`.
- schedule: `schedule_quiet_hours_preference`, `routine_planning_style`, `communication_directness`, `conflict_resolution_style`.
- communication: `communication_channel`, `communication_directness`, `conflict_resolution_style`.
- other: (no preferences; defaults only)

### 5.2 Inclusion algorithm
1) If `topics = ["other"]`, do not collect preferences; emit defaults and empty `included_preference_ids`.  
2) For each detected topic, collect its preference IDs.  
3) Union and de-duplicate.  
4) Fetch only those recipient answers.  
5) Emit signals + instructions for present answers; if missing, do NOT invent — omit and fall back to defaults.  
6) Default safe baseline still applies (section 7).

## 6. Power mode computation (tone only)
- Roles from `home_roles`: owner = owner/head tenant; housemate = everyone else.
- Mapping: owner->housemate = higher_sender; housemate->owner = higher_recipient; same = peer.
- Tone multiplier: higher_sender -> extra_gentle (add avoid "commands" and prefer "invite/request/impact language"); higher_recipient -> gentle (avoid demanding change); peer -> neutral.
- Hard rule: power must never introduce authority language.

## 7. Defaults and safety baseline
If no preferences are available, emit:
- `instructions.tone = warm_clear`
- `instructions.directness = soft`
- framing includes `use_impact_language` and `use_optional_requests`
- `avoid` includes authority/rules/enforcement/preference_disclosure/norms_reference/medical_or_diagnosis_language
- `do_not_add` as listed in section 3

## 8. Implementation notes (non-normative)
- Recommended RPC: `complaint_rewrite_build_context_pack_v1(home_id, sender_user_id, recipient_user_id, topics[], target_language)`.
- Idempotent and read-only; no side effects.  
- Use `search_path = ''` where required by deployment environments.

## 9. Enforcement boundaries (keep logic in backend)
- The context pack is authoritative. The orchestrator must pass it unchanged to the rewriter adapter.
- The rewriter/AI layer MUST NOT alter topic scope, add preferences, or change power/tone multipliers.
- If required fields are missing, orchestrator must reject the request; the AI must not infer defaults.
- Eval layer checks that AI output honors `instructions`, `avoid`, and `do_not_add`; remediation is retry or safe fallback, not relaxing instructions.

## 10. Validation checklist (backend)
- Required fields: `recipient_user_id`, `target_language`, `topics[]` (non-empty), `power.power_mode`, `instructions.tone`, `instructions.directness`, `instructions.avoid`, `instructions.do_not_add`.
- Enum enforcement:
  - `power_mode` ∈ {higher_sender, higher_recipient, peer}
  - `tone_multiplier` ∈ {extra_gentle, gentle, neutral}
  - `instructions.directness` ∈ {soft, balanced}
  - `instructions.repair_timing` ∈ {cool_off, talk_soon, check_in}
- Topic scope: `included_preference_ids` MUST correspond to the topic map; reject if unknown IDs are injected.
- Safety lists must not be empty: `avoid` and `do_not_add` require at least one entry each.
- Reject on missing required fields or unknown enum values; do NOT downgrade to defaults silently.

## 11. Versioning
- Adding preferences or topics: update topic map and signals; bump MINOR.
- Changing instruction semantics: bump MAJOR.
- Power mapping changes: bump MAJOR.

## 12. Non-goals
- No personality labels or profiling.
- Does not decide whether rewriting is allowed (frontend + orchestrator handle gating).
- Excludes house norms or rules.
- Does not attempt dispute resolution; only converts preferences into rewrite instructions.
