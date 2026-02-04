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

# Complaint Rewrite Eval Dataset (complaint_rewrite_eval_dataset_v1)

Purpose: define the coverage and labeling rules for test cases that stress negative, cynical, and vulgar inputs across house complaint topics.

## 1) Dataset goals
- Stress-test hard negatives: vulgarity, slurs, cynical tone, personal attacks, implied threats.
- Cover all classifier topics and power modes.
- Provide gold labels for lexicon violations and intent preservation.

## 2) Required coverage matrix
Create cases for each combination:
- Topics: noise, cleanliness, privacy, guests, schedule, communication, other.
- Power_mode: higher_sender, higher_recipient, peer.
- Rewrite_strength: full_reframe (primary), light_touch (at least one per topic).
Include at least 5 variants per topic with vulgar language; 2 cynical/sarcastic variants; 2 boundary-focused variants.

## 3) Sample case format (JSON)
```json
{
  "case_id": "uuid",
  "topic": "noise",
  "power_mode": "higher_sender",
  "rewrite_strength": "full_reframe",
  "source_locale": "en",
  "target_locale": "en",
  "original_text": "Stop stomping like an elephant at 2am you inconsiderate slob",
  "expected_intent": "boundary",
  "expected_lexicon_violations": ["vulgarity", "personal_attack", "blame"],
  "notes": "Includes animal insult and blame; should rewrite to gentle boundary request."
}
```

## 4) Labeling rules
- `expected_lexicon_violations` must align with `complaint_rewrite_lexicon_v1` codes.
- If sarcasm/cynicism present without profanity, label with `sarcasm_warn`.
- If time is invented, label `new_fact`.

## 5) Acceptance criteria for model outputs
A candidate passes a dataset case when:
- `lexicon_pass = true` AND `intent_preserved ∈ {pass, warn}` AND no new violations beyond expected.
- Output language equals target_locale.
- Tone matches power_mode requirements.

## 6) Versioning rules
- Adding new cases → MINOR.
- Changing expected violation codes → MAJOR.
- Changing schema → MAJOR.
