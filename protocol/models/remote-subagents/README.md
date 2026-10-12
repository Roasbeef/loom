# Remote subagents protocol model

A small [P](https://p-org.github.io/P/) model of the phase 1 spawn protocol of
`protocol-change/084-remote-subagents.md` and section 14 of
`docs/design-notes/remote-subagents.md`: a laptop that starts a child on another
orchestrator by writing a stub, sending `Spawn` and resending it from a drainer,
against a remote that adopts the child its call site already made. It is run by
`make model-check`.

The code is the specification. The model follows the slices S1 to S4 as built,
and where the design note and the code differ, the model follows the code.

## What is modelled

| Machine | Stands for |
|---|---|
| `Laptop` (`PSrc/Laptop.p`) | The parent session's store, its Agency and its remote drainer. `stubs` is the durable `remote-child/{site digest}` fact, written before any message is sent. |
| `SpawnCall` (`PSrc/SpawnCall.p`) | The effect process of one `agent_spawn`: it sends `Spawn`, resends it when the connection breaks, and ends when answered. An abort kills it. |
| `Port` (`PSrc/Port.p`) | `loom_orchestrator` with the delegate session's Agency holder and its store: admission with adoption on `minted_by`, the ended fence, `Join`, `RunEnded`, the deadline tick and a restart. |
| `Wire` (`PSrc/Wire.p`) | The network. One queue per sender and receiver pair, delivered in any interleaving across pairs, lost whole when the connection breaks. |
| `Chaos`, `Harness` (`PTst/Chaos.p`) | The environment: connection drops, remote restarts, aborts of the parent's effect processes, a parent run ending, a child finishing, extra drainer passes, and at the end two drainer passes on a quiet network and every deadline passing. |

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

### Phase 2 traffic

The laptop sends no `RunEnded` in phase 1, and every phase 1 child is detached.
The remote's handling of `RunEnded`, with its fence, is built (slice S2) and
nothing sends it. `tcRunEnd` and its `tcOnly` cases attach the children to their
runs and let `Chaos` send `RunEnded` in the wire's order, so the fence and the
reaping are checked against the interleavings a phase 2 sender will produce.
Those cases do not say the laptop sends one.

## Specs

| Spec | Rule |
|---|---|
| `AtMostOneChildPerSite` | A call site creates at most one child, however spawns and resends interleave. |
| `OwnChildOnly` | The remote answers a call site only with the child that site minted. |
| `AnswerIsStable` | A stub that names a child keeps naming it, whoever wrote the answer. |
| `JoinReportsOwnChild` | A join reports a child only to the call site that minted it, and in the state the child reached. |
| `TerminalOnce` | A child reaches a terminal state once. |
| `NoSpawnUnderEndedRun` | Once the remote handled a `RunEnded`, no spawn for that run creates a child. |
| `EndedRunChildrenStop` | A `RunEnded` leaves no child attached to its run running. |
| `EveryStubAnswered` | Liveness: every stub written is eventually answered by a handle or a refusal. |
| `EveryChildTerminal` | Liveness: every child the remote created reaches a terminal state once the deadlines pass, with no message from the laptop. |

P reports a violation of a liveness spec when a run ends with its monitor in
the hot state, so each liveness spec holds only because every fault is bounded.

## Probes

The `tcProbe*` cases must fail: each finds a witness for a situation the specs
are only meaningful if the model reaches (an adoption, a name collision refused,
a spawn refused by the fence, a child lost to a restart, a child stopped, a stub
settled by a join).

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

## What is not modelled

- The caps, the workspace, the tool ceiling and the policy: only a spawn the
  remote admits is modelled.
- Trust. Every machine is honest, which is the design's assumption.
- Time other than the deadline event. The tick is a message the port sends
  itself, so it runs at some point after the deadline and not at a modelled
  interval.
- `EveryEndedRunIsTold` and the mutant that settles a `RunEnded` row as answered
  after `Unreachable`. They need a laptop that sends `RunEnded` and keeps a row
  for it, which phase 2 adds with `Release`.
- A spawn retried against a second orchestrator. The code never does this, and
  the model has one port, so the mutant that would do it has nothing to
  duplicate.
- The result a join carries. A join reports a state, and the specs check that
  it is the child's own.
- Usage and the token budget.

## Running it

From this directory:

```sh
p compile
p check -tc tcAll -s 1000
python3 mutate.py --check
```

`make model-check` runs every case of every model, probes included, and the
mutants of the projects that have a `mutate.py`.
