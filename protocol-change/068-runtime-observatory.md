# protocol-change/068: a typed runtime observatory for one node

**Status**: PROPOSED 2026-10-04. **Affects**: the session conversation
protocol (spec Part 1 §1.6) gains three read commands; the v2 control socket
gains two owner commands; `runtime/effects.Hooks` gains an `observe` slot; the
strand driver gains an `Observe` message; the drain ledger's claim reply gains
a generation; protocol-change/065 gains the `observatory` role; the code-mode
prelude gains `cap/observe`. No durable row changes. **Raised by**: issue #730
(distributed runtime observatory), phase 0, for a single node. **Implemented**:
not yet.

## Problem

When a session looks stuck, nobody can ask Loom what it is doing. The
operator sees a phase label in the terminal and a spinner. An agent sees
nothing at all. Answering "why is `main` not making progress" today means
reading the log file, attaching `observer` or pickglass to a profiled node,
and matching pids to sessions by hand.

The facts are all present, but they are scattered and nothing joins them:

- The durable `op.state` register says which phase an operation is in
  (`machine/operation.RunPhase`), but nothing reports it with the call or
  request it is waiting on.
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
- **The drain ledger** (`runtime/internal/drain_registry`). Every strand
  driver incarnation already claims a slot in it before it starts, the
  ledger outlives every other child of the runtime tree, and if it dies the
  session stops. It is the one process that sees each incarnation of each
  strand in order.
- **The executor's observation** (`broker/executor_view`): a `Snapshot` built
  from the service's own books, a 64-entry ring trimmed on push, and types
  that cannot hold argv, environment or output bytes, with a test that plants
  a marker to prove it. It is the template for everything below.
- **`sessions.activity`** (protocol-change/050) and **`peers.inspect`**
  (protocol-change/049): owner-only, bounded, deadline-per-resident control
  reads that never open a saved session.
- **`gateway.read_only`**, the exhaustive classification that keeps an
  observer from issuing anything but a read.
- **`client/peers.router`**: a `CapRouter` whose identity comes from the
  host, never from arguments, with a per-capability admission ceiling.
- **The pickglass owner label** (protocol-change/065), which attributes BEAM
  processes to session, strand and role for an external inspector.

## What was considered

- **Expose raw BEAM evidence (`process_info`, `sys:get_state`, tracing) to
  agents behind a permission check.** Rejected. The issue's own rule is that
  domain state is the interface and runtime evidence only supports it.
  `sys:get_state` copies a whole actor state, which holds transcripts and
  credentials, and in-VM tracing is the probe machinery pickglass already
  owns, outside the daemon, under the owner's distribution cookie.
- **Make the event bus the causal record.** Rejected. The bus is defined as
  hints that carry no state ("events are hints; pulls are truth"), it has no
  retention, and its `pg` scope is open to every process on the node. A
  bounded ring is state with an owner, and putting it on the bus would change
  what the bus means.
- **Derive "last progress" from durable commit times instead of a ring.**
  This covers one question (how long since the operation committed anything)
  and not the others: whether a driver restarted, when a request started
  streaming, which approval was raised. The ring is small enough that the
  simpler data source is not worth the gaps.
- **Durable strand generations.** Rejected. A generation is runtime evidence
  about one daemon lifetime. Durable identity is already carried by `OpId`
  and the call coordinates, and a durable counter would add a write per
  restart for nothing a reader could use after the daemon restarts.
- **A separate `RunId`.** Rejected. In Loom a run is an operation, and `OpId`
  already names it durably. A second identity would need a mapping that could
  drift.
- **Five operations as the issue sketches them (`DescribeRun`, `ListActors`,
  `SnapshotRun`, `TraceRun`, `ExplainRun`).** Collapsed to three below.
  `ListActors` and `SnapshotRun` are the same read as `DescribeRun` with more
  or less evidence attached, and the evidence is cheap enough to always
  include. `TraceRun` is the event ring; BEAM tracing stays in pickglass.

## Decision

### Three layers, and which one Loom serves

| Layer | What it answers | Who serves it |
| --- | --- | --- |
| Domain state | What the strand is doing, what it waits on, its deadline, who owns it | Loom, through the operations below |
| Runtime evidence | Whether the processes behind it are alive, their mailbox length, heap and reductions | Loom, a fixed small set read with `process_info/2` |
| Source debugging and deep probes | Breakpoints, frames, call traces, heap retention, forced GC | EDB, and pickglass over `--profile` distribution. Never Loom. |

Loom calls no `erlang:trace`, `sys:get_state`, `garbage_collect` or
`process_info(_, dictionary | messages | backtrace)` on behalf of an
observatory request. Those remain the owner's tools, reached through the
owner-only distribution channel that `--profile` opens.

### Identities and generations

A request addresses a domain object by identity. A pid never appears in a
request and is never accepted as one; it appears in replies only as evidence.

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

**The strand generation is new.** The drain ledger counts claims per strand
name and returns the count in the `Claim` reply, so the first driver for a
strand in a session incarnation is generation 1 and each replacement is one
more. The ledger lives exactly as long as the session incarnation, so a
generation is meaningful only beside its incarnation, and every reply carries
both. Nothing compares a generation to make a decision; it is evidence, the
way `HelperView.ordinal` is (`broker/exec`).

A request may carry the generation it expects:

```json
{"session":"<id>","strand":"main","expect":{"incarnation":"<epoch:N>","generation":3}}
```

If the session incarnation or the strand generation differs, the reply is
`stale` with the current values and no observation. A reader that learned
about generation 3 never receives facts about generation 4 under the same
question.

### Observed values

Every fact that comes from a source which can fail is wrapped:

```gleam
pub type Observed(a) {
  /// Read from its source during this request.
  Known(value: a)
  /// Read from the event ring rather than re-read; `at_ms` says when.
  Stale(value: a, at_ms: Int)
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
  /// This build cannot observe it (for example a process Loom does not track).
  Unsupported
  /// The source answered with something the decoder refused.
  Unreadable
}
```

A missing number is `Missing`, never 0, and a missing state is `Missing`,
never `Idle`. Every reply carries `collected_at_ms` in system time (not
monotonic time, which is negative on the BEAM), the node epoch, and the
session incarnation.

### Activity: the domain state of a strand

`Activity` is computed from the strand's durable `current_operation`, that
operation's `op.state`, and the session's pending escalations:

```gleam
pub type Activity {
  Idle
  Starting
  Streaming(request: RequestRef, deadline_ms: Observed(Int))
  RetryWait(request: RequestRef, not_before_ms: Int)
  RunningTools(calls: List(CallView))
  AwaitingApproval(call: CallRef, escalation: String, park_deadline_ms: Observed(Int))
  Compacting
  AwaitingDeferred
  Cancelling
  Navigating
  Draining
}
```

The mapping follows `gateway.phase_of`, which becomes a shared function so the
two cannot disagree. `AwaitingApproval` is the one derived state: an operation
in `Tools` with a call in `CallEffectPending` whose coordinates equal the
`CallScope` of a `Pending` escalation. A scope can move between claimants
(`client/escalate`), so the join reads the record's current scope, not the
one it was raised with.

A `CallView` names the call, its tool name, its `ToolCallState` as one of
`planned | pending | ready | completed`, and, where the broker has a live
execution for the call's `{op, step_id}`, the execution's deadline and age
from `executor_view.LiveView`. `LiveView` gains the `{op, step_id}` it was
started for; it is an internal type and not a wire shape.

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
    role: owner.Role,
    pid: String,
    status: Observed(ProcessStatus),
    mailbox: Observed(Int),
    heap_bytes: Observed(Int),
    reductions: Observed(Int),
  )
}
```

The four values come from one `erlang:process_info(Pid, [status,
message_queue_len, total_heap_size, reductions])` per process, which needs an
`@external` in an `internal/ffi_process_info` module, because neither
`gleam_erlang` nor weft exposes `process_info/2`. A dead pid yields
`Missing(NotRunning)` for every field.

The driver's new `Observe(reply)` message answers from its own state:
generation, occupancy, the effect tokens it holds live with their worker
pids, and its retry wake time. It is a bounded call. A driver that does not
answer within its share of the deadline is reported as `Missing(TimedOut)`,
and that is itself evidence: the driver is busy or blocked, which no other
read can show.

Processes the strand does not own directly (the gateway, the agency, the
services tree, supervisors) are not listed in phase 1. Their attribution is
what pickglass is for.

### Causal events

Each session keeps a ring of the last 256 events, newest first and trimmed on
push, in a new per-session actor, `client/observatory` (role `observatory`,
added to protocol-change/065's table). Events carry identities and
classifications, never content:

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
  EscalationDecided(id: String, decision: Decision)
  OperationSettled(strand: String, op: OpId, outcome: Outcome)
}

pub type Stamped {
  Stamped(seq: Int, at_ms: Int, event: Event)
}
```

`seq` increases by one per event within the actor's lifetime, so a reader
sees a gap where events were trimmed or lost. `Outcome` and `StopReason` are
closed classifications (`ok`, `failed(kind)`, `cancelled`, `timed_out`,
`lost`), never an error string, because provider and tool error text can
carry secrets.

The strand driver produces its events through a new `Hooks.observe: fn(Event)
-> Nil` slot. The default is a no-op, and the client composition supplies a
function that casts to the session's observatory actor. `client/escalate`
casts its two events directly. Every send is fire-and-forget: if the actor is
down the event is lost, which costs evidence and nothing else. The ring is
evidence, not a log; nothing recovers from it and nothing durable depends on
it.

### Operations

| #730 name | Operation | Returns |
| --- | --- | --- |
| `DescribeRun`, `ListActors`, `SnapshotRun` | `observe.describe` | `Description`: per strand, identity, `Activity`, the current `OpId`, `ProcessEvidence`, and the newest event's age |
| `ExplainRun` | `observe.explain` | `Explanation` (below), with the `Description` it was computed from |
| `TraceRun` | `observe.events` | a page of `Stamped` events after a given `seq`, at most 128 |

`observe.describe` and `observe.explain` take a session and an optional strand
(all strands when omitted, up to 64). `observe.events` takes a session, an
optional strand filter and an `after` seq.

The observatory actor composes each reply under one 2,000 ms deadline, the
same as `sessions.activity`. It reads in a weft managed task so a slow source
never blocks the ring, and gives each source (durable state, the driver, the
escalation holder, the executor) a 500 ms share. A source that runs out of
time becomes `Missing(TimedOut)` and the reply is still sent.

### Explain

`explain(Description) -> Explanation` is a pure function in
`session_view/observatory`, beside the types and their total JSON decoders,
so the daemon, the terminal and the web view compute the same answer and the
rules are property-testable without processes.

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
  Idle
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
  UnresponsiveDriver
}

pub type Confidence {
  Complete
  Partial
}
```

The rules are fixed and listed in the module:

- The verdict comes from `Activity` alone. `RunningTools` is `BlockedOn(ToolCall)`
  naming the oldest pending call; `AwaitingApproval` is `BlockedOn(Approval)`.
- Facts report what was read: the blocking call's worker is alive or not, its
  deadline is N ms away or passed, the newest event for the strand is N ms old,
  the driver is generation G and replaced its predecessor at T.
- `UnresponsiveDriver` is chosen only when the driver's `Observe` call timed
  out. A driver whose pid is dead is reported as not running, with the
  current generation if the registry already shows a replacement.
- No rule turns a process exit into an outcome. A dead tool worker does not
  mean the tool's effect did not happen, and the explanation says the worker
  is gone, not that the call failed.
- There is no "stuck" verdict and no threshold. The explanation states that
  the newest event is 47 s old; deciding that 47 s is too long is the
  reader's job.
- `confidence` is `Partial` whenever any fact the verdict depends on is
  `Missing`, and `gaps` lists each one.

### Who may ask, and where

| Surface | Commands | Authority | Reach |
| --- | --- | --- | --- |
| Session conversation socket | `observe.describe`, `observe.explain`, `observe.events` | any member of the session: owner, operator or observer; classified `read_only` | that session only |
| v2 control socket | `observe.describe`, `observe.explain` with a `session_id` and the epoch | owner only, as `sessions.activity` | any resident session; a saved session is `not_found` and is never opened |
| Code mode | `cap/observe`: `describe`, `explain`, `events` | the launching strand's session, bound by the host | the caller's own session, any strand in it |
| Command line | `loom inspect <session> [--strand S] [--explain] [--events]` | owner, over the control socket | as the control socket |

`gateway.read_only` lists the three new commands as reads, so an observer may
issue them and the exhaustive `case` keeps the classification honest. The
control socket checks the owner and the epoch before it resolves the session,
exactly as protocol-change/049 does.

`cap/observe` is served by a router in the shape of `client/peers.router`:
`ServedHere` closures, the session taken from the launching identity and
never from an argument, and an admission ceiling of 32 calls per execution.
It is admitted on the default seam beside `cap/peer`, because what it reads is
the caller's own session.

An agent cannot observe another session. No operation in this proposal
grants that, and a later one that does needs an audit record first; Loom has
no audit store today (`docs/architecture/approvals.md` calls a missing audit
line "the accepted cost"), and a cross-session diagnostic grant without one
would be the first privileged read nobody can account for.

### Confidentiality

Every observatory type falls into one of three classes, decided by its
field types rather than by a filter at the edge:

| Class | Contents | Readers |
| --- | --- | --- |
| Identity | ids, strand names, generations, phases, counts, deadlines, ages, tool names, outcome kinds, pids, mailbox lengths, heap sizes | every reader above |
| Summary | the tool-argument summary from `tools/call_record.summarise` (allowlisted, at most 96 bytes) and the escalation preview the session already shows its members | every reader above |
| Never | argv, environment, working directory, policy, tokens, tool output, transcript text, provider request or response bodies, error text, mailbox contents, process dictionaries, actor state, stack traces | no one; no observatory type can hold them |

A test builds a session whose transcript, tool arguments, environment and
tool output carry a planted marker, runs every operation on every surface,
and asserts the marker appears in no reply, the way `executor_snapshot_test`
does for the executor's snapshot.

### Bounds

- A reply is at most 60,000 bytes, the `peers.inspect` budget. Lists that
  would exceed it are `Truncated`.
- At most 64 strands, 64 calls per strand, 16 processes per strand and 128
  events per page.
- One observatory request in flight per connection; a second is refused as
  `busy`.
- `cap/observe` admits 32 calls per execution.
- The ring holds 256 events per session. At an estimated 160 bytes for an
  event with three ids that is about 40 KiB; phase 1 measures it with
  `erts_debug:size/1` and records the figure here.
- The observatory performs no probes, so there is no trace, sampling or GC
  budget to bound.

### Trust boundary

```text
 agent (jailed program)        member client           owner CLI / TUI
        |                        |                          |
   cap/observe              session socket            control socket
 (own session only)      (own session, any role)    (any resident session)
        \                        |                          /
         +------------------ loomd (one node) -------------+
                                 |
                       client/observatory (per session)
                     durable state, driver, escalations,
                    executor snapshot, process_info/2 x4
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
failing the request. The operations, the classes, the bounds and the
explanation rules do not change. A hidden observer node that speaks to
`client/observatory` over distribution is a trusted-plane client like the
owner CLI, and the agent-facing surfaces keep reaching it only through the
session socket and `cap/observe`.

## What it costs

- One `process.send` per strand transition, request, tool call and
  escalation, to a per-session actor. Transitions happen per step, not per
  token, so this is a few sends per tool round.
- An estimated 40 KiB per resident session for the ring, plus one small
  actor.
- The strand driver gains a message and its state a generation. The drain
  ledger's claim reply changes shape (an internal type).
- `runtime/effects.Hooks` gains a field, so every construction of `Hooks`
  changes. `effects.default_hooks` supplies the no-op.
- One new `@external` for `process_info/2`, confined to
  `client/internal/ffi_process_info`, with the reason stated in the module.
- `gateway.phase_of` moves to a shared module so `Activity` and the existing
  `LiveOp.phase` cannot disagree.
- The prelude grows by `cap/observe`, so `make gen-prelude` runs and the
  `code_mode` description grows by a few lines.
- `protocol-change/065` gains the `observatory` role, and a process that
  pickglass groups under it.
- The command-line surface grows by `loom inspect`.

## Rollout

Phase 1 of #730, in this order, each a separate change:

1. Runtime: the generation from the drain ledger, the driver's `Observe`
   message, and the `Hooks.observe` slot with a no-op default. Tests: a
   restarted driver reports generation 2 under the same address; an `Observe`
   on a busy driver times out without blocking the caller.
2. `session_view/observatory`: the types, total decoders and `explain`, with
   property tests that an explanation never names a blocker the description
   does not contain and that any `Missing` input makes it `Partial`.
3. `client/observatory`: the actor, the ring, the composed reads, the
   `process_info` FFI, and the planted-marker test.
4. The three session-socket commands, the two control commands and `loom
   inspect`. Tests: an observer may read and not mutate; a stale `expect` is
   refused with the current values; a pid in a request is a `bad_request`;
   a saved session is never opened.
5. `cap/observe` and the regenerated prelude. Test: a program cannot name
   another session, and the 33rd call is refused.

## Points for the owner

- **Observers see runtime evidence.** Mailbox lengths and heap sizes go to
  every member, observers included. They reveal load, not content. If that is
  too much, the evidence fields become `Missing(Unsupported)` for an
  observer and nothing else changes.
- **`cap/observe` on the default seam.** That makes it available to every
  program, not only orchestration programs. Moving it to the orchestration
  seam is a one-line change if self-inspection should be reserved for
  programs that manage strands.
