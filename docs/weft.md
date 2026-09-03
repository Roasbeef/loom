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

Six modules, all Erlang-target, all interoperable with `gleam_otp` (a
weft `start` returns upstream's `StartResult`, a weft `supervised` returns
upstream's `ChildSpecification`, and every weft process answers the OTP
system messages, so it shows up in the observer like anything else).

| Module | What it is | The hand-rolled shape it replaces |
|---|---|---|
| `weft` | The run engine: a scope process owns every worker by link, with `limit`, `deadline`, an external cancel signal, input-order `start` and completion-order `fold`. Every task gets exactly one `Outcome`. | spawn + monitor + race a reply against `DOWN` + kill on timeout |
| `weft` managed tasks | `prepared_task`/`prepared_leaf` (owner known up front) and `managed` (owners discovered while the task runs, published through a `Ledger` with `adopt`, `adopt_leaf`, `adopt_under`). A task's slot is held and its outcome withheld until its worker *and every owner* have exited; only a normal transitive-owner exit proves drain. `start_witnessed` runs with no consumer at all — the scope's exit reason is the whole report — and `cancel_when_exits` names a consumer whose death cancels. | an ad-hoc ledger of monitored pids with cancel closures; the custodian |
| `weft/actor` | A strict superset of `gleam/otp/actor`: `continuing` (a message guaranteed to be handled before the mailbox), `then_handle`, `hibernate_after`, `idle_timeout`, `periodic` (a fixed-delay heartbeat), `on_shutdown`, `trapping_exits`, `unlinked`. | an init gate every handler checks first; a `ready` subject handshake; a `send_after` its own handler re-arms |
| `weft/state_machine` | A typed gen_statem: a state ADT with exhaustive `case state, message` dispatch, `postpone`, state / event / named / **periodic** timeouts with generation-stamped cancel-with-flush, enter callbacks, `selecting` for monitors and ports, `unlinked`. | mutually recursive functions with ten arguments each rebuilding one selector; a timer carrying an id so its handler can detect a stale fire; a hand-kept list of waiters; a `send_after` its own handler re-arms |
| `weft/poll` | `until(within:, every:, attempt:)`, bounded polling in the caller's own process: immediate first attempt, a last attempt at the deadline, `Fail` kept apart from `Retry`, `Expired` as its own outcome. `until_on` runs the same loop on an injected `Clock(now:, sleep:)`; `fold_until` threads a state from one attempt to the next and hands it back as `RanOut` on expiry; `Interval` is `Fixed` or `Doubling(from:, to:)`. | sleep-and-recurse until a deadline, on the wall clock or on an injected one |
| `weft/event_manager` | A typed gen_event: an ordered handler list, each handler's state sealed in its own closure, `notify` and `sync_notify` (which returns only once every handler has finished), and `Failed(reason)` as the answer a broken handler gives — it is dropped and logged while its siblings carry on. | a fan-out written by hand over a list of subscribers with a removal policy and a per-subscriber state record |

`weft/event_manager` has exactly one consumer here, and it took until
phase 3 of the extension work to find it. Every *other* fan-out in this
tree is a `pg` group or a homogeneous subject list with no per-handler
state and no failure to isolate, and those stay as they are.

## When to reach for it

Reach for weft when a process is about to be written for one of these
reasons, and name the primitive in the commit:

- **You are bounding something with a deadline and reaping it.** One task,
  `weft.deadline`, `weft.start`, match all seven `Outcome` variants. The
  deadline kills *and joins* before `start` returns, which is stronger than
  a fire-and-forget kill. In-tree: `tui/connection.start_safely_within`,
  `tui/internal/ffi_file.read_safely_within`, `conformance/simulation/
  control.attempt`, `codemode/satellite.run_service`, `client/mcp.start`.
  When the caller must not block on it — a TUI tick, an actor's loop —
  the same run goes through `weft.start_detached` and is polled with
  `weft.pull(within: 0)`, or `weft.start_relayed` into a subject. In-tree:
  `tui/sessions`, whose one-task switch run the terminal pulls each tick.
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
  (the request guard), `client/provider_relay` (the relay guard), and
  `codemode/satellite`'s `Host`, the persistent extension satellite —
  `Idle | Answering(id) | Destroyed(reason)`, where the open invocation's
  deadline is `Answering`'s own state timeout, so leaving the state
  cancels it and a fire that raced its own cancellation is dropped rather
  than mistaken for a real expiry.
- **Something owns work that outlives its own process.** A request worker
  whose socket belongs to a client library, an effect whose provider
  stream drains after the effect returns. That is a managed task with a
  `Ledger`, and the scope's pid is the drain witness. In-tree:
  `provider/custodian` (a witnessed run behind an unchanged API) and the
  effect reaper in `runtime/strand_runtime`.
- **Something must happen every N milliseconds regardless of activity.**
  A liveness probe, a lease renewal, a heartbeat. That is a *periodic*
  timeout — `sm.with_periodic_timeout(name:, every:, sending:)` on a
  machine, `actor.periodic(every:, sending:)` on an actor — and not an
  event timeout, which measures quiet and so never probes the chatty
  process most worth probing. The cadence is fixed delay: the next fire is
  armed once the handler for this one has returned, so a slow handler
  slows the ticks rather than queueing a backlog of them. In-tree:
  `broker/exec`'s idle heartbeat and `runtime/writer`'s lease renewal.
- **An ordered list of subscribers each hold different state, and a
  broken one must be dropped without taking the rest down.** That is
  `weft/event_manager`. The test is the *state*: if every subscriber is
  the same kind of thing and holds nothing, a subject list is simpler and
  is what the rest of this tree uses. In-tree:
  `client/extension/hooks`, the extension hook bus — one handler per
  installed extension, holding its name, the events it declared and its
  invoker; `notify` for the notifications, `sync_notify` plus a reply
  subject for the three events that need an answer, and `Failed` for a
  satellite that has died mid-session. It is *two* managers over one
  extension list rather than one, because a manager's mailbox is a queue
  and a `notify` cast onto it delays the next `sync_notify` asked on it:
  the notifications have a manager of their own so a slow tracer cannot
  spend the `tool_call` gate's budget and turn another extension's block
  into an allow. The two *chained* transforms
  (`context`, `tool_result`) are deliberately not on the bus: each must
  see its predecessor's output, which is a fold rather than a fan-out,
  and weft grows the shape before Loom grows a second bus.
- **You are waiting in the foreground on a synchronous probe.** A lock, a
  server coming up, a durable row landing. `weft/poll`. In-tree:
  `tui/bootstrap`'s four waits, `runtime/api.await_result`,
  `codemode/launch`'s accept loop.
- **…and the wait is bounded by the session's own clock.** `poll.until_on`
  with a `poll.Clock` built by `client/internal/timebase`, so a simulated
  session's wait is stepped by its runner rather than by the operating
  system. If the probe has to tell its successor something — the handles
  that already settled, the answer to give up with — it is `fold_until`,
  whose `RanOut` hands that state back. In-tree: `client/escalate.park`
  and `client/agency.wait_loop`.

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
- **`broker.clear_awaiting_helper` stays**, and it is the one logical-clock
  loop that did not move when `weft/poll` grew an injected clock. Three
  reasons, each load-bearing. It charges its budget by *subtracting its own
  nap*, so it terminates on a clock that never moves — and five of its
  seven tests wire `clock.fixed`, against which a deadline-based poll would
  wait forever. It stops on a retry-*admission* floor (`min_retry_window_ms`:
  do not spend the last second on an exchange the broker cannot answer in),
  not on the deadline, and returns the last refusal rather than an expiry
  sentinel. And its nap is deliberately never clipped to the remaining
  budget, where `weft/poll` clips by design. Forcing it in would break its
  arithmetic and the test that pins it.
- **The strand driver's `PollTick` stays a `Timers` call.** `runtime/
  effects.Timers` is an injection seam so a simulated session's poll clock
  runs on logical time; a periodic timeout is `process.send_after` under
  the hood, and moving the tick would silently convert the driver's
  checkpoint poll from injected to wall-clock. The tick also has to start
  when the predecessor-drain barrier resolves rather than at init, and it
  grants a poll permit for the duration of exactly one planning pass. A
  weft periodic timeout answers none of those three.
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
7. **Mutation-test the timeout.** Remove the state timeout (the periodic
   arm, the deadline) and name the test that fails. A port whose timeout no
   test notices has not been ported yet, and the same applies to a poll
   loop's retry: deleting the `Retry` arm must fail something, or the wait
   is only ever answering on its first attempt.
8. **A periodic timeout is armed at one place, not on every entry.** It
   belongs to the machine rather than to a state, so an enter callback that
   arms it on every entry to a state the machine keeps returning to has
   built an idle timeout by accident — a process that re-enters faster than
   the interval is never probed. `broker/exec` arms the heartbeat only on
   the path out of `AwaitingHello`, and cancels it on the way into `Dead`.
9. **Match all seven `Outcome` variants.** Plain tasks never produce
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

One gap weft has been asked for and does not yet have, so a consumer
should say so rather than force a fit: a monitored, non-panicking call
against a pre-existing pid (`broker/internal/call.try_call` and its
siblings). The other two the census named are closed — weft 0.4.1 carries
the periodic timeout kind and the injected clock for `weft/poll`.
