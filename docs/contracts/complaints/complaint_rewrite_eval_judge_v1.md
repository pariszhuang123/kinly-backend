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

# Complaint Rewrite Eval Judge (complaint_rewrite_eval_judge_v1)

Purpose: define the automated evaluation logic that scores provider outputs against lexicon and intent requirements.

## 1) Inputs
- `RewriteRequestV1`
- `RewriteResponseV1`
- `RecipientContextPackV1`
- `LexiconVersion` (e.g., `complaint_rewrite_lexicon_v1`)
- Optional dataset case (for offline regression) from `complaint_rewrite_eval_dataset_v1`

## 2) Outputs (RewriteEvalResultV1)
```json
{
  "schema_valid": true,
  "lexicon_pass": true,
  "tone_safety": "pass | warn | fail",
  "intent_preserved": "pass | warn | fail",
  "violations": ["vulgarity"],
  "judge_version": "v1",
  "dataset_version": "v1"
}
```

## 3) Evaluation steps (ordered)
1) Schema check: response matches `RewriteResponseV1`; output_language == target_locale.
2) Lexicon check: apply `complaint_rewrite_lexicon_v1`; populate `lexicon_pass`, `violations`, `tone_safety`.
3) Intent preservation:
   - If original intent = request/boundary/concern/clarification, rewritten text must still express that intent.
   - Fail if request removed or flipped; warn if softened but intact.
4) Content delta:
   - Fail if new complaints/facts added.
   - Warn if hedging reduces clarity but keeps request.
5) Power/tone alignment: enforce `power_mode` rules from context pack (no authority language, no demands toward higher_recipient, extra gentle for higher_sender).
6) Dataset assertions (if provided): ensure violations include expected codes; fail if mismatched.

## 4) Pass / warn / fail rules
- `lexicon_pass=false` → overall fail.
- Any hard violation (see lexicon) → fail.
- Intent_preserved = fail → fail overall.
- If only warnings present and lexicon_pass=true → overall pass with `tone_safety=warn`.

## 5) Telemetry
Record: rewrite_request_id, provider, model, prompt_version, policy_version, lexicon_version, judge_version, dataset_version, violations, tone_safety, intent_preserved.

## 6) Versioning
- Adding violation codes or warning logic → MINOR if backward-compatible.
- Changing pass/fail thresholds → MAJOR.
