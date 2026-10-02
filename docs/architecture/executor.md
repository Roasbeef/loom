# The executor service

Loom runs untrusted work in a native jail and keeps the books on that work in
Gleam. The two halves already exist: `broker/exec` supervises `loom-exec`
helpers, and the helper builds the jail. What does not exist is a single
object that says "this execution, on this helper, is in this state, and its
native resources are in that one". Issue #696 asks for one. This document is
the design for it, written before any code and accepted in
[ADR-017](../adr/017-executor-service-seam.md). It records where the tree is
today, the shape the service takes, how each lifecycle invariant is held, and
which parts of the issue the survey showed to be wrong.

The service is not built yet. Until S1 lands, everything under "The target
shape" is a plan, and everything under "The tree today" is a description of
`main` at `7dacc61`. The doc-check gate verifies every `path:line` citation
below, so a phase that moves code will fail the build until this page is
brought along. That is deliberate.

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
facts that shape the design are these.

### The helper machine

`broker/exec` holds two weft state machines. The per-helper machine wraps one
`loom-exec` process behind a `Transport` seam. Its phases are `Prepared`,
`AwaitingHello`, `Idle`, `Running`, `Cancelling` and `Dead`
(`broker/exec.gleam:489`). An execution is the `RunningExec` payload carried by
`Running` and `Cancelling` (`broker/exec.gleam:516`). It has a frame id from a
counter that belongs to the helper process, and that id never leaves the
module: callers correlate events by the `Subject` they passed to `run`. No
registry, queue or identity exists above it.

The helper machine owns three timers: the handshake deadline, the cancel
grace, and an idle heartbeat. The heartbeat is off in production, because
`start_effect_plane_in` sets `heartbeat_interval_ms: 0`
(`client/serve.gleam:672`). The execution's wall deadline is not in the helper
machine at all. It lives in the broker's relay and, independently, in the
helper's own `wall_s` policy limit.

### Pool custody

Custody of a helper is two independent facts. `Availability`
(`broker/exec.gleam:2443`) says what the pool may do with the entry:
`Available`, `Borrowed`, `Draining`, `RetiringActor` or `Unconfirmed`.
`Retirement` (`broker/exec.gleam:456`) says what the helper machine knows about
its own native process, and it has four values. `NoNativeResource` means
nothing was acquired. `PendingExit` means a shutdown frame was sent and the
port is retained so the exit status can still be selected. `NativeExit(status)`
means that status arrived, and it is the only evidence
[protocol-change/014](../../protocol-change/014-helper-shutdown-witness.md)
accepts. `LostExit` means the port is gone and the proof is lost for good.

The pool never reuses a slot without evidence. Capacity is counted over every
entry, including draining and unconfirmed ones (`lendable_again`,
`broker/exec.gleam:2861`), and an entry leaves the inventory only when its
actor exits normally after a recorded retirement (`record_owner_exit`,
`broker/exec.gleam:2769`). The cost is that most failures end in `LostExit`:
`mark_dead` closes the port (`broker/exec.gleam:2108`), and `kill_transport`
closes it before it sends `SIGKILL` (`broker/exec.gleam:2072`), so no exit
status can follow. A helper that missed its cancel deadline, timed out its
handshake or violated the protocol therefore costs one slot permanently. The
pool has no waiter queue. A full pool answers `AllBusy(size)` at once
(`next_helper`, `broker/exec.gleam:2823`), and waiting is the caller's polling loop
(`clear_awaiting_helper`, `broker/broker.gleam:469`), which `docs/weft.md`
rules deliberately hand-rolled. Idle retirement (#283) is not implemented.

### The broker relay

For every cleared call, `dispatch` (`broker/broker.gleam:1130`) spawns an
unlinked relay process, monitors it, and has the relay call `exec.run`
(`broker/broker.gleam:1218`). The relay owns the event subject, forwards output
to the caller, enforces the wall deadline, and, on a terminal event, tells the
broker to settle. The broker's `Active` row (`broker/broker.gleam:272`) holds
the helper, the relay pid and the monitor. Settlement runs `reclaim`
(`broker/broker.gleam:928`), which checks the helper in and releases the budget
slot and the token.

The relay selects two things: events from the helper machine, and the death of
the caller (`relay_wake`, `broker/broker.gleam:1255`). It does not watch the
helper actor itself. When that actor dies mid-execution, nothing sends a
terminal event, because the death notice runs inside the dying actor
(`notify_death`, `broker/exec.gleam:2143`). A relay with a wall deadline
eventually settles through its grace window. A relay with `deadline_ms == 0`,
the session-lifetime jobs of protocol-change/058, waits in
`selector_receive_forever` (`broker/broker.gleam:1267`) and never settles. The
jail itself is not leaked, since the port closes with the dead owner, the
helper reads end of file, and it cancels and joins its jail. The hang is on the
BEAM side.

### The per-session effect plane

`start_effect_plane_in` (`client/serve.gleam:652`) builds one pool and one
broker for each session, and the pair is captured by value in closures. The
two are fatal children of the instance (`instance_children`,
`client/serve.gleam:2003`), since a replacement would be unreachable. The
custody order of a session's teardown is Runtime, Services, Broker, Helpers,
Mcp, Storage, Namespace (`clean`, `client/internal/instance_owner.gleam:366`),
so the session's writer lease is released only after the `Helpers` step has
shown a native exit for every helper the session owned. `Helpers` is
`close_pool` with a five second wait (`client/serve.gleam:685`).

Only `serve.gleam` calls the pool API. Only `broker.gleam` calls `run`,
`stdin` and `cancel`. Seven clearance sites share the one broker per session:
the ordinary tool runner, the jobs runner, goal checks, language-server jails,
the hook runner, the worktree observer and the git-identity step. Code mode
reaches the broker through the opaque `Broker` handle at fifteen call sites in
the `codemode` package, so any design that changes the handle's type touches
all of them. One non-broker borrower exists: the boot-time `degraded` probe
checks a helper out directly (`client/serve.gleam:6474`).

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

### The seam

The service sits at the execution level. The broker keeps what it owns today,
which is policy composition, tokens, budgets, abort epochs and the `Active`
rows. Where it now checks a helper out, runs the execution, relays events and
checks the helper in, it calls a record of functions instead, defined in
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
    abandon: fn() -> Nil,
  )
}
```

`start` answers synchronously. A `NoHelper(CheckoutError)` refusal feeds the
broker's existing congestion handling unchanged, so `AllBusy(size)` still
means what it means today. It must answer at once, because the broker calls it
from its serial message handler, and a service that parked the request would
wait for a helper that only the broker's own mailbox can release
(`docs/architecture/effects.md`, "Tokens, budgets, and the helper pool"). The
wait therefore stays in the caller.

The broker builds `deliver` and `settle` per call. `deliver` sends the caller
its `CallOutput`; `settle` sends the broker its own `Settle` and then the
caller its `CallSettled`, the same two messages in the same order as today.
A dispatcher calls `settle` exactly once per started execution. The returned
`Execution` is all the broker keeps: its closures are the only way back to the
helper, so the broker never holds a `Helper` and never imports an
implementation. The broker monitors `guarantor`, the process whose death means
`settle` will never be called, and on that death calls `abandon` and reclaims
the budget slot and token. In the direct lane the guarantor is the relay, as
today. In the service lane it is the service itself, which owns every relay it
starts and settles a relay's death as a lost outcome on its own.

Carrying closures rather than ids keeps the direct lane free of a registry: its
closures capture the helper, exactly as the broker's `Active` row did. The
service lane's closures name the execution by `ExecutionId` and send to the
service, which looks the row up and drops anything addressed to a settled one.

Three alternatives sit at other heights and were rejected. A seam behind
`checkout` and `checkin` (`BrokerConfig`, `broker/broker.gleam:226`) is free to
build but sees only lend and return, never output, exit, cancel or deadline, so
the execution registry would have to be fed from the broker anyway. A seam at
the tool runner sits above policy and tokens and would change every one of the
seven clearance sites and fifteen code-mode sites. The design instead keeps
the `Broker` handle as the one door and replaces what sits beneath it, so no
call site outside `broker.gleam` and `serve.gleam` changes in S1. ADR-017
records the comparison.

### The modules

| Module | Role | Lives |
|---|---|---|
| `broker/dispatch` | The `Dispatcher` type and its request and settlement types. The broker imports this and nothing else from the service. | `packages/broker` |
| `broker/execution` | The pure core: `ExecutionId`, `HelperGen`, `Phase`, `Outcome`, `Output`, and `step(phase, event) -> #(Phase, List(Effect))`. It imports no process library and is property-tested without a process. | `packages/broker` |
| `broker/executor` | A `weft/actor` holding the registry of live executions, the pool handle, the diagnostic ring and the incarnation. Also the projection of pool custody. | `packages/broker` |
| `broker/relay` | One `weft/state_machine` per execution, running `step`: the event loop that today is `relay` in `broker.gleam`. It selects the helper's events, the caller's death and the helper actor's death. | `packages/broker` |
| `broker/direct` | Today's `dispatch`, relay and `checkin`, moved unedited behind the same record. Temporary. | `packages/broker` |

All five stay in `packages/broker` until S4. A separate `packages/executor`
could not be called by `broker.gleam` without a dependency cycle, so the seam
type would live in `broker` regardless, and the package would hold only an
implementation. It would also cost a manifest, a path dependency on weft, a
documentation pair, CI wiring and a lint policy, none of which S1 through S3
earn. `broker.gleam` must not import `executor.gleam`. The pure core sits in
`broker` and not in `core` or `machine` because lint rule R6 binds those
packages and not this one, and because the core reuses `ExecResult` and
`ExecFailure`, which `core` would otherwise have to duplicate.

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
`DirectLane` or `ServiceLane`, read from `LOOM_EXECUTOR_LANE` by the same
mechanism as `LOOM_HELPER_POOL` (`client/serve.gleam:1275`) and chosen in
`start_effect_plane_in`. S1 ships the service lane opt-in, with `DirectLane` as
the default, because the issue's rollout rule is that a new path starts
opt-in. S2 flips the default to `ServiceLane` once the failure matrix passes.
S3 deletes `broker/direct.gleam`, the setting and the variable.

Each lane constructs its own pool, so a switch never shares a helper, and the
lane is read when a session opens, so a running session never changes lanes.
Rollback before S3 is the variable at session open. That satisfies the issue's
requirement that both paths never believe they own the same resource, by
construction rather than by drain. The cost is one temporary duplicate relay of
about 110 lines for the length of two phases.

## The state model

The issue asks for three independent dimensions: the logical outcome of an
execution, the state of its output, and the native custody of its resources.
The tree already has the third. The first two are new and live in
`broker/execution`.

```gleam
pub opaque type ExecutionId { ExecutionId(incarnation: Int, seq: Int) }
pub type HelperGen { HelperGen(Int) }

pub type Phase {
  Dispatched(helper: HelperGen)
  Running(helper: HelperGen, output: Output)
  Cancelling(helper: HelperGen, output: Output, since_ms: Int)
  Settled(outcome: Outcome, output: Output)
}

pub type Outcome { Exited(exec.ExecResult) | Failed(exec.ExecFailure) | Lost(LossReason) }
pub type LossReason { HelperActorGone | RelayGone | ServiceClosing }
pub type Output { Open(Counters) | Drained(Counters, Truncation) | OutputLost }
```

An `ExecutionId` pairs an incarnation, stamped from the session clock when the
service starts, with a sequence number. Ids are never reused across a restart,
because a service restart is a session restart.

S1 mints no helper generation. The fence it needs comes from two facts that
already hold. Each execution's relay owns the subject its helper events arrive
on, so an event from an earlier execution cannot reach a later one's relay.
And the service is the only process that sends a helper `Run`, `CancelExec` or
`Stdin` in the service lane: the relay asks the service to cancel rather than
casting to the helper itself. Erlang orders messages between one sender and one
receiver, so a cancel the service sent for an execution reaches the helper
before any `Run` the service sends for the next one, and a helper that has
already settled the first ignores it in `Idle` (`broker/exec.gleam:1104`). A
row in `Settled` drops everything addressed to it. A `HelperGen` is added only
if S2's race test finds a window this argument misses, or if S3's introspection
needs to name a helper incarnation that a pid cannot.

```
                       exec_run ok          first output or exit
        (row inserted) ----------> Dispatched ----------------> Running
                                       |                           |
                  cancel, caller gone, |                           | wall deadline,
                  wall deadline        v                           v
                                   Cancelling <-------------------+
                                       |
     terminal frame, helper down,      |
     grace expired, service closing    v
        any live phase ------------> Settled(outcome, output)

   one Settled per ExecutionId; Settled accepts no effect-producing event
```

Native custody is a projection and not a fourth field. It is per helper,
because one helper carries many executions over its life, and `exec_exit` of
any one of them says nothing about whether the helper has retired. The
executor reads the pool's existing facts and renders them for introspection:

| Pool fact | Custody as rendered |
|---|---|
| `Prepared`, no acquisition | `NoNativeResource` |
| `Available` or `Borrowed` helper | `Held(generation)` |
| `Draining`, `RetiringActor`, or `Dead` with `PendingExit` | `Retiring(generation)` |
| `NativeExit(status)` | `Retired(native_exit)` |
| `Unconfirmed(RetirementOwnerGone)` or `Unconfirmed(RetirementExit)` | `CleanupUnconfirmed(reason)` |
| `Unconfirmed(RetirementProofLost)` | `ProofLost(reason)` |

Nothing in `exec.gleam` is renamed for this. A projection function in
`executor.gleam` does the rendering.

### Why four phases and not eight

The issue sketches `Queued`, `Preparing`, `Starting`, `Running`, `Cancelling`,
`Completing`, `Draining` and `Settled`. Five of those are not observable, and a
state the registry can never see is a state it can never test.

`Queued` has no referent, since nothing queues (see "Admission and bounds").
`Preparing` is the spawn and handshake, which happen inside `checkout` in the
pool actor and are synchronous to the broker (`spawn_new`,
`broker/exec.gleam:2868`), so the registry never sees a helper that is "being
prepared" for an execution. `Starting` has no second event to end it:
`dispatch_exec` replies `Ok` before the frame is written
(`broker/exec.gleam:1467`), and the first output or exit is the only evidence
the jail ran, so `Dispatched` to `Running` is the honest edge. `Completing` and
`Draining` collapse into settlement, which is one event; the grace period
after a cancel is `Cancelling`'s state timeout and not a state of its own.

### The transition function

`step` takes a phase and an event and returns the next phase with a list of
effects. The events are output, exit, failure, a cancel request, the wall
deadline, grace expiry, the helper actor's death and the caller's death. The
effects are sending a cancel to a helper generation, forwarding an event to the
caller, settling with an outcome, returning the helper, and arming the grace
timer. `Settled` is absorbing: it produces no effect for any event, which is
how exactly-one settlement is a property of the function and not a discipline
of its callers. A property test over random event sequences pins it.

One question the design settles by argument and leaves to a test is whether
`CancelExec` needs an execution id. It carries none today
(`broker/exec.gleam:403`), and a cancel cast that arrives after the helper has
processed `Exited` is seen in `Idle` and ignored (`broker/exec.gleam:1104`).
The mailbox is ordered, so a cancel sent while the row is live cannot overtake
the terminal event of a later execution. S2 writes the race test. If it finds a
window, then `CancelExec` grows a fence, and not before.

## How the lifecycle invariants are held

The issue lists twelve. The table gives, for each, what holds it in the tree
today, what holds it after the service, and the phase in which the difference
lands. "Defect" entries refer to the next section.

| # | Invariant | Held today by | Held in the service by | Phase |
|---|---|---|---|---|
| 1 | Ownership precedes acquisition | `prepare` parks an owner with `NoNativeResource`; the pool records the entry and its monitor before `begin` (`spawn_new`, `broker/exec.gleam:2880`). No analogue for an execution. | The registry row is inserted before `exec.run`, and the relay monitors the helper before it dispatches. | S1 |
| 2 | One helper, one live execution | The machine answers `HelperBusy`. The system did not: `status_of` reported `Running` and `Cancelling` as ready, so a checked-in busy helper was re-lent. The busy-checkin fix gives them `StatusBusy` (`status_of`, `broker/exec.gleam:1274`). | The pool lends a helper only when its status is `StatusReady`, which the busy-checkin fix makes mean idle. | Fix before S1 |
| 3 | Exactly one settlement per execution | The machine settles once and `Dead` absorbs, but a dead helper actor or a dead relay settles nothing (defect). | `Settled` is absorbing in `step`; one `Settled` message per id reaches the broker; `HelperDown` settles `Lost(HelperActorGone)`. | S1 |
| 4 | No claim of exactly-once effects | `run` promises one terminal event, not one effect. `HelperUnresponsive` is documented as "nothing was dispatched" (`broker/exec.gleam:292`), which a timeout cannot guarantee (defect). | `Lost(..)` is the only outcome for an execution that may have started and cannot be accounted for; nothing replays. The document claim is corrected. | S1, S2 |
| 5 | Cancel is idempotent and generation-fenced | Idempotent (`broker/exec.gleam:1086`). Fenced only by the broker's discipline of cancelling through the `Active` row. | The registry maps `ExecutionId` to `(helper, generation)` and drops anything addressed to a `Settled` row. | S1; race test S2 |
| 6 | BEAM death is not native cleanup | `record_owner_exit` refuses to free the slot (`broker/exec.gleam:2780`). Unchanged. | The service settles the caller as `Lost` but never touches custody. A killed service leaves the pool `Unconfirmed`. | S2 (negative test) |
| 7 | Native retirement keeps its witness | Only a native exit status selected from a retained port counts (`native_exit`, `broker/exec.gleam:1325`). | Unchanged, with one extension: under bwrap a deliberate `SIGKILL` of a port whose handle is kept yields status 137, which counts (defect). | S2 |
| 8 | No capacity reuse before evidence | `lendable_again` (`broker/exec.gleam:2861`). Unchanged. | Unchanged. The rule stays; the witnessed kill changes only which failures can produce evidence. | S2 |
| 9 | Late events from an old helper are fenced | Per-helper subjects, frame ids, pid-keyed pool messages. A late `Run` is not fenced (defect). | The registry fence plus the generation; a liveness check at dispatch drops a `Run` whose events owner is dead. | S1; late-`Run` S2 |
| 10 | Enforced, degraded, skipped and unsupported stay distinct | Typed refusals (`DegradedHelper`, `DegradedExecution`) and a report of strings. | The service forwards `ExecResult.enforcement` unchanged and the lane-equivalence test compares it byte for byte. The tag vocabulary becomes a shared artifact in S5. | S1; S5 |
| 11 | Darwin limits stay | `tolerated_layers_for_demand` and `FullEnforcement` still refusing `skip:darwin-process-lifecycle`. | Untouched. The witnessed-kill rule applies under bwrap only. | n/a |
| 12 | Shutdown is a state transition | The helper (`handle_shutdown`, `broker/exec.gleam:1303`) and the pool both have one. The broker has none: stopping it does not cancel active calls. | The service's `Closing` phase (below). | S2 |

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
`broker/exec.gleam:2524`). The other numbers are fixed literals and not knobs:

| Bound | Value | Where it is enforced |
|---|---|---|
| Output retained by the service | 0 bytes; counters only | Output goes to the caller as it does today; a test pins the zero. |
| Diagnostic ring | the last 64 settled executions per service | Pinned by test. |
| Registry size | at most the pool size (4 to 16) | By construction. |
| Relay grace after a cancel | 5000 ms | `relay_grace_ms`, `broker/broker.gleam:373` |
| Checkout wait | 15 000 ms | `exec.checkout(pool, waiting: 15_000)`, `client/serve.gleam:695` |
| Run call | 5000 ms | `exec.run`, `broker/broker.gleam:1218` |
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

The service has three phases: `Serving`, `Closing(deadline)` and
`Closed(outcome)`. On entering `Closing` it refuses new `start` calls with
`PoolUnavailable`, which is deliberately not congestion, so callers stop
polling (`broker/exec.gleam:2409`). It sends a cancel to every live row, and
settles each row as `Lost(ServiceClosing)` when its grace expires. Then it
calls `close_pool`, and `Closed` carries the pool's retirement verdict, which
the custody hook returns.

The broker is stopped before the service, as in today's custody order, so no
new row can arrive during `Closing`. The hook that stands at `Helpers` becomes
`executor.close(service, waiting: 5000)`, which drains executions and then
closes the pool. Nothing new is added to custody: the five second wait and the
two-sided proof (native exit status zero, and a normal actor exit) are the
pool's, unchanged. S2 tests shutdown mid-execution and asserts two things: the
caller saw exactly one settlement, and the pool reported a native witness or
`Unconfirmed`, never `Ok` without one.

There is no restartable in-session service. The pool and broker are fatal
children captured by value, and the service joins them. S2's "service restart
is not cleanup" test is therefore negative: kill the service, assert that the
pool is `Unconfirmed`, that no slot is reused, and that custody reports
`Failed(Helpers)`.

## Defects found on the way

The survey found four latent defects on the BEAM side and one in Go. Each was
checked against the code before it was ruled real. They are not hypothetical;
only one has a test today, and that test pins the wrong behaviour.

**The relay never learns that its helper actor died.** Described above under
"The broker relay". The fix is structural, so it lands with the relay port:
the new `broker/relay` selects the helper's monitor, and a `HelperDown` event
settles `Lost(HelperActorGone)`. A `Down` that arrives after a terminal event
is harmless because the relay has already exited. The direct lane keeps the
defect until S3 deletes it. Phase: S1.

**A busy helper can be checked in as available.** When a relay dies unsettled,
the broker casts a cancel and then checks the helper in at once
(`handle_relay_down`, `broker/broker.gleam:903`). `status_of` reports a
cancelling helper as ready, and any ready helper that comes back through
`handle_checkin` (`broker/exec.gleam:2803`) is marked `Available`. The next borrower's `run` gets
`HelperBusy`, which the broker turns into a failure of an unrelated call. The
fix is a small independent change off `main` on `broker/busy-checkin`: add
`StatusBusy` to `HelperStatus`, lend only on `StatusReady`, and retire a helper
that is checked in busy, which costs one lazy respawn per relay crash. Both
lanes benefit. Phase: independent PR, before S1.

**A late `Run` can start an execution nobody is listening to.** `try_call`
leaves the request queued when it times out, so a wedged actor that recovers
processes a `Run` whose caller was already told `HelperUnresponsive`, which the
type documents as "nothing was dispatched" (`broker/exec.gleam:292`). The
broker's next step retires the helper, which queues a shutdown right behind the
run, so the orphan is cancelled within one mailbox step. The residual harm is
that a jailed command may start after the caller was told it had not. S2 drops
a `Run` in `handle_run` (`broker/exec.gleam:1405`) when the owner of its events
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
| The states `Queued`, `Preparing`, `Starting`, `Completing`, `Draining`, and an output state `Closing` | None is observable. Whether a helper has "freed" or "joined" an execution is internal to the helper and not on the wire. |
| Output buffering or BEAM-side backpressure in the service | Ports are active. The honest bound is helper-side, and S2 measures cancel latency under flood instead. |
| A restartable in-session service | The pool and broker are fatal children captured by value. The service joins them. |
| Re-enabling the idle heartbeat | It is off in production on purpose (`client/serve.gleam:672`). |
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
   observable states. The model has four phases.
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
| Alongside | `broker/busy-checkin` and `sandbox/stdin-off-frame-loop`, each off `main` | The two defect fixes above, each with a test that fails without it. | Merged independently of the epic. |
| S1 | `executor/s1-service` | The `Dispatcher` seam, `execution`, `executor`, `relay` and `direct`, `HelperGen`, the relay's helper monitor, and the opt-in lane. | The broker's tests and the real-helper integration tests pass under both lanes, and the enforcement report for the same fixture is byte-identical. |
| S2 | `executor/s2-hardening` | The witnessed kill, the late-`Run` fence, the cancel race test, shutdown and service-death tests, the leak census, and the cancel-under-flood probe. The default flips to `ServiceLane`. | The failure matrix passes and the census reports no unconfirmed helper under bwrap. |
| S3 | `executor/s3-ops` | `executor.snapshot` and telemetry lines carrying phase, generation, custody and last failure, with no tokens, environment or output. `broker/direct.gleam`, the lane setting and the variable are deleted. | A stuck executor is debuggable from the snapshot, and no second lane remains. |
| S4 | `executor/s4-standalone` | A thin `packages/executor` that boots the service without `client`, a smoke entrypoint, and a pure census of `{service version, exec protocol 3, policy 2, helper features}` with a skew check. No control socket and no protocol change. | The entrypoint boots from `broker` and `host` alone, runs one jailed command, and exits zero. |
| S5 | `executor/s5-go-decision` | The enforcement-tag vocabulary as one generated source rendering a Go constants file and a Gleam module, gated like `make prelude-check`. ADR-018 records the verdict. | Wire bytes unchanged and golden fixtures pass. The expected verdict is no-go on moving Go and go on generating the contract. |

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
exist today. Names in plain text are the tests the phase will add, and the
final names may differ.

| Scenario | Covered by | Phase |
|---|---|---|
| Stdout, stderr and stdin execution | `echo_run_streams_output_and_exit_test`, `stdin_roundtrip_test`, `real_helper_echo_test` and `real_helper_stdin_roundtrip_test`, each run under both lanes. Descriptor hygiene is the helper's, tested in Go and by `make selftest`. | S1 |
| Sequential jobs, no spurious busy window | The Go `TestExitFrameWriteDoesNotHoldTheHelperBusy`; a new busy-checkin test (a helper checked in while running is not lent); a sequential-runs test on a real helper through the service | Fix before S1; S1 |
| Cancel before launch, during launch, running, and after completion | `cancel_is_idempotent_test`; a property over `step` for every phase and event; a cancel race against settlement and re-lend on a real helper | S1 (pure); S2 (real) |
| A process that ignores `SIGTERM` | `cancel_escalates_when_ignored_test`, `real_helper_orderly_running_retirement_test`; the witnessed-kill test with a marked argv; probe 4 | S2 |
| `setsid` and descendant escape | The self-test probe for an observed `setsid` escape, unchanged and run in each phase. The platform-specific claim does not change. | every phase |
| Malformed or oversized helper frame | `malformed_frame_closes_channel_in_band_test`; a service test that the execution settles once and that the slot is recovered under bwrap | S1; S2 |
| Helper actor crash | A new relay test: the helper actor is killed mid-run and the call settles `Lost(HelperActorGone)`, including with no deadline. `pool_helper_actor_death_is_unconfirmed_test` pins the custody half. | S1 |
| Executor-service crash | A new negative test: kill the service; assert `Unconfirmed`, no slot reuse, custody `Failed(Helpers)` | S2 |
| Shutdown during output | A new test: shut down mid-run with output flowing; the caller sees one settlement and the pool reports a witness or `Unconfirmed` | S2 |
| Slow consumer | The helper-side `real_helper_output_truncation_test`; probe 5 for cancel latency under flood. The BEAM side is not bounded for jobs whose output is the wire; see "Admission and bounds". | S2 |
| Missing enforcement feature | `degraded_helper_refused_on_full_enforcement_test`, the `platform_enforcement_*` tests, and the byte-exact fixture under both lanes | S1 |
| Unsupported platform | `host_platform_for_names_the_unjailed_ones_test`; the self-test's `UNSUPPORTED PLATFORM` result. No new behaviour. | unchanged |
| Late old-generation event | A table test of `step` against a `Settled` row; a real race test; a late-`Run` test with a stalled actor | S1; S2 |
| Code-mode hostile BEAM | `the_real_token_does_not_widen_policy_test`, `cap_calls_without_the_token_are_all_denied_test`, `satellite_that_never_returns_is_killed_at_the_deadline_test`, and `make e2e-codemode`, all under both lanes; the default flip in S2 waits on them | S1; S2 |

Beyond the matrix, three checks follow from the design and not from the issue.
A property test shows that no event sequence produces two settlements for one
id. A test pins the zero-byte retention and the 64-entry ring. And the S1
equivalence test is the cheapest disproof of the seam: if any broker case needs
a lane-specific expectation, the execution-level seam is leaking semantics and
ADR-017 is wrong.

## Where the code lives

Today the whole subject lives in two files and one wiring site:
`broker/exec.gleam` for the helper machine and pool, `broker/broker.gleam` for
the relay, and `client/serve.gleam` for the per-session wiring. The ADR-017
modules join `broker` in S1. The package documentation for `broker`
(`packages/broker/CLAUDE.md`) and the effect-plane overview
(`docs/architecture/effects.md`) describe the helper pool and the relay, and are
updated with the phase that changes them.
