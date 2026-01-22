# Codex i18n Hygiene (CODEX-L10N-001)

Status: Active (blocking in CI)  
Scope: Entire repository

## Intent
Keep localization keys healthy so Codex changes never leave dangling strings or missing translations. The repo must always pass `dart run tool/l10n_integrity_check.dart lib/l10n/intl_en.arb`.

## Canonical Source of Truth
- English ARB: `lib/l10n/intl_en.arb` (all lifecycle decisions anchor here).

## Supported Reference Forms (Dart)
- `S.of(context).<key>`
- `S.current.<key>`
- `context.l10n.<key>`
- Prefer one style per file; avoid mixing forms without reason.

## Hard Invariants
- I1 — No unused EN keys: every key in `intl_en.arb` is referenced at least once in `lib/**/*.dart` (excluding generated).
- I2 — No invalid references: every referenced key exists in `intl_en.arb`.
- I3 — EN is canonical: non-EN ARBs may lag but must not introduce keys missing from EN (optional enforcement flag in the check).

## Key Naming Rules
- Lower camelCase.
- Semantic, not layout-based (e.g., `sharePaidToMeTitle`, not `titleText2`).
- Prefer stability across copy tweaks; avoid baking fragile wording into keys.

## When Codex Changes UI Copy
- Scenario A — Change wording only: keep the key, update the value in `intl_en.arb`.
- Scenario B — New surface/concept: add a new key to `intl_en.arb`, use it via an approved reference form, and include metadata.
- Scenario C — Delete/remove UI: delete the key from `intl_en.arb` and remove its Dart usage; the integrity check must go clean.

## Required Metadata for New Keys
For each new key `fooBar`:
```
"fooBar": "…",
"@fooBar": {
  "description": "Where/why this string is used"
}
```
If placeholders exist, document them in metadata.

## Prohibited Behaviors
- Leaving unused keys in `intl_en.arb` “for later”.
- Adding keys only to non-EN ARBs.
- Introducing raw strings in UI when localization exists.
- Renaming keys to match new wording (causes churn).
- Duplicating keys with the same meaning.

## Verification Procedure
Run before declaring work done:
- `dart run tool/l10n_integrity_check.dart lib/l10n/intl_en.arb`

Pass criteria:
- Exit code 0
- Unused keys: 0
- Invalid references: 0
- (Optional) No extra keys in non-EN ARBs when strict mode is enabled

Fix failures by removing unused keys, adding missing definitions, or correcting typos.

## PR Checklist (Codex Output Must Include)
- Updated `lib/l10n/intl_en.arb` for any new or changed copy.
- Removed any now-unused keys from `intl_en.arb`.
- No invalid references in Dart.
- `l10n_integrity_check` passes.
