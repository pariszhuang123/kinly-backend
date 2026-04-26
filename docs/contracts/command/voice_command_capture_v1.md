---
Domain: Command
Capability: Voice Command Capture
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v1.0
Relates-To: contracts/api/kinly/command/command_entry_api_v1.md, contracts/api/kinly/command/command_router_contract_v1_1.md
See-Also: contracts/api/kinly/homes/paywall_status_get_v1.md
---

# Voice Command Capture v1.0

## 1. Purpose

This contract defines the voice-capture lifecycle that feeds the command entry API.

It covers:

- when recording starts
- when recording stops
- when transcription is considered ready for command submission
- manual versus automatic stop behavior
- how a finalized transcript becomes a `command_submit_v1` request

This contract is intentionally limited to voice capture for natural-language commands. It does not define photo capture, multimodal capture, or general chat UX.

---

## 2. Capture Lifecycle

Voice command capture has four phases:

1. `recording`
2. `finalizing_audio`
3. `transcribing`
4. `ready_to_submit`

Rules:

- recording starts only after explicit user action, for example tapping the microphone button
- the system MUST show that recording is active
- audio MUST NOT be submitted to the command router until recording has ended and transcription is final enough for a first-pass command attempt
- once the transcript reaches `ready_to_submit`, the client SHOULD call `command_submit_v1` with:
  - `p_input_mode = "voice"`
  - `p_transcript_text = final transcript`
  - `p_raw_text = null`

---

## 3. Recording Start

Recording MUST start only after an explicit user gesture.

Allowed start triggers:

- tap microphone
- press-and-hold microphone

Not allowed:

- passive always-on listening
- auto-start recording on screen open

Rules:

- each recording session SHOULD create a fresh client-side capture id
- the eventual command `request_id` SHOULD be created before submission and remain stable across retry
- the UI SHOULD make it obvious that voice is being captured

---

## 4. Recording Stop

Voice command capture SHOULD support two stop modes.

### Manual stop

Manual stop MUST always be available.

Examples:

- tap stop
- release push-to-talk control

When manual stop occurs:

- recording ends immediately
- the system moves to `finalizing_audio`
- the client starts transcription as soon as the recorded segment is finalized enough to process

### Automatic stop

Automatic stop SHOULD also be supported.

Automatic stop is based on end-of-speech detection plus a hard backstop.

Recommended behavior:

- detect trailing silence after speech ends
- stop automatically after the silence threshold is exceeded
- also stop automatically when the hard maximum recording duration is reached

Recommended default thresholds for v1:

- end-of-speech silence threshold: about `1000` to `1500` ms
- hard maximum recording duration: about `30000` to `60000` ms

Rules:

- automatic stop MUST NOT remove the user's ability to stop manually earlier
- silence detection SHOULD begin only after speech has actually started, to avoid stopping too early on initial hesitation
- if the hard maximum duration is reached, the system SHOULD stop and continue with the captured audio rather than discard it

---

## 5. Transcription Readiness

After recording ends, the client enters `transcribing`.

Rules:

- the client SHOULD wait for a stable final transcript before calling `command_submit_v1`
- partial transcripts MAY be displayed live in the UI, but partial transcripts MUST NOT be treated as the submitted command payload for v1
- if transcription returns empty or unusable text, the client SHOULD not submit the command and SHOULD surface a recoverable retry state

Mapped backend errors:

- unusable transcript -> `transcription_failed`
- transcription timeout -> `transcription_timeout`

---

## 6. Submission Mapping

Once transcription is ready, the client submits the voice command through the same command API as typed input.

```sql
command_submit_v1(
  p_home_id,
  'voice',
  NULL,
  p_transcript_text,
  p_timezone,
  p_locale,
  p_client_timestamp,
  p_request_id
)
```

Rules:

- voice and text share the same backend command pipeline after transcript finalization
- the router and modules MUST treat the transcript as the effective user input for that request
- request-time `timezone` and `locale` SHOULD describe the current device/app context, not only stored notification preferences

---

## 7. Multi-Intent Voice Commands

Voice input MAY contain:

- multiple intents across multiple features
- multiple items inside one feature
- both of the above in the same utterance

Examples:

- "Add milk and eggs, and log a $24 grocery expense"
- "Open house norms and show what is due today"
- "Add bread, apples, and soap"

Rules:

- the transcript is submitted once
- the router MAY classify one or more intents from that single transcript
- same-feature multi-item handling belongs to the targeted module
- cross-feature multi-intent handling belongs to the router plus batch response envelope

---

## 8. Manual vs Automatic Stop Recommendation

For v1, the recommended product behavior is:

- support both manual stop and automatic stop
- manual stop is mandatory
- automatic stop is recommended for convenience

Reasoning:

- manual stop gives the user control when they pause mid-thought
- automatic stop reduces friction for short command-style utterances
- supporting both covers the main failure modes without needing a complex conversational audio protocol

---

## 9. Deterministic vs LLM Usage

Voice capture itself does not decide deterministic versus LLM parsing. It only produces the finalized transcript.

The downstream command system applies this rule:

- voice capture -> finalize transcript
- `command_submit_v1` -> classify intent, usually with the router AI path
- routed module -> prefer deterministic handling first
- module-scoped LLM is allowed only when deterministic parsing is not safe enough

Practical interpretation:

- the presence of voice input alone does NOT force module LLM parsing
- voice and text should follow the same routing and module decision rules once the transcript is finalized

---

## 10. UX States

Recommended visible user states:

- `Listening`
- `Finishing`
- `Transcribing`
- `Processing command`
- `Couldn’t catch that`

Rules:

- the system SHOULD distinguish transcription failure from command classification failure
- the system SHOULD distinguish "still listening" from "processing your command"
- if auto-stop is enabled, the user SHOULD still see that they can stop manually

---

## 11. Non-Goals

Out of scope for v1:

- continuous back-and-forth streaming voice conversation
- barge-in during command execution
- live router invocation on partial transcript chunks
- multimodal capture with photo/audio in one request
- passive background listening
