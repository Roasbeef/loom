# Weft in Loom

[weft](https://github.com/Roasbeef/weft) is the concurrency library every
effectful package in this tree builds its process machinery on. It is a
sibling repository by the same author, published to hex as `weft`, and it
exists because Loom kept hand-rolling the same five shapes — a parked
worker released by a permit, a poll-until-deadline loop, a spawn-monitor-
race-kill scaffold, a timer whose handler re-checks for a stale fire, and a
list of waiters flushed on a state change — and each copy re-decided the
same races. This page says what weft gives, when to reach for it, when not
to, and the rules a port in this repository is held to. The survey that
led here, with the per-site measurements, is
`docs/design-notes/weft-adoption.md`; the plan of record is loom#159.

## What it gives

Five modules, all Erlang-target, all interoperable with `gleam_otp` (a
weft `start` returns upstream's `StartResult`, a weft `supervised` returns
upstream's `ChildSpecification`, and every weft process answers the OTP
system messages, so it shows up in the observer like anything else).

| Module | What it is | The hand-rolled shape it replaces |
|---|---|---|
| `weft` | The run engine: a scope process owns every worker by link, with `limit`, `deadline`, an external cancel signal, input-order `start` and completion-order `fold`. Every task gets exactly one `Outcome`. | spawn + monitor + race a reply against `DOWN` + kill on timeout |
| `weft` managed tasks | `prepared_task`/`prepared_leaf` (owner known up front) and `managed` (owners discovered while the task runs, published through a `Ledger` with `adopt`, `adopt_leaf`, `adopt_under`). A task's slot is held and its outcome withheld until its worker *and every owner* have exited; only a normal transitive-owner exit proves drain. `start_witnessed` runs with no consumer at all — the scope's exit reason is the whole report — and `cancel_when_exits` names a consumer whose death cancels. | an ad-hoc ledger of monitored pids with cancel closures; the custodian |
| `weft/actor` | A strict superset of `gleam/otp/actor`: `continuing` (a message guaranteed to be handled before the mailbox), `then_handle`, `hibernate_after`, `idle_timeout`, `on_shutdown`, `trapping_exits`, `unlinked`. | an init gate every handler checks first; a `ready` subject handshake |
| `weft/state_machine` | A typed gen_statem: a state ADT with exhaustive `case state, message` dispatch, `postpone`, state / event / named timeouts with generation-stamped cancel-with-flush, enter callbacks, `selecting` for monitors and ports, `unlinked`. | mutually recursive functions with ten arguments each rebuilding one selector; a timer carrying an id so its handler can detect a stale fire; a hand-kept list of waiters |
| `weft/poll` | `until(within:, every:, attempt:)`, bounded polling in the caller's own process: immediate first attempt, a last attempt at the deadline, `Fail` kept apart from `Retry`, `Expired` as its own outcome. | sleep-and-recurse until a wall-clock deadline |

`weft/event_manager` (a typed gen_event) is also there and Loom uses none
of it: every fan-out in this tree is a `pg` group or a homogeneous subject
list with no per-handler state and no failure to isolate. Two surveys
looked; that is a standing rejection, not an oversight.

## When to reach for it

Reach for weft when a process is about to be written for one of these
reasons, and name the primitive in the commit:

- **You are bounding something with a deadline and reaping it.** One task,
  `weft.deadline`, `weft.start`, match all seven `Outcome` variants. The
  deadline kills *and joins* before `start` returns, which is stronger than
  a fire-and-forget kill. In-tree: `tui/connection.start_safely_within`,
  `tui/internal/ffi_file.read_safely_within`, `conformance/simulation/
  control.attempt`, `codemode/satellite.run_service`, `client/mcp.start`.
- **A handler must run before anything in the mailbox.** `continuing`.
  In-tree: `runtime/strand_runtime`'s `AwaitPredecessors`, which blocks on
  the drain ledger's claim before the driver can be nudged.
- **A process is a phase machine.** If you are writing `fn forwarding(...)`
  and `fn cancelling(...)` that recurse into each other, or arming a timer
  whose handler checks "is this still my phase?", it is a
  `weft/state_machine`: the phases are the state ADT, the per-phase
  bookkeeping is data, the timer is a state timeout that dies with its
  state, and a message the current state cannot handle is `postpone`d and
  replayed on the next transition. In-tree: `broker/exec` (the helper
  lifecycle), `codemode/launch` (the node-report holder), `provider/gateway`
  (the request guard), `client/provider_relay` (the relay guard).
- **Something owns work that outlives its own process.** A request worker
  whose socket belongs to a client library, an effect whose provider
  stream drains after the effect returns. That is a managed task with a
  `Ledger`, and the scope's pid is the drain witness. In-tree:
  `provider/custodian` (a witnessed run behind an unchanged API) and the
  effect reaper in `runtime/strand_runtime`.
- **You are waiting in the foreground on a synchronous probe.** A lock, a
  server coming up, a durable row landing. `weft/poll`. In-tree:
  `tui/bootstrap`'s four waits, `runtime/api.await_result`,
  `codemode/launch`'s accept loop.

## When not to

- **`core`, `machine` and `prompt` never import it.** They are the
  portable subset (no `@external`, no `gleam_erlang`, no `gleam_otp`; lint
  R6 gates), and weft imports both OTP packages in every module. What
  moves onto weft is a *driver*, never the machine: `machine/planner.
  next_action` is a pure function whose state lives in durable registers,
  and a weft state machine is a process whose state dies with its pid.
- **`events/bus` stays on `pg`.** Cross-process group membership is a
  different problem from an in-process handler list.
- **Janitors that defend an untrappable kill stay.** `on_shutdown` cannot
  run on a brutal kill; `broker/exec.watch_cleanup` and `codemode/launch`'s
  janitor exist for exactly that case.
- **Per-key deadline tables stay.** `mcp/client`'s in-flight expiry dict is
  N independent deadlines; a machine's timeouts belong to its one current
  state.
- **Loops on the injected logical clock stay.** `broker.clear_awaiting_
  helper` and `client/agency.wait_loop` charge attempts against a `Clock`
  the simulation steps; `weft/poll` measures the monotonic clock and
  cannot be run on logical time.
- **The cross-generation drain barrier stays.** `runtime/internal/
  drain_registry` sequences *across* driver restarts; weft's model is one
  generation, and no primitive covers a chain of scopes for one logical
  resource.
- **Producer-side backpressure is not `postpone`.** `cap/actor`'s parked
  senders await an admission acknowledgement; weft has no bounded-mailbox
  primitive, and the sandbox prelude's surface is deliberately narrow.

## The rules a port is held to

These are the ones that cost real time to learn.

1. **A state's payload does not change while the machine is in that
   state.** A state timeout is cancelled by a transition to a state that
   compares *unequal*, and a `transition` to an equal value is not a state
   change. Re-entering `Cancelling(exec)` with a mutated `exec` silently
   restarts the escalation deadline. Anything that moves per event goes in
   data. `broker/exec`'s `Phase` doc is the reference.
2. **Every `case state, message` pair is written.** No `_ ->`. An arm that
   is unreachable by construction says so in a comment and `keep`s. This is
   what makes a port bigger than what it replaced, and it is the point: a
   reviewer can see every transition.
3. **Start unlinked when the starter must not share fate.** A guard started
   by the consumer it serves, a holder that must outlive its host: `sm.
   unlinked` / `actor.unlinked`. A supervisor always links; `supervised`
   ignores the setting.
4. **Children are asked after their parent, never beside it.** Publish a
   child owner beneath the process that coordinates it (`adopt_under`),
   so the parent keeps sole custody of cancelling what it started and the
   scope reaches the child directly only when the parent died without
   finishing that job. The custodian does this for every child of its
   worker.
5. **Cancel capabilities are idempotent** (protocol-change/010). The
   witness asks owners itself; an owner may hear its cancel from the
   witness and from the worker.
6. **The grace bounds the report, never the witness.** Loom does not use
   `weft.cancel_grace`: each layer keeps its own acknowledgement timer to
   *report* `CancellationUnconfirmed`, and the scope keeps waiting for the
   owner's exit however long it takes.
7. **Mutation-test the timeout.** Remove the state timeout (or the
   deadline) and name the test that fails. A port whose timeout no test
   notices has not been ported yet.
8. **Match all seven `Outcome` variants.** Plain tasks never produce
   `DrainProofLost` or `CancellationUnconfirmed`; the arms exist so a run
   that grows an owner fails exhaustiveness rather than taking a
   catch-all.

## Extending it

Weft is `../weft` beside this checkout. During a body of work that needs
new primitives, every package that uses weft points at the sibling
checkout as a path dependency (`weft = { path = "../../../weft" }`), so a
change lands in weft's `main`, passes weft's own `make check` (format,
warning-free build, its tests, the same lint this repository runs, its doc
graph), and is used here at once. One hex release is cut when the surface
has settled, and the path dependencies switch back to a hex range in one
commit before the branch merges; `docs/plan.md` in the weft repository is
its handoff and records every ruling the engine has made. Two things the
resolver does not do by itself when a path dependency changes: refresh
the requirement lists of local packages in every manifest that lists
them, and add the entry to a manifest that reaches weft only
transitively. Both are hand-edited, and a missing one presents as
`weft.app` not found at application start.

Gaps weft has been asked for and does not yet have, so a consumer should
say so rather than force a fit: a periodic timeout kind (the broker
heartbeat, the writer's lease renewal and the driver's poll tick all
re-arm by hand), a monitored, non-panicking call against a pre-existing
pid (`broker/internal/call.try_call` and its siblings), and an injectable
clock for `weft/poll`.
