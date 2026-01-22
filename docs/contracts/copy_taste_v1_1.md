# Kinly Copy & Product Taste Contract v1.1

Status: Draft for MVP (home-only)

Scope: All user-facing English source copy across app UI, notifications, emails, and any AI rewrites. Localization mirrors these rules.

Owners:
- Owner: Planner (founder/product)
- Steward: Docs (maintains contract/rules)
- Enforcer: CI lint + guards
- Human sign-off: Required only for new or sensitive copy; taste debates stay in human review, not CI

Purpose: Keep Kinly’s copy calm, warm, reassuring, light, and clear. Copy should reduce friction, help contributions feel seen, and keep homes calmer/closer/coordinated.

## Voice and Avoidances
- Traits: Calm, warm, reassuring, light, clear; second person.
- Avoid: blame/shame, pressure/urgency, competitive framing, over-gamification, jargon, culture-bound idioms.
- Tone stands without emojis; emojis are optional accents only.

## Readability and Structure
- Readability: Flesch-Kincaid grade ≤7 (applied globally).
- Sentence length: Hard cap 18 words; prefer 10–16; one idea per string.
- Present tense; short sentences; everyday words.

## Surface Rules (with 5% tolerance to avoid false positives)
- Button/CTA: Verb-first; ≤22 chars (hard with tolerance); no translator note required.
- Title: ≤28 chars (compact) or ≤40 chars (hero/modal); Title Case.
- Subtitle: ≤110 chars; 1–2 sentences.
- Snackbar/Toast: 1 sentence; ≤70 chars; what happened → next step.
- Notification: Title ≤40 chars; Body ≤90 chars; one reason per notification.
- Dialogs/Alerts: Title ≤40 chars; Body 1–3 sentences; each sentence ≤18 words. Destructive template: “This will {consequence}. This action can’t be undone. Continue?”
- Empty States: Title + 1–2 sentences + single CTA; sentences ≤18 words.
- Errors: 1–2 sentences; what happened → what to do; sentences ≤18 words.
- Success/Completion: Quiet appreciation; short, concrete.
- Emails (if used later): Subject ≤60 chars; preview ≤90 chars; sentences ≤18 words.

## Metadata Surfaces (tag strings for lint)
button, title, subtitle, snackbar, dialog_title, dialog_body, error, empty_title, empty_body, notification_title, notification_body, email_subject, email_body, paywall_title, paywall_subtitle, paywall_bullet, onboarding_hint, tooltip, success_message, empty_hint.

## Translator Notes (selective)
- Do NOT add notes for buttons, obvious labels, or neutral system messages.
- DO add notes when tone matters (reassuring/gentle/appreciative), for reminders/errors/reflections/gratitude, and for money/responsibility/social dynamics.
- Rule: If a wrong translation could break emotional safety → add a note.

## Placeholders and Plurals
- Every placeholder documented with type + example. Tone note optional unless sensitive.
- Any string with `{count}` uses ICU plural syntax. Do not plural-proof everything—only where numbers appear.
- Avoid gendered language by default; use neutral phrasing.

## Banned Words (system text; UGC exempt)
owe, debt, failed, broke, streak (negative), urgent, immediately, last chance, deadline, warning, mistake, fault, penalty, must, should, cannot/can’t (allowed in destructive confirms), late, overdue, fix, correct, punish, require, “you forgot”.

## Notifications & Nudges
- Send only with a meaningful reason; one clear purpose.
- Friendly, optional-feeling; no all caps or urgency.

## AI-Generated/Rewritten Text
- Keep sentences short; no certainty about feelings; no therapy/diagnosis.
- Focus on home dynamics, not individual blame.
- Text must stand on its own without emojis; always user-editable.

## CI Enforcement (blocking, objective)
- Length limits per surface (with 5% tolerance).
- Grade >7 or sentence >18 words fails.
- Missing metadata when placeholders or tone-sensitive strings require it.
- Missing placeholder type/example.
- Missing ICU plural when `{count}` present.
- Banned words present in system strings.
- All-caps or excessive punctuation in notifications.

## Human Review (non-blocking)
- Tone warmth, phrasing preferences, “could be gentler” suggestions.
- Subjective taste or alternative word choices.

## Lint Spec (objective rules)
- Input: EN ARB as source of truth; skip UGC and test fixtures by path/namespace.
- Surface tagging: use metadata field `@key.surface` from the list above; default to lenient “body” limits if absent, but flag missing surface as a warning.
- Length checks: apply per-surface caps with 5% tolerance; count characters without placeholders; sentence length by word count.
- Readability: compute Flesch-Kincaid on bodies >50 chars; fail if >7.
- Banned words: case-insensitive match; allow if metadata marks string as UGC.
- Placeholders: require `type` + `example`; forbid concatenation; require ICU plural when `{count}` exists.
- Notifications: flag all-caps titles/bodies and punctuation beyond one terminal mark.
- Output: short report (counts per rule, sample keys), non-zero exit to block CI on violations above.

## Audit Plan for intl_en.arb
- Parse EN ARB, apply surface tags, and run lint rules above.
- Emit a short report: counts per violation category, sample offenders, suggested fixes.
- Focus manual review on Welcome, Create/Join, Today, Flow/Chores, Share/Money, Gratitude, Auth errors.
