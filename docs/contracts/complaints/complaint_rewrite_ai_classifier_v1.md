---
Domain: Product
Capability: complaint_rewrite
Scope: backend
Artifact-Type: contract
Stability: stable
Status: active
Version: v1.1
Audience: internal
Last updated: 2026-02-01
---

# AI Classifier (complaint_rewrite_ai_classifier_v1)

## 1) Purpose
Define a cheap, fast, bounded AI classification step that gives lightweight semantic understanding of a sender’s message without rewriting it.

The classifier exists to:
- detect what the message is about (topic)
- detect what the sender is trying to do (intent)
- detect the language the message is written in
- decide how much rewriting is needed

This is a cost-control and safety component, not a creative one.

## 2) Core Principles
1. Cheap first: MUST use the cheapest viable model.
2. No creativity: MUST NOT paraphrase or rewrite text.
3. Deterministic output: same input → same shape.
4. Bounded responsibility: decides what this is, not how to say it.
5. Fail safe: when uncertain, choose safer (gentler, scoped) options.

## 3) Inputs
### 3.1 Required input
```json
{
  "classifier_request_id": "uuid",
  "sender_message": "string",
  "sender_user_id": "uuid",
  "surface": "weekly_harmony | direct_message | other"
}
```
The classifier MUST NOT receive recipient preferences, house norms, or role/power information.

## 4) Outputs
### 4.1 ClassifierResultV1
```json
{
  "classifier_version": "v1",
  "detected_language": "bcp47",
  "topics": ["noise | cleanliness | privacy | guests | schedule | communication | other"],
  "intent": "request | boundary | concern | clarification",
  "rewrite_strength": "light_touch | full_reframe",
  "confidence": {
    "topic_confidence": "low | medium | high",
    "intent_confidence": "low | medium | high"
  },
  "safety_flags": ["none | emotional_intensity | ambiguous_intent"]
}
```

## 5) Classification Responsibilities
### 5.1 Topic detection
- Detect one or more topics from the controlled enum.
- Prefer fewer topics; if unsure between two, include both.
- If nothing matches, return `other`.

### 5.2 Intent detection
- Assign exactly one: request | boundary | concern | clarification.
- If ambiguous, default to `concern`.
- Intent informs rewrite framing and intent-preservation evals.

### 5.3 Sender language detection
- Detect language of `sender_message`; output valid BCP-47 code.
- Used to decide if translation is required; frontend must not provide this.

### 5.4 Rewrite strength decision
- `light_touch`: message already calm; phrasing tweaks only.
- `full_reframe`: emotionally sharp, accusatory, or tense.
- If emotional intensity detected → `full_reframe`.
- If confidence low → default to `full_reframe` (safer).

## 6) Safety Flags (advisory only)
Allowed: `emotional_intensity`, `ambiguous_intent`, `none`.
- Never shown to users.
- May influence rewrite tone or caution level downstream.
- If `none` is present, it MUST be the only value in the list.

## 7) MUST NOT
- No rewrite, summary, or softening.
- No inference of preferences, house rules, or power.
- No judgments about correctness or blame.
- No free-form text explanations.
- No delivery or visibility decisions.

## 8) Model Requirements
- Use cheapest viable model; swappable without contract change.
- Must handle short text classification, language detection, structured JSON output.
- Classifier model MUST NOT be reused for rewriting.

## 9) Error Handling and Fallbacks
If classifier fails or times out, orchestrator MUST:
- default `topics` = ["other"]
- default `intent` = concern
- default `rewrite_strength` = full_reframe
- set `topic_confidence` and `intent_confidence` = low

## 10) Versioning Rules
- Adding topics or intents → MINOR bump.
- Changing classification semantics → MAJOR bump.
- Model/provider swaps do not affect version.

## 11) Summary
Classifier = the “ears”: it listens and labels. It does not speak.
