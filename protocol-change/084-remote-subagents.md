# protocol-change/084: subagents on another orchestrator

**Status**: PROPOSED 2026-10-09, direction ruled by the owner the same day
(transport, child shape, approvals, who spawns, and the defaults). Phase 1 was
simplified after review on 2026-10-11. Slices S1 (the policy and the port
messages), S2 (the delegate session and the box's Agency) and S3 (the laptop's
stubs, drainer and tools) of phase 1 are built; the rest is not, and every
spelling below that is not built is provisional until phase 1 lands.
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
interfaces: the parent's `remote-child/` stubs and `remote-ended/` rows, an
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
spawn, and a `remote-ended` row is the pending row for a run end. The drainer
machine is generalised by one field and a second instance runs over them.

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
  refusal. Its state is `Requested`, `Spawned`, `Settled` or `Refused`, and it
  is written before the first `Spawn` is sent. `Requested` means pending.
- `remote-ended/{operation}/{orchestrator}`, reserved, is the pending row for a
  run end. It is `Pending` until the remote answers `RunEnded` and `Told`
  after. It is written by the same process that `agency.reaping_hooks` spawns
  with `spawn_unlinked` to run `reap_run`, once per remote orchestrator holding
  a child the run owns, so the strand driver never waits.
- The lineage cell gains an optional `orchestrator`. A cell without it decodes
  as local. It is written when the spawn is answered.
- `peer_outbox_drain.Options` gains `pass: fn() -> Backlog`, and `Backlog`
  (`Owed` or `Clear`) becomes public. The current body is the peer-mail
  instance's pass. A second instance, under its own name in the same
  restartable service tier, has a pass over the stubs and run-end rows: it
  resends each `Requested` stub's `Spawn` and each `Pending` row's `RunEnded`
  every five seconds, skipping an orchestrator that did not answer earlier in
  the same pass. `peer_outbox.Row`, `peers.resend` and `OutboxDue` are
  untouched. Neither kind of row is refused after an hour; each is retried
  until the remote answers, because every message is idempotent and the child
  it concerns is bounded by its deadline.

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
- **Turn end.** When the parent's run ends, `reap_run(op)` stops every child
  that `ParentRun(op)` owns and `RunEnded` carries that to the remote, so a
  model that ends its turn after spawning reaps its remote children as it
  reaps local ones. A laptop suspended in the middle of an `agent_wait` has not
  ended the run: only the in-flight `Join` task is cancelled. A child spawned
  with `detach` outlives the turn, bounded by its deadline and the retention
  sweep, and a later `agent_wait` on its handle still reads the result. This
  is the recommended behavior and awaits the owner's confirmation; remote
  children detached by default is the alternative (design note, section 17).
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
  with a second instance, and `reaping_hooks` writing `remote-ended` rows;
  `agent_spawn` with `on`, `agent_wait` over mixed handles, `agent_roster` from
  stubs; `context: "mine"` refused; the upward refusal wording. Tests:
  simulated-session tests with a fake endpoint. As built, the Agency asks through
  `client/remote_reach.Reach`, a record of the three functions, because the
  orchestrator port sits above the Agency in the module graph;
  `client/remote/remote_spawner` fills it. The handle's `@{orchestrator}` suffix
  is parsed and dropped, and a wait finds a remote handle in the parent's own
  stubs. A refusal heard where the model waits removes the stub, and one the
  drainer learns afterwards leaves it `Refused` with the reason. The process that
  writes a run-end row tells the orchestrator at once and leaves the row `Pending`
  for the drainer only when nobody answered. Remote usage is recorded on the
  settled stub; counting it against a goal and refusing `sessions.move` for a
  parent that holds a live stub are not built. The design note's section 15 lists
  the differences.
- **S4. Deadline tick and retention.** The per-delegate-session
  `weft/state_machine` calling `reap_overdue`, and the boot sweep.
- **S5. A shipped two-orchestrator test and the P model.** The test is modelled
  on `daemon_shipped_peer_mail_test`: three children spawned, joined, with
  structured results and usage; the laptop killed mid-spawn; the link cut
  mid-join; the run ended with the link down. The P model holds
  `AtMostOneChildPerSite`, `NoSpawnUnderEndedRun`, `EndedRunChildrenStop` and
  `EveryEndedRunIsTold`. This document moves to ACCEPTED when S5 is green.

Phase 2 adds `Release` and its daemon-level drainer, `SpawnerRemoved`, the
boot-time reopen, the open-time `RunEnded` repair, metering on the remote
(`spawner_spend`, `token_budget_per_day`, `child_token_budget`, `max_per_day`,
`TokenBudgetSpent`, handed off with `spawn_unlinked`), the keeper, `ChildSend`
with receipts, upward peer mail with the `BusyOnly` grant, `with_on` in code
mode, and the two upward specs. Phase 3 is `approval_ceiling`,
`ChildEscalation` and `Resolve`.

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
Metering needs a hand-off off the strand driver and is phase 2.

**Without `Release`, a deleted parent session leaves its remote children until
their deadlines,** at most `max_within_s`, and the delegate session until the
retention sweep.

**Ending a turn reaps remote children** unless they were spawned detached.

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
protocol-change/083. Two points remain for the owner (design note, section 17):
accepting one-shot provisioning for adding a laptop, and confirming that ending
a turn reaps remote children (recommended) rather than detaching them by
default. This document moves to ACCEPTED, with the implemented spellings, when
S5 of phase 1 lands.
