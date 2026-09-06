# ADR-010: Retain one unsent command during reconciliation

**Status**: accepted · **Date**: 2026-09-05 · **Supersedes**: nothing ·
**Relates to**: [protocol 015](../../protocol-change/015-daemon-control-and-session-attachments.md), [ADR-009](009-record-terminal-attempt-custody.md)

## The question

Live testing found that ordinary Enter could refuse a prompt while the terminal
was receiving a periodic snapshot. Draining already-arrived replies before
handling a key fixes stale local state, but cannot complete a transfer whose
next fragment has not arrived. Two separate idle sessions still refused their
first submissions after that correction. Both retained their drafts and sent
no mutation; bounded waits for their replies failed.

The terminal reconciles every 250 milliseconds when no transfer is active.
Each transfer includes credit exchanges, bounded decoding and event-loop
progress. Ready is therefore a temporary window between captures, not a
reliable opportunity for keyboard admission.

## Decision

**Retain at most one unsent local mutation behind an already-adopted snapshot.**
Reuse the channel's existing bounded outgoing slot. The command remains bound
to the same attachment and contains the original encoded intent, including any
approval sequence or configuration selection. A later snapshot must not
reinterpret that intent. Initial attachment, a closed channel, another queued
command, and an outstanding mutation still refuse admission.

Local admission distinguishes waiting from sending. Waiting allocates no wire
request ID, emits no issued-request recording, and starts no mutation-response
deadline. A valid completed cut updates local authority before the command is
sent. The server independently checks authority and conditional-write inputs.
A failed capture, revocation, cancellation or replacement prevents an unsent
command from crossing to another attachment. A sent command with a lost reply
remains an unknown outcome and is never retried automatically.

The terminal leaves the submitted text, attachments and submission mode visible
and locked while waiting. It clears that composer only when sending, never when
reserving the local slot. Escape cancels the unsent intent before any existing
abort shortcut runs, then unlocks the unchanged draft. Another Enter or composer
edit cannot replace it. Scroll and resize do not require editing the composer.
This rule needs no duplicate draft or compare-and-restore mechanism.

A target change cancels the unsent intent before switching and retains the
editable composer with a notice naming the old target. Neither successful nor
failed candidate adoption may move that intent to another attachment. Sending
to the newly selected target requires another explicit user action. An action
originating in an overlay must not clear unrelated composer text when it sends.

## Why

Refusing every mutation during reconciliation preserves safety but makes
ordinary submission depend on capture timing. Draining queued replies is still
necessary, but live testing shows that it does not solve active transfers.
Waiting synchronously in the keyboard handler would block the terminal.
Another WebSocket or an unbounded command queue would add transport and
ownership machinery that one unsent slot does not require.

The cost is explicit local admission and draft state. This proposal does not
change wire frames, server ordering, recording format or the prohibition on
automatic mutation resend. Protocol 015's one-response-per-request and credited
transfer rules remain unchanged.

## Review and disposition

Independent critique confirmed that Ready-only admission conflates periodic
read progress with permission to submit. It also rejected removing the guard
alone: the existing queued-send path does not recheck authority or report
definitely-not-sent failure. Primary review confirmed those paths in
`tui/session_channel` and the TUI's request-counter-based draft restoration.
The decision incorporates typed local dispositions, a fresh role check and the
locked-composer rule. No wire or recording-format change is authorized here.

## Verification required

Tests must distinguish an active capture from an already-queued final reply.
They must prove one eventual wire send after valid completion, refusal of a
second local mutation, no send after revocation or failed capture, no migration
to a replacement attachment, and no resend after an unknown outcome. The draft
must remain recoverable on every definitely-not-sent path.

The native two-terminal gate must accept ordinary prompts during reconciliation
and paint their completed replies without keyboard-driven redraws. Focused
tests do not replace that gate.
