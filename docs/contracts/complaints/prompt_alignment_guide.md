---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: guide
Stability: stable
Status: active
Version: v1.0
Audience: internal
Last updated: 2026-02-01
---

# Prompt ↔ Lexicon Alignment Guide

Purpose: keep provider prompts aligned with hard/soft rules in `complaint_rewrite_lexicon_v1` so model outputs reliably pass validation.

## Hard rules to encode explicitly in prompts
- No profanity, slurs, personal attacks, or blame language.
- No authority/command/enforcement language; always request or invite.
- Do not mention preferences, tailoring, or house rules.
- Do not add new complaints, facts, or exact times not provided.
- Output must be in target_locale only.
- Preserve sender intent (request/boundary/concern/clarification) and include a concrete request/impact if present.

## Soft rules (warn-level) to steer
- Avoid sarcasm/cynicism; keep warm-clear tone.
- Avoid excessive hedging that makes the request unclear.

## Mapping prompt instructions to lexicon codes
- “Avoid profanity or insults” → `vulgarity`, `personal_attack`
- “Use impact language, not blame” → `blame`
- “Phrase as a request, not a rule/command” → `authority`
- “Do not mention preferences or personalization” → `preference_disclosure`
- “Keep it concise; no extra complaints” → `new_fact`
- “Warm-clear tone; no sarcasm” → `sarcasm_warn`
- “Be clear and direct enough” → `hedge_warn`

## Minimal prompt skeleton (to adapt per provider/model)
- System: summarize the hard rules above in 3–4 bullet commands.
- User: include RewriteRequestV1 (with context_pack + policy), and restate: “Rewrite in <target_locale>. Keep intent <intent>. No commands/rules. No profanity or insults. Keep concise, warm and clear.”
- Reminder: explicitly forbid adding new issues or exact times.

## Testing checklist before rollout
1. Run offline eval on `complaint_rewrite_eval_dataset_v1`; target 0 hard violations, <5% warn-only.
2. Smoke test online path with 5–10 recent real requests (anonymized) ensuring zero hard violations.
3. Record prompt_version and tie to routing table; bump prompt_version on any material change.
