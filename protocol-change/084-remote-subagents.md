# protocol-change/084: subagents on another orchestrator

**Status**: ACCEPTED 2026-10-16. Proposed 2026-10-09, with the direction ruled
by the owner the same day (transport, child shape, approvals, who spawns, and
the defaults). Phase 1 was simplified after review on 2026-10-11, and the owner
ruled the same day that remote children are detached by default (see "Turn end"
below). Phase 1 shipped in #960 and #969, with the spellings the sections below
give as built. The three failure cases the shipped test does not drive (the
laptop killed mid-spawn, the link cut mid-join, the parent's turn ended with the
link down) are covered by the P model
(`protocol/models/remote-subagents`, the cases `tcDrops`, `tcAbort` and
`tcRestart`), not by the shipped test. Phase 2 lands as dated addenda at the end
of this document, the first being `Release` (2026-10-16). Every spelling below
that an addendum has not built is still provisional.
**Affects**: the orchestrator port's closed message type (three constructors in
phase 1, `Spawn`, `Join` and `RunEnded`; `Release` and `ChildSend` in phase 2;
`ChildEscalation` and `Resolve` in phase 3), `loom.toml` (a `[spawners.<name>]`
table on the remote; the spawning daemon's `[orchestrators.<name>]` rows gain
no key, but a name may not contain `@` or `#`), the remote daemon's catalogue
(one table in phase 1, `delegate_sessions`, at the next version after 078 and
083; a spend table in phase 2), the model-facing `agent_spawn` (one argument,
`on`) and its handle text, `cap/strand` (one assignment field, phase 2), the
session's remote drainer (one field on `peer_outbox_drain.Options`, and a
second instance of the machine), and durable cells that are not Part 1
interfaces: the parent's `remote-child/` stubs, an
optional `orchestrator` on the lineage cell, and the delegate session's
`delegate/ended/` fences. `runtime/child_run.Stop` is unchanged in phase 1 and
gains three variants in phase 2. The client control protocol (Part 1.6) is
unchanged.
**Raised by**: the owner's question of 2026-10-09, whether an orchestrator on
a laptop can start and direct subagents on a remote orchestrator, "basically
via TLS distribution".
**Design**: [docs/design-notes/remote-subagents.md](../docs/design-notes/remote-subagents.md).
**Builds on**: [protocol-change/078](078-distributed-runtime.md) (remote
workspaces, pools, the orchestrator port, peer mail between orchestrators and
the sender outbox), [076](076-config-profiles.md) (profiles) and, where
present, protocol-change/083 on PR #934 (the Khepri directory). Phase 1 does
not need #934, and either order of landing is safe.

## Problem

A subagent is a strand in its parent's session. The parent session's Agency
mints its name from the parent's call site, records its lineage, enforces the
addressing rule, the depth and fan-out caps and the result contract, joins it,
and reaps it when the parent's run ends or its deadline passes. Every one of
those reads and writes one session store on one machine, so a model cannot
have a child that runs on another orchestrator, with that machine's checkout,
toolchains, provider keys or capacity.

Nothing in protocol-change/078 supplies it. An executor runs a session's tool
calls but holds no conversation; peer mail carries messages between sessions
that already exist; a move transfers a whole session. And the model cannot
create a session anywhere, because `sessions.create` is an owner command.

## What was considered

### Transport: the control connection with a scoped principal (rejected)

The laptop's daemon would be a client of the remote daemon over `wss`, the
endpoint the terminal uses, authenticated by a credential bound to a new
principal kind, `delegate`. The remote owner would create the principal with a
grant (placement, profile, tool ceiling, caps, deadlines, budget) and a
single-use claim, as `access.invite` does under protocol-change/053, and the
credential would authorize a `delegate.*` command family and nothing else. The
daemon already ships the client (`host/websocket`, `host/access`), and the
remote already authenticates principals and revokes credentials.

This is the stronger option, and it is recorded so a later reader knows it
exists. Its advantage is the trust boundary. The laptop never joins the
remote's distribution, so the remote's checks bind even a compromised laptop:
an attacker holding the laptop and its credential could do what the grant
allows and nothing else, could not read other sessions or reach the remote's
executors, and would be cut off by one `access.revoke`. Because the laptop is
the machine most likely to be compromised, this was the first draft's
recommendation.

The owner ruled against it on 2026-10-09, in favor of the distribution
transport below. The reasons on that side are these. The deployment already
trusts its orchestrators as Erlang peers, and a laptop that is to direct work
on the remote is being given that standing on purpose. The distribution path
reuses the orchestrator port, peer mail's `Endpoint` and failure split, and
the shape of its drainer, and the remote can deliver to the laptop over the
connection the laptop made, where the control path would have needed a second,
pull-only vocabulary for anything the remote has to tell the parent. And a
second authentication path between daemons, with its own principal kind, claim
flow, grant storage and total decoders for untrusted input, is a large surface
to build for one feature. If a deployment later needs spawners it does not
trust as peers, this option can be built beside the chosen one: the remote's
spawn handling is written against a spawner identity, so the control path
would be a second way to establish that identity.

### Transport: the orchestrator port over TLS distribution (chosen)

Spawn, join and run end become constructors of the orchestrator port's
`Message`, beside `Owns`, `PeerCommand`, `Import`, `ImportStatus` and
`Activate`. The laptop is a pinned distribution peer of the remote. A pinned
peer is fully trusted, as every peer in #923 already is, so the remote's spawn
policy bounds an honest peer and is not a security boundary against a
compromised one. Trust is symmetric: a compromised remote can equally call any
function on the laptop daemon, including its other sessions and keys. The
design note's section 5 states this in full.

### Delivery that must survive a failure: the peer outbox (rejected)

The first draft put `SpawnStatus` and `RunEnded` rows in the peer outbox. That
does not fit the code. `peer_outbox.Row` has a fixed shape (a sending strand,
a recipient session and exported strand, a message id and text). The drainer's
only action is `peers.resend`, which resolves a recipient and calls `Deliver`.
And `OutboxDue` settles any row older than an hour as refused. The remote
rows are therefore their own durable facts: the stub is the pending row for a
spawn. The drainer machine is generalised by one field and a second instance
runs over the stubs.

### A status query and a site fence (rejected)

The first draft let a spawn whose window ran out be settled by a `SpawnStatus`
message, with a per-site fence so that the status could not be overtaken by a
spawn from a killed process. Because the stub stores the request, the drainer
can resend the `Spawn` itself, and the remote's adoption on `minted_by` makes
every resend idempotent. Nothing queries, so there is nothing to fence. The
`delegate/ended/{op}` fence stays: it is what stops an orphan when a run is
aborted while a `Spawn` is in flight.

### Where the spawn policy lives

**A catalogue grant.** Durable, changeable at runtime, revoked by a command.
Rejected: under distribution, revocation means removing a pin and restarting
anyway, and every other peer-facing table (peers, executors, pools,
orchestrators) is configuration validated at boot.

**`[orchestrators.<laptop>.spawn]`.** The owner's suggestion, beside the
existing peer table. Not taken: under protocol-change/083 every
`[orchestrators.<name>]` node of a Khepri member daemon must itself be a
member, which would make a sleeping, roaming laptop hold a replica of the store
that decides session ownership. `[orchestrators]` also means whom a daemon asks
about sessions and to whom it may move them, which a spawner needs neither of.

**`[spawners.<name>]`.** A separate table whose node must be a pinned
distribution peer and nothing more. Chosen, and settled by checking the
membership rule in protocol-change/083 (design note, section 17).

### Where the spawn switch lives

A boolean on the spawning daemon's `[orchestrators.<name>]` row was in the first
draft. Rejected: it is a naked `Bool` (lint R9) and a second authority that can
disagree with the remote's policy. Every `[orchestrators.<name>]` row is a
valid `on`, and the remote's `[spawners]` table refuses with its reason.

### Shape of the remote child

**A strand in an existing remote session.** Rejected: the child would share a
session, its lineage namespace and its visibility with the remote's own owner
and members.

**One new session per child.** Rejected: each child would need its own store,
runtime and, on an executor, its own scope, of which an executor admits 16;
and lineage, caps and reaping would have to be rebuilt across sessions.

**One delegate session per (spawner, parent session).** Each child is a strand
in a session the remote creates for one parent session, and the remote's own
Agency mints and judges it. Chosen.

### Model surface: a new tool

Rejected in favor of an `on` argument to `agent_spawn`, so a remote child is
waited on, listed and reaped with the tools that already do so.

## Proposal

### Configuration

On the remote:

```toml
[spawners.laptop]
node = "laptop@100.64.0.5"        # one of [[distribution.peers]]
executor = "box"                  # or pool = "linux", or directory = "/srv/loom/scratch"
workspace = "loom"                # with executor or pool: a registered workspace
profile = "cheap-review"          # a [profiles.<name>] key
tools = ["fs_read", "fs_write", "fs_edit", "grep", "bash", "code_mode",
         "agent_note", "agent_send"]
max_depth = 1
max_sessions = 4
max_within_s = 14400
default_within_s = 1800
retain_s = 604800
# approval_ceiling = { ... }      # phase 3
```

| Key | Meaning |
|---|---|
| `node` | The spawning orchestrator's node, which must be a `[[distribution.peers]]` node. Two tables may not share a node. |
| `executor` and `workspace`, `pool` and `workspace`, or `directory` | Exactly one placement for every delegate session of this spawner. |
| `profile` | The `[profiles.<name>]` that seeds every delegate session. |
| `tools` | The tool ceiling. The default omits `agent_spawn`, the peer tools, `schedule_*`, `remember` and skill installation. |
| `max_depth` | The deepest child allowed, default 1, so children cannot spawn. It is never above the remote Agency's own `depth_cap`, 1 in phase 1: a remote child's own spawn is judged against that cap, so a larger value would hand the child a spawn tool it could never use. |
| `max_sessions` | Delegate sessions this spawner holds, default 4, at most 16, an executor's scope limit. The live children of one delegate session are bounded by the Agency's existing `fan_out` and `session_strands`, so the spawner's total is at most `max_sessions` times `session_strands`. |
| `max_within_s`, `default_within_s` | The deadline cap (default 4 h) and the deadline a spawn gets when it names none (default 30 min). |
| `retain_s` | How long a delegate session with no message from its spawner is kept before the boot sweep deletes it (default 7 days). At least `max_within_s`. |
| `approval_ceiling` | Phase 3: the grants the parent's operator may approve. Absent means none. |

Phase 2 adds `max_per_day`, `token_budget_per_day` and `child_token_budget`,
with their spend table. Phase 1 reports usage and does not meter it: the
usage hook runs on the strand driver and must never block.

The table requires `[distribution]`. The decoder refuses an unknown node, a
node shared with another table, a placement that does not resolve or that
names more than one, an unknown profile, a `max_sessions` above 16, a
`default_within_s` above `max_within_s`, and a `retain_s` below `max_within_s`.
A daemon with no `[spawners]` table accepts no spawns.

On the spawning daemon the `[orchestrators.<name>]` rows are unchanged, and
every one of them is a valid value of `on`. The decoder refuses an
orchestrator name that contains `@` or `#`, because a handle is parsed by
splitting on the last `#` and then the last `@`.

### The orchestrator port (`client/remote/orchestrator_port.Message`)

Phase 1 adds three constructors. `parent` is `{session, strand}` on the
spawning orchestrator; `caller` is the parent's `{operation, step_id,
source_index, minter}`, with `minter` either `ToolCall` or `Program(ordinal)`.

- `Spawn(parent, caller, depth, parent_tools, request, reply)`. `request` is
  `{purpose, brief, model, tools, within_ms, result_schema, detach}`, and
  `parent_tools` is the parent's active tool names, which the remote has no
  parent strand to read. The port resolves the sender's node to a
  `[spawners.<name>]` table, resolves or opens the delegate session for
  (spawner, parent session), and asks its Agency holder to admit the spawn.
  The holder checks the ended fence for `caller.operation`, derives the
  child's name from the caller with the parent strand rendered as the
  reference `^{strand}`, adopts an existing child only when its lineage cell's
  `minted_by` equals the caller's call site, and otherwise checks the policy
  and the Agency's caps and creates the child. The answer is
  `Ok(Spawned(handle, tools, model, model_id, remaining_ms))` or
  `Error(SpawnRefusal)`. A repeat from the same call site answers the same
  handle, which is what lets the sender resend until it is answered. Runs in
  a task linked to the port.
- `Join(parent, handles, within_ms, reply)` waits, as the Agency's `wait`
  does, for children of `^{parent.strand}`, for at most 25 000 ms. It answers
  one entry per handle in order: `Ready(handle, outcome, report, result,
  notes, usage)` or `Pending(handle, waited_ms)`. `usage` is the four token
  buckets and the cost, summed over the child's run and priced by the remote.
  Runs in a task linked to the port.
- `RunEnded(parent, operation, reply)` writes the ended fence for
  `operation`, then stops every child whose current run is owned by that
  operation, and answers how many it stopped. A repeat stops nothing more.

A message from a node no `[spawners]` table names is refused. A daemon with no
`[spawners]` table starts the port without a spawn host and refuses all
three, as a daemon that receives no sessions refuses `Import`. Unlike
`PeerCommand`, these messages may open a delegate session that is not
resident: it exists only to serve its spawner, and a join on a settled child
must be able to read its result after the session was closed.

`SpawnRefusal` covers: unknown spawner, the ended fence (`ParentRunEnded`),
the depth cap, the Agency's `fan_out` and `session_strands` caps and the
spawner's `max_sessions` (each naming its key), a tool outside the ceiling, an
invalid argument (including a `within_ms` above `max_within_s` and
`context: "mine"`), `NameAlreadyMinted`, and a failure of the remote's store.
As built in S1 (`client/remote_spawn`), the depth cap is one `Cap` beside the
other three (`CapReached(cap, limit)`), `UnknownSpawner` carries the sender's
node, and the sender's node is taken from the process that asked, since the
messages above carry no origin field. S1 had a temporary `Unimplemented`
refusal for a daemon with a matching spawner and no delegate session yet; S2
removed it. All three messages run in a task linked to the port, including
`RunEnded`, because it waits on the delegate session's Agency holder. As built
in S2, a `RunEnded` for a parent that has no delegate session yet creates the
session, counted against `max_sessions`, so that the ended fence exists before a
late `Spawn` for that run arrives.

Phase 2 adds `Release(parent_session, reply)`, which stops every child of the
delegate session, detached ones included, marks it released and deletes it
once its cleanup is proven, and `ChildSend(parent, child, message_id, text,
within_ms, reply)`, delivered through the remote Agency's `send` with a receipt
stored under the message id, so a repeat answers the receipt. Phase 3 adds
`Resolve(parent, escalation, decision, expected_seq, reply)`, admitted only
when every grant in the decision is inside `approval_ceiling`, and the
laptop's port gains `ChildEscalation(parent, child, escalation, reply)`, sent
by the remote.

### The sending end

Each call is made the way `remote_peer` makes a peer-mail call: connect to the
pinned peer if it is not connected, send to its `loom_orchestrator`, and wait
under a deadline (30 s for `Spawn`, the join window plus 2 s for `Join`, 7 s
otherwise). The result is `Result(answer, peer_mail.Failure)`: `Refused` for a
definitive answer, and `Unreachable` for `noconnection`, `noproc` or no answer
within the deadline. A spawn that is `Unreachable` is resent with a doubling
pause from 50 ms to 2 s until its 30-second window runs out, and never sent to
another orchestrator.

Phase 1 has no connection keeper. Every call connects on demand, and the remote
sends nothing to the laptop on its own. Phase 2, which adds messages the remote
originates, adds a keeper in the shape of #934's `directory/member`: while a
parent session holds a live remote child it reconnects to that remote every two
seconds when the connection is down.

### Records

On the spawning daemon, in the parent session's store:

- `remote-child/{site digest}`, reserved, is the stub and the pending row for a
  spawn. It holds the orchestrator, the derived name and the whole request
  (including the caller's coordinates, the depth and the parent's tool names),
  then the handle, then the settled outcome and usage, or the remote's
  refusal. A refusal is recorded on the stub whoever hears it, and the stub is
  never removed. Its state is `Requested`, `Spawned`, `Settled` or `Refused`, and it
  is written before the first `Spawn` is sent. `Requested` means pending.
- The lineage cell gains an optional `orchestrator`. A cell without it decodes
  as local. It is written when the spawn is answered.
- `peer_outbox_drain.Options` gains `pass: fn() -> Backlog`, and `Backlog`
  (`Owed` or `Clear`) becomes public. The current body is the peer-mail
  instance's pass. A second instance, under its own name in the same
  restartable service tier, has a pass over the stubs. It resends each
  `Requested` stub's `Spawn` every five seconds, skipping an orchestrator that
  did not answer earlier in the same step, and it sends one `Join` with a
  window of 0 for each (orchestrator, parent strand) group of `Spawned` stubs
  whose deadline has not passed, recording each `Ready` as `Settled` so that a
  child nobody waits on does not hold a fan-out slot. A pass is `Owed` while
  any stub is `Requested` or any child is running, and the instance goes idle
  when none is. `peer_outbox.Row`, `peers.resend` and `OutboxDue` are
  untouched. A stub is not refused after an hour; it is retried until the
  remote answers, because every message is idempotent and the child it
  concerns is bounded by its deadline. A `Spawned` stub counts against the
  fan-out caps only until its child's deadline passes, which is read from the
  stub and the clock with no message.

On the remote:

- `delegate_sessions(spawner, parent_session, session_id, last_contact_ms)` in
  the catalogue, keyed by `(spawner, parent_session)`. As built in S2 the table
  is `catalogue_delegate_sessions`, like the other catalogue tables, at catalogue
  version 15, with `session_id` unique and referencing `catalogue_sessions`. Phase 2 adds a `state`
  column of `open`, `releasing` and `released`.
- In each delegate session's store, under a reserved prefix that
  `api.put_fact` refuses: `delegate/ended/{operation}`, written by `RunEnded`
  before it reaps and read by spawn admission.

A delegate session is created through `manager.create_scoped` with the
`SessionOnly` domain, so it is created the same way with or without #934. A
`CreateStrandError` arm and a check in `create_strand` refuse a name that
begins with `^`, so the parent reference can never name a strand;
`CreateStrandError` has no invalid-name arm today, so the arm is new. Each
child's deadline is enforced on the remote's clock by the Agency's overdue
check and by a periodic timeout, for each open delegate session, of a
`weft/state_machine` that calls `reap_overdue`. A boot sweep deletes delegate
sessions whose last contact is older than the spawner's `retain_s`, or than the
default when the spawner's table is gone. A delegate session that is not open
is opened by the next `Join` or `Spawn` for it (`manager.open`), and runtime
recovery resumes its children; phase 1 has no boot-time reopen.

### The delegate session

An ordinary session of the remote daemon, owned by its owner, seeded from the
spawner's profile and placed by the spawner's placement with the
`session_only` memory domain. The manager's `movable` check answers
`not_movable` for it by one arm on a marker in the catalogue row. Refusing
members of a delegate session is phase 2, alongside the refusal of peer links
other than the upward grants below; until then the owner can open, read and
prompt it, so nothing is protected. Its only peer grants are the phase 2 upward
grants below.

A spawn from the port is judged by the same `spawn_on`, with a private `Source`
(`Local | Delegated`) threaded through the Agency. The caller is an ordinary
`Caller` whose strand is the reference `^main` and whose other fields are the
parent's call site. For a `Delegated` source, `spawn_on` and `reconcile`, which
read the parent's configuration, and `child_tools`, which takes the parent's tool
list, take both from the message: the configuration is the delegate session's
`main` strand, which the policy profile seeded, and the tool list is
`parent_tools`, narrowed by the request and the ceiling.

On the spawning daemon, `check_capacity` counts the parent's stubs that are
`Requested` or `Spawned` as live children of their parent strand, against the
same `fan_out` and `session_strands`. This is an explicit change: `is_live`
reads the local `strand.state`, which a remote child does not have. A parent
with a stub that is not `Settled` or `Refused` makes `sessions.move` answer
`not_movable`, checked in the mover's close step, where the session file is
already open.

### Upward messages (phase 2)

A remote child's `agent_send` to its parent is peer mail from the delegate
session to the parent session, through `peers.send`, its outbox row and its
drainer. The endpoint is `remote_peer.at` for the delegate session's recorded
spawner node, not a directory lookup. At spawn the parent's Agency writes the
peer grant for (delegate session, child strand) to (parent session, parent
strand) with `may_wake = false`, so the parent admits the message exactly once
by its id and only as a steer into an open run.

In phase 1 an upward send is refused without new code: its target `^{strand}`
is a strand with no state in the delegate session, so `send` answers
`ParentRunEnded`. Only the rendering is remote-aware, for a target that begins
with `^`.

### Model-facing changes

- `agent_spawn` gains `on`, an enum of every `[orchestrators.<name>]` key,
  offered only in sessions the owner holds alone
  (`manager.unshared_sessions`). With `on`, `context: "mine"` is refused,
  `within_ms` must be within the spawner's cap, and `model` names the remote's
  catalogue.
- A remote handle renders as `{strand}#{operation}@{orchestrator}`.
  `agent.parse_handle` reads the orchestrator after the last `@` that follows
  the last `#`.
- `agent_wait` accepts local and remote handles together under one deadline,
  with one `Join` per orchestrator within 25 s. `agent_roster` lists remote
  children from the stubs.
- In phase 1, `agent_send` to a remote child is refused with a sentence that
  names the result and the notes as the way to report, and a remote child's
  `agent_send` to its parent is refused with `ParentRunEnded` worded for a
  parent on another orchestrator.
- **Turn end.** Remote children are detached by default (the owner's ruling of
  2026-10-11, option (b) of the design note's question 3). `agent_spawn` with
  `on` sends the request detached whatever `detach` the model gave. When the
  parent's run ends, `reap_run(op)` stops the local children as ever, and
  nothing is sent to the remote: the laptop sends no `RunEnded` in phase 1. A
  remote child runs to its deadline, bounded by the retention sweep, and a
  later `agent_wait` on its handle reads the result. A laptop suspended in the
  middle of an `agent_wait` has not ended the run: only the in-flight `Join`
  task is cancelled. The port's `RunEnded` message and the delegate session's
  ended fence stay as S2 built them, because phase 2's `Release` reuses them.
- `cap/strand` gains `with_on` on the assignment (phase 2).
- `child_run.Stop` gains `Released`, `SpawnerRemoved` and `TokenBudgetSpent`,
  and `tools/agent.Outcome` gains the matching variants, in phase 2. A record
  written before this change decodes as before.
- Remote usage, recorded on the stub, counts against the parent goal's token
  budget.

### Phasing

Phase 1 has five slices, each of which lands on `origin/main` alone.

- **S1. Policy and messages.** The `[spawners.<name>]` decoder with the keys
  above; the `@` and `#` refusal in orchestrator names; `Spawn`, `Join` and
  `RunEnded` with `SpawnRefusal`. Tests: decoder fixtures and a port unit test
  with a fake host.
- **S2. The delegate session and remote Agency.** The `delegate_sessions`
  table and the session created through `manager.create_scoped(SessionOnly)`
  on the first `Spawn`; a `Source` through `spawn_on` and
  `reconcile`, with the caller an ordinary `Caller` for `^main`; the `^` prefix refusal; the `delegate/ended/{op}` fence, read at
  admission and written by `RunEnded` before `reap_run`; `Join` as `wait` plus
  usage. Tests: in-VM Agency tests.
- **S3. The laptop side.** The stub written ahead and the lineage cell with
  `orchestrator`; `check_capacity` counting stubs; the parameterised drainer
  with a second instance; `agent_spawn` with `on`, `agent_wait` over mixed handles, `agent_roster` from
  stubs; `context: "mine"` refused; the upward refusal wording. Tests:
  simulated-session tests with a fake endpoint. As built, the Agency asks through
  `client/remote_reach.Reach`, a record of two functions, `spawn` and `join`, because the
  orchestrator port sits above the Agency in the module graph;
  `client/remote/remote_spawner` fills it. The handle's `@{orchestrator}` suffix
  is parsed and dropped, and a wait finds a remote handle in the parent's own
  stubs. Every refusal leaves the stub `Refused` with the
  reason, wherever it is heard. Remote children are always detached, the laptop
  sends no run end, and the drainer settles children that finish unwaited by a
  zero-window `Join`. Remote usage is recorded on the
  settled stub; counting it against a goal is not built, and refusing
  `sessions.move` for a parent that holds a live stub is built in S6 (see the
  addendum of 2026-10-16). The design note's section 15 lists
  the differences.
- **S4. Deadline tick and retention.** The per-delegate-session periodic timeout
  calling `reap_overdue` (as built, on the Agency holder actor), and the boot
  sweep that deletes delegate sessions idle past `retain_s`.
- **S5. A shipped two-orchestrator test and the P model.** The test is modelled
  on `daemon_shipped_peer_mail_test`: three children spawned, joined, with
  structured results and usage; the laptop killed mid-spawn; the link cut
  mid-join; the parent's turn ended with a child running and the link down, the
  child outliving the turn. The P model holds `AtMostOneChildPerSite` and the
  drainer's settling liveness; the run-end specs wait for a sender in phase 2.
  This document moves to ACCEPTED when S5 is green.

  As built, the P model is written and checked (`protocol/models/remote-subagents`,
  eight mutants caught) and the shipped test
  (`daemon_shipped_remote_subagents_test`) drives three remote children through a
  ledger-provisioned pair of daemons: a join, a child that outlives the turn, and
  a deadline stop by the box's tick. It does not drive a `RunEnded` stop, which
  has no sender in phase 1, or the laptop-killed, link-cut and link-down cases.
  The model covers them (`tcDrops`, `tcAbort` and `tcRestart`), and the status
  is ACCEPTED as of 2026-10-16.

Phase 2 adds `Release` and its daemon-level drainer, `SpawnerRemoved`, the
boot-time reopen, the open-time `RunEnded` repair, metering on the remote
(`spawner_spend`, `token_budget_per_day`, `child_token_budget`, `max_per_day`,
`TokenBudgetSpent`, handed off with `spawn_unlinked`), the keeper, `ChildSend`
with receipts, upward peer mail with the `BusyOnly` grant, `with_on` in code
mode, and the two upward specs. Phase 3 is `approval_ceiling`,
`ChildEscalation` and `Resolve`.

Phase 4's observation of a remote child, its glance on the parent's agent strip
and a page of its transcript read with `ChildHistory` behind
`[spawners.<name>] transcript`, is its own proposal,
[protocol-change/090](090-remote-observation.md), because it ships transcript
content across orchestrators, which this proposal did not propose to do.

## What it costs

**No boundary against a compromised spawner or remote.** A spawner is a pinned
distribution peer and can call any function on the remote, so the spawn policy
binds only an honest peer. Trust is symmetric, so a compromised remote can
equally call any function on the laptop daemon. This is #923's assumption for
every orchestrator, extended to a laptop. A spawner's bundle must be guarded
like an orchestrator's, and cutting a compromised one off means removing its
pin from every node and restarting them.

**Provisioning.** A laptop needs a provisioned bundle. Provisioning is
one-shot today, so adding a spawner to an existing deployment reprovisions
every node.

**The port does longer work.** `Spawn` can open a session and `Join` waits up
to 25 seconds, so both run in tasks off the port's loop, as `Activate` does. A
spawn still takes the delegate session's holder, so many spawns from one
parent serialize there, as local spawns serialize in the parent's holder.

**Each delegate session on an executor holds a scope,** so a spawner's
`max_sessions` takes capacity from the remote's executors.

**Phase 1 does not meter tokens on the remote.** Deadlines, `max_sessions` and
the delegate Agency's caps bound the work in time and width, not in tokens.
Metering needs a hand-off off the strand driver and is phase 2. Because remote
children are detached, a child that nobody waits on or releases runs to its
deadline, at most `max_within_s` (4 hours by default), and spends what it
spends until then.

**Without `Release`, a deleted parent session leaves its remote children until
their deadlines,** at most `max_within_s`, and the delegate session until the
retention sweep.

**A remote child outlives its parent's turn.** Ending a turn does not stop it,
and a model that forgets to wait leaves it running to its deadline.

**Upward messages (phase 2) are weaker than local ones** when the laptop is
disconnected. A child that sends while the laptop is unreachable is told the
message was queued, and a later delivery that finds the parent idle is refused
and recorded on the child's outbox row rather than told in the child's turn.

**Usage is reported by the remote** and recorded on the stub, not metered by
the laptop. The laptop's provider usage ledger keeps recording only requests
the laptop made.

**Version skew.** As on the rest of the port, a message the remote cannot
match crashes the port, so both ends are upgraded together.

The formal model is a new P model, `protocol/models/remote-subagents`, with
the specs and mutants listed in the design note's section 14. It is phase 1
acceptance work, and `make model-check` would run it.

## Decision

Direction accepted by the owner on 2026-10-09: TLS distribution over the
orchestrator port with #923's trust model, a strand in one delegate session per
(parent orchestrator, parent session), approvals by the parent's operator
within the remote owner's ceiling in phase 3, spawning only from sessions the
owner holds alone, and the defaults above. `[spawners.<name>]` over
`[orchestrators.<laptop>.spawn]` is settled by the membership rule in
protocol-change/083. The owner ruled on 2026-10-11 that ending a turn
does not stop remote children: they are detached by default and bounded by
their deadlines. One point remains for the owner (design note, section 17):
accepting one-shot provisioning for adding a laptop. Phase 1 shipped in #960 and
#969, and this document is ACCEPTED as of 2026-10-16.

## Addendum 2026-10-16: `Release` (phase 2, slice S6)

This records what slice S6 built, and where it differs from the proposal above.
The proposal spelled `Release(parent_session, reply)`, a reuse of the `RunEnded`
handler, and a delete of the delegate session by the retention sweep alone.

### The message

`orchestrator_port.Message.Release(parent, reply)` carries the `Parent` that
every other message carries, and only its session names what is released. The
answer is `Result(Int, SpawnRefusal)`: the number of children the box stopped.
The pieces on each side are `ask_release` and `remote_spawner.release_over`
(sending), `SpawnHost.release` (judging the sender against `[spawners]`, as for
the other messages), `delegate_host.releaser` (the serving function),
`agency.DelegateEndpoint.release` (the Agency's closure) and
`remote_reach.Reach.release` (the laptop's record of functions). It runs in a
task linked to the port, as the other three do.

A `Release` for a pair with no delegate row answers `Ok(0)` and creates nothing.
That is the opposite of `RunEnded` as built, whose handler resolves the pair
through `delegate_host.resolver` and creates a session so that the ended fence
exists before a late `Spawn`. A release that did the same would create a session
only to delete it, and would count against `max_sessions` meanwhile, so
`delegate_host.resolve_existing` is a separate path that reads the pair's row and
finds the Agency only for a session that is open and resident. A closed session
holds no running child, so the box neither opens it nor asks it anything.

### The box

The row gains a `state` column (catalogue version 16): `open`, `releasing` or
`released`. A state only moves forward. The sequence for one `Release`:

1. The Agency's holder writes `delegate/released`. This is a fence on the whole
   session and not on one operation, in the same reserved prefix as
   `delegate/ended/{operation}`. `admit_run` reads it beside the operation fence,
   on the create path and after adoption, so a resent `Spawn` that already landed
   is still answered with the child it made, and a new child is refused as
   `ParentRunEnded`.
2. The holder stops every child that is running, whoever owns it, with
   `child_run.Stop.Released` and `tools/agent.Outcome.Released`. Both decode only
   the words they know and every older row still decodes. The count is of runs
   nobody had stopped, so a repeat answers zero. A parent that has been deleted
   has no run left to own anything, which is why this is not a loop over
   `reap_run`.
3. The registry (`manager.release_delegate`) marks the row `releasing` and stops
   the session's slot. From then on `delegate_session` refuses a message for the
   pair as `ParentRunEnded`, so nothing opens the session again. The session and
   its row are deleted when the slot has drained, which is when the row moves to
   `released` and the registration is removed together with it. A closed session
   is deleted at once.

A repeat of `Release` answers `Ok(0)` without asking the Agency, and hands the
session to the registry again, which finishes a deletion that failed. A row that
stays `released` is a deletion that failed after the slot drained, and the
retention sweep removes any delegate session that is not `open` and has no slot,
whatever its age. Deleting the session removes everything stored under it: its
conversation, and with it the facts, the outbox rows and the remembered
permissions that later phases keep there.

A `Release` can reach the box before the `Spawn` it concerns, because the two
come from different processes. The box then has no session to delete, answers
zero and creates nothing, and the `Spawn` that follows makes a session, which
the child's deadline and the retention sweep bound. The sender cannot do better
without the box remembering a deleted session, which would be a table that grows
without bound.

### The laptop

Deleting a session (`manager.delete_session`, and the directory's finishing of a
delete) first reads the stubs from the closed session file
(`remote_release.stubs_at`), takes the orchestrators of every stub that is not
`Refused` (`remote_child.holders`), and writes one row for each into
`catalogue_remote_releases(parent_session, orchestrator, written_ms)`, a new
catalogue table in version 16 that names no registration. It does this in the
registry's turn and before the registration is removed. A crash between the two
is safe in both orders: rows without a deletion release a pair that still holds
its session, and a deletion without rows is the bound of phase 1. A file that
cannot be read owes nothing, because such a session could not have been waited
on. A catalogue that cannot take the rows refuses the deletion.

The rows are drained by a third instance of `peer_outbox_drain`, one for the
daemon and not for a session, which `daemon/main` starts beside the port
(`start_release_drain`). The registry rings it when a deletion writes a row, as
it sleeps while nothing is owed. A pass sends each orchestrator `Release` for its
rows and settles a row on `Ok` or on a definitive `Refused`. A `StoreFailure` from the box (a registry timeout, a session still opening, a failed deletion) is not definitive: `release_over` reports it as `Unreachable`, so the row stays and the next pass sends again. An orchestrator that is removed
from the configuration is a refusal and so settles its rows. `Unreachable` leaves
the row and the orchestrator is not asked again in the same pass. The retry is
the drainer's fixed five seconds, and the first attempt comes one interval after
the deletion. A row has no time to live, which is longer than
`spawners.default_retain_s` on every box, because the thing it concerns lives as
long as the longest deadline plus that retention.

### Moves

`sessions.move` refuses a parent that has a stub that is `Requested`, or
`Spawned` with a deadline that has not passed, because the child reports to this
orchestrator by name and a third one would be unreachable for it. The check is in
the session mover, after the slot has drained and before the close step, because
that is the first moment the file can be read without a writer holding it. The
move ends as `Aborted` with a reason that begins `not_movable` and names the
orchestrator, and it is not the synchronous reply of the command.

### The model

`protocol/models/remote-subagents` gains the release row, the session's three
phases, `eRelease`, and the specs `ReleasedSessionHasNoRunningChild`,
`ReleaseMakesNoSession` and `EveryReleaseIsTold`. The last is the property the
design called `EveryEndedRunIsTold`, with `Release` in place of `RunEnded`. Three
mutants are caught: a release that reaps without the fence, a drainer that
settles a row on an unreachable call, and a release that creates a session.

## Addendum 2026-10-16: retention and spawner removal (phase 2, slice S7)

`[spawners.<name>] idle_close_s` (default 3600, at least 1) is the one new key.
The retention sweep now runs every hour as well as at boot
(`daemon/main.start_delegate_sweep`, a weft periodic). It deletes a delegate
session without a slot when its spawner's table was removed, whatever the
session's age, and it closes, without deleting, a resident open session that
has no child with a run and has had no message for `idle_close_s`. A resident
delegate session never hibernates, so without the hourly pass an idle one holds
an executor scope until the daemon restarts. The next `Spawn` or `Join` reopens
a closed session. No `SpawnerRemoved` stop is added: nothing runs in a session
that is not open, so there is no child to record a stop for.

The close is a compare-and-close in two registry turns, with the question about
the session's children asked between them, outside any turn. The second turn
stops the session only if its row's `last_contact_ms` is still the value the
first turn read, because a `Spawn` or `Join` moves it in a registry turn before it
reaches the Agency. One window remains: a `Spawn` that arrives while a closed
session is draining finds the slot stopping and is refused as
`StoreFailure("the delegate session is stopping")`. The spawner's next attempt
reopens the session. No further refusal is added for it.

## Addendum 2026-10-16: metering (phase 2, slice S8)

Three optional keys on `[spawners.<name>]` bound what a spawner's children spend
on this machine: `token_budget_per_day` (tokens, input plus output, over a
rolling day), `max_per_day` (spawns admitted over the same day) and
`child_token_budget` (tokens of one child). An absent key bounds nothing, which
is phase 1 behaviour, and a present one is a positive integer. A spawner that
sets none is unmetered: nothing is recorded or judged for it.

### The spend table

Catalogue version 17 adds `catalogue_spawner_spend(spawner, hour_bucket, tokens,
spawns)`, one row per spawner and hour, the hour being Unix milliseconds divided
by 3,600,000. A rolling day is the 24 newest buckets. A write adds to the
current bucket and prunes the spawner's expired ones in the same transaction, so
the table stays bounded without a sweep. The rows name no session and outlive
the delegate sessions they were made in. Tokens are recorded only for a spawner
that sets `token_budget_per_day`.

### Admission

A new spawn is refused when the day's tokens have reached
`token_budget_per_day` or the day's spawns have reached `max_per_day`, as
`SpawnRefusal.CapReached(cap: TokensPerDay | SpawnsPerDay, limit:)`. The Agency's
holder makes the claim, because only the holder can tell a resent spawn from a
new one. It calls the closure `Config.claim` (the daemon's
`manager.claim_spawn`) only when the call site has no child yet, the ended and
released fences have passed, and the child is about to be created. A resent
spawn is adopted before any claim, so it is answered with its child, is not
counted, and is not refused even at the cap.

The claim is one registry message, `ClaimSpawn`. In one turn it reads the
spawner's last 24 buckets, judges both caps and counts the spawn, touching only
the catalogue connection the registry already owns. It calls no session, and the
registry never waits on a holder, so the holder waiting on it cannot deadlock.
Two claims see each other because the registry handles one message at a time.
The holder bounds the wait by `holder_timeout_ms`. A claim that goes unanswered
is a `StoreFailure`, which the laptop retries, and never a cap. Only a spawner
that sets `token_budget_per_day` or `max_per_day` has a claim; one with only
`child_token_budget` writes no spawn counts. A spawn that is claimed and then
refused further in (a depth cap, say) still counts, which errs toward the cap.

### The child budget

A delegate session of a metered spawner wraps its usage slot
(`agency.metering_hooks`). The slot's only work on the strand driver is one
`process.spawn_unlinked`. That process reports the request's tokens to the
registry and, when `child_token_budget` is set, reads the child's total from the
usage ledger (`child_usage.of_strands`) and sends the holder
`StopChild(strand, TokenBudgetSpent)`. The holder records the stop and aborts the
run through `reap`, as for every other stop. The child overshoots by at most the
request that crossed the budget. `child_run.Stop` and `tools/agent.Outcome` gain
`TokenBudgetSpent`, written `token_budget_spent`; every decoder keeps accepting
older rows, and a model reading a wait sees an aborted outcome with that reason.

### The laptop

A goal's token budget counts the settled remote children. The goal cell gains
`remote_tokens`, the part of `tokens_used` that remote children account for. It
is a total beside the ledger cursor: an evaluation adds the growth of the sum
over the settled stubs, so recomputing adds nothing, and a goal that is pinned,
replaced or resumed starts the figure where it stands. A cell without the field
reads as zero.

The full snapshot gains an optional `remote_usage`, a list with one entry for
each orchestrator (`orchestrator`, `input`, `output`, `cache_read`,
`cache_write`, `cost`). It is omitted when empty, an old client ignores it, and
an absent field decodes to no entries. The terminal shows it in the footer and
the session tab, and the web view lists it after the context breakdown, each
labelled by orchestrator.

## Addendum 2026-10-17: messaging and `with_on` (phase 2, slice S9)

This records what slice S9 built, and where it differs from the proposal above and
from the design note's section 8.6. The proposal had a child's upward message go
through peer mail with a grant written at spawn. It cannot: `peers.send` first
requires an operator-authorized outgoing link on the sending session, and a box's
`default_tools` excludes the `peer_*` tools, so a child could neither link nor
send. The owner ruled on 2026-10-16 that traffic from the box is pushed over a
connection the laptop keeps up, and that the mechanism is an outbox row, not a
peer link.

### The link keeper

`client/remote/link_keeper` is a daemon-level `weft/state_machine`, one for each
`[orchestrators.<name>]`, started by `daemon/main.start_link_keepers` beside the
orchestrator port and reached by a `weft/registry` address that outlives a restart
of the keeper. It is `Idle` or `Holding`. A session's remote drainer votes `Hold`
or `Drop` through `Reach.keep`; the keeper monitors each voting process and drops
a voter that dies. While it holds, a periodic of two seconds asks
`distribution.is_connected` and calls `distribution.connect` only when the node is
not connected. Nothing is persisted. `remote_drain.pass` votes at each pass, which
runs at session open and every five seconds while a child runs, so a restarted
daemon has its votes again within one pass. The vote is per orchestrator: `Hold`
for each one with a stub that is `Requested`, or `Spawned` with a deadline that
has not passed, and `Drop` for each of the others. The votes are in the machine's
data and not in the `Holding` state, because a state that changed with every vote
would re-arm the beat. An orchestrator enrolled after the daemon started has no
keeper until the next start, and a vote for it is dropped; its calls still dial on
demand.

### The messages

`orchestrator_port.Message` gains three constructors.

| Constructor | Direction | Key | Admitted by |
| --- | --- | --- | --- |
| `ChildSend(parent, child, message_id, text, reply)` | laptop to box | `message_id`, the sending call site's digest | the delegate Agency's `send`, with the receipt `delegate/receipt/{id}` committed with the delivery |
| `ChildMail(parent, child, message_id, text, reply)` | box to laptop | `message_id`, the child's call-site digest | the parent Agency's holder (`AdmitChildMail`), which steers the parent strand and writes `remote-mail/{id}` in one commit |
| `ChildProgress(parent, child, glance, reply)` | box to laptop | `(child, glance.at)`, older ignored | a compare-and-set of `Stub.glance` |

`ChildSend` is served through `SpawnHost.send` and runs in a task linked to the
port, as the other four do. The other two are served through a new `ChildHost`
record, `daemon/main.child_host` (`refusing_children()` for a daemon with no
`[orchestrators]`, which answers every message `OriginMismatch`). `start_with`
takes it as one more argument. Each runs `detached` and carries the `Origin` of
the process that sent it. The host refuses a message whose node is not the
configured node of the orchestrator the parent's stub names: the Agency finds the
stub and asks the daemon's `admits(orchestrator)`, so the Agency never learns the
roster and the roster never learns the stub.

`remote_mail.ChildRefusal` is `UnknownChild | ParentSessionNotOpen |
OriginMismatch | Busy(reason) | StoreFailure(reason)`. `ParentSessionNotOpen` and
`Busy` are worth asking again; `Busy` is a laptop whose holder was not up, did not
answer, or whose store write failed, so nothing was decided. `StoreFailure` is
final: an id reused for other content, a message beyond its bounds, a corrupt
receipt. `Receipt` is `Delivered | Declined(reason)`, and a `Declined`
receipt is final: a parent with no run open is never woken for a child's message.

**Key on the name, never on the handle.** The laptop writes the stub in the
holder before the first `Spawn` leaves, and the stub records the child's derived
name. So every message about a child finds a stub in whatever state, and the host
keys on `Stub.name` and the parent strand. It admits `ChildMail` against a
`Requested` stub, which has no handle, and the answer to the `Spawn` that arrives
later agrees with it. A `ChildProgress` for a stub in any state is kept on the
stub (`Stub.glance`, a new optional member), and `spawned` writes the state
without touching it. Nothing on this path reads the lineage cell, which is written
only with `Spawned`.

### The box's outbox

A delegate session keeps `delegate/outbox/{kind}/{key}` rows in its own store:
`mail/{message id}` for a child's upward message, and `progress/{strand}` for the
`at` of the newest glance the laptop acknowledged. A glance from the box is cut to the bounds a local glance has before the stub
keeps it. A progress message has no row,
because the glance it carries is already the durable `client/glance/{strand}`
fact. A second `peer_outbox_drain` instance per delegate session runs
`delegate_drain.pass`, rung when a row is written and when a child is admitted,
and ticking every five seconds while a row is pending or any child has a run.
(The pass is in `delegate_drain` and the rows are in `delegate_outbox` because the
Agency writes the rows and cannot import the drainer.)

**The no-dial rule.** A row rings the drainer with `peer_outbox_drain.ring`, which runs a pass at once
where `poke` arms one a retry interval away (the release drainer rings the same
way). The pass asks `Laptop.connected`, which reads the
connection set. With no connection it sends nothing, makes no attempt and reports
what it owes, so a laptop behind a NAT costs the box one read a tick. The box
learns the laptop's node from `[spawners.<name>] node`, never from a message.

**The TTL rule.** A mail row is settled by an answer and never by age. A receipt
settles it as `Answered(Delivered)` or `Answered(Declined(..))`, and a definitive
refusal as `Refused(reason)`. Silence and `ParentSessionNotOpen` leave it
pending. A settled row stays, as the record the child can read back, and goes
with the delegate session on `Release` and in the retention sweep. A glance the
laptop did not acknowledge is sent again only as the newest glance, so an
intermediate glance lost to a disconnect is never resent.

A child that finishes before its mail is delivered would drop the laptop's vote,
so `Joined.Ready` carries `owed`, the number of the child's mail rows the box has
not settled. The laptop records it on the stub (`Stub.owed`), keeps voting `Hold`
and keeps joining the settled child while it is nonzero, within an hour of the
child's deadline, and drops the vote when a join reads zero. The keeper waits
longer after a connect that fails to bring the node back, doubling from two
seconds to thirty and resetting when it is up.

### Upward mail

When `Config.spawner` is `Some` (the daemon sets it from the session's catalogue
row, as it does `deadline_tick_ms`), a remote child's `agent_send` to its parent
reference writes the mail row and answers `queued`. No peer link is written and
`peers.send` is not used; the authorization is the spawn, which is the correction
to the proposal. Without a spawner link the same send is refused as in phase 1.
`tools/agent.Delivery` gains `Queued`, written `queued` in a tool result and in
`strand.send`, for a message recorded for an orchestrator that is away.

### Downward sends

A parent's `agent_send` to a remote child asks the child's orchestrator through
`Reach.send`. The box delivers through the delegate Agency (`delegate_send`) and
stores the receipt, so a resend answers `Admitted`. A child with an open run takes
the message as a steer. An idle child starts a run that is detached (a run of a
child whose parent is a reference has no owner: `child_owner` returns none for a
parent beginning with `^`) and bounded by the child's existing deadline: the run
record gets the absolute deadline the spawn gave the child, not a fresh budget,
so any number of sends cannot lengthen the child's life. A send after that
deadline is refused by the box (`ReadFailed`, "the child's deadline has
passed") and, earlier, by the laptop, which knows the deadline from the stub. `within_ms` on a send to a remote child
is refused. An `Unreachable` send writes `remote-send/{message id}` on the laptop
and answers `queued`; the third step of `remote_drain.pass` resends it and removes
it on any answer. A handle for a later run of a remote child belongs to the child's
stub by its strand, so a wait on it joins on the box. `agency.refuse_remote_child`
is gone.

### Reserved prefixes

On the laptop, `remote-mail/` (a receipt for each message a child sent) and
`remote-send/` (a send nobody answered) join `remote-child/` as keys the model
cannot write. On the box, `delegate/outbox/` and `delegate/receipt/` are corners
of the existing `delegate/` reservation. A model that could write one could mark
mail it never received as delivered, send text to a child under the parent's name
without a tool call, or settle an outbox row to hide that its mail was never
delivered.

### `with_on`

`cap/strand.Assignment` gains `on` and `with_on`, the wire value carries `on`, and
`orchestration.decode_spawn` reads it, so a foreground code-mode program can place
a child. A background program, and a workflow step, stay refused with the words
the tool gives.

### Not built in this slice

`ChildEscalation` and the `escalation/{id}/{seq}` outbox kind belong to phase 3.
The key space is open for them. The P model's three new specs are
`UpwardAtMostOnce`, `UpwardOnlyIntoOpenRun` and `EveryMailAnswered`, with
`MailFindsItsStub` for the rule that mail finds a `Requested` stub. Four mutants
are caught: admitting without a receipt, a policy that may wake the parent, a row
settled without an answer, and a host that keys on the handle. The model assumes
fair reconnection and a parent session that is eventually opened, and says so.

## Addendum 2026-10-17: approvals (phase 3, slices S10 and S11)

[protocol-change/089](089-remote-approvals.md) records what these slices built,
because they touch the client control protocol (`EscalationRecord.placement` and
`admitted`), which this document leaves unchanged. Where it differs from the
proposal above and from the design note's section 11:

- The ceiling is `[spawners.<name>.approval_ceiling]`, a table with one key for
  each constructor of `broker/policy.Grant`, and not the inline value the
  proposal sketched.
- `ChildEscalation(parent, child, record, reply)` carries the protocol's own
  `EscalationRecord`, with the grants the ceiling admits, and is sent from the
  `delegate/outbox/escalation/{id}/{seq}` row the S9 drainer owns. The laptop
  files it under `remote-escalation/{orchestrator}/{id}`, not under its own
  `escalation/` prefix, which the session's tool clearance spends.
- `Resolve(parent, child, escalation_id, decision, expected_seq, decided_by,
  reply)` replaces the proposal's `Resolve(parent, escalation, decision,
  expected_seq)`. The decision is `Approve(grants, action, scope)`, `Deny` or
  `Forget(grant)`, and the box judges it through the delegate session's hub.
- A session-scope approval is remembered in the delegate session with `Spawner`
  provenance and re-checked against the ceiling when the session opens.
- The P model is unchanged. 089 says why.

## Addendum 2026-10-17: depth across machines (phase 4, slice S13)

This records what slice S13 built. A child on the box may now start children of
its own, in its delegate session and on a third orchestrator. Phase 4 also
proposed several placements chosen by name; the owner ruled to defer them, so a
spawner still has exactly one placement.

### Depth

`max_depth` counts from the spawning orchestrator's own strand, which is depth 0,
so a child on the box is at depth 1. The `Spawn` already carried the parent's
depth, and nothing on the wire changes: a grandchild's `Spawn` carries the depth
of the child's lineage cell, 1, and the third orchestrator judges the grandchild
at depth 2 against its own spawner's `max_depth`.

The daemon now sets a delegate session's Agency `depth_cap` to its spawner's
`max_depth` (`daemon/main.depth_cap_of`, beside `deadline_tick_of`, carried as
`serve.Settings.depth_cap`). Every spawn in the session is judged by that figure:
a delegated spawn, a child's local spawn and a child's spawn elsewhere. A
delegate session whose spawner was removed keeps the default of 1.

The proposal said `max_depth` is never above the remote Agency's `depth_cap`,
and the code took `int.min(max_depth, depth_cap)` without saying so. The clamp
stays and is documented, not refused: with the cap set from `max_depth` the two
are equal in a daemon, so the clamp never binds there. It binds only for a host
that builds the Agency with another cap, where it keeps the tool a child holds
and the limit its spawns meet the same. A decoder refusal would have had nothing
to refuse once the cap follows the table.

### The spawn tool

`spawners.default_tools(max_depth)` holds `agent_spawn` exactly when
`max_depth` is above 1. A ceiling the owner writes is kept as written. A
delegated child that asks for no narrowing keeps the spawn tool its ceiling-clamped
parent tools hold (`agency.child_tools`), where a local child's default drops
it; a child at the limit loses it either way.

### `spawn_on`

`[spawners.<name>] spawn_on` is a list of this daemon's `[orchestrators.<name>]`
keys on which a child of the spawner may start a child of its own. It defaults to
none, and a nonempty list under a `max_depth` of 1 is refused, because no child
there could use it. Names are checked for their grammar and not against the
file's orchestrators, since in ledger mode the ledger supplies rows the file
never writes. The key is in `spawners.row`, `docs/configuration.md` and so in
`make doc-check`.

A delegate session's `Reach` is now `remote_spawner.over_distribution` narrowed
by `remote_reach.restricted(spawn_on)`: only the listed names are offered, a
spawn on any other is refused as not configured, and `offered` is the policy's
answer, true when the list names one. It is not `manager.unshared_sessions`,
because a delegate session is held by the box's owner alone and that test would
offer every orchestrator. Join, send and release are not narrowed, since they
concern a child a stub already records.

The slice's plan said a delegate session's reach was `none` because
`agency.delegate_endpoint` trims `remote`. The trim is on the endpoint the port
calls, not on the session's seam: the seam had the daemon's ordinary reach, with
the owner test, and only the missing spawn tool kept a child from using it.

### The grandchild

The grandchild's parent is the delegate session, so the third orchestrator sees
the box as its spawner and holds a delegate session for the pair (box, delegate
session). The stub, the lineage cell, the remote drainer and the link keeper are
the ones a laptop uses, unchanged. The third orchestrator needs a
`[spawners.<name>]` table for the box's node.

A grandchild may not outlive its parent (`agency.within_parent`). Its budget is
the smaller of what it asked for and what its parent's deadline leaves, and a
parent past its deadline may start no child. A spawn on a third orchestrator that
names no budget is sent the remainder, since the box does not know the third's
default; a third orchestrator whose `max_within_s` is below that remainder
refuses it. The wire does not change for this: the refusal names both figures,
the `within_ms` it was sent and its own limit in milliseconds
(`remote_spawn.over_cap`), so the model can ask again with a budget that fits
in one step. A grandchild in the
delegate session is also capped at the parent's absolute deadline when its
lineage cell is written. The same rule holds for any strand with a deadline that
spawns, and a strand a human talks to has none.

Metering is per hop. Each orchestrator meters the children that run on it
against its own spawner's budgets, and counts what it can see: the box counts
the child's tokens, the third orchestrator counts the grandchild's, and neither
adds the other's.

### The release cascades

`Release` of a delegate session now reaches its children's children:

1. The holder writes the released fence and stops the children, as before.
   `admit_remote` now reads the released fence before it writes a stub, so a
   stopped child starts nothing elsewhere.
2. The registry deletes the session once its slot has drained, as before. In
   that turn, before it removes the registration, `manager.delete_delegate`
   reads the stubs from the closed file (`remote_release.stubs_at`, in a task
   with a deadline so a faulty file costs the turn a bound), and writes one
   `catalogue_remote_releases` row for each orchestrator a stub that is not
   refused names, with the delegate session as the parent session, then rings
   the release drainer. These are the rows a laptop's deletion writes, and they
   outlive the session they name. The retention sweep's deletion of a delegate
   session does the same.
3. The daemon's release drainer, which every daemon with distribution starts, so
   also one that is both a spawner's target and a spawner, sends the third
   orchestrator `Release`, and it stops the grandchildren and deletes its
   delegate session.

The rows are written at the deletion and not when the release is handled. A
first version wrote them in the turn that marked the row releasing. Until the
slot has drained, though, the session's remote drainer and a spawn still being
asked keep resending the `Spawn` of a stub that is `Requested`, so the third
orchestrator could handle the `Release`, delete its session, and then make a
child for the late `Spawn` whose parent was gone. After the drain nothing of the
session runs to send it. A `Spawn` already in flight from the effect process
that was asking can still arrive after the `Release`, from another process; that
child is bounded by its deadline, as at depth 1.

### Tests and the model

`agency_test` drives a delegate session two levels deep over two fake
orchestrators: a spawn on the allowed one with the cell's depth, a refusal of
the one `spawn_on` leaves out, the depth refusal on both sides, the deadline
clamp, and a release after which a child starts nothing elsewhere.
`delegate_host_test` checks that a closed session's deletion owes the third
orchestrator a release from its file and that the drainer's pass releases the
third orchestrator's session, and that for a resident session the row appears
only together with the session's deletion. `daemon_shipped_remote_depth_test`
runs three shipped daemons from a three-orchestrator ledger: the laptop's parent
starts a child on the box, which starts a grandchild on the third, and deleting
the laptop session stops both and deletes both delegate sessions.

`protocol/models/remote-subagents` gains a relay (the box's delegate session as a
spawner) and two `Port` machines at depth 2, the specs `OneOrchestratorPerSite`,
`ReleasedDescendantsEnd` and `NoSpawnAfterOwnRelease`, and the case `tcDepth`.
The relay goes on resending until the box deletes the session, and the cascade
is written then. Three mutants are caught: a spawn retried against a second
orchestrator, which the model could not state with one port; a deletion that
does not cascade; and a cascade written when the release is handled, before the
slot drains.
