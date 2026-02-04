---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.0
Audience: internal
Last updated: 2026-02-01
---

# Complaint Rewrite Lexicon (complaint_rewrite_lexicon_v1)

Purpose: normative language rules the rewritten message MUST satisfy before delivery. Applies to all surfaces and locales; enforced by async validation and judged output.

## 1) Inputs
- `RewriteRequestV1` (original message, context pack, policy)
- `RewriteResponseV1` (candidate output)
- Locale: `target_locale` (lexicon applies after translation)

## 2) Hard must-pass checks
A candidate **fails** if any are true:
1. **Vulgarity / slurs**: contains profanity, slurs, or coded slurs. (Locale-specific list; see dataset section.)
2. **Personal attacks**: accusatory “you/your” + negative trait (e.g., "you’re lazy", "your cooking is disgusting").
3. **Blame language**: explicit blame/judgment ("your fault", "you always").
4. **Authority / enforcement language**: commands or rules references ("I’m the owner so you must…", "house rules say").
5. **Preference disclosure**: mentions recipient preferences or that the tone was personalized.
6. **Medical / diagnosis**: assigns conditions or diagnoses.
7. **New facts/complaints**: introduces issues not present in the original text.
8. **Non-target language**: output_language != target_locale (after normalization).

## 3) Tone and framing (soft guardrails → warn)
Warn (but do not fail) when:
- Sarcasm/cynicism markers that reduce warmth but are non-profane (e.g., "gee thanks", "of course you forgot").
- Over-apologizing that changes intent ("sorry I’m probably overreacting").
- Excessive hedging that makes request unclear.

## 4) Directness and clarity
- Must preserve the request/intent from the original (request/boundary/concern/clarification).
- Must include a specific request or impact statement when present originally.
- Should keep concise; avoid added small talk.

## 5) Power and role constraints
- If `power_mode = higher_sender`, tone must be extra gentle; must NOT include authority claims.
- If `power_mode = higher_recipient`, avoid demanding change; keep invitational language.
- Always avoid commands; use requests or suggestions.

## 6) Allowed constructs
- Impact language ("it makes it hard for me to sleep").
- Optional invitations ("could we", "would you mind").
- Time windows only if present in source or in context pack instructions; do not invent exact times.

## 7) Output categories (for eval_result)
- `lexicon_pass`: true/false
- `violations`: array of codes from: `vulgarity`, `slur`, `personal_attack`, `authority`, `preference_disclosure`, `medical`, `new_fact`, `non_target_locale`, `blame`, `sarcasm_warn`, `hedge_warn`.
- `tone_safety`: `pass | warn | fail` (warn if only warn-level codes; fail if any hard violation).

## 8) Versioning rules
- Adding violation codes → MINOR if backward-compatible; MAJOR if semantics change.
- Locale-specific vocabulary updates → MINOR.

## 9) Compliance responsibilities
- Async worker must run lexicon checks after provider response and before persisting output.
- On fail: do not store output; mark job failed or retry per policy; record violations in eval_result.
- On warn: may store output but MUST record warnings in eval_result.
