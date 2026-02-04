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

# Complaint Rewrite Types (complaint_rewrite_types_v1)

Purpose: define the canonical request/response/policy types used across complaint rewrite contracts.

## 1) RewritePolicyV1
### 1.1 Schema (JSON)
```json
{
  "tone": "gentle | neutral | calm",
  "directness": "soft | balanced",
  "emotional_temperature": "cool_down | steady",
  "rewrite_strength": "light_touch | full_reframe"
}
```
Rules:
- `rewrite_strength` MUST match classifier output unless overridden by safety defaults.
- `tone` and `directness` MUST be consistent with context pack power/tone rules.

## 2) RewriteRequestV1
### 2.1 Schema (JSON)
```json
{
  "rewrite_request_id": "uuid",
  "home_id": "uuid",
  "sender_user_id": "uuid",
  "recipient_user_id": "uuid",
  "recipient_snapshot_id": "uuid",
  "recipient_preference_snapshot_id": "uuid",

  "surface": "weekly_harmony | direct_message | other",
  "original_text": "string",

  "topics": ["noise | cleanliness | privacy | guests | schedule | communication | other"],
  "intent": "request | boundary | concern | clarification",
  "rewrite_strength": "light_touch | full_reframe",

  "source_locale": "bcp47",
  "target_locale": "bcp47",
  "lane": "same_language | cross_language",

  "classifier_result": { "ClassifierResultV1": true },
  "context_pack": { "RecipientContextPackV1": true },
  "policy": { "RewritePolicyV1": true },

  "classifier_version": "string",
  "context_pack_version": "string",
  "policy_version": "string",

  "created_at": "timestamptz"
}
```
Rules:
- `source_locale` and `target_locale` MUST be valid BCP-47 and MUST NOT be "unknown".
- `lane` MUST be derived deterministically from locales (`same_language` iff equal).
- `original_text` is write-once; never mutated after persistence.
- No provider/model/prompt hints are allowed inside `RewriteRequestV1`.

## 3) RewriteResponseV1
### 3.1 Schema (JSON)
```json
{
  "rewrite_request_id": "uuid",
  "recipient_user_id": "uuid",
  "rewritten_text": "string",
  "output_language": "bcp47",

  "prompt_version": "string",
  "policy_version": "string",
  "lexicon_version": "string",
  "eval_result": { "RewriteEvalResultV1": true },

  "created_at": "timestamptz"
}
```
Rules:
- `output_language` MUST equal the request `target_locale`.
- `policy_version` MUST equal the request `policy_version`.
- `lexicon_version` MUST be set to the lexicon used for validation. If no lexicon is configured, use `"none"`.

## 4) Canonicalization (for caching)
If caching is enabled, the canonical request hash MUST be computed as:
- UTF-8 JSON, sorted object keys, no whitespace, no floating point fields.
- hash = sha256(canonical_json).

## 5) Versioning
- Adding optional fields → MINOR.
- Changing required fields or semantics → MAJOR.
