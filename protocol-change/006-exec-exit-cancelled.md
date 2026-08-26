# protocol-change/006 — add `cancelled` to `exec_exit`

**Status**: ACCEPTED 2026-08-26 · **Affects**: Part 1.4 `exec_exit` ·
**Raised by**: issue #53 (cancel ladder evasions) · **Implemented**:
sandbox + broker

## Problem

`exec_exit` describes how the payload ended with `code`, `signal`,
`wall_ms` and `timed_out`. None of those can say **that the helper
stopped the execution rather than the execution ending on its own**, and
the two are not distinguishable from any of them:

- A cancelled run whose payload had backgrounded its work reported
  `code=0 signal=0` — an ordinary clean success — in 3 of 3 measured
  runs. The shell's last foreground command completed; the ladder
  reached the rest. Nothing in the frame said the run was truncated, so
  the broker settled it as `Completed` and the caller could not tell.
- `code=143` is not evidence in the other direction either. It is
  produced by a TERM-killed payload, by a jailed payload whose supervisor
  relays 128+15, and by `sh -c 'exit 143'` with no cancel involved at
  all. A broker assertion on that byte is an assertion about three
  distinct causes.
- `signal` is worse: under a jail the helper waits on the bwrap
  supervisor, which relays a signalled payload by *exiting* 128+signal,
  so `signal` is 0 for every jailed execution regardless.
- `timed_out` covers exactly one of the two ways the helper stops a run
  and says nothing about the other.

The helper is the only party that knows, because it is the party that
climbed the ladder.

## Proposal

One boolean, alongside `timed_out`:

```
exec_exit := {
  code, signal, stdout_bytes, stderr_bytes,
  stdout_truncated, stderr_truncated,
  enforcement, degraded, wall_ms, timed_out,
  cancelled: bool,          # new
}
```

`cancelled` is true when the helper's cancel ladder was engaged for this
execution — an explicit `cancel` frame, or the wall-clock deadline, which
climbs the same ladder. `timed_out` continues to separate the two causes,
so `cancelled && !timed_out` is "the broker asked" and
`cancelled && timed_out` is "the policy's wall clock ran out".

It is set from the ladder's own state machine (`jail.Escalation`), which
now keeps the fact after the process exits — that is when it is asked.

## Impact

- Go: `framing.ExecExit` gains one msgpack field; `jail.Result` gains
  `Cancelled`; `server.go` copies it across.
- Gleam: `framing.Body.ExecExit` and `exec.ExecResult` gain `cancelled`.
  `decode_exec_exit`'s `check_keys` list gains the key, and the field is
  **required**, not optional: both ends of this wire ship together from
  one tree, and an optional field with a `False` default would let a
  helper that omits it read as "not cancelled" — the same allow-by-absence
  the sibling issue (#54) is about.
- Every constructor of either record gains one field. The compiler finds
  them all.
- `broker/exec`'s cancel path is unchanged in behaviour; what changes is
  that `Exited(result)` now carries a result that admits it was
  truncated, and tests can assert the property instead of the byte.

No durable format changes: `exec_exit` crosses the helper wire only.

**Rebuild `bin/loom-exec`.** Both ends of this wire ship from one tree,
so a helper binary built before this change no longer speaks it: its
`exec_exit` has no `cancelled` key, `decode_exec_exit` refuses the frame
as malformed, and the execution settles as `ChannelFault` — correctly, a
frame missing a required field is not a frame. Every suite that spawns a
helper builds one from source into its own build directory and is
therefore immune; the exception is the checked-in artifact path
`bin/loom-exec`, which only `make binaries` refreshes and which
`packages/client`'s live code-mode test uses. A stale one there fails
that test at `assert !outcome.is_error` with "the sandbox channel broke
protocol". `make binaries` is the fix.

## Decision

**Accepted.** The alternative — inferring cancellation broker-side from
"we sent a cancel frame and then an exit arrived" — was considered and
dismissed. It is knowable only inside the helper actor, it is a race
(an execution that finished before the cancel reached the helper is
*not* truncated), and it leaves `ExecResult` — the value that outlives
the actor and reaches every caller, the tools, and the transcript —
still unable to say what happened. The frame is where the fact belongs
because the helper is where the fact is.
