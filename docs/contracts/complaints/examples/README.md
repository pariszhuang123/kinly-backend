---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: guide
Stability: stable
Status: active
Version: v1.1
Audience: internal
Last updated: 2026-02-01
---

# Recipient Context Pack Examples

Use these fixtures as golden cases for adapter and eval tests. They mirror `RecipientContextPackV1` from `complaint_rewrite_backend_context_pack_v1`.

## Files
- `context_pack_noise_owner_to_housemate.json` — noise topic, higher_sender tone multiplier (owner -> housemate).
- `context_pack_privacy_peer.json` — privacy topic, peer power.
- `context_pack_no_preferences_fallback.json` — baseline when no preferences are available.

## How to use in tests
- Adapter tests: load fixture, render prompt/payload, assert required fields and enums are preserved verbatim.
- Eval smoke: feed alongside a sample rewrite request and verify the rewriter honors `instructions`, `avoid`, and `do_not_add`.
- Regression: keep these snapshots stable; if mappings change, update fixture and bump version per contract rules.

## Guardrails when extending
- Do not add model/provider identifiers to fixtures.
- Keep `avoid` and `do_not_add` non-empty.
- Match `topics` and `included_preference_ids` to the topic map in the contract.
- `included_preference_ids` should reflect answered preferences actually present in the snapshot (not just the full topic map).

# Offline Eval Cases (dev/CI)

- Fixtures: `examples/eval_cases/*.json` (one per case). Key fields: `case_id`, `original_text`, `target_locale`, `expected_intent`, `power_mode`, `expected_lexicon_violations`.
- Runner: `tool/rewrite_eval/run_batch.sh <provider_outputs.jsonl>`
  - Outputs file format (JSONL, one line per case result):
    ```json
    {"case_id":"cleanliness_peer_full_reframe_09","rewritten_text":"...","output_language":"en","recipient_user_id":"00000000-0000-0000-0000-000000000000"}
    ```
    `recipient_user_id` can be any stable UUID; used only for schema checks.
  - The runner loads fixtures, evaluates each output with `evaluateRewrite`, and prints JSONL with `eval_result`, `expected_lexicon_violations`, and `matched_expected` boolean.
- Typical workflow
  1. Produce model outputs for each `case_id` (prompt however you like) and save to `provider_outputs.jsonl` in the format above.
  2. Run `./tool/rewrite_eval/run_batch.sh provider_outputs.jsonl`.
  3. Inspect stdout or pipe to a file, then compute pass rate (e.g., `jq -r '.matched_expected' | grep -c false`).
  4. Fail your CI/promote step if any `matched_expected` is false or if `eval_result.tone_safety == "fail"`/`lexicon_pass == false`.

Recommended practices
- Keep this offline; production collector already calls `evaluateRewrite` on live outputs.
- Tag runs with model/prompt/adapter_kind when you generate outputs so you can compare regressions.
- When adding new cases, cover each violation code, intents, locales, and power modes; bump dataset/judge versions if evaluation rules change.
