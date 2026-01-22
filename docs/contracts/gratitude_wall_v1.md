# Kinly Gratitude Wall Contract v1

Status: Draft (Home-only MVP alignment)  
Scope: Shared Home Gratitude Wall + Personal Gratitude Wall  
Audience: Product, design, engineering, AI agents.

Purpose

The Gratitude Wall exists to make care visible without making people visible,
and to absorb emotional risk so gratitude does not become pressure,
performance, or leverage. It is not a communication channel, a social feed, or
a record of obligation.

Built on existing wall

This contract refines the current Gratitude Wall built on `mood_submit_v2`
publishing, `gratitude_wall_list`, and related status/stats RPCs. Identity
payloads that exist for legacy reasons must be suppressed in shared UI; the
shared wall is a presentation change, not a new data model.

Governing sentence

Kinly makes care visible without making people visible. If a design choice
contradicts that sentence, it is wrong.

1) Core Principles

- System speaks first: all gratitude surfaced in shared spaces is framed as a
  system-owned update, not a personal message. Users do not post to people;
  Kinly publishes that gratitude exists.
- Identity is backgrounded: authored by real people, but never foregrounded in
  shared space. No usernames, avatars, sender labels, or per-person grouping.
  Audience is explicit (“your home”); author is not.
- Ambient, not interactive: visible but cannot be replied to, reacted to, or
  escalated. No comments, reactions, threads, or acknowledgements required.
  Silence is a valid response.
- Time-boxed by default: shared gratitude is ephemeral, scoped to a week, fades
  or resets automatically, and never resurfaces past entries. Memory for
  individuals lives privately, not collectively.

2) Home Gratitude Wall (Shared)

- What it is: a weekly ambient surface that shows that care was expressed—not
  who expressed it.
- Displayed: gratitude text (short, constrained), “Shared with your home”, and
  time context (“This week”). Optional header: “Gratitude showed up this week.”
- Never displayed: sender/receiver names, avatars, counts per person, “who
  hasn’t posted”, ordering that implies priority, historical comparison.
- Layout contract: cloud-style masonry with irregular placement, no obvious
  start or end, no sorting by user or time, and soft visual weight. The wall
  must not feel like a feed.
- Posting guardrails: pre-write guidance (“Name a small moment or action you
  appreciated this week.”) plus a soft anti-sarcasm nudge (“This might read as
  critical. Want to soften it so it feels appreciative?”). Users may proceed as
  is, but friction exists.
- After posting: system confirmation “Shared. No reply needed.” to explicitly
  remove obligation.

3) Personal Gratitude Wall (Private)

- What it is: a private reflection surface to rebalance attention and feel
  seen.
- Identity rules: full context visible to the individual (sender/receiver
  known privately), never exposed publicly.
- Display rules: same cloud aesthetic with heavier grounding; entries compressed
  to 1–2 lines by default; older entries visually de-emphasised; AI-softened
  reflection shown when content is heavy; original text always accessible but
  collapsed.
- Memory rules: personal timeline allowed; no auto-resurfacing of old emotional
  text; no streaks or performance indicators. Private memory supports
  reflection, not rumination.

4) Counts & Metrics (Strict)

- Allowed: qualitative system language only, e.g., “Gratitude showed up” or
  “Several moments of appreciation this week.”
- Not allowed: numeric counts in shared space, per-person counts, trends, or
  comparisons (“more than last week”). Counts combined with identity are treated
  as weaponisation risk.

5) Safety Under Stress (Non-Negotiable)

- Sarcasm: light detection with a soft nudge; no public call-outs; no reply
  surface. Sarcasm cannot escalate.
- Power imbalance: silence is never surfaced; participation asymmetry hidden;
  private gratitude available as a relief valve. Kinly protects the person who
  cares more.
- Low-trust homes: system framing dominates; no targeting; weekly reset
  prevents suspicion loops; gratitude remains light and reversible.

6) Failure Conditions (Do Not Ship If…)

The Home Gratitude Wall must not ship if it looks like a social feed, shows who
posted most, allows replies or reactions, persists as shared history, makes
silence visible, or encourages “keeping score.” Any of these violate the Safety
Contract.

7) Interop Notes

- For any pipelines that source from mood or mentions (see
  `docs/contracts/gratitude_mentions_v1.md`), shared surfaces must strip
  identity and per-person counts per this contract.
- Foundation surfaces must preserve dependency direction (UI → BLoC →
  Repository → Supabase) and keep shared identity suppression in the UI/BLoC
  layer; repositories should not reintroduce sender context.

```contracts-json
{
  "domain": "gratitude_wall",
  "version": "v1",
  "entities": {
    "SharedGratitude": {
      "fields": ["text", "sharedWith=home", "timeContext=this_week"]
    },
    "PersonalGratitude": {
      "fields": ["text", "sender", "receiver", "timeContext", "softenedReflection?"]
    }
  },
  "functions": {},
  "rls": []
}
```
