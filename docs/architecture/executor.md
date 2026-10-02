# The executor service

Loom runs untrusted work in a native jail and keeps the books on that work in
Gleam. The two halves already existed: `broker/exec` supervises `loom-exec`
helpers, and the helper builds the jail. What did not exist was a single
object that says "this execution, on this helper, is in this state, and its
native resources are in that one". Issue #696 asks for one. This document began
as the design, written before any code and accepted in
[ADR-017](../adr/017-executor-service-seam.md). S1 has since built the service
lane, and the page now records where the tree is, the shape the service took,
how each lifecycle invariant is held, and which parts of the issue the survey
showed to be wrong.

The service is built and opt-in. `LOOM_EXECUTOR_LANE=service` selects it, and
the direct lane, which is the broker's behaviour from before the seam existed,
stays the default (see "The lane switch"). "The tree today" therefore still
describes what runs unless the switch is set, and it now cites the direct lane
at its new home in `broker/direct`. "The target shape" and "The state model"
describe what S1 built, and where the build differs from the S0 sketch the text
says so. Everything labelled S2 or later is still a plan. The doc-check gate
verifies every `path:line` citation below, so a phase that moves code will fail
the build until this page is brought along. That is deliberate.

## Why the boundary exists

The issue states the split in one sentence, and the design keeps it: Gleam
describes, supervises and exposes execution, and a native process establishes
confinement and proves what happened to operating-system resources. The
reasons are those of Rule Zero (`docs/loom-design.md`). A BEAM actor is not an
independently sandboxable kernel process, so OTP supervision cannot stand in
for namespaces, Landlock, seccomp or a process-group kill. A NIF would run
inside the emulator's address space and change the failure boundary without
creating per-actor confinement. The jail therefore stays out of process, and
the kernel stays the boundary.

What belongs on the Gleam side is everything that is bookkeeping about the
jail: who asked for an execution, which helper carries it, what state it is in,
who is owed a settlement, and what the native side has and has not proved. The
tree already does part of this work, scattered across three modules. The
helper machine knows one execution as a payload inside one of its phases. The
pool knows custody of helpers. The broker's per-call relay knows deadlines and
the caller. No module owns the execution as a whole, so four properties that
the issue lists as invariants rest on convention rather than on a type: a
relay learns when its helper dies, a cancel cannot reach a replacement
execution, a settlement happens once, and shutdown accounts for work in
flight. The service exists to make those four mechanical.

The service does not make execution faster, and nothing here claims it will.
It adds one hop between the broker and the helper, and the baselines at the
end of this page exist so that the hop is measured rather than assumed free.

## The tree today

The survey behind this section read every module the service touches. The
facts that shape the design are these. They describe the direct lane, which is
what the tree does unless the lane switch is set, and the direct lane's own
modules are cited at their present homes.

### The helper machine

`broker/exec` holds two weft state machines. The per-helper machine wraps one
`loom-exec` process behind a `Transport` seam. Its phases are `Prepared`,
`AwaitingHello`, `Idle`, `Running`, `Cancelling` and `Dead`
(`broker/exec.gleam:529`). An execution is the `RunningExec` payload carried by
`Running` and `Cancelling` (`broker/exec.gleam:556`). It has a frame id from a
counter that belongs to the helper process, and that id never leaves the
module: callers correlate events by the `Subject` they passed to `run`. No
registry, queue or identity exists above it.

The helper machine owns three timers: the handshake deadline, the cancel
grace, and an idle heartbeat. The heartbeat is off in production, because
`start_effect_plane_in` sets `heartbeat_interval_ms: 0`
(`client/serve.gleam:723`). The execution's wall deadline is not in the helper
machine at all. It lives in the broker's relay and, independently, in the
helper's own `wall_s` policy limit.

### Pool custody

Custody of a helper is two independent facts. `Availability`
(`broker/exec.gleam:2515`) says what the pool may do with the entry:
`Available`, `Borrowed`, `Draining`, `RetiringActor` or `Unconfirmed`.
`Retirement` (`broker/exec.gleam:488`) says what the helper machine knows about
its own native process, and it has four values. `NoNativeResource` means
nothing was acquired. `PendingExit` means a shutdown frame was sent and the
port is retained so the exit status can still be selected. `NativeExit(status)`
means that status arrived, and it is the only evidence
[protocol-change/014](../../protocol-change/014-helper-shutdown-witness.md)
accepts. `LostExit` means the port is gone and the proof is lost for good.

The pool never reuses a slot without evidence. Capacity is counted over every
entry, including draining and unconfirmed ones (`lendable_again`,
`broker/exec.gleam:2994`), and an entry leaves the inventory only when its
actor exits normally after a recorded retirement (`record_owner_exit`,
`broker/exec.gleam:2901`). The cost is that most failures end in `LostExit`:
`mark_dead` closes the port (`broker/exec.gleam:2140`), and `kill_transport`
closes it before it sends `SIGKILL` (`broker/exec.gleam:2105`), so no exit
status can follow. A helper that missed its cancel deadline, timed out its
handshake or violated the protocol therefore costs one slot permanently. The
pool has no waiter queue. A full pool answers `AllBusy(size)` at once
(`next_helper`, `broker/exec.gleam:2944`), and waiting is the caller's polling loop
(`clear_awaiting_helper`, `broker/broker.gleam:505`), which `docs/weft.md`
rules deliberately hand-rolled. Idle retirement (#283) is not implemented.

### The direct lane's relay

Every cleared call reaches a helper through the `Dispatcher` the broker was
started with, and the direct lane's is `broker/direct`. `start_execution`
(`broker/broker.gleam:1109`) builds a `Dispatch`, calls `Dispatcher.start`, and
on success keeps an `Active` row (`broker/broker.gleam:280`) holding the
`Execution` the dispatcher returned, the broker's monitor on that execution's
guarantor, and the call's token and budget slot. The broker never holds a
`Helper`. Direct `start` (`broker/direct.gleam:120`) borrows a helper, spawns an
unlinked relay process, waits for the relay to hand back the event subject it
owns, and only then sends the helper its start with `exec.run`
(`broker/direct.gleam:169`), before `start` returns. The relay (`relay`,
`broker/direct.gleam:242`) forwards output to the caller, enforces the wall
deadline, and on a terminal event calls the broker's `settle` closure, which
sends the broker a `Settle` and then the caller a `CallSettled`. The broker
handles that `Settle` by demonitoring the guarantor, calling the execution's
`release`, which in this lane is `checkin`, and running `reclaim`
(`broker/broker.gleam:987`), which revokes the token and releases the budget
slot.

The relay selects two things: events from the helper machine, and the death of
the caller (`relay_wake`, `broker/direct.gleam:221`). It does not watch the
helper actor itself. When that actor dies mid-execution, nothing sends a
terminal event, because the death notice runs inside the dying actor
(`notify_death`, `broker/exec.gleam:2175`). A relay with a wall deadline
eventually settles through its grace window. A relay with `deadline_ms == 0`,
the session-lifetime jobs of protocol-change/058, waits in
`selector_receive_forever` (`broker/direct.gleam:236`) and never settles. The
jail itself is not leaked, since the port closes with the dead owner, the
helper reads end of file, and it cancels and joins its jail. The hang is on the
BEAM side. A relay that itself dies unsettled is also silent to its caller: the
broker's monitor on the guarantor fires and the broker reclaims the slot and the
token, but `settle` was never called, so no `CallSettled` follows.

### The per-session effect plane

`start_effect_plane_in` (`client/serve.gleam:702`) builds one pool and one
broker for each session, and in the service lane one executor service between
them. The pool and the broker are captured by value in closures, and each is a
fatal child of the instance (`instance_children`, `client/serve.gleam:2160`),
since a replacement would be unreachable. The service is a third fatal child in
the service lane. The custody order of a session's teardown is Runtime,
Services, Broker, Helpers, Mcp, Storage, Namespace (`clean`,
`client/internal/instance_owner.gleam:366`), so the session's writer lease is
released only after the `Helpers` step has shown a native exit for every helper
the session owned. In the direct lane `Helpers` is `close_pool` with a five
second wait (`client/serve.gleam:762`); in the service lane it is
`executor.close` with the same wait (`client/serve.gleam:811`), which drains
executions and then closes the pool.

Only `serve.gleam` builds the pool. Only `direct.gleam` and `executor.gleam`
call `run`, `stdin` and `cancel`, and `broker.gleam` reaches them through the
closures of an `Execution`. Seven clearance sites share the one broker per
session: the ordinary tool runner, the jobs runner, goal checks,
language-server jails, the hook runner, the worktree observer and the
git-identity step. Code mode reaches the broker through the opaque `Broker`
handle at fifteen call sites in the `codemode` package, so any design that
changes the handle's type touches all of them. One non-broker borrower exists:
the boot-time `degraded` probe checks a helper out directly
(`client/serve.gleam:6657`).

Some native processes never go through the pool, and "all execution goes
through the service" must not be read to include them: MCP servers (an open
issue, #109), the `loom-exec --publish-git-identity` step, credential commands
in `[secrets]`, and the daemon's own launch helpers.

### The native side

The helper is a 316-line frame loop that serves one execution at a time, and
it holds no state between executions. Two facts about it matter to the
service. First, it reports an execution as free as soon as the child is
reaped, which is strictly before the terminal frame is written and before
cgroup removal is joined (`execFreed`,
`sandbox/internal/server/server.go:147`). A broker that treated `exec_exit` as
"fully cleaned up" would claim more than the helper does, which is why
protocol-change/014 insists on the process exit status as the witness.

Second, the helper has a latent head-of-line fault. `exec_stdin` is handled
on the frame-loop goroutine, and `WriteStdin` holds the execution's mutex
across a pipe write (`WriteStdin`, `sandbox/internal/jail/run.go:649`). A
payload that never reads stdin, given enough stdin to fill the pipe, blocks the
loop, so cancel, heartbeat and shutdown frames go unread. `Cancel` needs the
same mutex (`sandbox/internal/jail/run.go:678`), so the wall-clock timer stalls
too. That fault is fixed on its own branch; see "Defects found on the way".

## The target shape

The shape below is what S1 built. Where the build departs from the S0 sketch
the text names the departure and the reason, because the sketch is what
ADR-017 and the issue comment describe.

### The seam

The service sits at the execution level. The broker keeps what it owns today,
which is policy composition, tokens, budgets, abort epochs and the `Active`
rows. Where it used to check a helper out, run the execution, relay events and
check the helper in, it calls a record of functions instead, defined in
`broker/dispatch`:

```gleam
pub type Dispatcher {
  Dispatcher(start: fn(Dispatch) -> Result(Execution, StartRefusal))
}

pub type Dispatch {
  Dispatch(
    request: exec.ExecRequest,
    seq: Int,
    deadline_ms: Int,
    clock: Clock,
    caller: Option(Pid),
    deliver: fn(Chunk) -> Nil,
    settle: fn(Terminal) -> Nil,
  )
}

pub type Execution {
  Execution(
    id: ExecutionId,
    guarantor: Pid,
    cancel: fn() -> Nil,
    stdin: fn(BitArray, Eof) -> Nil,
    release: fn() -> Nil,
    abandon: fn() -> Nil,
  )
}
```

`start` answers synchronously. A `NoHelper(CheckoutError)` refusal feeds the
broker's existing congestion handling unchanged, so `AllBusy(size)` still
means what it means today, and `NotStarted` is the dispatcher saying it could
not set up its own machinery, which the broker answers as `BrokerUnavailable`.
`start` must answer at once, because the broker calls it from its serial
message handler, and a service that parked the request would wait for a helper
that only the broker's own mailbox can release
(`docs/architecture/effects.md`, "Tokens, budgets, and the helper pool"). The
wait therefore stays in the caller.

The broker builds `deliver` and `settle` per call. `deliver` sends the caller
its `CallOutput`; `settle` sends the broker its own `Settle` and then the
caller its `CallSettled`, the same two messages in the same order as before the
seam. A dispatcher reports `settle` exactly once per started execution, by
whichever of its relay and its service holds the verdict, and the next two
paragraphs are how that is made true. The returned `Execution` is all the
broker keeps: its closures are the only way back to the helper, so the broker
never holds a `Helper` and never imports an implementation. In the direct lane
the closures capture the helper, exactly as the broker's `Active` row did. In
the service lane they name the execution by `ExecutionId` and cast to the
service, which looks the row up and drops anything addressed to a row that is
gone.

**`release` and `abandon` are exclusive.** The S0 sketch had only `abandon`,
and the helper's return was left to the dispatcher. Building the direct lane
showed that the moment of the return matters. The broker handles a `Settle` by
demonitoring the execution's guarantor, which also flushes any `DOWN` already
queued, then calling `release`, then reclaiming the slot and token
(`broker/broker.gleam:987`). A guarantor `DOWN` that reaches the broker with
the monitor still in place calls `abandon` instead, through
`handle_guarantor_down` (`broker/broker.gleam:961`). Because the demonitor is
the step that separates the two paths, the broker calls exactly one of them for
any execution, never both and never `abandon` after a settlement. An earlier
draft returned the helper from inside the relay, ahead of `settle`, and that
opened a window in which a relay killed between the two made the broker
`abandon`, and so cancel, a helper that another call had already been lent. The
helper therefore goes back where it always went, while the broker processes the
settlement, and the broker's own ordering is what keeps `abandon` away from a
helper that has been lent on. In the direct lane `release` is `checkin` and
`abandon` is a cancel followed by `checkin`. In the service lane both are casts
to the service, covered below.

**The relay is the guarantor, in both lanes.** The guarantor is the process
whose unsettled death means `settle` will never be called, and the broker
monitors it. S0 sketched the service as the service-lane guarantor. As built it
is the relay in both lanes, which is the process that calls `settle`, so the
broker has one rule (demonitor on `Settle`, `abandon` on `DOWN`) and it is the
same rule for either dispatcher. The service watches the relay as well. A
relay that dies unsettled is therefore seen twice, by the broker, which casts
`Abandon`, and by the service's own monitor, which delivers `RelayDown`.
Whichever arrives first removes the row, cancels the helper, returns it busy so
the pool retires it, and settles the caller as `ExecutionLost(RelayDown)`. The
second finds no row and is dropped. That makes the caller's settlement
unconditional in this lane, where the direct lane gives none.

Carrying closures rather than ids keeps the direct lane free of a registry.
`ExecutionId` lives in `broker/dispatch` beside the `Execution` that carries it,
and is opaque so that identities come only from its constructor function and
the pair can grow a field without touching a call site. It is an incarnation
and a sequence number, where the sequence is the broker's own call id.

Three alternatives sit at other heights and were rejected. A seam behind
`checkout` and `checkin` (`BrokerConfig`, `broker/broker.gleam:234`) is free to
build but sees only lend and return, never output, exit, cancel or deadline, so
the execution registry would have to be fed from the broker anyway. A seam at
the tool runner sits above policy and tokens and would change every one of the
seven clearance sites and fifteen code-mode sites. The design instead keeps
the `Broker` handle as the one door and replaces what sits beneath it, so no
call site outside `broker.gleam` and `serve.gleam` changed in S1, and
`broker.start` keeps its signature by wrapping the direct dispatcher. ADR-017
records the comparison.

### The modules

| Module | Role | Lives |
|---|---|---|
| `broker/dispatch` | The `Dispatcher`, `Dispatch`, `Execution` and `ExecutionId` types, the `Chunk`, `Terminal` and `StartRefusal` vocabulary, and `relay_grace_ms`, so the two lanes cannot disagree on how long a cancel may take. It defines vocabulary and no process. The broker imports this and nothing else from the service. | `packages/broker` |
| `broker/execution` | The pure core of one relay: `Mode`, `Core`, `Event`, `Effect` and `step(core, event) -> #(Core, List(Effect))`. It imports no process library and is property-tested without a process. | `packages/broker` |
| `broker/relay` | One `weft/state_machine` per execution, running `step`: it selects the helper's events, the caller's death, the helper actor's death and the service's control messages, and performs the effects. | `packages/broker` |
| `broker/executor` | A `weft/state_machine` with phases `Serving`, `Closing` and `Closed`, holding the table of live rows, the pool's seams as closures, and the incarnation. It is the service lane's dispatcher and the only process that speaks to a helper about an execution. | `packages/broker` |
| `broker/direct` | The dispatch machinery the broker carried inline, moved behind the same record with its relay loop unedited. Temporary. | `packages/broker` |

All five stay in `packages/broker` until S4. A separate `packages/executor`
could not be called by `broker.gleam` without a dependency cycle, so the seam
type would live in `broker` regardless, and the package would hold only an
implementation. It would also cost a manifest, a path dependency on weft, a
documentation pair, CI wiring and a lint policy, none of which S1 through S3
earn. `broker.gleam` does not import `executor.gleam`. The pure core sits in
`broker` and not in `core` or `machine` because lint rule R6 binds those
packages and not this one, and because the core settles in the seam's own
vocabulary and reuses `ExecResult` and `ExecFailure`, which `core` would
otherwise have to duplicate. The S0 sketch had the diagnostic ring in the
executor and described it as a `weft/actor`. The ring is not built (it belongs
to S3's snapshot), and the three phases below made the service a state machine.

### The relay reaches the service through closures

`broker/relay` never imports `broker/executor`, which imports it to start
relays, so the two ways back are closures the service builds and hands over in
`Link` (`broker/relay.gleam:111`): `cancel`, a cast to the service, and
`may_settle`, a bounded call. A relay never casts to a helper. That is the
whole of the single-sender argument in "The state model", and it is why the
relay cannot cancel the wrong execution: it has no handle with which to do so.

`may_settle` answers a `Permission` (`broker/relay.gleam:95`), which has three
values. `Granted` means the execution was live and is now spoken for, so this
relay reports. `AlreadySettled` means the service has settled or released it
already, so reporting again would be a second settlement and the relay says
nothing. `ServiceSilent` means the service did not answer within
`settle_wait_ms` (`broker/relay.gleam:190`) or is gone, and the relay reports
anyway. The third arm is the delicate one, and the module argues it. A dead
service settles nothing, so the relay's report is the only one. A live service
that answers late has, by the order of its own mailbox, either granted this
relay's ask, which changes nothing since the relay has gone, or seen the
relay's death after the ask and found the row no longer live. Between the three
answers an execution is reported once.

### Locality

There is one service per session effect plane, in process, wrapping that
session's pool. The reason is the proof. The custody order releases the writer
lease only after `Helpers` has shown a native exit for each helper the session
owned. A daemon-wide pool could lend session A's helper to session B, and then
"A's jails are joined" would have to be proven from `exec_exit`, which
protocol-change/014 says is not a join witness. The only way to keep the proof
under sharing is to retire helpers per session, and that is no sharing at all.

Capacity across sessions is already bounded by the session slots times the
pool ceiling of sixteen. If the baseline memory probe shows that bound too
loose, the remedy is idle retirement (#283), not a daemon-wide semaphore. In
local mode the service lives inside `loomd`. A second VM would buy nothing,
since the helper is already out of process and the kernel is the boundary, and
it would cost a wire the epic is told not to define.

### The lane switch

The service ships behind a setting. `Settings.executor_lane` takes one of
`DirectLane` or `ServiceLane` (`ExecutorLane`, `client/serve.gleam:333`), read
from `LOOM_EXECUTOR_LANE` by the same mechanism as `LOOM_HELPER_POOL`
(`client/serve.gleam:1391`) and chosen in `start_effect_plane_in`, which hands
off to `start_direct_lane` (`client/serve.gleam:752`) or `start_service_lane`
(`client/serve.gleam:789`). Only the exact text `service` selects the service
lane (`executor_lane_named`, `client/serve.gleam:1993`). An unset variable,
`direct`, a different capitalisation and a typo all select the direct lane,
silently, as `LOOM_HELPER_POOL` falls back to its default on text that is not a
number: the variable is an opt-in to a newer path, and a typo that left a
session on the established one is the safe direction to fail in.

S1 ships the service lane opt-in, with `DirectLane` as the default, because the
issue's rollout rule is that a new path starts opt-in. S2 flips the default to
`ServiceLane` once the failure matrix passes. S3 deletes `broker/direct.gleam`,
the setting and the variable. The lane is read once when a session opens. A
session builds its one pool first, exactly as it always did, and the lane only
chooses what stands between the broker and that pool, so a running session never
changes lanes and no helper is ever visible to both dispatchers. Rollback before
S3 is the variable at session open. That satisfies the issue's requirement that
both paths never believe they own the same resource, by construction rather than
by drain. The cost is one temporary duplicate relay loop of under a hundred
lines, for the length of two phases.

The test `Settings` builders read the variable through
`executor_lane_from_environment` (`client/serve.gleam:1978`), so exporting
`LOOM_EXECUTOR_LANE=service` runs the client and conformance suites over the
service lane without editing a test. Two tests pin the switch itself:
`the_lane_variable_selects_the_service_only_by_name_test` and
`the_service_lane_is_a_fatal_root_and_closes_under_custody_test`, which checks
that the service is a fatal root beside the pool and the broker, that the
`Helpers` step closes it, and that the lease is released only after.

## The state model

The issue asks for three independent dimensions: the logical outcome of an
execution, the state of its output, and the native custody of its resources.
The tree already has the third. The first two are new and live in
`broker/execution`, and as built they are smaller than the S0 sketch, which
put a four-variant `Phase` with a `HelperGen` and an `Outcome` type in a single
registry row. The built types are these.

```gleam
// broker/execution: the relay's pure core
pub type Mode { Streaming | Draining }
pub type Settledness { Open | Settling(terminal: dispatch.Terminal) }
pub type Core {
  Core(mode: Mode, output: Output, cancel: CancelState, settled: Settledness)
}

pub type Event {
  ExecOutput(chunk: dispatch.Chunk) | ExecExited(result: exec.ExecResult)
  | ExecFailed(failure: exec.ExecFailure) | CancelRequested | CallerDown
  | HelperDown | DeadlineReached | GraceExpired
}
pub type Effect {
  Deliver(chunk: dispatch.Chunk) | SendCancel | EnterDraining
  | Settle(terminal: dispatch.Terminal)
}
pub fn step(core: Core, event: Event) -> #(Core, List(Effect))

// broker/dispatch and broker/exec: how an execution ended
pub type Terminal { Completed(result: exec.ExecResult) | Failed(failure: exec.ExecFailure) }
pub type ExecFailure { ... | ExecutionLost(cause: LossCause) }
pub type LossCause { HelperActorDown | RelayDown | ExecutorClosing }

// broker/executor: whether anyone may report the verdict
type Status { Live | Granted }
```

The logical outcome is `dispatch.Terminal`. There is no separate `Outcome` and
no `Lost` variant beside `Failed`: a loss is `Failed(ExecutionLost(cause))`,
which is the one failure that says the execution may have started and its
result is unknown. Putting it in `ExecFailure` means it travels the existing
`Terminal` and `CallFailed` path with no new broker outcome. It carries
`LossCause`, whose three values are the three machines that can be lost: the
helper's actor (`HelperActorDown`), the relay (`RelayDown`), and the service
itself closing (`ExecutorClosing`). Nothing may replay an execution that ended
this way. `broker.denial_for_failure` answers `None` for it, because an
approval would invite the retry, and `tool.exec_failure_text` tells the model
plainly that the command may have run and its outcome is unknown. The S0 names
`LossReason`, `HelperActorGone`, `RelayGone` and `ServiceClosing` did not
survive.

The state of the output is `execution.Output`, counters and one `Truncation`
flag, and nothing else. The service retains no output bytes: the relay hands
each chunk to the caller as it arrives. The S0 `Open | Drained | OutputLost`
variants are not built, because no decision depends on them.

An `ExecutionId` pairs an incarnation with a sequence number. The incarnation
is the session clock's reading when the service starts, so ids from an earlier
service can never equal one from a later one, and a service restart is a
session restart in any case. The direct lane always mints incarnation zero. The
sequence number is the broker's call id.

### Where the phases went

S0 put one `Phase` (`Dispatched`, `Running`, `Cancelling`, `Settled`) in each
registry row. As built, the lifecycle is split by who can observe each part.
The service's row has two statuses, `Live` and `Granted`. The relay's `Core`
has a `Mode`, `Streaming` or `Draining`, and a `Settledness`. The helper
machine keeps the phases it always had. The split follows from what a decision
can depend on, and `Dispatched` versus `Running` is the case that shows it: the
relay does exactly the same thing before the first output as after it, so the
edge between them changes no decision and would be a state with no transition
effect. `Dispatched` is therefore the interval during which the row is `Live`
and the core is `Streaming` and has delivered nothing, which needs no name.

`Draining` is the grace after a cancel that the relay itself started. Only two
causes put the core there, a dead caller and a passed wall deadline. A cancel
the broker asked for does not, because the service has already forwarded it to
the helper before the relay hears of it (`CancelRequested`), and today's broker
cancel never moved the relay into a grace window either: the helper's own
cancel grace bounds the wait and reports `CancelEscalated` itself. The name
collides with the issue's `Draining`, which meant output draining. The built
`Draining` is the cancel grace, and it has no relationship to output. `Settled`
is the `Settling` value of `Core.settled`. The module says *settling* and not
*settled* because the core has only decided the verdict. The relay must still
ask the service for leave to report it, and that handshake is `broker/relay`'s.

```
  relay: execution.Mode

                          caller down, wall deadline
    Streaming ------------------------------------------> Draining
        |                                                     |
        | exit, failure, helper down                          | exit, failure, helper down,
        |                                                     | grace expired (CancelEscalated)
        v                                                     v
    Settling(terminal) <--------------------------------------+
    absorbing: Settle is emitted once; a broker cancel is only recorded

  service: executor.Status

                       relay asks, first ask
    Live -----------------------------------------------> Granted
      |                                                       |
      | relay lost, abandon or closing:                       | Release, or Abandon
      | the service settles ExecutionLost(..)                 |
      v                                                       v
    row removed                                          row removed
```

### Why the helper has no generation

S1 mints no `HelperGen`. The fence it would provide comes from two facts that
already hold. Each execution's relay owns the subject its helper events arrive
on, so an event from an earlier execution cannot reach a later one's relay. And
the service is the only process that sends a helper a `Run`, `Stdin` or
`CancelExec` in the service lane: the relay asks the service to cancel through
`Link` rather than casting to the helper itself. Erlang orders messages between
one sender and one receiver, so a cancel the service sent for an execution
reaches the helper before any `Run` the service sends for the next one, and a
helper that has already settled the first ignores it in `Idle`
(`broker/exec.gleam:1136`). The other half of the fence is the row. A message
addressed to an execution whose row is gone, or whose settlement has been
granted, is dropped, and `a_stale_cancel_does_not_reach_the_next_execution_test`
holds the closures of a finished execution and calls them after a second
execution has started on the same helper. A `HelperGen` is added only if S2's
real-helper race test finds a window this argument misses, or if S3's
introspection needs to name a helper incarnation that a pid cannot.

One limit is worth stating, because the module could otherwise be read as
proving more. No test fails if the relay is changed to cast to the helper
directly, since the absorbing core never cancels after it has settled, so the
ordering half of the argument is argued and not independently exercised. The
row half is exercised.

### The rows: `Live` and `Granted`

A row exists only while the service holds a helper for the execution. It is
`Live` until nobody has been given leave to report a verdict. The relay asks
(`MaySettle`) before it reports, and the first ask for a live row turns it
`Granted` and is answered `Granted`; every later ask is answered
`AlreadySettled` (`grant_settlement`, `broker/executor.gleam:716`). The service
settles a row itself only when it is `Live`, and only for a lost relay or a
closing service (`lose_row`, `broker/executor.gleam:768`). It never settles a
`Granted` row, because the relay may already have reported. Because the status
is read and written inside one mailbox, the two settlers cannot both win.

A `Granted` row whose relay dies is the case that needs care. When the
service's own monitor reports the death, the relay may or may not have
reported, so the service neither settles nor cancels: the execution had
ended. It waits for the broker, which sends `Release` if it saw the
settlement and `Abandon` if it did not. An `Abandon` is proof that the relay
made no settlement send at all, because the relay's first send on settling is
the broker's own `Settle`, and a process's messages reach the broker ahead of
its death notice. So on `Abandon` the service settles the caller as
`ExecutionLost(RelayDown)` and returns the helper, and the caller hears a
settlement in this lane in every case
(`an_abandoned_granted_row_settles_the_caller_as_lost_test`).
A `Live` row can be released too, and the case is real. A relay whose ask went
unanswered reports anyway as `ServiceSilent`, the broker releases, and the
service reads `Release` before the late ask. The execution has been reported,
so `release_row` treats it exactly as a granted one (`broker/executor.gleam:744`),
and the relay's late ask finds no row and is answered `AlreadySettled` to a
process that has already gone.

A row ends when the broker releases it, when the broker abandons it, or when the
service settles a lost relay or an execution that outlasted a close. Each of
those returns the helper to the pool, which retires it if it comes back busy.
A close then hands the pool to `close_pool`, which retires every helper the
pool owns and drops any `Granted` row that was still waiting for a release that
will not come.

### The duplicate-sequence refusal

`dispatch_execution` (`broker/executor.gleam:517`) refuses a `start` whose
sequence number is still in the table, answering `NotStarted` and borrowing no
helper. The check exists because `start` is a call with a 20 second budget, the
checkout wait plus the run call (`start_wait_ms`, `broker/executor.gleam:244`).
A service wedged for longer leaves the broker answering `NotStarted` for a call
that the service then goes on to start. The broker does not advance its call
counter on a refusal, so it will reuse that id, and an unchecked service would
overwrite a live row with it. The refusal keeps the service's own table
consistent. It cannot recall a settlement the service has already sent, so the
hazard remains: it needs a service blocked past a whole window and then
recovering, and the broker issues at most one `start` at a time, so the window
cannot be met by queueing. `a_taken_sequence_number_is_refused_without_a_helper_test`
pins the refusal.

### Custody, the census and the inventory

Native custody stays a projection and not a fourth field. It is per helper,
because one helper carries many executions over its life, and `exec_exit` of
any one of them says nothing about whether the helper has retired. S1 built the
counting half. `exec.pool_census` (`broker/exec.gleam:2675`) asks the pool
actor for a `PoolCensus` (`broker/exec.gleam:2444`): the configured `size`
beside five counts that partition the entries, `available`, `borrowed`,
`draining`, `retiring` and `unconfirmed`. The pool answers in every phase,
including while closing, and never postpones the question behind a retirement,
since an observer during shutdown is the observer most in need of an answer. A
pool that is gone or silent is `PoolUnavailable`. `executor.inventory` returns
an `Inventory` of the service's incarnation, its live rows in start order (each
a `LiveRow` with an id and a start time), and the census beside them. It is
answered inside one service handler, so the rows cannot change while the census
is read. `pool_census_counts_the_inventory_by_custody_test` and
`the_inventory_shows_a_live_row_until_the_release_test` cover the two.

The per-helper rendering below is the other half. It is not built, and it
belongs to S3's snapshot. The executor would read the pool's existing facts and
render them for introspection.

| Pool fact | Custody as rendered |
|---|---|
| `Prepared`, no acquisition | `NoNativeResource` |
| `Available` or `Borrowed` helper | `Held(generation)` |
| `Draining`, `RetiringActor`, or `Dead` with `PendingExit` | `Retiring(generation)` |
| `NativeExit(status)` | `Retired(native_exit)` |
| `Unconfirmed(RetirementOwnerGone)` or `Unconfirmed(RetirementExit)` | `CleanupUnconfirmed(reason)` |
| `Unconfirmed(RetirementProofLost)` | `ProofLost(reason)` |

Nothing in `exec.gleam` is renamed for this. A projection function in
`executor.gleam` would do the rendering, and the `generation` it mentions is
the open question above: it exists only if S2 or S3 finds that a pid cannot do
the job.

### Why the issue's eight phases are two modes

The issue sketches `Queued`, `Preparing`, `Starting`, `Running`, `Cancelling`,
`Completing`, `Draining` and `Settled`. Five of those are not observable, and a
state the registry can never see is a state it can never test.

`Queued` has no referent, since nothing queues (see "Admission and bounds").
`Preparing` is the spawn and handshake, which happen inside `checkout` in the
pool actor and are synchronous to the broker (`spawn_new`,
`broker/exec.gleam:3001`), so the registry never sees a helper that is "being
prepared" for an execution. `Starting` has no second event to end it:
`dispatch_exec` replies `Ok` before the frame is written
(`broker/exec.gleam:1474`), and the first output or exit is the only evidence
the jail ran. `Completing` and `Draining` collapse into settlement, which is
one event; the grace period after a cancel is `Draining`'s state timeout in the
built relay and not a state of its own beyond that.

What survives of the eight is what the relay's decisions depend on. `Running`
is `Streaming`, `Cancelling` is `Draining`, and `Settled` is the absorbing
`Settling`. The S0 sketch kept a fourth, `Dispatched`, as the honest edge
before first output. Building the core showed that edge decides nothing, which
is the argument above.

### The transition function

`step` (`broker/execution.gleam:269`) takes a core and an event and returns the
next core with a list of effects. It is total and pure. The eight events are
output, exit, failure, a broker cancel, the caller's death, the helper actor's
death, the wall deadline and the grace expiry. The four effects are delivering
a chunk, asking the service to cancel, entering `Draining`, and settling with a
terminal. `Settling` is absorbing: once a core has emitted `Settle`, every event
answers `#(core, [])`, which is how exactly-one settlement is a property of the
function and not a discipline of its callers. The module's doc carries the
transition table for the two modes, and lint rule R14 holds the table to the
type's constructors.

Three choices in the table are deliberate. A `CancelRequested` is recorded and
sends nothing, for the reason given above. A `HelperDown` settles
`Failed(ExecutionLost(HelperActorDown))` in either mode, because a dying helper
notifies from inside itself and a relay that waited would wait for a deadline
that may not exist. And the two timeouts are meaningful in one mode each: a
`DeadlineReached` in `Draining` and a `GraceExpired` in `Streaming` cannot fire,
because the shell arms each as the state timeout of its own mode, but the core
answers them with no effect so that a stale fire the timer book failed to drop
could not settle an execution early.

`execution_test` runs 600 seeded random event sequences through `step`.
`at_most_one_settle_per_sequence_test` checks that none produces two
settlements, `nothing_is_produced_after_settle_test` that none delivers after
settling, `terminal_events_always_settle_test` that every terminal event settles,
and `cancel_is_sent_at_most_once_test` that a cancel is not repeated.

One question the design settled by argument and left to a test is whether
`CancelExec` needs an execution id. It carries none (`broker/exec.gleam:443`),
and a cancel cast that arrives after the helper has processed `Exited` is seen in
`Idle` and ignored (`broker/exec.gleam:1136`). S1 delivered the row half of the
test, and S2 writes the race against a real helper. If it finds a window, then
`CancelExec` grows a fence, and not before.

## How the lifecycle invariants are held

The issue lists twelve. The table gives, for each, what holds it in the direct
lane, what holds it in the service lane as S1 built it, and the phase in which
the difference lands or the remainder is planned. "Defect" entries refer to the
section after the next.

| # | Invariant | Held in the direct lane by | Held in the service lane by | Phase |
|---|---|---|---|---|
| 1 | Ownership precedes acquisition | `prepare` parks an owner with `NoNativeResource`; the pool records the entry and its monitor before `begin` (`spawn_new`, `broker/exec.gleam:3001`). No analogue for an execution. | The relay, with its monitor on the helper actor, starts before `exec.run`, and the row is in the table before the service handles another message. The service is blocked for all of it, so no message sees the interval. | S1, built |
| 2 | One helper, one live execution | The machine answers `HelperBusy`. The system did not: `status_of` reported `Running` and `Cancelling` as ready, so a checked-in busy helper was re-lent. The busy-checkin fix gives them `StatusBusy` (`status_of`, `broker/exec.gleam:1306`). | The pool lends a helper only when its status is `StatusReady`, which the busy-checkin fix makes mean idle. | Fixed ahead of S1 |
| 3 | Exactly one settlement per execution | The machine settles once and `Dead` absorbs, but a dead helper actor or a dead relay settles nothing (defect). | `Settling` is absorbing in `step`; the relay reports only after `Granted`, which a live row yields once; `HelperDown` settles `ExecutionLost(HelperActorDown)`. `settled_is_absorbing_test`, `at_most_one_settle_per_sequence_test`, `only_the_first_ask_to_settle_is_granted_test`. | S1, built |
| 4 | No claim of exactly-once effects | `run` promises one terminal event, not one effect. `HelperUnresponsive` is documented as "nothing was dispatched" (`HelperUnresponsive`, `broker/exec.gleam:297`), which a timeout cannot guarantee (defect). | `ExecutionLost` is the only outcome for an execution that may have started and cannot be accounted for; nothing replays it, and `denial_for_failure` offers no approval for it. The `HelperUnresponsive` doc comment is corrected with the late-`Run` fence. | S1 built; comment S2 |
| 5 | Cancel is idempotent and generation-fenced | Idempotent (`Cancelling(..)` in `broker/exec.gleam:1134`). Fenced only by the broker's discipline of cancelling through the `Active` row. | The service is the helper's only sender, and a message for a row that is gone or `Granted` is dropped. No generation is minted. `a_stale_cancel_does_not_reach_the_next_execution_test`. | S1 built; race test S2 |
| 6 | BEAM death is not native cleanup | `record_owner_exit` refuses to free the slot (`record_owner_exit`, `broker/exec.gleam:2901`). Unchanged. | A lost relay is settled as `ExecutionLost(RelayDown)` and its helper is returned busy, so the pool retires it under the same evidence rules. The service never touches custody. A killed service leaves the pool `Unconfirmed`. | S1 (relay); S2 (service death, negative test) |
| 7 | Native retirement keeps its witness | Only a native exit status selected from a retained port counts (`native_exit`, `broker/exec.gleam:1357`). Unchanged, with one extension planned: under bwrap a deliberate `SIGKILL` of a port whose handle is kept yields status 137, which counts (defect). | Unchanged. | S2 |
| 8 | No capacity reuse before evidence | `lendable_again` (`broker/exec.gleam:2994`). Unchanged. | Unchanged. The rule stays; the witnessed kill changes only which failures can produce evidence. | S2 |
| 9 | Late events from an old helper are fenced | Per-helper subjects, frame ids, pid-keyed pool messages. A late `Run` is not fenced (defect). | Each relay owns its execution's subject, and the row fence drops anything addressed to a finished execution. A liveness check at dispatch drops a `Run` whose events owner is dead. | S1 (subject, row); late-`Run` S2 |
| 10 | Enforced, degraded, skipped and unsupported stay distinct | Typed refusals (`DegradedHelper`, `DegradedExecution`) and a report of strings. | The service forwards `ExecResult.enforcement` unchanged. `real_helper_outcomes_are_identical_in_both_lanes_test` compares it, and the exit and the output, across the two lanes. The tag vocabulary becomes a shared artifact in S5. | S1 built; S5 |
| 11 | Darwin limits stay | `tolerated_layers_for_demand` and `FullEnforcement` still refusing `skip:darwin-process-lifecycle`. | Untouched. The witnessed-kill rule applies under bwrap only. | n/a |
| 12 | Shutdown is a state transition | The helper (`handle_shutdown`, `broker/exec.gleam:1335`) and the pool both have one. The broker has none: stopping it does not cancel active calls. | The service's `Closing` phase (below), tested in `executor_test`. | S1, built |

Invariant 10 is the honest weak spot. The report is a list of strings with a
`skip:` prefix convention, assembled in Go and interpreted in Gleam by two
vocabularies that agree only because tests keep them so. The service does not
make that better or worse; S5 decides whether a generated shared file should.

## Admission and bounds

The service has no admission queue. The caller's retry loop is the queue, and
its remaining clearance budget is the queue's age limit. That placement is not
an omission; it follows from the broker's structure. The broker checks a helper
out inside its serial handler and checks one in only on settlement, so a
service that parked a request would be waiting on the mailbox it blocks. The
retry loop sits outside that mailbox and cannot reach this state. `docs/weft.md`
lists the loop among the shapes that stay hand-rolled, for three stated reasons
that a service-side queue would break. The issue's "queue depth" and "queue
age" become counters of congested refusals and retries, not a data structure.

Because nothing is admitted without a helper, the registry is bounded by the
pool size, which is clamped to sixteen (`max_pool_size`,
`broker/exec.gleam:2596`). The other numbers are fixed literals and not knobs:

| Bound | Value | Where it is enforced |
|---|---|---|
| Output retained by the service | 0 bytes; counters only | `execution.Output` holds counts. Output goes to the caller as it does today; the retention test is planned with the ring. |
| Diagnostic ring | the last 64 settled executions per service | Not built in S1. It belongs to S3's snapshot. |
| Registry size | at most the pool size (4 to 16) | By construction: a row exists only while the service holds a helper for it. |
| Relay grace after a cancel | 5000 ms | `relay_grace_ms`, `broker/dispatch.gleam:67`, shared by both lanes |
| Checkout wait | 15 000 ms | `exec.checkout(pool, waiting: 15_000)`, `client/serve.gleam:772` and `client/serve.gleam:796` |
| Run call | 5000 ms | `run_wait_ms`, `broker/direct.gleam:66` and `broker/executor.gleam:247` |
| Service `start` call | 20 000 ms | `start_wait_ms`, `broker/executor.gleam:244`: the checkout wait plus the run call |
| Relay's ask to settle | 5000 ms | `settle_wait_ms`, `broker/relay.gleam:190` |
| Output per stream | `policy.limits.output_bytes`; 0 means unlimited | The helper (`limiter.go`). |
| Frame payload | 16 MiB | Both framing codecs. |

The issue also asks for bounded behaviour under a slow output consumer. The
design delivers a narrower guarantee, and says so. Ports are active, so the
BEAM side has no flow control, and three unbounded mailboxes sit in series:
the helper actor, the relay and the caller. The only honest bound is the
helper-side per-stream cap, which discards after truncation so the child never
blocks. Jobs whose output is the wire, such as a language server's stdout
(protocol-change/058), are uncapped by design. The service therefore does not
buffer or push back. What S2 proves instead is that cancel stays responsive
under a flood: probe 5 below measures the latency from a cancel to settlement
while `yes` fills both streams.

No daemon-wide ceiling is added. The bound is the session slots times sixteen
helpers, and the memory baseline decides whether that is too loose.

## Shutdown as a transition

The service has three phases, `Serving`, `Closing(closer)` and `Closed(outcome)`
(`Phase`, `broker/executor.gleam:222`), and it is a `weft/state_machine` and not
a plain actor for the reasons the pool's own phases are one. Closing is a
transition with a deadline, and the machine owns both: `Closing` carries a
state timeout for the half-budget drain, which dies with the state and so needs
no stale-fire check; a second closer is postponed until the first has a verdict
and replayed when the machine reaches `Closed`; and `Closed` is a state that
answers the stored verdict, which a plain actor would have to fake with a flag.
Every phase and message pair is written out, with the messages that mean the
same in all phases binding the phase to a name, so a new message is still a
compile error (`handle`, `broker/executor.gleam:430`). ADR-017 sketched the
service as an actor holding a registry; closing is what made it a machine.

On a `Close` in `Serving` (`begin_close`, `broker/executor.gleam:814`) the
service sends a cancel to every live row and, if any is still live, enters
`Closing` with a state timeout of half the budget. From then on it refuses new
`start` calls with `NoHelper(PoolUnavailable)`, which is deliberately not
`AllBusy`, so callers stop polling (`broker/exec.gleam:2487`). Live rows settle
through their relays as the cancels land, and the service finishes as the last
one is granted. If the half-budget expires first, the rows still live are
settled `ExecutionLost(ExecutorClosing)`: the relay is killed first so it cannot
answer a late ask, and the helper is returned busy so the pool retires it
(`expire_live_rows`, `broker/executor.gleam:842`). Then it calls `close_helpers`,
which is `close_pool`, with what remains of the budget, and replies with the
pool's retirement verdict (`finish_closing`, `broker/executor.gleam:827`).

An `Ok` verdict ends the service. An `Error` does not: custody of helpers that
could not be shown retired must not be dropped quietly, so the service stays
alive in `Closed(outcome)` and answers any later `close` with the same verdict,
as the pool does. That is also why the `Closed` phase exists at all.

The broker is stopped before the service, as in the custody order, so no new row
can arrive during `Closing`, and a `Release` for a granted row will never come
once the broker has stopped, which is why granted rows do not delay a close. The
hook that stands at `Helpers` in the service lane is
`executor.close(service, waiting: 5000)`. Nothing new is added to custody: the
five second wait and the two-sided proof (native exit status zero, and a normal
actor exit) are the pool's, unchanged.

S1 tests the close. `close_with_a_live_execution_settles_it_and_answers_the_pool_test`
shows a live execution cancelled and settled through its relay with the pool's
verdict returned, `close_settles_an_execution_that_will_not_end_as_lost_test`
shows one that ignores cancel settled once as `ExecutionLost(ExecutorClosing)`,
and `start_during_closing_is_refused_as_pool_unavailable_test` shows the
refusal. S2 adds two more: a shutdown with output flowing, asserting that the
caller saw exactly one settlement and that the pool reported a native witness or
`Unconfirmed`, never `Ok` without one.

There is no restartable in-session service. The pool and broker are fatal
children captured by value, and the service joins them. S2's "service restart
is not cleanup" test is therefore negative: kill the service, assert that the
pool is `Unconfirmed`, that no slot is reused, and that custody reports
`Failed(Helpers)`.

## Defects found on the way

The survey found four latent defects on the BEAM side and one in Go. Each was
checked against the code before it was ruled real. They were not hypothetical;
only one had a test, and that test pinned the wrong behaviour. Two are now
fixed, and the status of each is stated with it.

**The relay never learns that its helper actor died.** Described above under
"The direct lane's relay". The service lane fixes it structurally, and S1 built
the fix. `relay.init` monitors the helper actor in the relay's own initialiser,
before the execution is dispatched, and a `HelperDown` event settles
`ExecutionLost(HelperActorDown)` in either mode. A monitor of an actor that is
already dead fires at once, so a helper that died between its checkout and its
dispatch settles as lost too, instead of leaving the relay to wait for a
terminal event nobody can send. A `Down` that arrives after a terminal event is
harmless: the relay has settled and stopped, and a core that has settled
answers every event with nothing.
`helper_actor_death_settles_as_lost_promptly_test` and
`helper_actor_death_settles_with_no_deadline_test` pin it, the second being the
session-lifetime case that used to hang for ever. The direct lane keeps the
defect until S3 deletes it, and `lane_equivalence_test` leaves the case out on
purpose: an equivalence assertion over it would say the old defect is a feature.
Phase: S1, built.

**A busy helper can be checked in as available.** When a relay dies unsettled,
the broker abandons the execution (`handle_guarantor_down`,
`broker/broker.gleam:961`), which in the direct lane casts a cancel and then
checks the helper in at once. `status_of` used to report a cancelling helper as
ready, so a helper checked in mid-execution (`handle_checkin`,
`broker/exec.gleam:2924`) went back into the lendable set, and the next
borrower's `run` got `HelperBusy`, which the broker turned into a failure of an
unrelated call. The fix landed ahead of S1 as `375d873`: `StatusBusy` joins
`HelperStatus`, the pool lends only on `StatusReady`, and a helper that is
checked in busy is retired, which costs one lazy respawn per relay crash. Both
lanes benefit. `status_of_a_running_helper_is_busy_test`,
`busy_checkin_retires_the_helper_without_a_further_checkout_test` and
`pool_of_one_refuses_then_respawns_after_a_busy_checkin_test` pin it. Phase:
independent change, before S1.

**A late `Run` can start an execution nobody is listening to.** `try_call`
leaves the request queued when it times out, so a wedged actor that recovers
processes a `Run` whose caller was already told `HelperUnresponsive`, which the
type documents as "nothing was dispatched" (`broker/exec.gleam:297`). The
broker's next step retires the helper, which queues a shutdown right behind the
run, so the orphan is cancelled within one mailbox step. The residual harm is
that a jailed command may start after the caller was told it had not. S2 drops
a `Run` in `handle_run` (`broker/exec.gleam:1437`) when the owner of its events
subject is no longer alive, replies `NotReady`, and corrects the two doc
comments. A clock-stamped expiry is the stronger fence and is taken only if the
race test shows the liveness check losing. Phase: S2.

**A killed helper's slot is never recovered.** This is the permanent slot loss
described under "Pool custody". `mark_dead` closes the port before any exit
status can be selected, so the entry is `ProofLost` for good. The likeliest
trigger is a handshake timeout under load, since `spawn_new` blocks the pool for
the handshake wait. The recovery that touches no wire is the witnessed kill:

1. `kill_transport` sends `SIGKILL` to the helper's OS pid and keeps the port
   open. Erlang delivers `{exit_status, 137}` to the owner of a port whose child
   died by signal, and the port is already opened with `exit_status`
   (`broker_ffi.erl:77`). This was measured in the development container before
   the design was accepted.
2. `Retirement` gains `PendingExit` for a kill as well as for a shutdown, and the
   failure paths that today end `LostExit` (`CancelDeadline`,
   `HandshakeDeadline`, `HeartbeatMissed`, `ChannelFault`, `ProtocolViolation`,
   `SendFailed` with the port still open) move to it.
3. A retirement that ends in a deliberate kill counts as proof only when the
   helper's hello advertised `bwrap`. Under bwrap, `--die-with-parent` and
   `--unshare-pid` (`sandbox/internal/jail/bwrap.go:185`) make the helper's
   death the jail's death, which is the property the tree already relies on
   when the BEAM dies. Without bwrap (degraded Linux, where a payload can
   `setsid` away, and Darwin, where the descendant tracker lives inside the
   killed helper) the slot stays `Unconfirmed`, exactly as today.

The cheapest disproof runs in the same container: a jailed command that ignores
`SIGTERM` with a marked argv, the helper stopped with `SIGSTOP`, a cancel, and
then a check that `WireClosed(137)` reached the machine, that no process with
that argv survives a second, and that the pool lends again. If the marker
survives, step 3 is wrong and the slot must stay unconfirmed. Phase: S2.

**The Go helper stalls on stdin.** Described above under "The native side". The
fix moves `exec_stdin` off the frame-loop goroutine, with a Go test that gives a
non-reading payload one mebibyte of stdin and then cancels, expecting an exit
within three seconds. It changes behaviour and not bytes, so it does not
contradict "reuse `loom-exec` unchanged", which means the wire is unchanged.
Phase: independent PR on `sandbox/stdin-off-frame-loop`, alongside S1.

## What is deliberately not built

The survey produced a cut list, and each item has a reason that a future reader
should be able to find before proposing the item again.

| Not built | Why |
|---|---|
| A service-side queue, queue age, or admission beyond pool size and `max_outstanding` | The wait cannot move into the broker's serial handler; see "Admission and bounds". |
| A daemon-wide service or helper ceiling | The proof of custody is per session; the existing bound is session slots times sixteen. |
| A workspace registry | Nothing in the tree associates helpers with workspaces. Per-execution policy roots carry it. #697 can add one if it needs one. |
| The states `Queued`, `Preparing`, `Starting`, `Completing`, an output-draining state, and an output state `Closing` | None is observable. Whether a helper has "freed" or "joined" an execution is internal to the helper and not on the wire. The built `Draining` is a different thing: the grace after a cancel. |
| A `HelperGen` | S1's fence is the single sender plus the row, and no window has been found. S2's real-helper race test decides whether one is added. |
| The diagnostic ring and the per-helper custody rendering | S3's snapshot is their only consumer. S1 built the census and the inventory, which are what the counters need. |
| Output buffering or BEAM-side backpressure in the service | Ports are active. The honest bound is helper-side, and S2 measures cancel latency under flood instead. |
| A restartable in-session service | The pool and broker are fatal children captured by value. The service joins them. |
| Re-enabling the idle heartbeat | It is off in production on purpose (`client/serve.gleam:723`). |
| Per-execution `limits`, use of the token by the helper, a shutdown acknowledgement, a `--version` flag, any new frame kind | Each is a wire change. The helper ignores `limits` and only checks the token for non-emptiness (`docs/spec-gaps.md`). |
| Any NIF, and any Erlang FFI beyond `broker/internal/ffi_port` | The witnessed kill needs none: `kill_os_process` and `port_event` already exist. |
| Folding #283 (idle retirement) into the epic | It is a pool change: one named timeout re-armed to the soonest expiry. The service must only not block it, so `Availability` stays the pool's. |
| A `packages/executor` before S4 | See "The modules". |
| A second fake helper; knobs for handshake, cancel and checkout timeouts | They stay literals. |
| A generation on the wire | Generations are BEAM-side only. |

## Where the issue's framing was corrected

The issue was written from the structure of the code and not its detail, which
is a reasonable way to write an epic and a poor way to plan the work. Seven
corrections follow. They are also posted as a comment on #696, because the
next reader will find the filing before this page.

1. There is no execution object, queue, generation or output backpressure to
   wrap. An execution is a payload inside a helper phase, admission is
   caller-side polling by a documented ruling, and the three custody dimensions
   already exist as `Availability` crossed with `Retirement`. S1 adds a registry
   above `exec`; it does not refactor it.
2. `Queued`, `Preparing`, `Starting`, `Completing` and `Draining` are not
   observable states. S1 built two relay modes, an absorbing settled flag, and
   two row statuses, and no execution phase of the four the S0 sketch kept.
3. The idle heartbeat is off in production, and "local deadlines" live in the
   broker relay and in the helper's `wall_s`, not in the helper machine.
4. The Go helper holds no orchestration worth moving. The duplication is codecs
   and a tag vocabulary. S5 shrinks to generating the contract.
5. S4 has no caller without #697. It shrinks to packaging and a pure version
   census, and defines no local control channel.
6. `exec_start.limits` is ignored by the helper and `token` is checked only for
   being non-empty. The service must not read meaning into either.
7. Measurement found four latent defects and one Go bug, and two of the fixes
   land as independent changes.

## The phases as re-scoped

The branches are stacked, each cut from the one before.

| Phase | Branch | What it delivers | Exit |
|---|---|---|---|
| S0 | `executor/s0-design` | This page, ADR-017, the baseline harness (`make bench-exec`), and the correction comment on #696. | Reviewed design, no change in behaviour. |
| Alongside | `broker/busy-checkin` and `sandbox/stdin-off-frame-loop`, each off `main` | The two defect fixes above, each with a test that fails without it. The busy-checkin fix is in the tree as `375d873`; the stdin fix is independent of the epic. | Merged independently of the epic. |
| S1 (built) | `executor/s1-service` | The `Dispatcher` seam with its `release` and `abandon` split, `broker/execution`, `broker/relay`, `broker/executor` and `broker/direct`, the relay's helper monitor, `ExecutionLost`, `pool_census` and the inventory, and the opt-in lane switch. No `HelperGen` is minted. | `both_lanes_show_the_caller_the_same_events_test` and `both_lanes_refuse_an_empty_pool_alike_test` in `lane_equivalence_test` run twelve scenarios and an empty pool through both lanes over fake helpers and compare the caller's events without normalising. `real_helper_outcomes_are_identical_in_both_lanes_test` in `real_lane_test` runs four payloads through both lanes over real helpers and asserts the same bytes, the same exit and a byte-identical enforcement report. |
| S2 | `executor/s2-hardening` | The witnessed kill, the late-`Run` fence, the real-helper cancel race test, shutdown-with-output and service-death tests, the leak census, and the cancel-under-flood probe. The default flips to `ServiceLane`. | The failure matrix passes and the census reports no unconfirmed helper under bwrap. |
| S3 | `executor/s3-ops` | `executor.snapshot` and telemetry lines carrying phase, generation, custody and last failure, with no tokens, environment or output; the diagnostic ring; the per-helper custody rendering. `broker/direct.gleam`, the lane setting and the variable are deleted. | A stuck executor is debuggable from the snapshot, and no second lane remains. |
| S4 | `executor/s4-standalone` | A thin `packages/executor` that boots the service without `client`, a smoke entrypoint, and a pure census of `{service version, exec protocol 3, policy 2, helper features}` with a skew check. No control socket and no protocol change. | The entrypoint boots from `broker` and `host` alone, runs one jailed command, and exits zero. |
| S5 | `executor/s5-go-decision` | The enforcement-tag vocabulary as one generated source rendering a Go constants file and a Gleam module, gated like `make prelude-check`. ADR-018 records the verdict. | Wire bytes unchanged and golden fixtures pass. The expected verdict is no-go on moving Go and go on generating the contract. |

S1's exit rule was that the broker's tests and the real-helper integration tests
pass under both lanes and the enforcement report for the same fixture is
byte-identical. The two equivalence tests carry it. They leave out, by design,
the two places the service lane is meant to differ: a helper actor that dies
mid-run, and a relay that dies. `executor_test` covers both.

S4's adapter for #697 needs no new code. `Dispatcher` is already a record of
functions, and #697 supplies one whose `start` crosses its transport.

## Protocol changes

None is needed in any phase. The witnessed kill is a signal sent from the BEAM
and a port event the machine already selects. `StatusBusy`, `BrokerConfig`,
`HelperStatus` and `Retirement` are the broker's own API and not a frozen
interface of the specification. The census reads existing constants. The tag
generator must reproduce today's strings byte for byte, and the golden
fixtures prove it. Anything that adds a frame kind, a key, or a flag the broker
passes on the wire path would bump `exec_protocol_version` and require its own
`protocol-change/` file, and nothing here does. One filing remains
conditional: an operator-facing `executor status` command on daemon control
would need one. The plan is to build a Gleam snapshot and telemetry first and
file only if they prove insufficient.

## Baselines

Each probe runs the real helper under bwrap, which this development container
provides: `loom-exec --self-test` reports ten layers enforced and one skipped
(the cgroup pids ceiling, because there is no delegated cgroup v2). The
harness is `make bench-exec`, gated by `LOOM_BENCH_EXEC=1`, and writes one
line of JSON per probe. A change in S1 through S3 that does not move the
number it was meant to move did not fix the cost it claimed to.

The first run is recorded below, taken on 2026-10-02 against `main` at
`7dacc61` in a four-scheduler Linux container, under `BestEffort` demand
(platform enforcement refuses every result here because the cgroup layer is
absent). A second run on the same tree reproduced every figure within the
noise of a shared machine: the warm round trip moved from 11.3 ms to 10.6 ms at
p50, so compare runs taken on a quiet box.

| # | Probe | What it measures | What it is the "before" for | p50 | p95 |
|---|---|---|---|---|---|
| 1 | Spawn to ready | `prepare_helper`, `begin` and `await_ready`, 30 runs; orderly close afterwards | The service's dispatch latency; idle retirement (#283) | 4.9 ms | 5.8 ms |
| 2 | Round trip | `clear_call` of `true` on a warm pool of four, 100 sequential runs | The extra service hop, which must not move it beyond noise | 11.3 ms | 13.2 ms |
| 3 | First wide batch | Pool of four, eight concurrent calls, three fresh pools; per-call latency, and time to the last settlement (cold 74–87 ms, warm 49–71 ms) | The serial spawn cost inside the pool actor, which had never been measured | 47.2 ms | 82.1 ms |
| 4 | Cancel to settle | `sleep` cancelled (10 runs, code 143), and a payload ignoring `SIGTERM` (5 runs, code 137) | The cancel ladder; the witnessed kill must not regress it | 5.0 ms and 2006 ms | 7.7 ms and 2007 ms |
| 5 | Flood | `yes` for three seconds with a one-mebibyte cap (1 MiB received, 33 chunks) and with none (837 MB, 25,706 chunks); BEAM memory stayed near 35 MiB with 0.37 MiB retained | The evidence that replaces "backpressure": cancel settles in 4.5 ms and 4.0 ms | 4.5 ms | n/a |
| 6 | Leak census | 100 executions: 80 successes, 17 cancels, 3 escalations of a `SIGSTOP`ped helper | Each escalation settled `CancelEscalated` after the pool's 3,000 ms grace; `close_pool` answered `RetirementProofLost`; ports returned to baseline, 7 BEAM processes remained (the pool holding unconfirmed custody), and **no** `loom-exec` or `bwrap` process survived. S2 drives the unconfirmed count to zero | n/a | n/a |
| 7 | Memory | Resident memory of an idle helper; of a running jail tree; BEAM memory of a warm pool of four | 6.4–6.5 MiB per idle helper, 11.8 MiB for helper, two bwrap processes and `sleep`; 415 KiB of BEAM memory for four helpers. At sixteen helpers a session costs about 100 MiB of helper memory, which keeps a daemon-wide ceiling on the cut list until a session count says otherwise | n/a | n/a |
| 8 | Enforcement fixture | `ExecResult.enforcement` for `true`, byte-exact | The S1 lane-equivalence comparison: `bwrap`, a `mounts:` plan, `rlimit-fsize`, `rlimit-cpu`, `landlock:abi=7`, `no-new-privs`, `seccomp-net`, and `skip:cgroup-v2` | n/a | n/a |
| 9 | Tag drift | A diff of the Go and Gleam tag vocabularies | S5's input | S5 | S5 |
| 10 | Stdin hazard | A non-reading payload, one mebibyte of stdin, then a cancel; time to `exec_exit` | Fixed on its own branch: no exit within three seconds before, 8–67 ms after | n/a | n/a |

The leak census is the measurement that most changes the plan. Every escalated
helper's jail died with it, as `--die-with-parent` and the PID namespace
promise, and the pool still had to treat each slot as unconfirmed because the
port was closed before an exit status could be read. The defect is the lost
proof, not a lost process, which is what the S2 witnessed kill recovers.

Two things are not measurable here and are not mocked: the cgroup pids and
memory ceiling, and anything on Darwin.

## Verification

The issue's fourteen scenarios map onto tests as follows. Names in code format
exist today. Names in plain text are the tests a later phase will add, and the
final names may differ. S1's tests are in `execution_test`, `executor_test`,
`dispatch_test`, `lane_equivalence_test` and `real_lane_test` under
`packages/broker/test/broker`. A scenario that a lane test covers is written
here with the scenario's name in quotation marks, because that is how the test
names it.

| Scenario | Covered by | Phase |
|---|---|---|
| Stdout, stderr and stdin execution | `echo_run_streams_output_and_exit_test`, `stdin_roundtrip_test`, `real_helper_echo_test` and `real_helper_stdin_roundtrip_test` at the exec level; through both lanes, `both_lanes_show_the_caller_the_same_events_test` ("an echo completes", "several chunks arrive in order", "stdin reaches the payload") and `real_helper_outcomes_are_identical_in_both_lanes_test` (output on both streams, a nonzero exit, stdin through `cat`). `stdin_sent_straight_after_clear_call_reaches_the_payload_test` holds the `Run`-before-`Stdin` ordering in the service lane. Descriptor hygiene is the helper's, tested in Go and by `make selftest`. | S1, built |
| Sequential jobs, no spurious busy window | The Go `TestExitFrameWriteDoesNotHoldTheHelperBusy`; `status_of_a_running_helper_is_busy_test`, `busy_checkin_retires_the_helper_without_a_further_checkout_test` and `pool_of_one_refuses_then_respawns_after_a_busy_checkin_test`; a dedicated sequential-runs test on a real helper through the service | Fix before S1; real-helper test S2 |
| Cancel before launch, during launch, running, and after completion | `cancel_is_idempotent_test`; in the pure core, `a_broker_cancel_is_recorded_and_sends_nothing_test`, `a_broker_cancelled_execution_still_settles_on_its_exit_test`, `caller_death_while_streaming_cancels_and_drains_test` and `cancel_is_sent_at_most_once_test`; through the service, `cancel_settles_the_execution_and_returns_the_helper_test` and `a_stale_cancel_does_not_reach_the_next_execution_test`; a cancel race against settlement and re-lend on a real helper | S1 (pure and fakes); S2 (real) |
| A process that ignores `SIGTERM` | `cancel_escalates_when_ignored_test`, `real_helper_orderly_running_retirement_test`; through the service, `the_drain_grace_escalates_when_the_helper_never_answers_test` and the lane scenario "a cancel the helper ignores escalates"; the witnessed-kill test with a marked argv; probe 4 | S1 (service); S2 (witnessed kill) |
| `setsid` and descendant escape | The self-test probe for an observed `setsid` escape, unchanged and run in each phase. The platform-specific claim does not change. | every phase |
| Malformed or oversized helper frame | `malformed_frame_closes_channel_in_band_test` and the lane scenario "a malformed frame closes the channel in band"; a service test that the slot is recovered under bwrap | S1; S2 |
| Helper actor crash | `helper_actor_death_settles_as_lost_promptly_test` and `helper_actor_death_settles_with_no_deadline_test`, which settle `ExecutionLost(HelperActorDown)` with and without a deadline; in the pure core, `helper_death_while_streaming_settles_lost_test` and `helper_death_after_a_terminal_event_changes_nothing_test`. `pool_helper_actor_death_is_unconfirmed_test` pins the custody half. | S1, built |
| Relay crash | `a_relay_crash_settles_lost_and_the_next_call_runs_test`, `an_abandoned_granted_row_settles_the_caller_as_lost_test`, and in `dispatch_test` `unsettled_guarantor_death_abandons_once_and_frees_the_slot_test` | S1, built |
| Executor-service crash | A new negative test: kill the service; assert `Unconfirmed`, no slot reuse, custody `Failed(Helpers)` | S2 |
| Shutdown during output | `close_with_a_live_execution_settles_it_and_answers_the_pool_test`, `close_settles_an_execution_that_will_not_end_as_lost_test` and `start_during_closing_is_refused_as_pool_unavailable_test` cover shutdown mid-run. A new test with output flowing: the caller sees one settlement and the pool reports a witness or `Unconfirmed` | S1 (close); S2 (with output) |
| Slow consumer | The helper-side `real_helper_output_truncation_test`; probe 5 for cancel latency under flood. The BEAM side is not bounded for jobs whose output is the wire; see "Admission and bounds". | S2 |
| Missing enforcement feature | `degraded_helper_refused_on_full_enforcement_test`, the `platform_enforcement_*` tests, the lane scenarios "a degraded helper is refused in band" and "a lying exit report is refused in band", and the byte-exact enforcement comparison in `real_helper_outcomes_are_identical_in_both_lanes_test` | S1, built |
| Unsupported platform | `host_platform_for_names_the_unjailed_ones_test`; the self-test's `UNSUPPORTED PLATFORM` result. No new behaviour. | unchanged |
| Late old-generation event | `settled_is_absorbing_test` and `helper_death_after_a_terminal_event_changes_nothing_test` against a settled core; `a_stale_cancel_does_not_reach_the_next_execution_test` against a gone row; a real race test; a late-`Run` test with a stalled actor | S1 (core, row); S2 (real, late `Run`) |
| Code-mode hostile BEAM | `the_real_token_does_not_widen_policy_test`, `cap_calls_without_the_token_are_all_denied_test`, `satellite_that_never_returns_is_killed_at_the_deadline_test`, and `make e2e-codemode`, all under the service lane by exporting `LOOM_EXECUTOR_LANE=service`; the default flip in S2 waits on them | S2 |

Beyond the matrix, several checks follow from the design and not from the issue.
`at_most_one_settle_per_sequence_test` shows that no event sequence produces
two settlements for one execution. In `dispatch_test`,
`settling_releases_once_and_never_abandons_test` and
`unsettled_guarantor_death_abandons_once_and_frees_the_slot_test` show that the
broker calls `release` or `abandon` and never both. `only_the_first_ask_to_settle_is_granted_test`
shows that a second relay ask is refused, and
`a_taken_sequence_number_is_refused_without_a_helper_test` that a duplicate
`start` takes no helper. `pool_census_counts_the_inventory_by_custody_test` and
`the_inventory_shows_a_live_row_until_the_release_test` hold the census and the
inventory. A test that pins the zero-byte retention and the 64-entry ring waits
for the ring, which is S3's. And the lane-equivalence tests are the cheapest
disproof of the seam: if any broker case needed a lane-specific expectation, the
execution-level seam would be leaking semantics and ADR-017 would be wrong. None
did in S1.

## Where the code lives

The subject now lives in the five ADR-017 modules and one wiring site. The
helper machine and pool stay in `broker/exec.gleam`, with `pool_census` added to
the pool. The seam vocabulary is `broker/dispatch.gleam`, the pure core is
`broker/execution.gleam`, the per-execution shell is `broker/relay.gleam`, the
service lane's dispatcher is `broker/executor.gleam`, and the direct lane's is
`broker/direct.gleam`. `broker/broker.gleam` holds the broker's own decisions
and calls whichever dispatcher it was started with. `client/serve.gleam` does the
per-session wiring and holds the lane switch. The package documentation for
`broker` (`packages/broker/CLAUDE.md`) carries the types, messages and
invariants of the new modules, and the effect-plane overview
(`docs/architecture/effects.md`) describes the helper pool and the relay and is
updated with the phase that changes them.
