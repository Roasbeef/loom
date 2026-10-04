# protocol-change/014: retain native exit on helper shutdown

**Status**: ACCEPTED 2026-09-05 · **Affects**: Part 1.4 executor channel ·
**Raised by**: single-daemon session retirement · **Implementation**: broker + sandbox implemented; release acceptance remains open

## Problem

A daemon must finish retiring one session's effects before releasing its
writer lease and admitting a replacement. The helper already cancels and
joins its active jail when stdin closes. But `erlang:port_close` removes
the port before the broker can select its native exit-status event.
Returning from that call proves that BEAM closed the channel, not that
the helper finished cleanup.

The existing `cancel` frame stops an execution but keeps the helper alive
for reuse. Neither `exec_exit` nor an acknowledgement sent before helper
exit proves that the helper itself has retired.

## Proposal

Add one harness-to-helper frame after the hello exchange:

```
{v: 1, id: u64, kind: "shutdown", body: {}}
```

The body must be an empty map. The helper does not use the identifier and
sends no acknowledgement. On receipt, it stops accepting commands, cancels
and joins any active jail through its existing cleanup path, then exits.
Execution output already in flight may precede that exit.

The broker sends the frame and retains the port until it selects the
native exit-status event. A successful send, an `exec_exit`, a caller
timeout, or the death of the BEAM owner is not confirmed retirement.
Without native exit evidence, session cleanup remains unconfirmed and
cannot release the session's reservation or writer lease.

Native exit proves that the helper process ended. Successful orderly
shutdown also runs the helper's existing cancel-and-join path. Neither
claim strengthens platform containment: Darwin's documented descendant
tracking limits still apply, and helper exit does not undo remote effects.

## Impact

The Go framing package accepts `shutdown`; the helper server handles it
through the same final cleanup used by EOF. Gleam framing gains the
corresponding body variant. The helper state machine retains the port
while draining, and the pool must retain every idle and lent helper until
its close outcome is known.

Both ends ship from the same tree. Rebuild `bin/loom-exec` and release
artifacts together; there is no compatibility fallback to `port_close`.
The frame version stays at 1, following the other accepted additions to
this wire. No conversation-store format or generated SQL artifact changes.

**Superseded on 2026-09-06 by the addendum to `protocol-change/006`
(issue #64).** "Following the other accepted additions" was following a
precedent that had already cost an hour of wrong diagnosis in issue #61.
Adding a kind to the exec channel is a version bump like any other: a
helper that predates this document answers `shutdown` as an unknown kind
rather than by retiring, which is exactly the disagreement a version
number exists to name. This change is the exec protocol's **3**. The
envelope version — the `v` key — does stay at 1, and that half of the
sentence still holds; the two numbers are separate, and
`broker/framing`'s module comment says why.

## Decision

**Accepted.** The owner approved the frame on September 5. Closing stdin
through `port_close` was rejected because it discards the required exit
evidence. A shutdown acknowledgement was rejected because the helper can
send it while cleanup is still running. Native exit supplies the completion
event without another acknowledgement protocol.

## Addendum, 2026-10-02: a kill keeps its witness (issue #696, S2)

The wire, `proto` and the Part 1 text are unchanged. What changes is the
broker's rule for which native exit counts as retirement evidence, and that
rule is this document's to state, because it decides what releases a session's
writer lease.

**The problem.** The status-0 witness above covers an orderly shutdown only.
When a helper missed its cancel ladder, never finished its handshake, went
silent or broke the framing, the broker killed it by closing the port and then
sending SIGKILL. Closing the port first discards the exit status the kill
produces, so the retirement could never be proved, the pool slot stayed
`Unconfirmed(RetirementProofLost)` for good, and `close_pool` reported the same
for the life of the session, although the measured leak census showed that no
`loom-exec` or `bwrap` process survived any of those kills.

**The decision.** The broker now sends SIGKILL to the port's OS pid and
*retains the port*. Erlang delivers `{exit_status, N}` to the owner of a port
whose child was signalled, so the kill is followed by a status the broker can
select, exactly as a shutdown is. That status is retirement evidence under
these conditions and no others, decided by how much jail the helper had when it
stopped answering:

a. The helper was in `AwaitingHello` or `Idle` (no jail dispatched yet, or the
   last one already joined). The helper writes its hello before it reads any
   frame and the broker sends no `exec_start` before `Idle`, so a helper that
   never accepted a hello had no jail. `Idle` is entered on an `exec_exit`,
   which the helper writes only after `Settle` returned, and `Settle` has
   already SIGKILLed the execution's process group (and, on Darwin, its tracked
   descendants). The status retires the helper on every platform, at the grade
   of the status-0 witness. It is slightly weaker: an orderly status 0 also
   waits for the helper's cgroup release (`populated 0`, up to 2 s), and a kill
   skips that and leaves the per-execution cgroup directory.
b. The helper was in `Running` or `Cancelling` and its accepted hello
   advertised `bwrap`. `--die-with-parent` and the PID namespace
   (`--unshare-pid`) make the helper's death the jail's: SIGKILL is pending on
   the namespace root before the status is observable. The payload may keep
   running for a couple of scheduler wakeups after the broker selects the
   status and the namespace tears down over tens of milliseconds, and it cannot
   reach the protected session store in that time.
c. Any other kill, which means degraded Linux or Darwin with a live execution,
   remains unconfirmed (`RetirementExit(status)`). Darwin's descendant tracker
   lives inside the killed helper, so its limits stay its limits.

A helper that dies *unasked* (the port closes on its own with a status) is
judged by the same rule from the phase it died in, so the two cases cannot
disagree. Status 0 after the shutdown frame is `Ok` as before; any other status
after a shutdown still is not. A write that fails finds the port already
closed, so no status can follow and the proof is lost, as it always was.

**What it costs.** (b) is weaker than the status-0 witness, under which every
payload task already has SIGKILL pending when the helper exits, and the
per-exec cgroup directory under a delegated base is not removed on a killed
helper's path (a leak of a directory, not of a process; the helper could sweep
stale `exec-*` siblings at startup, which is Go work outside this change).

**Measured.** `real_helper_kill_verdict_precedes_no_late_payload_write_test`
runs a jailed payload that appends the wall clock to a file in a writable root
as fast as `date` can fork, stops the helper with SIGSTOP, lets the cancel
escalate, and records the wall-clock instant at which `close` answers `Ok`.
Over nine runs the payload's latest write was never later than that instant:
it landed 0.06 to 5.3 ms before it, against a tolerance of 100 ms. That is
the disproof this decision named for itself, and it did not fire. The test
disproves a much later jail, not a sub-millisecond one: `date` forks about once
a millisecond, so it resolves nothing finer.

**Review and disposition (docs/execution.md §7).** An independent read-only
review of the diff checked it against `jail/run.go`, `jail/bwrap.go`,
`cgroup/cgroup.go`, `server/server.go` and the custody order in `client/serve`.
It found the mechanism sound for a jail that exists and raised three
corrections, all accepted: the handshake-deadline kill (the likeliest trigger,
under load) stayed lost on every platform although it has no jail to leave, so
the verdict now follows the phase and not the features alone; an unasked death
in a live phase was judged by a stricter rule than a kill from the same phase,
so both now use the exposure rule; and the test that a late exit after a lost
channel is ignored had been deleted, so it was restored against a real port
(`real_helper_failed_write_loses_the_proof_test`). It also asked for this
addendum rather than a new number, and recommended against a separate verdict
per consumer, which is not taken: the hazard window is the same for both, and a
third outcome through `close_pool` would cost about a hundred lines and a
weaker invariant for no reachable resource.

## Addendum, 2026-10-03: a failed write keeps its witness (issue #696 follow-up)

The wire is unchanged. This corrects one sentence of the addendum above, "A
write that fails finds the port already closed, so no status can follow and
the proof is lost, as it always was."

**The problem.** The sentence is wrong when the helper died on its own. A port
opened with `exit_status` delivers `{exit_status, S}` and only then closes, so
a write that fails after the helper died finds the status already queued in
the broker actor's mailbox. Recording `LostExit` at the failed write made the
actor drop that status, left the pool slot `Unconfirmed(RetirementProofLost)`
for the life of the pool, made `close_pool` answer an error, and blocked the
session's writer lease at the custody `Helpers` step.

**The decision.** A failed write, including a failed shutdown frame, now waits
for the status as a kill does, with nothing to kill and nothing to close
(`PendingExit(Unprompted(..))`). The exit is judged by the phase the helper was
in, exactly as any exit nobody asked for is, so the grades (a) to (c) above
apply unchanged. After a failed shutdown write the status is not read as a
shutdown acknowledgement: the helper never received the frame, so status 0 is
not its report of a join. The five-second witness window that bounds the wait
after a kill bounds this one too, and a status that does not arrive in it
becomes `LostExit` as before. Expiry still grants no proof.

**What it costs.** A helper whose port closed with no status (a port closed
from outside, or a port that failed without one) now holds its slot for the
witness window before it is `LostExit`, where it was `LostExit` at once.

**The cgroup directory a kill leaves (issue #702).** The first addendum says a
killed helper's per-exec cgroup directory is not removed and that a startup
sweep would be Go work outside that change. It is now done, in Go and with no
wire change: `loom-exec` removes, at the start of server mode, the
`exec-<id>-<pid>` directories in its delegated base whose execution process no
longer exists and whose cgroup is unpopulated, by rmdir. The grade of evidence
in (b) is unchanged: the directory was never evidence of anything, only a leak.
