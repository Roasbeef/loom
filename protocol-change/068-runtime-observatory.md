# protocol-change/068: a typed runtime observatory for one node

**Status**: PROPOSED 2026-10-04. **Affects**: the session conversation
protocol (spec Part 1 §1.6) gains two read commands, and a third with the
event ring; the v2 control socket gains two owner commands; the strand driver
gains an `Observe` message; the drain ledger's claim reply gains a generation,
which changes `strand_runtime.Options.claim_reaper` and
`supervisor.Config.strand_options`; `executor_view.LiveView` gains the call it
serves. With the event ring, `runtime/effects.Hooks` gains an `observe` slot
and protocol-change/065 gains the `observatory` role. No durable row changes.
**Raised by**: issue #730 (distributed runtime observatory), phase 0, for a
single node. **Implemented**: not yet.

## Problem

When a session looks stuck, nobody can ask Loom what it is doing. The
operator sees a phase label in the terminal and a spinner, and no
agent-readable status exists at all. Answering "why is `main` not making
progress" today means reading the log file, attaching `observer` or
pickglass to a profiled node, and matching pids to sessions by hand.

Some of the answer is already on the wire. Each strand in a session snapshot
carries `LiveOp(op, phase)` (`client/protocol`), with the phase string from
`gateway.phase_of`, and `session_view/agent_view.Status` turns that into the
per-strand status the terminal and the web view draw. Those say which phase
a strand is in. They do not say what the phase is waiting on, and the rest of
the facts are scattered with nothing to join them:

- The durable `op.state` register holds the tool calls and the model request
  of the current step (`machine/operation.RunPhase`), but nothing reports the
  call or request a strand is waiting on.
- A parked approval is not a machine phase. It is a `Pending` escalation
  record whose `CallScope` names a tool call in `CallEffectPending`, and only
  a reader that joins the two knows the run is waiting for a person.
- Deadlines exist (the provider request deadline, the broker `Budget`, the
  approval park, job and async-run deadlines), but no accessor reports the
  one that applies to what a strand is doing now.
- The strand driver has no query message, so its in-memory view of live
  effects is reachable only through `sys:get_state`.
- A driver that a supervisor restarted looks identical to its predecessor:
  same strand name, same `Address`, same pickglass label. Nothing numbers
  incarnations, so an observer cannot say "this is a replacement".
- The event bus is hint-only and stateless, and the hint half has no producer
  (`docs/architecture/events.md`, "Who is on the bus today"). There is no
  record of what happened in the last minute.

Issue #730 asks for one typed model of a run that local and remote callers
share. The distributed half needs #697's node identities and TLS
distribution, neither of which exists. This proposal is the part that does
not: the identities, the observation types, the operations, their authority
and their bounds, served from inside one `loomd`.

## What exists to build on

- **The daemon epoch** and the resident session's `incarnation` string
  (`epoch:N`, `client/daemon/manager`). Every mutating control command already
  carries the epoch, and `frame_authority` already compares the incarnation.
- **Durable coordinates.** `OpId` for operations, `{op, step_id,
  source_index}` for a tool call (`machine/planner.ToolClearanceKey`), and
  `{op, step_id, attempt}` for a model request
  (`GenerationEffectPending.attempt`).
- **The drain ledger** (`runtime/internal/drain_registry`). A strand driver
  incarnation that reaches its loop has a claim in flight to it. The ledger is
  the runtime tree's first child, temporary and significant, so it outlives
  every restartable child and its death ends the session incarnation.
- **The executor's observation** (`broker/executor_view`): a `Snapshot` built
  from the service's own books, a 64-entry ring trimmed on push, and types
  that cannot hold argv, environment or output bytes, with
  `executor_snapshot_test` planting a marker to prove it. It is the template
  for everything below.
- **`sessions.activity`** (protocol-change/050) and **`peers.inspect`**
  (protocol-change/049): owner-only, bounded control reads that never open a
  saved session. `sessions.activity` asks every resident concurrently under
  one 2,000 ms deadline.
- **`gateway.read_only`**, the exhaustive classification that keeps an
  observer from issuing anything but a read.
- **The pickglass owner label** (protocol-change/065), which attributes BEAM
  processes to session, strand and role for an external inspector.

## What was considered

- **Expose raw BEAM evidence (`process_info`, `sys:get_state`, tracing) behind
  a permission check.** Rejected. The issue's own rule is that domain state is
  the interface and runtime evidence only supports it. `sys:get_state` copies
  a whole actor state, which may hold effect closures and records the
  observatory has no business returning, and in-VM tracing is the probe
  machinery pickglass already owns, outside the daemon, under the owner's
  distribution cookie.
- **Make the event bus the causal record.** Rejected. The bus is defined as
  hints that carry no state ("events are hints; pulls are truth"), it has no
  retention, and its `pg` scope is open to every process on the node. A
  bounded ring is state with an owner, and putting it on the bus would change
  what the bus means.
- **No ring at all; derive recency from durable state.** Durable state
  answers which phase, which call and which approval. It does not record when
  a request started streaming or when a driver was replaced, and those times
  are what "no progress for 47 s" needs. The ring is specified here but ships
  after describe and explain, so the first two operations do not wait on it.
- **Durable strand generations.** Rejected. A generation is runtime evidence
  about one daemon lifetime. Durable identity is already carried by `OpId`
  and the call coordinates, and a durable counter would add a write per
  restart for nothing a reader could use after the daemon restarts.
- **A separate `RunId`.** Rejected. In Loom a run is an operation, and `OpId`
  already names it durably. A second identity would need a mapping that could
  drift.
- **A server-side check of an expected generation in each request.**
  Rejected for phase 1. Every reply carries the incarnation and generation it
  describes, and nothing in phase 1 acts on a reply, so a reader can compare
  for itself. A check belongs with the first operation that changes state.
- **Five operations as the issue sketches them (`DescribeRun`, `ListActors`,
  `SnapshotRun`, `TraceRun`, `ExplainRun`).** Collapsed to three below.
  `ListActors` and `SnapshotRun` are the same read as `DescribeRun` with more
  or less evidence attached, and the evidence is cheap enough to always
  include. `TraceRun` is the event ring; BEAM tracing stays in pickglass.
- **An agent-facing capability (`cap/observe`) in phase 1.** Deferred; see
  "The agent surface" below.

## Decision

### Three layers, and which one Loom serves

| Layer | What it answers | Who serves it |
| --- | --- | --- |
| Domain state | What the strand is doing, what it waits on, its deadline | Loom, through the operations below |
| Runtime evidence | Whether the processes behind it are alive, their mailbox length, heap and reductions | Loom, a fixed small set read with `process_info/2` |
| Source debugging and deep probes | Breakpoints, frames, call traces, heap retention, forced GC | EDB, and pickglass over `--profile` distribution. Never Loom. |

Loom calls no `erlang:trace`, `sys:get_state`, `garbage_collect` or
`process_info(_, dictionary | messages | backtrace)` on behalf of an
observatory request. Those remain the owner's tools, reached through the
owner-only distribution channel that `--profile` opens.

### Identities and generations

A request names a session and, optionally, a strand. A pid is never part of
a request; it appears in replies only as evidence.

| Object | Identity | Generation | Where it comes from |
| --- | --- | --- | --- |
| Node | daemon `epoch` | the epoch is one lifetime | `client/daemon/root` |
| Session | canonical `SessionId` | resident `incarnation` (`epoch:N`) | the manager's slot |
| Strand | strand name | driver `generation`, an integer from 1 | the drain ledger (new) |
| Operation | `OpId` | none; an operation is never re-minted | `op.meta` |
| Model request | `{op, step_id, attempt}` | `attempt` | `op.state` |
| Tool call | `{op, step_id, source_index}` | none | `op.state` |
| Escalation | escalation id | the record's register `seq` | `escalation/<id>` |
| Background job | `JobId` | none | `job/<id>` |
| Execution | `ExecutionId` rendered `incarnation.seq` | the executor incarnation | the broker |

**The strand generation is new.** The drain ledger keeps a counter per strand
name, separate from its chain of live reapers (which `forget` trims as
reapers retire), and returns the incremented value in the `Claim` reply. The
first claim for a strand in a session incarnation is generation 1 and each
later claim is one more. The ledger lives exactly as long as the session
incarnation, so a generation is meaningful only beside its incarnation, and
every reply carries both. Nothing in the runtime compares generations to make
a decision; a generation is evidence, the way `HelperView.ordinal` is
(`broker/exec`).

Two consequences of how drivers claim, which the types carry:

- **The claim is asynchronous to the driver's start.** `start_reaper` sends
  the claim from a claimant process after `weft.adopt_leaf`, while the driver
  is already addressable. An `Observe` that arrives first finds no generation
  yet, so the driver reports its generation as `Observed(Int)` and a reply
  can read `Missing(NotYet)` for it.
- **Some incarnations never claim.** A driver whose reaper scope dies before
  handoff, whose adopt is refused, or that forgoes its claim halts and is
  restarted by the factory without taking a number. Generations therefore
  count claims, not starts, and a gap in them is not possible; a restart that
  never claimed is invisible to the count and visible only in pickglass.

### Observed values

Every fact that comes from a source which can fail is wrapped:

```gleam
pub type Observed(a) {
  /// Read from its source during this request.
  Known(value: a)
  /// A list cut at its bound; `omitted` counts what was left out.
  Truncated(value: a, omitted: Int)
  /// No value, and why.
  Missing(gap: Gap)
}

pub type Gap {
  /// The source did not answer within its share of the deadline.
  TimedOut
  /// The process that would answer is not running.
  NotRunning
  /// The source is running but has not produced the value yet.
  NotYet
  /// This build cannot observe it.
  Unsupported
  /// The source answered with something the decoder refused.
  Unreadable
}
```

A missing number is `Missing`, never 0, and a missing state is `Missing`,
never idle. Every reply carries `collected_at_ms` in system time (not
monotonic time, which is negative on the BEAM), the node epoch, and the
session incarnation. Phase 2 adds a `Stale` variant for evidence from a node
that stopped answering; nothing in phase 1 returns an old value in place of a
fresh read.

### Activity: the domain state of a strand

`Activity` is computed from the strand's durable `current_operation`, that
operation's `op.state`, and the session's pending escalations. It covers
every phase `gateway.phase_of` distinguishes, and splits the assistant phase
by its `Generation` state:

```gleam
pub type Activity {
  /// No current operation.
  Idle
  /// `RunPhase.Starting`.
  Starting
  /// `RunPhase.Checkpoint`.
  Checkpoint
  /// `Assistant(GenerationReady)`: admission and model resolution, before
  /// the request is sent. The ref carries `next_attempt`.
  Preparing(request: RequestRef)
  /// `Assistant(GenerationEffectPending)`.
  Streaming(request: RequestRef, deadline_ms: Observed(Int))
  /// `Assistant(GenerationRetryWait)`.
  RetryWait(request: RequestRef, not_before_ms: Int)
  /// `RunPhase.Tools`, with no call parked on an approval.
  RunningTools(calls: List(CallView))
  /// `RunPhase.Tools`, with a call parked on a pending escalation.
  AwaitingApproval(call: CallRef, escalation: String, calls: List(CallView))
  /// `RunPhase.Compacting`, or a compaction operation.
  Compacting
  /// `RunPhase.AwaitingDeferred`.
  AwaitingDeferred
  /// `RunPhase.FailureDrain`.
  FailureDrain
  /// A navigation operation.
  Navigating
  /// Any operation whose control is `CancelRequested`.
  Cancelling
}
```

`gateway.phase_of` moves to a shared module and `Activity` is built beside
it, so the phase string on `LiveOp` and the `Activity` variant cannot
disagree. Phase 1 does not change `agent_view.Status`; once `Activity` is on
the wire, `agent_view` can project from it instead of from the phase string,
which is a separate change.

`AwaitingApproval` is the one derived variant: an operation in `Tools` with a
call in `CallEffectPending` whose `{op, step_id, source_index}` equal the
current `CallScope` of a `Pending` escalation. A parked call is a live tool
effect, so it stays `CallEffectPending` for as long as the park lasts. The
park ends at its configured window or the call's budget deadline, whichever
is first, and the call then settles in band while the record may stay
`Pending`; the join requires both, so it stops reporting the call as awaiting
approval once the call settles. A scope can move between claimants (`client/escalate`), so the join
reads the record's current scope, not the one it was raised with.

A `CallView` names the call, its tool name, and its `ToolCallState` as one of
`planned | pending | ready | completed`. Where the broker has a live execution
for the call's `{op, step_id}`, it adds the execution's deadline and age from
`executor_view.LiveView`. `LiveView` gains the `{op, step_id}` its execution
was started for, which `broker.CallSpec` already carries; `LiveView` is an
internal type and not a wire shape.

### Runtime evidence

For each strand the reply lists the processes Loom can name without asking a
third party:

- the strand driver, found through the registry's `Address`;
- its live effect workers and provider effect workers, from the driver's new
  `Observe` reply;
- any executor helper serving one of the strand's calls, from the executor
  snapshot.

Each is reported as:

```gleam
pub type ProcessEvidence {
  ProcessEvidence(
    kind: ProcessKind,
    pid: String,
    status: Observed(ProcessStatus),
    mailbox: Observed(Int),
    heap_bytes: Observed(Int),
    reductions: Observed(Int),
  )
}

pub type ProcessKind {
  Driver
  EffectWorker
  ProviderWorker
  ExecutorHelper
}
```

`ProcessKind` is the observatory's own closed set, not `owner.Role`: a helper
has no owner role, and the observatory does not read labels back
(protocol-change/065).

The four values come from one `erlang:process_info(Pid, [status,
message_queue_len, total_heap_size, reductions])` per process, which needs an
`@external` in an `internal/ffi_process_info` module, because neither
`gleam_erlang` nor weft exposes `process_info/2`. A dead pid yields
`Missing(NotRunning)` for every field.

The driver's new `Observe(reply)` message answers from its own state: its
generation, occupancy, the effect tokens it holds live with their worker
pids, and its retry wake time. It is a bounded call. A replacement driver
handles `AwaitPredecessors` before any other message and blocks until its
predecessors' effects drain, so an `Observe` to a driver in that window times
out. The reply therefore also asks the drain ledger how many reapers the
strand has; more than one means a replacement is waiting for an older
generation to drain, which `explain` reports as such rather than as an
unresponsive driver.

Processes the strand does not own directly (the gateway, the agency, the
services tree, supervisors) are not listed in phase 1. Their attribution is
what pickglass is for.

### Operations

| #730 name | Operation | Returns |
| --- | --- | --- |
| `DescribeRun`, `ListActors`, `SnapshotRun` | `observe.describe` | `Description`: per strand, identity, `Activity`, the current `OpId` and `ProcessEvidence` |
| `ExplainRun` | `observe.explain` | `Explanation` (below), with the `Description` it was computed from |
| `TraceRun` | `observe.events` | a page of events from the ring after a given `seq`, at most 128. Ships with the ring. |

`observe.describe` and `observe.explain` take a session and an optional strand
(all strands when omitted, up to 64). `observe.events` takes a session, an
optional strand filter and an `after` seq.

Each reply is composed under one 2,000 ms deadline, as `sessions.activity`
is. The sources (durable state, the driver, the drain ledger, the escalation
holder, the executor) are read concurrently in weft managed tasks with a
500 ms share each. A source that runs out of time becomes
`Missing(TimedOut)` and the reply is still sent.

The types, their total JSON decoders and `explain` live in
`session_view/observatory`, which is portable (lint R6), so the daemon, the
terminal and the web view decode and explain the same way. The reads that
fill a `Description` live in `client/observatory`.

### Explain

`explain(Description) -> Explanation` is a pure function, so its rules are
property-testable without processes.

```gleam
pub type Explanation {
  Explanation(
    strand: String,
    verdict: Verdict,
    facts: List(Fact),
    gaps: List(Gap),
    confidence: Confidence,
  )
}

pub type Verdict {
  NothingRunning
  Working
  BlockedOn(blocker: Blocker)
  Undetermined
}

pub type Blocker {
  Approval(escalation: String)
  ToolCall(call: CallRef)
  ModelRequest(request: RequestRef)
  RetryBackoff(not_before_ms: Int)
  DeferredPoll
  Cancellation
  PredecessorDrain(waiting_generation: Int)
  UnresponsiveDriver
}

pub type Confidence {
  Complete
  Partial
}
```

The rules are fixed and listed in the module:

- The verdict comes from `Activity`. `Idle` is `NothingRunning`.
  `AwaitingApproval` is `BlockedOn(Approval)`. `RunningTools` is
  `BlockedOn(ToolCall)` naming the oldest call in `pending`, or `Working`
  when no call is pending (every call is planned, ready or completed).
  `Streaming` is `BlockedOn(ModelRequest)`; `Starting`, `Checkpoint`,
  `Preparing`, `Compacting`, `FailureDrain` and `Navigating` are `Working`.
- A timed-out `Observe` is `BlockedOn(PredecessorDrain)` when the ledger
  shows more than one reaper for the strand, or when the strand has no
  generation yet (a replacement whose claim has not landed is blocked in the
  same way). It is `BlockedOn(UnresponsiveDriver)` only when the strand has a
  generation and the ledger shows one reaper.
- Facts report what was read: the blocking call's worker is alive or not,
  its deadline is N ms away or has passed, the driver is generation G.
- No rule turns a process exit into an outcome. A dead tool worker does not
  mean the tool's effect did not happen, and the explanation says the worker
  is gone, not that the call failed.
- There is no "stuck" verdict and no threshold. With the ring, a fact states
  that the newest event for the strand is 47 s old; deciding that 47 s is
  too long is the reader's job.
- `confidence` is `Partial` whenever any fact the verdict depends on is
  `Missing`, and `gaps` lists each one.

### Who may ask, and where

| Surface | Commands | Authority | Reach |
| --- | --- | --- | --- |
| Session conversation socket | `observe.describe`, `observe.explain` (and `observe.events` with the ring) | any member of the session: owner, operator or observer; classified `read_only` | that session only |
| v2 control socket | `observe.describe`, `observe.explain` with a `session_id` and the epoch | owner only, checked before the session is resolved, as `peers.inspect` | any resident session; a saved session is `not_found` and is never opened |
| Command line | `loom inspect <session> [--strand S] [--explain]` | owner, a thin client of the control commands | as the control socket |

`gateway.read_only` lists the new commands as reads, so an observer may issue
them and the exhaustive `case` keeps the classification honest.

### The agent surface

No phase 1 operation is reachable from a model-influenced process. Agents
get a surface later, as `cap/observe`, under one rule this proposal fixes
now: **an agent-facing reply never reveals that an escalation exists, was
raised, or was decided.** `client/escalate` is built so the model sees the
same in-band refusal whether policy refused a call or a person did, and
"must never be able to tell that an approval existed and was set aside". A
parked call is also recognisable indirectly: it stays pending with no
executor execution while its worker stays alive, and with the ring its
`CallStarted` and `CallSettled` times show the park window. An agent surface
therefore returns only `Activity` and `Verdict`, with `AwaitingApproval`
reported as `RunningTools`, every call list in it empty, and
`BlockedOn(Approval)` and `BlockedOn(ToolCall)` both reported as `Working`. It
returns no per-call views, no process evidence, no escalation events and no per-call
event times. It reads
its own session only, takes the session from the launching identity as
`client/peers.router` does, and has a per-execution admission ceiling.

An agent cannot observe another session. No operation in this proposal
grants that, and one that does needs an audit record first: Loom has no audit
store today (`docs/architecture/approvals.md` calls a missing audit line
"the accepted cost"), and a cross-session read granted to an agent without
one would be a privileged read nobody can account for.

### Confidentiality

Every observatory type falls into one of three classes, decided by its field
types rather than by a filter at the edge:

| Class | Contents | Readers |
| --- | --- | --- |
| Identity | ids, strand names, generations, phases, counts, deadlines, ages, tool names, outcome kinds, pids, mailbox lengths, heap sizes | every reader above |
| Argument text members already see | the escalation preview: the call's canonical argument JSON (for `bash`, an object holding the command), cut to 512 characters as `session_view/approval` cuts it, and drawn only as text, because it is model-controlled. | members of the session (it is already on their wire through `EscalationsGet`) and the owner; never an agent surface |
| Never | tool output, transcript text, provider request or response bodies, error text, environment, working directory, policy, tokens, mailbox contents, process dictionaries, actor state, stack traces, and argument text beyond the preview above | no one; no observatory type can hold them |

Outcomes are closed classifications, never text: `ok`, `cancelled`,
`timed_out`, `lost`, or `failed(kind)` with `kind` from a fixed
`FailureKind` set. Provider and tool error text can carry secrets, and a
free-form kind would let it back in.

A test builds a session whose transcript, tool arguments, environment and
tool output carry a planted marker, runs every operation on every surface,
and asserts the marker appears in no reply except the bounded preview where
the call's own arguments contain it, the way `executor_snapshot_test` does
for the executor's snapshot.

### Causal events

The ring ships after describe and explain. Each session keeps the last 256
events, newest first and trimmed on push, in a per-session actor,
`client/observatory` (role `observatory`, added to protocol-change/065's
table). Events carry identities and classifications, never content:

```gleam
pub type Event {
  DriverStarted(strand: String, generation: Int)
  DriverStopped(strand: String, generation: Int, reason: StopReason)
  PhaseChanged(strand: String, op: OpId, phase: String)
  RequestStarted(strand: String, request: RequestRef)
  RequestSettled(strand: String, request: RequestRef, outcome: Outcome)
  CallStarted(strand: String, call: CallRef, tool: String)
  CallSettled(strand: String, call: CallRef, outcome: Outcome)
  EscalationRaised(id: String, call: CallRef)
  EscalationSettled(id: String, settlement: Settlement)
  OperationSettled(strand: String, op: OpId, outcome: Outcome)
}

pub type Settlement {
  Approved
  Rejected
}

pub type Stamped {
  Stamped(seq: Int, at_ms: Int, event: Event)
}
```

`seq` increases by one per event within the actor's lifetime, so a reader
sees a gap where events were trimmed or lost. `DriverStarted` is recorded
when the driver's claim resolves, because that is when it has a generation.

`Event` is a runtime type (`runtime/observed`), because the strand driver
produces most of it through a new `Hooks.observe: fn(Event) -> Nil` slot;
`effects.default_hooks` supplies a no-op, and the client composition supplies
a function that casts to the session's observatory actor. `client/escalate`
casts its two events directly. `session_view/observatory` holds the wire form
and its decoder, so the runtime takes no dependency on `session_view`.

Every send is fire-and-forget: if the actor is down the event is lost, which
costs evidence and nothing else. The ring is evidence, not a log; nothing
recovers from it and nothing durable depends on it.

### Bounds

- A reply is at most 60,000 bytes, the `peers.inspect` budget. Lists that
  would exceed it are `Truncated`.
- At most 64 strands, 64 calls per strand, 16 processes per strand and 128
  events per page.
- The ring holds 256 events per session. At an estimated 160 bytes for an
  event with three ids that is about 40 KiB; the ring's step measures it
  with `erts_debug:size/1` and records the figure here.
- The observatory performs no probes, so there is no trace, sampling or GC
  budget to bound.

### Trust boundary

```text
      member client                        owner CLI / TUI
            |                                     |
      session socket                         control socket
  (own session, any role)               (any resident session)
            \                                     /
             +----------- loomd (one node) ------+
                               |
                     client/observatory reads
                durable state, driver, drain ledger,
              escalations, executor, process_info/2 x4
                               |
                ---- no distribution on this path ----

 owner only:  loomd --profile  ==distribution (0600 cookie)==>  pickglass
              (deep probes, tracing, heap attribution)
```

Nothing in this proposal starts distribution, reads the cookie, or gives a
model-influenced process a path to it. Distribution stays where
protocol-change/065 and `docs/distribution.md` put it: off unless the owner
starts a profiled node, loopback-only, and the owner's.

### What phase 2 adds, and what it must not change

When #697 lands node identities and TLS distribution, a node gains an id
beside its epoch, every identity gains a node, and a remote session's facts
become `Stale` or `Missing(TimedOut)` when the node is unreachable instead of
failing the request. The operations, the classes, the bounds, the agent rule
and the explanation rules do not change. A hidden observer node that speaks to
the observatory over distribution is a trusted-plane client like the owner
CLI.

## What it costs

- The strand driver gains a message and its state a generation. The drain
  ledger gains a counter per strand, and its claim reply changes shape, which
  changes the public `strand_runtime.Options.claim_reaper` and
  `supervisor.Config.strand_options` fields and their callers.
- `executor_view.LiveView` gains `{op, step_id}`.
- One new `@external` for `process_info/2`, confined to
  `client/internal/ffi_process_info`, with the reason stated in the module.
- `gateway.phase_of` moves to a shared module.
- The session socket and the control socket each gain two commands, and the
  command line gains `loom inspect`.
- With the ring: one `process.send` per strand transition, request, tool call
  and escalation, to a per-session actor (a few sends per tool round, since
  transitions happen per step and not per token); an estimated 40 KiB per
  resident session; a new field on `runtime/effects.Hooks`, so every
  construction of `Hooks` changes; and the `observatory` role in
  protocol-change/065.

## Rollout

Phase 1 of #730, in this order, each a separate change:

1. Runtime: the generation counter in the drain ledger, the driver's
   `Observe` message, and the ledger's reaper count. Tests: a restarted
   driver reports generation 2 under the same address; an `Observe` on a
   driver waiting for its predecessor times out without blocking the caller,
   and the ledger reports two reapers.
2. `session_view/observatory`: the types, total decoders and `explain`, with
   property tests that an explanation never names a blocker the description
   does not contain, that `Activity` is total over `OperationState`, and that
   any `Missing` input the verdict depends on makes it `Partial`.
3. `client/observatory` reads and the `process_info` FFI, with the
   planted-marker test.
4. The session-socket and control-socket commands and `loom inspect`. Tests:
   an observer may read and not mutate; a member of one session cannot read
   another; the control commands refuse a member and a stale epoch; a saved
   session is never opened.
5. The event ring, `Hooks.observe`, `observe.events`, and the explanation
   fact for the newest event's age.

The agent surface is a later proposal, held to the rule above.

## Point for the owner

**Observers see runtime evidence.** Mailbox lengths and heap sizes go to
every member, observers included. They reveal load, not content. If that is
too much, the evidence fields become `Missing(Unsupported)` for an observer
and nothing else changes.
