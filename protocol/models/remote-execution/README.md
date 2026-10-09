# Remote tool execution protocol model

A small [P](https://p-org.github.io/P/) model of how an orchestrator runs a
session's tool calls on an executor: the orchestrator's surface against the
executor's host and its execution ledger. It is the model that
`docs/design-notes/distributed-runtime.md` section 9 and
`protocol-change/078-distributed-runtime.md` ("Impact") promise, and it is run
by `make model-check`. Issue #697 tracks it.

The code is the specification here, not the design note. Where the note and
the code disagree, the model follows the code, and the disagreements it found are
listed, with their fixes, under "Defects found and fixed". Session movement between orchestrators is a different
model (`protocol/models/session-move`, TLA+); clearance and approvals stay
local and are not modelled.

The model checks interleavings, not fidelity. The row-level rules inside one
ledger transaction (which state may move to which, the byte budget, the digest
check) are exercised by `storage/test/storage/exec_ledger_test.gleam` against
SQLite and are not repeated here.

## What is modelled

| Machine | Stands for |
|---|---|
| `Host` (`PSrc/Host.p`) | `remote/host.gleam` over `storage/exec_ledger.gleam`. The ledger half (`scopeToken`, `ledger`) is durable. The host half (`placed`, `live`, `dead`) is the VM's memory. |
| `Body` (`PSrc/Host.p`) | The tool body, a weft run whose end reaches the host as a message (`remote/host.gleam:1003`, `run_finished`). It ends whenever the scheduler gets to it. |
| `Orch` (`PSrc/Orchestrator.p`) | One session's open, with its durable intents and staged results: `remote/workspace.gleam` attaching once per open, and the runtime that stages outcomes. |
| `Call` (`PSrc/Call.p`) | One effect process: `surface.run` for a fresh call and `surface.recover` for an orphaned one (`remote/surface.gleam:298` and `:335`). |
| `Wire` (`PSrc/Wire.p`) | The network. One queue per sender and receiver pair, delivered in any interleaving across pairs, lost whole when the connection breaks. |
| `Chaos`, `Harness` (`PTst/Chaos.p`) | The environment: connection drops, executor VM crashes, an open ending, a runtime restarting inside an open. |

### The host and the ledger

`Host.admitRun` is `host.admit_run` (`remote/host.gleam:740`) with
`exec_ledger.admit` (`storage/exec_ledger.gleam:561`) inside it. The order of
the checks is the code's. With no plane in this VM, a key the ledger holds a row
for is answered from the row (`answer_without_plane`), and only a key with no row
is refused with `NoPlane`. With a plane, the attach token is compared by value
(`storage/exec_ledger.gleam:1152`, `require_current`), then the row decides:

| The ledger holds | The host does | Code |
|---|---|---|
| nothing | inserts `admitted`, starts the body, the sender is its first waiter | `remote/host.gleam:845` (`start_run`) |
| `admitted` and a live run | the sender joins its waiters; nothing starts | `remote/host.gleam:869` (`join_run`) |
| `admitted` and no live run | marks it unknown and answers `RunLost` | `remote/host.gleam:869` (`join_run`) |
| `terminal` | answers the stored outcome | `remote/host.gleam:740` (`admit_run`) |
| `unknown` | answers `RunLost` | `remote/host.gleam:740` (`admit_run`) |
| `acked` (a tombstone) | answers `RunLost`; nothing starts | `remote/host.gleam:740` (`admit_run`) |

`Host.bodyDone` is `run_finished` and `commit_outcome` (`remote/host.gleam:1003`,
`:1021`): the row becomes `terminal` before any waiter is answered. A result for
a run that was cancelled meanwhile has no live entry and is dropped. Waiters
are monitored: `Host.callGone` is `caller_down` for a process the orchestrator
killed (`remote/host.gleam:1121`), `Host.connectionLost` is the same handler with
reason `noconnection`, and `Host.waiterDown` is `waiter_gone` with
`cancelsRun` (`remote/host.gleam:1132`, `:328`). A run whose last waiter is gone for
any reason but `noconnection` is cancelled by `Host.cancelRun`
(`remote/host.gleam:1157`): the row becomes `unknown`, then the live entry (the
worker) goes. A `Run` from a process that is already dead is handled as the
monitor does it, by firing its `DOWN` at once (`remote/host.gleam:886`, `add_waiter`).

`Host.ask` is `Query` and `QueryOrFence` (`remote/host.gleam:1324`, `:1355`) over
`exec_ledger.query` and `exec_ledger.query_or_fence` (`storage/exec_ledger.gleam:686`,
`:710`): a row is reported as it stands, and a missing row is `Missing` for a
`Query` and, for a `QueryOrFence`, is stored as a terminal "did not start" row
in the same step and reported `Fenced`. `Host.ack` is `exec_ledger.ack`
(`storage/exec_ledger.gleam:765`): a settled row becomes a tombstone, `ROW_ACKED`,
that keeps the key taken and holds no outcome, and an admitted row is not touched.
The model has one incarnation, so a tombstone is never pruned.

A host crash is the executor's VM restarting. `Host.restart` keeps the ledger
and the attach token, turns every `admitted` row into `unknown`
(`exec_ledger.open`, `storage/exec_ledger.gleam:460`, which runs `recover_ledger_calls`
at `:1005`), and empties the host's memory. The host does not rebuild any plane,
so a `Run` for a key with no row is refused with `NoPlane` until an attach, and a
`Run` for a key the ledger holds a row for is answered from the row:
`remote/host.gleam:740` looks at `state.placements`, and a restarted host starts
with `dict.new()` (`remote/host.gleam:343`, `initialise`). Nothing is relaunched.

### The orchestrator

An open attaches once with a token minted for it (`remote/surface.gleam:205`), before
its first call. `Orch` sends `Attach` and waits; a dropped connection sends the
same `Attach` again. Each exchange has its own reply subject in the code
(`process.new_subject()` in `remote/surface.gleam:487`, `send_and_wait`), so a reply
to an attempt the sender gave up on is never taken for the answer to a later
one; the model numbers attempts and `Call` and `Orch` accept only the current
one. The environment cannot end an open while it is attaching.

`Call` in `MODE_RUN` sends `Run` and waits, and whenever the connection drops
it sends the same `Run` again (`remote/surface.gleam:425`, `exchange`, and `:468`,
`attempt`). In `MODE_RECOVER` it first asks the ledger, with `QueryOrFence`
for a `ReplayNever` call and `Query` for a `ReplaySafe` one
(`remote/surface.gleam:335`, `recover`). The table in `PSrc/Call.p` maps each answer
to what the model reads. An `admitted` answer sends `Run` again to join
(`remote/surface.gleam:370`, `await_live`), where anything but a finished outcome
becomes "unknown". A missing row for a `ReplaySafe` call is the planner's
replay arm, so the same process sends `Run` (`runtime/strand_runtime.gleam:964`,
`not_started`); for a `ReplayNever` call the runtime stages "did not run"
(`:992`), which the model delivers as `D_NOT_RUN`.

`Orch` keeps a durable set of intents and staged results. `eOpenCrash` kills
the open: its calls die, the host's monitors of them fire with a reason other
than `noconnection`, the next open mints a new token and attaches, and every
key with no staged result is recovered. `eRuntimeRestart` kills only the
runtime: the calls die and are recovered, and the open and its token stay
(`surface.gleam` shares one token across every runtime restart inside an
open, and `client/CLAUDE.md` makes that an invariant). Staging a result and
acknowledging it are one step in `Orch`. `surface.ack` has no caller in the
tree; the acknowledgement that reaches the host comes from the owner port's
reconciler (`remote/owner_port.gleam:313`, `acknowledge_settled`), which runs
at attach (`:135`, `bind`) and on a timer (`:274`, `tick`).

### The wire

Erlang orders messages only per sender and receiver pair, so a request from one
effect process can arrive after a later request from another, and a dead
open's `Run` can arrive after the next open's `Attach`. `Wire` keeps one queue
per pair and delivers the head of any non-empty queue at each step. The model
has no other source of disorder.

A break loses every message in flight in both directions and tells each
process that was waiting for a reply `noconnection`, which is what the monitor
`surface.send_and_wait` takes before it sends does (`address.watch`). A process
is waiting from the moment it hands the wire a request until the wire delivers
the reply to that attempt. The host also hears `noconnection`, and drops every
waiter. A message sent after a break travels normally, because Erlang
reconnects on the next send. An executor VM crash is a break that also
restarts the host; the restart reaches the host in the wire's own order, so
what the wire delivered earlier was handled by the old VM and what it
delivers later by the new one.

The orchestrator's acknowledgement is held by the wire until every message
already in flight has been delivered or lost (`ACK_AFTER_QUIET`) in most cases,
and sent as soon as the result is staged (`ACK_AT_ONCE`) in `tcDefectLateRun`.
The ledger no longer depends on the acknowledgement's delay: see "Defects found
and fixed", the second entry.

## Specs

Each spec is in `PSpec/Specs.p`, named after the rule it encodes. The first
five are the safety rules the issue lists; the others are listed under the
bullet of `packages/client/CLAUDE.md` ("Remote tool calls (protocol 078)",
"Invariants that break things when violated") that they cover.

| Spec | Rule | Code |
|---|---|---|
| `AtMostOnceStart` | The tool body for a key starts at most once, ever. | `remote/host.gleam:740` (`admit_run`), `storage/exec_ledger.gleam:561` (`admit`) |
| `NoStartAfterFence` | Once recovery reported a `ReplayNever` key as not started, or the ledger holds its fence, the key never starts. A report of "not started" also must not follow a start. | `storage/exec_ledger.gleam:710` (`query_or_fence`), `remote/surface.gleam:335` (`recover`) |
| `UnknownIsFinal` | An unknown key is never started again, never gets a terminal row, and is never staged as finished or as "did not run". | `remote/host.gleam:1157` (`cancel_run`), `storage/exec_ledger.gleam:460` (`open`) |
| `OutcomeFaithful` | An outcome staged as finished is the outcome the ledger stored as terminal for that key, and a key is staged once. | `remote/host.gleam:1003` (`run_finished`), `storage/exec_ledger.gleam:686` (`query`) |
| `StaleTokenRefused` | A `Run` whose token is not the scope's current token never starts a body. | `storage/exec_ledger.gleam:1152` (`require_current`) |
| `CancelOnlyOnAbort` | A live run is cancelled only for a waiter that was killed, never for `noconnection`. | `remote/host.gleam:328` (`cancels_run`) |
| `EveryKeyDelivered` | Liveness: every call made durable has its outcome staged. P reports a hot monitor at the end of a run. | `remote/surface.gleam:425` (`exchange`) |
| `RefusalMeansUntouched` | A refusal staged for the model means the executor never started the call. Asserted by `tcDefectNoPlane`; see below. | `remote/surface.gleam:298` (`run`) |

`EveryKeyDelivered` is cheap and honest because every fault is bounded: a
dropped connection is repaired by sending again, a dead open is recovered by the
next one, and a restarted executor answers every key from its ledger.

### The CLAUDE.md invariants, one by one

1. One attach per open, shared by every strand and runtime restart: modelled.
   `Orch` attaches once per open, and `eRuntimeRestart` keeps the token.
   `StaleTokenRefused` and mutant M1 check what the token is for. The rule that
   a second attach inside an open gets another strand's live `Run` refused is a
   consequence of the first, not a separate behaviour; not modelled.
2. `Run` is idempotent by key and the host never starts a second run:
   `AtMostOnceStart`, mutant M4.
3. The host cancels only for a waiter that exits with a reason other than
   `noconnection`: `CancelOnlyOnAbort`, mutant M2, and the probes for the
   re-send paths.
4. The row is terminal before any reply: `OutcomeFaithful`, mutant M5. The row
   is unknown before the worker is killed: `Host.cancelRun` does both in one
   step, so the order cannot be violated in the model and a regression would
   need a Gleam test. A request for an unknown key never starts the call:
   `UnknownIsFinal`.
5. An escalation crosses as a remaining duration: out of scope (clearance and
   approvals stay local).
6. A scope with no plane closes as `UnknownCleanup(0)`; a failed build leaves
   the scope open for a retry attach: out of scope (`Close` and the plane
   build are not modelled).
7. A plane build, a run and a close are each a weft run, and `Building` refuses
   a second attach, a `Run` and a `Close`: out of scope. The model completes the
   build inside the attach.
8. A repeated `Close` answers the stored outcome: out of scope. Moving a
   session is the TLA+ model's.
9. Recovery of a `ReplayNever` call must fence: `NoStartAfterFence`, mutant M3.
10. The host's death must end the daemon: the model has the VM crash, which is
    what the rule makes of a host death. How the daemon halts is out of scope.
11. `ffi_remote.send` to an unregistered local name raises: out of scope.
12. The owner port's requester is a remote pid and needs weft 0.4.6: out of
    scope (owner callbacks are not modelled).

### What is abstracted away

- Scope states beyond `Open`: `Closing`, `Closed`, reopening at the next
  incarnation, capacity (`max_unclean_scopes`) and the workspace check. A
  `QueryOrFence` incarnation check is not modelled either, because the
  incarnation never changes.
- The byte budget, `OutcomeTooLarge`, the digest check and a damaged row.
- The plane build, `PlaneBuilding`, and the plane factory. Attach completes the
  build.
- `ListUnacked` and the reconciler's timer. An acknowledgement is sent once,
  when the result is staged, and may be held by the wire. Pruning tombstones is
  not modelled either, because the incarnation never changes.
- Owner callbacks, tails, authority reads, version mismatch, and the census.
- Time. A body ends at any time after it starts. The reconnect loop's pauses
  are the scheduler's.
- An abort of a single call (the orchestrator killing one effect process). An
  open crash and a runtime restart kill the effect processes, which is the same
  signal to the host.
- A plane's own failure (`job_lost`): a tool run that ends without a result. It
  lands in the same place as a crash, an `unknown` row.
- An attach in flight when its open ends. The environment waits for the attach
  to complete before it ends an open. A delayed `Attach` from an earlier open
  could replace the token a later open holds, because `exec_ledger.attach` has
  no generation to order them by. The orchestrator's attach is acknowledged
  before the open's first call, so this needs an open that died mid-attach;
  it is not explored.

## Probes

`tcProbe*` cases assert that a situation never happens, so each is expected to
fail: the checker found a witness. `scripts/model_check.sh` requires every probe
to fail and every other case to pass.

| Probe | The witness |
|---|---|
| `tcProbeResendJoins` | A `Run` sent again after a dropped connection joins the run that was still going. |
| `tcProbeStaleRun` | A dead open's `Run` reaches the host after the next open's attach and is refused for its token. |
| `tcProbeFenceBeforeRun` | A `Run` arrives for a key whose fence is already stored and finds it taken. This needs a runtime restart: across opens the token refuses the stale `Run` before the ledger is read, so the fence matters for the restart inside one open, where the token is the same. |
| `tcProbeStoredOutcomeRead` | A connection drop leaves the run going, it finishes with nobody waiting, and a re-sent `Run` reads its stored outcome. |
| `tcProbeRecoveryFenced` | A recovery fences a key nobody ran. |
| `tcProbeKeyUnknown` | A row becomes unknown. |
| `tcProbeAbortCancels` | A killed waiter cancels a live run. |

One path has no probe: a recovery that finds the key `admitted` and joins the
run by sending `Run` (`await_live`). It needs the host to miss the death of the
dead open's effect process, and the checker reaches it about once in 3,000
schedules, too rarely for a gate that runs 2,000. It is exercised by the cases
that include open crashes and connection drops.

## Defects found and fixed

The model found two rules that did not hold against the code. Both are fixed,
and each is now an ordinary case that passes, with a mutant that reopens it.
While they were open they were kept as `tcProbeDefect*` probes, which failed so
that the gate stayed green and said so when a fix landed.

### 1. A restarted executor refused a call it may have run

`tcDefectNoPlane` asserts `RefusalMeansUntouched`. Before the fix it failed after
a handful of schedules.

1. A `Run` for key K is admitted, and the tool body starts
   (`remote/host.gleam:845`, `start_run`).
2. The executor's VM restarts. `exec_ledger.open` turns K's row `unknown`, and the
   host's `placements` is empty (`remote/host.gleam:343`).
3. The orchestrator's effect process hears `noconnection`, reconnects and sends
   `Run` again (`remote/surface.gleam:468`, `attempt`).
4. `admit_run` checked the plane before the ledger, found none, and answered
   `RunRefused(NoPlane)`.
5. `surface.run` staged the refusal's text for the model, "the executor has no
   workspace for this session", which reads as the call not having happened.

The row said `unknown`, and `unknown_outcome_text` says plainly that the call may
have run. Nothing re-attaches inside an open, so every later call was refused the
same way until the session was opened again.

The fix: a scope with no plane answers a key the ledger holds a row for from the
row (`answer_without_plane`, `remote/host.gleam:740`). A terminal row gives its
stored outcome, an unknown row gives `RunLost`, and only a key with no row meets
`NoPlane`. `Host.admitRun` does the same. Mutant `M6-plane-checked-before-ledger`
puts the plane check back first.

### 2. A late `Run` could start a key whose row was acknowledged

`tcDefectLateRun` asserts every safety spec over runtime restarts, with the
acknowledgement sent as soon as a result is staged (`ACK_AT_ONCE`). Before the fix
it failed within a few hundred schedules, on `NoStartAfterFence`.

1. An effect process E1 sends `Run(K, t)` for a `ReplayNever` call. The message
   is still in flight.
2. The runtime restarts inside the open. E1 dies. The token is still `t`.
3. Recovery's effect process E2 sends `QueryOrFence(K)`. It reaches the host
   first (E1 and E2 are different senders). K has no row, so the host stores
   the fence and answers `Fenced`.
4. The runtime stages "did not run", and the acknowledgement deleted K's row.
5. E1's `Run(K, t)` arrived. The token was current and K had no row, so it was
   admitted and the body started, after the model was told the call did not run.

The ledger's old account was that the attach token stops a stale runtime's late
`Run` whether or not a row exists, and that the orchestrator sends each `Run`
once. The token does stop it across opens. Across a runtime restart inside one
open the token is the same, so only the row stopped it, and the surface does
re-send (`remote/surface.gleam:425`, `exchange`). The real transport is one
ordered stream per connection, and the acknowledgement comes from the reconciler,
which runs at attach and then once a minute (`remote/owner_port.gleam:274`), so
the window was narrower than the model's. It was still open, and closing it
should not rest on timing.

The fix is structural, in the ledger. An acknowledgement retires the row and
leaves a tombstone in `call_ack` (`storage/exec_ledger.gleam:765`, `ack`). A key
with a tombstone is never admitted again in that incarnation, and a `Run` for it is
answered `RunLost`. A key admitted once in an incarnation therefore never starts
again in it, by construction. Tombstones hold no outcome and no reserved bytes,
and are dropped when the scope reopens at a new incarnation, closes with every
child retired, or is released. The model has one incarnation, so it never prunes.
Mutant `M7-ack-deletes-the-row` puts the delete back.

## Mutants

`mutate.py` reintroduces one bug as exact text replacements, runs the test case
named for it, and requires it to fail on the rule it names. `python3 mutate.py
--check` runs all of them and is what `scripts/model_check.sh` runs after the
project's cases. A mutant that survives means the model has stopped depending
on the rule the mutation removes.

| Mutant | The change | Caught by |
|---|---|---|
| `M1-host-ignores-token` | `admitRun` skips the attach token comparison. | `tcOnlyStaleToken` (`StaleTokenRefused`) |
| `M2-noconnection-cancels` | `cancelsRun` returns true for `noconnection`. | `tcOnlyCancelOnAbort` (`CancelOnlyOnAbort`) |
| `M3-recover-never-with-query` | `Call` asks a `ReplayNever` key with a plain `Query`. | `tcOnlyNoStartAfterFence` (`NoStartAfterFence`) |
| `M4-second-run-for-admitted-key` | `admitRun` starts a second run for an admitted, live key instead of joining it. | `tcOnlyAtMostOnceJoin` (`AtMostOnceStart`) |
| `M5-reply-before-commit` | `bodyDone` answers the waiters, then commits in a later step, which a crash can overtake. | `tcOnlyOutcomeFaithful` (`OutcomeFaithful`) |
| `M6-plane-checked-before-ledger` | With no plane, `admitRun` refuses every `Run` with `NoPlane` before it looks at the ledger. | `tcDefectNoPlane` (`RefusalMeansUntouched`) |
| `M7-ack-deletes-the-row` | `ack` deletes the row instead of leaving a tombstone. | `tcOnlyNoStartAfterAck` (`NoStartAfterFence`) |
| `M8-stop-does-not-fence` | A stop for a key with no row does nothing, instead of barring the key. | `tcOnlyExecNoStartAfterStop` (`ExecNoStartAfterStop`) |
| `M9-noconnection-stops` | The worker takes a dropped connection for a cancel and stops the program. | `tcOnlyExecStopOnlyOnDecision` (`ExecStopOnlyOnDecision`) |
| `M10-settled-ignores-record` | The reconciler acknowledges every settled execution row, whatever its record says. | `tcOnlyExecAckOnlyWhenRecordTerminal` (`ExecAckOnlyWhenRecordTerminal`) |
| `M11-restart-relaunches` | A restarted executor starts its admitted programs again instead of marking them unknown. | `tcOnlyExecAtMostOnce` (`AtMostOnceStart`) |
| `M12-reconciler-skips-executions` | The reconciler never stops a running program whose record closed. | `tcOnlyEveryExecutionSettles` (`EveryExecutionSettles`) |

## Background executions

The addendum to protocol-change/078 on background code mode adds a second kind
of key to the same host and ledger: an execution, keyed
`(session, op, "async/<id>", 0)`, which a worker on the orchestrator starts with
`StartExecution` and which a stop or the reconciler can end. The model checks it
with three more machines in `PSrc/Execution.p` and `PSrc/Host.p`, and the specs
in `PSpec/ExecutionSpecs.p`.

| Machine | Stands for |
|---|---|
| `Record` (`PSrc/Execution.p`) | `client/async_runs` with `async_codemode.remote` and the owner port's reconciler: the durable phase of each record, the worker it starts, recovery after an orchestrator restart, the decision to close a record (a cancel, the deadline, a lost recovery question), and the reconciler's pass that stops orphans and acknowledges settled rows. |
| `Exec` (`PSrc/Execution.p`) | One worker, `surface.start_execution`: it sends `StartExecution`, sends the same start again after a dropped connection, and tells its record how the start ended. |
| `ExecBody` (`PSrc/Host.p`) | The program on the executor. It ends whenever the scheduler gets to it, unless it was stopped. |

`Host` handles `StartExecution` through the same admission as `Run`, so the
token, the row and the restart rules above apply to executions unchanged.
`Host.stopExecution` is `exec_ledger.stop_or_fence`: an admitted row becomes
unknown and the program is stopped, and a key with no row is inserted unknown,
so a start that a dead worker sent before the record closed finds the key
taken. `Host.listExecutions` is the reconciler's listing of running executions
and unacknowledged rows. The reconciler's pass is held by the wire until
nothing is in flight, as the acknowledgement is.

A record's phase is decided before anything is sent. A decision to close it is
made durable first and the stop follows, so a stop that a partition loses is
found again by the reconciler, which stops a running program whose record is no
longer live. A dropped connection is not a decision. After an orchestrator
restart, recovery asks the executor for each live record's key once: a terminal
row finishes the record with the stored value, and any other answer, or no
answer, loses it.

| Spec | Rule | Code |
|---|---|---|
| `ExecNoStartAfterStop` | Once the host has processed a stop for a key, no program for it starts. | `exec_ledger.stop_or_fence` |
| `ExecFinishedIsStored` | A record finished with a value only if the ledger stored that value as the key's terminal row. | `host.run_finished`, `async_runs` recovery |
| `ExecStopOnlyOnDecision` | A stop reaches the host only for an execution whose record was decided closed. | `surface.start_execution`, `async_runs.close` |
| `ExecNotLostWhenFinished` | A program that committed its value while its record was live, with no stop decided, ends finished. | `host.deliver` |
| `ExecAckOnlyWhenRecordTerminal` | The reconciler acknowledges an execution's row only once its record is finished or lost. | `workspace.settled_by_kind` |
| `EveryExecutionSettles` | Liveness: every claimed record ends finished or lost, and every program that started ends terminal or unknown. | the reconciler and the deadline |

`AtMostOnceStart`, `UnknownIsFinal`, `StaleTokenRefused` and `CancelOnlyOnAbort`
from `PSpec/Specs.p` are asserted over executions too. Two probes show the
model reaches the paths the specs depend on: `tcProbeExecStartBarred`, a late
start that finds its key barred by a stop, and `tcProbeExecRecoveredValue`, a
recovery that keeps a value the executor stored while the orchestrator was down.

| Case | Executions and calls | Faults |
|---|---|---|
| `tcExecQuiet` | two executions | none |
| `tcExecCancel` | two executions | two drops, two cancels |
| `tcExecOpenCrash` | two executions | one drop, one orchestrator restart, one cancel |
| `tcExecHostCrash` | two executions | one drop, one executor crash, one cancel |
| `tcExecAll` | two executions beside one call of each replay kind | two drops, one crash, one open ending, two cancels |
| `tcOnlyExec*`, `tcOnlyEveryExecutionSettles` | as `tcExecCancel`, except `tcOnlyExecAtMostOnce` (`tcExecHostCrash`'s) | one spec each, for `mutate.py` |

Left out: the input journal, progress and the other owner-bound calls, which
travel over the owner port and are tested in Gleam against the executor's
router (`client/remote/owner_link_test`); the idle expiry, which closes a record
as the deadline does; the result size limit; and MCP, which is configuration
and placement rather than protocol.

## Running it

```sh
make model-check                       # the TLA+ model, then every P project
cd protocol/models/remote-execution
p compile
p check -tc tcAll -s 30000             # one case, 30,000 schedules
python3 mutate.py M3-recover-never-with-query
python3 mutate.py --check              # every mutant
```

The P tool (`dotnet tool install --global P`, version 3.0) must be on `PATH` or
in `~/.dotnet/tools`. `make model-check` is not part of `make check` or CI,
which do not install it. It uses 1,000 schedules a case and 2,000 for a probe,
and the whole gate takes about three minutes with the TLA+ model and the
terminal-attachment model. This project's mutants take about a minute.

The cases:

| Case | Calls | Faults |
|---|---|---|
| `tcQuiet` | one `ReplayNever`, one `ReplaySafe` | none |
| `tcPartition` | the same | three connection drops |
| `tcOpenCrash` | two `ReplayNever`, one `ReplaySafe` | one drop, two opens ending |
| `tcHostCrash` | one of each | one drop, one executor crash, one open ending |
| `tcRuntimeRestart` | two `ReplayNever`, one `ReplaySafe` | two runtime restarts |
| `tcAll` | the same three | two drops, one crash, one open ending, one runtime restart |
| `tcDefectNoPlane` | the same as `tcHostCrash` | `RefusalMeansUntouched` only |
| `tcDefectLateRun` | the same as `tcRuntimeRestart`, with the acknowledgement sent at once | every spec above |
| `tcOnly*` | as `tcAll`, except `tcOnlyNoStartAfterFence` (`tcRuntimeRestart`'s traffic), `tcOnlyNoStartAfterAck` (the same, with the acknowledgement sent at once) and `tcOnlyAtMostOnceJoin` (`tcPartition`'s) | one spec each, for `mutate.py` |

Every regular case checks all of `AtMostOnceStart`, `NoStartAfterFence`,
`UnknownIsFinal`, `OutcomeFaithful`, `StaleTokenRefused`, `CancelOnlyOnAbort`
and `EveryKeyDelivered`.
