# Terminal attachment and mutation protocol model

A small [P](https://p-org.github.io/P/) model of how the terminal client
replaces its session attachment and custodies mutations across three
processes: the terminal, the attachment worker, and the daemon's gateway
connection. It exists because most of this client's bugs have come from
interleavings across those processes, and phase 2 of issue #530 moves mailbox
drains into runtime-delivered messages and job starts into keyed effects,
which is where those interleavings are decided. The model is written before
that change so the change has something to be checked against.
[ADR-013](../../../docs/adr/013-tui-effects-as-values.md) records the design
it checks, in its "Addendum: protocol model".

The model checks interleavings, not fidelity. Where a rule lives entirely
inside one reducer, the property tests over `session_channel` (PR #536) run
the shipped code and are the better check; the table under "Specs" says
which rules are left to them.

## What is modelled

| Machine | Stands for |
|---|---|
| `Terminal` (`PSrc/Terminal.p`) | `tui.step` followed by `runtime.perform`: one reducer step, then its effects in a separate P step. Messages may arrive between the two, as they may in the BEAM mailbox; no other reducer step runs until the effects are performed. |
| channel functions (`PSrc/Channel.p`) | `tui/session_channel`, as pure functions over a value that queue `Transmit`/`Shut` outputs and `Update`s for the caller to take. |
| `AttachmentWorker` (`PSrc/Worker.p`) | The Weft task body in `attachment.start_recorded`: resolve, connect, publish `Prepared`, wait for the acknowledgement. |
| `Socket` (`PSrc/Socket.p`) | The stratus socket and its guardian (`host/websocket`) together with the daemon's `ClientGateway` handler for that one connection (`packages/client/protocol.md`). |
| `Operator`, `Deadline`, `Fuse` (`PTst/Environment.p`, `PSrc`) | The environment: operator keys and clock readings, the attempt's 90 s deadline, and a connection broken from the daemon or network side. |

The terminal's inboxes are integers standing for terminal-created `Subject`s.
`attachment.start_recorded` creates the prepared, frames and outcomes inboxes
before the worker starts, and the model does the same. The runtime buffers
what arrives for a live inbox and drops what arrives for one that was never
created or has been discarded. The reducer reads those buffers where the code
reads its mailbox today: `tick.update_tick` polls the candidate
(`attachment.poll`) before it drains `Model.inbox`
(`inbound.drain_connection`), and a key drains ready traffic before it acts
(`interaction.update_ready_key`).

### Events and the code they stand for

| Event | Code |
|---|---|
| `eWrite`, `eShut` | `session_channel.Transmit` / `Shut` performed by `session_channel.perform`; also the close inside `attachment.cancel` |
| `eFrame` | a `connection.Message` delivered to a frames inbox |
| `ePrepared`, `eOutcome`, `eAck`, `eCancel` | `attachment.Prepared`, the weft relay's outcome (`AllDelivered` or a failure), `attachment.Acknowledge`, `weft.cancel` |
| `eWorkerClose`, `eGuardianKill` | the worker's own `connection.close` when its acknowledgement wait times out; the guardian killing a socket after its startup worker exits abnormally |
| `eOpOpen`, `eOpSubmit`, `eOpEscape`, `eOpQuit` | `session_control.begin_open`, Enter through `outbound.send_frame`, Escape through `inbound.cancel_pending`, Ctrl-C through `submit.quit` |
| `eClockRefresh`, `eClockDeadline` | a tick after the 250 ms idle refresh fell due; a tick after a request deadline passed (`session_channel.tick`) |
| `eTick`, `ePerform` | the runtime's wakeup after traffic arrived; `runtime.perform` |

Announcements the specs observe: `eCmdAdmitted`/`eCmdResolved` (a
`Disposition` and its later `Submission`, `Acknowledged` or `UnknownOutcome`
update), `eLaneClosed` (`fail`, `retire` or `close` at quit),
`eCandidateCaptured`, `eCandidateFailed`, `eVisible` (the swap in
`interaction.candidate_outcome`), `eApplied` (one message reduced into the
visible lane), `eQuit`, worker and socket lifetimes, and `eDaemonApplied`.

### What is abstracted away

- A snapshot transfer is `snapshot_begin`, one `snapshot_next` credit, and
  `snapshot_end`. Chunk counts, payload limits, fragment validation,
  approvals, lookups and history pages are not modelled.
- The attachment role is always Operator, so revocation between waiting and
  sending (`flush_queued`'s re-check) is not exercised.
- Recording and attempt traces, replay, `start_resumed`, the preview peer,
  Herdr, clipboard and the daemon relaunch are not modelled. Reconnect is
  modelled as what follows the relaunch: `begin_open` on the same session,
  which the operator's `eOpOpen` covers.
- Daemon internals: a `Socket` keeps its own sequence counter and pushes at
  most two commit notices; nothing is shared between two connections.
- Time is not modelled. A request deadline or the idle refresh can fall due
  at any tick the operator chooses, which includes every ordering the real
  clock allows.
- The attempt deadline and a daemon-side break are environment choices made
  when the worker or socket starts. Runs in which neither happens are the
  ones that test progress: the protocol must not rely on a deadline for it.

## Specs

Each spec is in `PSpec/Specs.p`, named after the code rule it encodes.

| Spec | Rule | Code |
|---|---|---|
| S1 `ReplacementIsFailPreserving` | The visible session changes only for an attempt whose initial cut was validated, whose worker completed after the acknowledgement, and whose adoption check passed. A failed attempt never becomes visible. | `attachment.poll`, `attachment.adopt`, `interaction.candidate_outcome`; tui CLAUDE.md "Session replacement is fail-preserving" |
| S2 `NoStaleRepaint` | Every message reduced into the visible lane came from the socket that lane was adopted with. | `interaction.candidate_outcome` (the swap of `Model.inbox`), `tick.update_tick`; "Every inbox the terminal reads is created by the terminal" |
| S3 `MutationCustody` | A mutation is written once and applied by the daemon at most once. A lost reply is reported `UnknownOutcome` exactly once, on the attachment that sent it. A waiting command is sent exactly once or reported `DefinitelyNotSent` exactly once, and never crosses to another attachment. Liveness: while the terminal runs, no command stays waiting or sent and unresolved forever. | ADR-010; `session_channel.admit`, `flush_queued`, `fail`, `retire`, `cancel_unsent`; "Uncertainty survives attachment replacement" |
| S4 `NoWriteAfterShut` | No write reaches a socket after the terminal closed it. | `session_channel.close`, `runtime.take` |
| S4b `ShutAtMostOnce` | The terminal closes each socket at most once. | `session_channel.close`, `session_channel.receive` (finding F1) |
| S5 `WorkerNeverStranded` | A worker that published `Prepared` is eventually acknowledged, cancelled, or ended by its own deadline. | `attachment.acknowledging`, `attachment.cancel` |
| S6 `QuitReleasesEverything` | After quit, every socket and worker the terminal owned eventually stops. | `submit.quit`, `attachment.cancel`, `session_channel.close` |
| S7 `OneRequestInFlight` | Per socket, a request is written only after the daemon answered the previous one, and request ids strictly increase. | `session_channel.admit`, `send`, `credit`, `capture_again`, `send_queued`; "A commit notice is idempotent and order-free" |

S5 and S6 are liveness specs, and S3 has a liveness half. P reports a
liveness violation when a run ends with the monitor in a hot state.

### Alignment with the property tests

The property tests over `session_channel` check these rules against the
shipped reducer. This table pairs each of them with the model:

| Property-test invariant | In the model |
|---|---|
| At most one request in flight | S7, observed across the wire |
| Request ids are never reused | S7 |
| A sent mutation is never re-sent; `UnknownOutcome` exactly once on loss | S3 |
| A waiting command is sent exactly once or reported `DefinitelyNotSent` | S3 |
| No `Transmit` follows a `Shut` on the same socket | S4 (and S4b for the second `Shut`) |
| Credits are never exceeded | covered by the property test; the model's daemon asserts only that a credit arrives inside an open transfer |
| A stale `reply_to` fails closed | covered by the property test; the model's channel fails on any mismatched `replyTo`, which S2 relies on |
| Pushes never allocate ids | covered by the property test; S7 would see an id a push allocated as a reuse |

## Running it

The toolchain is the P 3.0 dotnet tool (`p --version` prints 3.0.4.0 here).

```sh
cd protocol/models/terminal-attachment
p compile
p check -tc tcReplace -s 30000
```

The test cases are in `PTst/Tests.p`. `tcSubmit` opens one session and
submits; `tcReplace` interleaves replacements with submissions, refreshes and
deadlines; `tcQuitLate` and `tcQuitEarly` end in Ctrl-C, late or while the
first attachment is still opening. The four check every spec but S4b.
`tcShutOnceReplace` and `tcShutOnceAtQuit` check S4b alone over the replace
and quit traffic, so a regression of F1 is reported under its own name.

`PTst/Probes.p` holds reachability probes. Each asserts that one situation
never happens, so a probe *failing* is the checker finding a witness that the
model reaches it. They guard against a vacuous model, in which a spec passes
only because the situation it constrains never occurs. Run them the same way
(`p check -tc tcProbeUnknown -s 2000`); a passing probe is the problem.

`PGenerated/` and `PCheckerOutput/` are build output and are ignored.

## Results

Against the model as committed, which matches `session_channel` after PR #536:

| Test | Schedules | Bugs |
|---|---|---|
| `tcSubmit` | 30,000 | 0 |
| `tcReplace` | 30,000 | 0 |
| `tcQuitLate` | 30,000 | 0 |
| `tcQuitEarly` | 30,000 | 0 |
| `tcShutOnceReplace` | 30,000 | 0 |
| `tcShutOnceAtQuit` | 30,000 | 0 |

All nine probes find a witness within 230 schedules: a lost reply reported
`UnknownOutcome`, a retained command sent, a retained command reported not
sent, a second adoption, a retirement producing `UnknownOutcome`, a frame
from a replaced socket arriving after adoption, a candidate failing while a
session is visible, a prepared worker cancelled, and a deferred commit notice
spent as a catch-up.

### Finding F1: a closed lane closed its socket again

Before PR #536, `session_channel.close` and `session_channel.fail` had no
`Closed` guard, and `receive` matched a transport `Closed` or `NetworkFault`
before it looked at the phase. The first version of this model encoded that
and S4b failed on two paths, both reachable in the shipped code:

- **Quit after a failure.** An adopted lane's catch-up passed its deadline;
  `inbound.tick_channel` called `session_channel.tick`, which ran `fail`,
  `close` and `close_socket` and queued `Shut`. Ctrl-C then reached
  `submit.quit`, whose `session_channel.close` on the already closed lane
  queued a second `Shut`.
- **A daemon close crossing the terminal's.** The lane timed out as above
  while the daemon closed the same socket. stratus's `on_close` put `Closed`
  in `Model.inbox`, which nothing discards without an adoption, and the next
  `inbound.drain_connection` handed it to `receive`. `fail` ran again: a
  second `Shut`, and a second `Failed` update, which re-ran
  `inbound.apply_channel_update(Failed)`, printed a second "conversation: …"
  error, and asked `begin_reconnect` again (refused, because the first
  request was already attempting or spent). A `NetworkFault` followed by the
  transport's `Closed` reaches the same arm.

The second close was a message to a stopped socket actor, so the harm was the
duplicate error. The session-channel property test found the same bug
independently (seed 1, "I5 the lane queued a second close"), and PR #536 fixed
it: `close` on a `Closed` lane returns the lane unchanged, with no trace note
and no second `Shut`, and a transport `Closed` or `NetworkFault` on a `Closed`
lane returns `#(channel, [])` after writing its `Received` trace note. The
model now matches that code, S4b passes, and mutation M16 below restores the
old `close` to show S4b still catches it.

## Mutation checks

`mutate.py` reintroduces one guarded bug at a time as an exact text
replacement, compiles, runs the named tests, and restores the sources:

```sh
python3 mutate.py --list
python3 mutate.py M5-drop-acknowledgement 10000 tcReplace
```

Rerun the whole table after a change to the model or to the code it stands
for; a mutation whose pattern no longer matches fails loudly. Results, each
at up to 10,000 schedules (the checker stops at the first counterexample):

| Mutation | Test | Caught by |
|---|---|---|
| M1 adopt as soon as the cut is captured, before the worker completes | `tcReplace` | S1, "adopted before its worker completed" |
| M2 keep reading the old inbox after the swap | `tcReplace` | S2, a frame from the old socket applied to the new lane |
| M3 resend the unconfirmed mutation on the new attachment | `tcReplace` | S3, "written to the wire twice" |
| M4 `close` leaves the phase open, so the lane keeps writing | `tcWriteAfterShutOnly` | S4, "written … after the terminal closed it" (in `tcReplace`, S3 fires first) |
| M5 drop the acknowledgement | `tcReplace` | S5, liveness |
| M6 `retire` drops `UnknownOutcome` | `tcReplace` | S3, "lane closed without an UnknownOutcome" |
| M7 a commit notice captures while a request is in flight | `tcReplace` | S7, "written while request … is unanswered" |
| M8 quit does not abandon the candidate | `tcQuitLate`, `tcCustodyQuitLate` | S5, and S6 alone, liveness |
| M9 the unsent command moves to the adopted lane | `tcReplace` | S3, "lane closed with command … still waiting" |
| M10 acknowledge before the cut is captured | `tcReplace` | not caught; correct, see below |
| M11 skip the `Discard` of the old inbox | `tcReplace` | not caught; correct, see below |
| M12 quit skips `cancel_pending` | `tcQuitLate` | S3, "lane closed with command … still waiting" |
| M13 drain the adopted inbox before polling the candidate | `tcReplace` | not caught; correct, see below |
| M14 M10 plus no captured check in `adopt` | `tcReplace` | S1, "adopted without a validated initial cut" |
| M15 quit leaves the adopted lane open | `tcQuitLate` | S6, liveness |
| M16 `close` on a `Closed` lane queues `Shut` again (F1) | `tcShutOnceAtQuit` | S4b, "closed … a second time" |
| M17 transport loss re-fails a `Closed` lane | `tcShutOnceReplace`, `tcReplace` | not caught; see below |

### What the uncaught mutations say

M10, M11 and M13 change the code without breaking any rule, and the specs are
right not to report them:

- **M10, acknowledging before the cut is captured.** The worker completes
  early, and `attachment.adopt`'s own check that a cut was captured turns
  that completion into a failed attempt. The attempt is lost, the visible
  session is not. The check in `adopt` is therefore load-bearing: M14 removes
  it as well and S1 fails at once. A task outcome alone is not proof that
  the cut arrived.
- **M11, skipping the `Discard` of the old inbox.** Nothing stale reaches the
  visible lane, because the model stopped reading the old inbox when it
  swapped `Model.inbox`. The `Discard` only frees the messages still queued
  there.
- **M13, draining the adopted inbox before polling the candidate.** Frames
  already queued for the old lane are reduced while the old lane is still
  visible, which is correct; a mutation reply read that way becomes
  `Acknowledged` instead of `UnknownOutcome`.

M17 restores only the other half of F1: a second transport loss runs `fail`
on a closed lane again. With #536's guard in `close` still in place it
queues no second `Shut`, so S4b does not see it. What remains is a duplicate
`Failed` update, which no spec here observes; the property test's check that
a closed lane is inert to every event is what covers it. M16 is caught only
at quit for the same reason: in `tcShutOnceReplace` the only way to reach
`close` on a closed lane is through `receive`, which M16 leaves guarded.

### The rule phase 2 must keep

Issue #530 lists "adoption discards the old inbox before swapping in the new
one" as an ordering hazard. M2 and M11 together say what is actually
required. **The invariant to preserve is that no message from the old inbox
is delivered to the reducer after the swap.** The `Discard` itself is not
the invariant. Phase 2 moves inbox handling into the runtime, which will
select on the live inboxes and deliver their contents as messages. A runtime
that keeps delivering a replaced inbox's queued messages, even for one step,
is M2, and S2 fails within a few hundred schedules. A runtime that stops
selecting on it at the swap is correct whether or not the queued messages are
ever flushed.
