# ADR-009 — Record terminal attempts before replaying adoption

**Status**: accepted · **Date**: 2026-09-05 · **Supersedes**: nothing · **Relates to**: protocol-change/015

## The question

The terminal keeps its current conversation while it validates a replacement.
Both sockets can issue request 1 and capture 1:1. The old recording format
records untagged incoming frames, so it cannot say which connection produced
a cut or whether the terminal adopted that connection.

## Decision

**New recordings use local format 2 and terminal-local attempt identities.**
A recording identifies each attempt's expected session, epoch and incarnation;
issued requests; raw incoming frames; and adoption or closure. Adoption is
recorded only after the terminal commits the validated replacement.

Request markers contain identity, command kind and bounded selectors: snapshot
identity/index, catch-up cursor, or at most eight exact escalation identities.
They contain no prompt body, credentials, URL, headers, configuration values or
approval grants. Incoming frames retain the server's existing encoding.

Replay keeps at most one current attempt and one candidate. It validates the
same transfer bounds and requires an issued request before its response. Only
an adoption marker replaces the visible session. Failed or closed candidates
release their buffers; late frames from a replaced attempt cannot repaint the
new view. Mixed historical and version-2 recordings are rejected.

## Why

Inferring connection identity from request or snapshot identifiers was rejected
because these identifiers are local to each connection. Synthesizing legacy
snapshot events was rejected because it would test a presentation adapter
instead of the live v2 decoder. A separate replay socket actor would introduce
an effect and ownership problem into an otherwise local replay.

## Consequences

The recorder, terminal channel, attachment boundary and virtual backend share
typed attempt events. Replay opens no connection, starts no daemon and sends
no mutation. Historical untagged recordings remain readable through their
replay-only decoder. This is a local recording format change, not a change to
the gateway protocol. Tests must cover overlapping identities, rejected
candidates, adoption ordering, missing credits and mixed formats.

## Addendum: recording as effects (phase 2 S3, 2026-09-26)

Phase 2 of [issue #530](https://github.com/Roasbeef/loom/issues/530) moves
the terminal's recording writes out of its reducer.
[ADR-013](013-tui-effects-as-values.md) has the mechanism in its S3
addendum; this records what it means for the recording. The format, and
the decision above, are unchanged.

**When bytes are written.** Before this change `tui.step` appended the
input's line, and each lane's trace callback appended its attempt event,
while the reducer ran. Now the step decides every line and writes none. It
queues the input's line as its first effect, before the reducer runs, and
each lane queues its attempt events as `session_channel.Note` outputs in
the same queue as its socket writes, which the reducer moves into the
step's effects where the lane was transitioned. The runtime appends the
lines after the step, in that order, through `recording.append`, the only
write after `recording.start`. A line decided under one recorder names that
recorder, so it reaches the file that was open when it was decided.

**Why the order is unchanged.** The rule this ADR needs is that within one
event the input's line precedes every line the event caused, the caused
lines follow in the order their causes were decided, and event N's lines
all precede event N+1's. Synchronous appends kept it by writing each line
at the moment it was decided. The effect queue keeps it by putting each line
at that moment's position: the input first, a request's `attempt_requested`
ahead of its frame, a frame's `attempt_frame` ahead of anything the frame
made the lane send, and an attempt's `attempt_failed` ahead of its cleanup.
The runtime performs a step's effects before the next event is stepped. An
advance of a replacement that fails part way through a poll is discarded
with its writes, as before, and its notes are kept, because the recording
has always held what it received.

**Why the format is unchanged.** Only the time of the write moved. The
lines are encoded by the same `encode_line`, and no line was added or
removed. `packages/tui/test/recording_effects_test.gleam` drives the
shipped `update` through a scripted session and compares the file with a
golden taken before the change
(`packages/tui/test/recordings/scripted-session.golden.jsonl`), with
offsets set aside: an initial capture, a resize, a prompt that waits
behind a read, a switch whose worker fails before it opens a socket, and a
quit. The test passes on both sides of the change.

**Timestamps.** A line's offset is still read from the host's monotonic
clock when it is appended, measured from the reading `recording.start`
took, and not from `Model.stamp`. The step stays clock-free either way,
because the read happens in the runtime. Three things decided it. The
recorder's epoch is a host reading, and the stamp's transport reading is
injected: a fixture that puts a replay lane on a model freezes it at zero,
so a stamp offset could mix two clocks and come out negative. One close is
decided outside any step: `attachment.cancel` closes an abandoned
attempt's lane when the runtime performs its `Abandon`, and there is no
stamp there. What the change does to offsets is this: the lines one step
decides are now all appended after that step, so they carry offsets a few
microseconds apart where before they were spread across the step's own
running time, while the spacing between the lines of different events is
kept. A stamp would have given every line of one event exactly the same
offset and taken the time from before the step rather than after it.

**The one ordering that can differ.** A replacement abandoned after it
opened its lane has its `attempt_closed` line written by that
`attachment.cancel`. Before this change that write came after every line
of the step, because every other line was written during the step. Now it
comes at the `Abandon`'s place in the queue, directly after the attempt's
`attempt_failed`. The two differ only when the same step goes on to record
something else, which a tick can do: it settles the replacement before it
drains the adopted lane and runs that lane's idle refresh. In that case
the adopted lane's `attempt_frame` or `attempt_requested` lines now follow
the abandoned attempt's `attempt_closed` rather than preceding it. The
lines are the same and belong to different attempts, and replay
(`attempt_replay.apply`) applies each attempt's events independently, so
it reconstructs the same state. Keeping the old order would take a second
queue for writes performed after the step's lines, which is the split this
change removed. A quit, the other path that abandons a replacement, queues
the adopted lane's close first and so writes the same bytes as before.
