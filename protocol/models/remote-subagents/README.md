# Remote subagents protocol model

A small [P](https://p-org.github.io/P/) model of the phase 1 spawn protocol of
`protocol-change/084-remote-subagents.md` and section 14 of
`docs/design-notes/remote-subagents.md`: a laptop that starts a child on another
orchestrator by writing a stub, sending `Spawn` and resending it from a drainer,
against a remote that adopts the child its call site already made. Phase 2 adds
`Release`: the laptop deletes the parent session and tells the remote, which
stops the children and deletes the session that held them. Phase 2 also adds a
child's mail to its parent (slice S9): a row in the delegate session's outbox, sent
over a connection the laptop keeps up, and answered with a receipt. Phase 4 adds
depth (slice S13): the box's children start children of their own on a third
orchestrator, and the box's release reaches them. It is run by `make
model-check`.

The code is the specification. The model follows the slices S1 to S4 and S6 as
built, and where the design note and the code differ, the model follows the
code.

## What is modelled

| Machine | Stands for |
|---|---|
| `Laptop` (`PSrc/Laptop.p`) | The parent session's store, its Agency and its remote drainer. `stubs` is the durable `remote-child/{site digest}` fact, written before any message is sent. `releaseOwed` is the catalogue's `catalogue_remote_releases` row, written when the session is deleted. |
| `SpawnCall` (`PSrc/SpawnCall.p`) | The effect process of one `agent_spawn`: it sends `Spawn`, resends it when the connection breaks, and ends when answered. An abort kills it. |
| `Port` (`PSrc/Port.p`) | `loom_orchestrator` with the delegate session's Agency holder and its store: admission with adoption on `minted_by`, the ended fence, `Join`, `RunEnded`, `Release` with its fence and the deletion of the session, the deadline tick and a restart. |
| `Wire` (`PSrc/Wire.p`) | The network. One queue per sender and receiver pair, delivered in any interleaving across pairs, lost whole when the connection breaks. |
| `Chaos`, `Harness` (`PTst/Chaos.p`) | The environment: connection drops, remote restarts, aborts of the parent's effect processes, a parent run ending, a child finishing, extra drainer passes, the parent session being deleted, the remote's slot draining, and at the end two drainer passes on a quiet network, the slot draining and every deadline passing. |

### Depth (phase 4, slice S13)

Every case also builds the machines below the box, and the cases with `grands`
use them. The box's delegate session is itself a spawner: a child there may
start a child of its own on a third orchestrator. A second `Laptop` machine, the
relay, plays the delegate session's spawning side: its stubs, its drainer and its
release rows. It talks to two more `Port` machines at depth 2 over a second
`Wire`. The first is the orchestrator the box's `spawn_on` allows, and every
grandchild is placed there; the second exists so that a spawn sent to the wrong
orchestrator has somewhere to land. Child identities start at 0, 1000 and 2000 on
the three Ports, so no two children share one.

| Event | What it stands for |
|---|---|
| `eGrandSpawn` | A running child on the box calls `agent_spawn` with `on`. The box asks the relay to write the stub and send the `Spawn`, once per child. A child that is not running starts nothing, which stands for the released fence that `admit_remote` reads before it writes a stub. |
| `eCascade` | The box handled a `Release`, stopped its children, and now owes each third orchestrator that a stub that is not refused names a release row (`delegate_holders` and `manager.release_delegate`). The relay writes the rows, says which it owes (`eCascadeWritten`) and rings its own drainer. |
| a box restart | Also kills the relay's effect processes, as it kills the children's runs. The stubs stay. |

A stub records the orchestrator it names when it is written (`dest`), and every
resend and join goes there. An effect process knows a `spare` orchestrator only
so that the mutant that retries against it can be stated.

### The mail (phase 2, slice S9)

`eUpward` makes a running child mail its parent: the `Port` writes a row in the
session's outbox (`outbox`, stored with the session, so a restart keeps it and a
deletion discards it) and rings its drainer. A pass (`eMailPass`) sends every row
with no answer as `K_MAIL`, through `eSendUp`, which the `Wire` delivers only
while the connection is up and otherwise does not produce at all: the remote never
dials. A send from the laptop dials, so it brings the connection up, a break takes
it down, and `eReconnect` brings it back and rings the drainer. The environment
sends `eReconnect` and `eParentOpen` before the run ends, which is the model's
stated assumption: the link keeper's reconnection is fair, and a parent session
that is closed is eventually opened.

The laptop answers a `K_MAIL` in this order:

| The laptop holds | It answers |
|---|---|
| the parent session closed (`eParentClose`) | `MAIL_NOT_OPEN`, and the row stays |
| no stub for the child's call site | `MAIL_UNKNOWN` |
| a receipt for the mail's id | the receipt, steering nothing |
| the parent's run open | steers the parent and stores `MAIL_DELIVERED` |
| the parent's run ended (`eParentRunEnds`) | stores `MAIL_DECLINED` |

The stub is looked up by call site, which stands for the child's name, in any state:
the stub is written before the first `Spawn` leaves, so mail that arrives before the
answer to the spawn finds a `ST_REQUESTED` stub. Only an answer other than
`MAIL_NOT_OPEN` settles a row.

`UpwardOnlyIntoOpenRun` holds because the modelled parent run never reopens once
it has ended; a parent that starts a new run later would make a declined mail a
delivery only for mail not yet sent. The model also leaves the keeper's vote
abstract: the fair reconnection stands for the laptop holding the link while a
stub is `Requested`, running, or settled with mail still owed.

### The spawn

A call site is an integer. The stub is written when the parent starts the call
site, so an abort loses an effect process and never a stub. The drainer's pass
sends `Spawn` for each `Requested` stub and a zero-window `Join` for each
`Spawned` one. An answer is written to the stub whether the effect process or
the drainer received it. A `Refused` stub is kept, and a later `Spawned` moves
it to `Spawned`.

The port admits a `Spawn` in the order of design note section 8.2:

| The session holds | The port does |
|---|---|
| a child under the derived name, minted by this call site | adopts it: answers its handle and creates nothing |
| a child under the derived name, minted by another call site | refuses the spawn |
| no child under the name, and the ended fence set for the run | refuses the spawn |
| no child under the name | creates the child and answers its handle |

The model derives one name for call sites 0 and 2, which a real digest would
not. Without the collision the `minted_by` comparison has nothing to refuse, and
the first mutant could not be caught.

### The end of a child

A child leaves running in one of four ways, each announced once: it finishes
(`eFinishOne`, which the environment sends), the tick stops it after its
deadline, a `RunEnded` stops it when it is attached to that run, or the remote
restarts. A restart ends every run that was going and arms no tick, because a
delegate session is only reopened by the next `Spawn` or `Join` and nothing
runs in a closed one (design note section 8.3). A deadline is a single event
that makes every running child overdue and every later child born overdue; the
tick then stops them. The model does not measure time otherwise.

### The run end

The laptop sends no `RunEnded`, and every remote child is detached. The remote's
handling of `RunEnded`, with its fence, is built (slice S2) and nothing sends it.
`tcRunEnd` and its `tcOnly` cases attach the children to their runs and let
`Chaos` send `RunEnded` in the wire's order, so the fence and the reaping are
checked against the interleavings a sender would produce. Those cases do not say
the laptop sends one.

### The release (phase 2, slice S6)

Deleting the parent session (`eDelete`) writes one release row when some stub is
not refused, then removes the stubs and kills the effect processes with the
session. A drainer pass sends `Release` for the row and watches the connection
while it waits. A broken connection is an unreachable call, which is not an
answer: the row stays and the next pass sends again. Only `Released` settles it.

The remote's session has three phases:

| Phase | Meaning |
|---|---|
| `SS_NONE` | No delegate row. A `Release` answers zero and makes nothing. A `Spawn` or a `RunEnded` makes a session. |
| `SS_OPEN` | A session that serves spawns. |
| `SS_RELEASING` | A `Release` was handled: the released fence is written and every running child is stopped. Every spawn is refused. |

The slot draining (`eSlotDrained`, chosen by the environment) deletes a
releasing session with the children, fences and everything else stored under it,
which includes the outbox rows and remembered permissions that later phases keep
there. The next `Spawn` for the parent makes a new session. That session is a
different generation, and the specs that count creations per site or per run
start again at each deletion. A stale `Spawn` that overtakes the `Release` across
senders and reaches the remote after the session was deleted therefore makes a
session whose children run to their deadlines. The code accepts that, and so
does the model: the parent is gone, and the deadline and the retention sweep
bound the child.

## Specs

| Spec | Rule |
|---|---|
| `AtMostOneChildPerSite` | A call site creates at most one child on an orchestrator, however spawns and resends interleave. |
| `OneOrchestratorPerSite` | A call site's children are all on one orchestrator: a spawn is never retried against another. |
| `OwnChildOnly` | The remote answers a call site only with the child that site minted. |
| `AnswerIsStable` | A stub that names a child keeps naming it, whoever wrote the answer. |
| `JoinReportsOwnChild` | A join reports a child only to the call site that minted it, and in the state the child reached. |
| `TerminalOnce` | A child reaches a terminal state once. |
| `NoSpawnUnderEndedRun` | Once the remote handled a `RunEnded`, no spawn for that run creates a child. |
| `EndedRunChildrenStop` | A `RunEnded` leaves no child attached to its run running. |
| `ReleasedSessionHasNoRunningChild` | A `Release` leaves no running child in the session it releases, and no child is made in that session afterwards. |
| `ReleaseMakesNoSession` | A `Release` never makes a delegate session. |
| `EveryStubAnswered` | Liveness: every stub written is eventually answered by a handle or a refusal. |
| `EveryReleaseIsTold` | Liveness: every release row a spawner writes, the laptop's or the box's, is eventually answered. |
| `ReleasedDescendantsEnd` | Liveness: once the box handles a `Release`, the rows for every third orchestrator its children started children on are written and answered, and a third orchestrator's release leaves no grandchild running. |
| `UpwardAtMostOnce` | A mail steers the parent at most once, however often it is sent. |
| `UpwardOnlyIntoOpenRun` | A mail steers only a parent whose run is open. |
| `MailFindsItsStub` | Mail about a child the parent holds a stub for is never answered unknown. |
| `EveryMailAnswered` | Liveness: every mail row is eventually answered, under fair reconnection and a parent session that is eventually opened. |
| `EveryChildTerminal` | Liveness: every child the remote created reaches a terminal state once the deadlines pass, with no message from the laptop. |

P reports a violation of a liveness spec when a run ends with its monitor in
the hot state, so each liveness spec holds only because every fault is bounded.

## Probes

The `tcProbe*` cases must fail: each finds a witness for a situation the specs
are only meaningful if the model reaches (an adoption, a name collision refused,
a spawn refused by the fence, a child lost to a restart, a child stopped, a stub
settled by a join, a release that stopped a child, a spawn refused by the released
fence, a release that found no session, a released session deleted, a grandchild
made on a third orchestrator, a release that cascaded to one, and a cascaded
release that stopped a grandchild).

## Mutants

`mutate.py` applies each mutant as exact text replacements, runs the test case
that names the rule, and requires the case to fail on that rule. `make
model-check` runs it.

| Mutant | Violates |
|---|---|
| Adopt on a name match without comparing `minted_by` | `OwnChildOnly` |
| A resend creates a second child instead of adopting | `AtMostOneChildPerSite` |
| Admission does not read the ended fence | `NoSpawnUnderEndedRun` |
| `RunEnded` reaps without writing the fence | `NoSpawnUnderEndedRun` |
| `RunEnded` writes the fence and reaps nothing | `EndedRunChildrenStop` |
| The tick stops nothing | `EveryChildTerminal` |
| The drainer does not resend `Requested` stubs | `EveryStubAnswered` |
| The drainer joins the wrong child | `JoinReportsOwnChild` |
| `Release` reaps without writing the released fence | `ReleasedSessionHasNoRunningChild` |
| An unreachable call settles the release row | `EveryReleaseIsTold` |
| `Release` makes a delegate session when the parent has none | `ReleaseMakesNoSession` |
| The laptop steers a mail without storing its receipt | `UpwardAtMostOnce` |
| The laptop steers a mail into a parent whose run ended (a policy that may wake) | `UpwardOnlyIntoOpenRun` |
| The remote settles a mail row when it sends, without an answer | `EveryMailAnswered` |
| The laptop finds the stub by the handle, which a `Requested` stub lacks | `MailFindsItsStub` |
| A spawn whose connection broke is retried against a second orchestrator | `OneOrchestratorPerSite` |
| The box's release stops its children and writes no release rows for the third orchestrators | `ReleasedDescendantsEnd` |

## What is not modelled

- The caps, the workspace, the tool ceiling and the policy: only a spawn the
  remote admits is modelled.
- Trust. Every machine is honest, which is the design's assumption.
- Time other than the deadline event. The tick is a message the port sends
  itself, so it runs at some point after the deadline and not at a modelled
  interval.
- `EveryEndedRunIsTold`. The laptop sends `Release` and not `RunEnded`, so the
  property the design called `EveryEndedRunIsTold` is checked as
  `EveryReleaseIsTold` with `Release` in its place.
- A crash of the laptop between the release row and the deletion of the session.
  Both orders are safe in the code (rows without a deletion release a pair that
  still holds its session, and a deletion without rows is the bound of phase 1),
  and the model's deletion is one step.
- The deletion failing after the slot drained. The row stays released and the
  retention sweep removes it, which the unit tests check.
- The depth and fan-out caps across machines. The third orchestrators admit
  every grandchild the box sends, and the depth refusal is checked by the unit
  tests (`agency_test`).
- A grandchild's deadline. The model has one deadline event per Port, and the
  clamp that keeps a grandchild's deadline inside its parent's is checked by
  `agency_test`.
- A stale grandchild spawn that overtakes the cascaded release, across senders
  on the second wire, and makes a new session on the third orchestrator. As at
  depth 1, its child is bounded by its deadline, and `ReleasedDescendantsEnd`
  says nothing about it.
- The result a join carries. A join reports a state, and the specs check that
  it is the child's own.
- Usage and the token budget.
- Progress. A glance is a view, sent without a row, and the specs say nothing
  about it. `ChildEscalation` belongs to phase 3.
- The keeper's two second cadence. The model has a connection that is up or down
  and a fair reconnection, which is the assumption the keeper's liveness needs.
- The first `ChildSend` direction. A send is a request the laptop resends until
  it is answered, as a `Spawn` is, and the receipt rule is the one `Spawn`'s
  adoption already exercises.

## Running it

From this directory:

```sh
p compile
p check -tc tcAll -s 1000
python3 mutate.py --check
```

`make model-check` runs every case of every model, probes included, and the
mutants of the projects that have a `mutate.py`.
