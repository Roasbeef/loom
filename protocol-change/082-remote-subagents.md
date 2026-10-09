# protocol-change/082: subagents on another orchestrator

**Status**: PROPOSED 2026-10-09, direction ruled by the owner the same day
(transport, child shape, approvals, who spawns, and the defaults). Nothing
here is built, and every spelling below is provisional until phase 1 lands.
**Affects**: the orchestrator port's closed message type (five constructors
in phase 1, `ChildSend` in phase 2, `ChildEscalation` and `Resolve` in phase
3), `loom.toml` (a `[spawners.<name>]` table on the remote, and one key,
`subagents`, on an `[orchestrators.<name>]` row of the spawning daemon), the
remote daemon's catalogue (one table for delegate sessions and one for spend,
at the next version after 078 and 081), the model-facing `agent_spawn` (one
argument, `on`) and its handle text, `cap/strand` (one assignment field, phase
2), two new kinds of row in the session outbox, and durable cells that are not
Part 1 interfaces: the parent's `remote-child/` stub, an optional
`orchestrator` on the lineage cell, and the delegate session's fences.
`runtime/child_run.Stop` gains three variants. The client control protocol
(Part 1.6) is unchanged.
**Raised by**: the owner's question of 2026-10-09, whether an orchestrator on
a laptop can start and direct subagents on a remote orchestrator, "basically
via TLS distribution".
**Design**: [docs/design-notes/remote-subagents.md](../docs/design-notes/remote-subagents.md).
**Builds on**: [protocol-change/078](078-distributed-runtime.md) (remote
workspaces, pools, the orchestrator port, peer mail between orchestrators and
the sender outbox), [076](076-config-profiles.md) (profiles) and, where
present, protocol-change/081 on PR #934 (the Khepri directory).

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
reuses the orchestrator port, peer mail's outbox, drainer, `Endpoint` and
failure split, and the remote can deliver to the laptop over the connection
the laptop made, where the control path would have needed a second, pull-only
vocabulary for anything the remote has to tell the parent. And a second
authentication path between daemons, with its own principal kind, claim flow,
grant storage and total decoders for untrusted input, is a large surface to
build for one feature. If a deployment later needs spawners it does not trust
as peers, this option can be built beside the chosen one: the remote's spawn
handling is written against a spawner identity, so the control path would be a
second way to establish that identity.

### Transport: the orchestrator port over TLS distribution (chosen)

Spawn, status, join, run end and release become constructors of the
orchestrator port's `Message`, beside `Owns`, `PeerCommand`, `Import`,
`ImportStatus` and `Activate`. The laptop is a pinned distribution peer of the
remote. A pinned peer is fully trusted, as every peer in #923 already is, so
the remote's spawn policy bounds an honest peer and is not a security boundary
against a compromised one. The design note's section 5 states this in full.

### Where the spawn policy lives

**A catalogue grant.** Durable, changeable at runtime, revoked by a command.
Rejected: under distribution, revocation means removing a pin and restarting
anyway, and every other peer-facing table (peers, executors, pools,
orchestrators) is configuration validated at boot.

**`[orchestrators.<laptop>.spawn]`.** The owner's suggestion, beside the
existing peer table. Not taken: under protocol-change/081 every
`[orchestrators.<name>]` node of a Khepri member daemon must itself be a
member, which would make a sleeping, roaming laptop hold a replica of the store
that decides session ownership. `[orchestrators]` also means whom a daemon asks
about sessions and to whom it may move them, which a spawner needs neither of.

**`[spawners.<name>]`.** A separate table whose node must be a pinned
distribution peer and nothing more. Chosen, pending the owner's confirmation
(design note, section 17).

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
max_live = 8
max_per_day = 200
max_sessions = 4
max_within_s = 14400
default_within_s = 1800
token_budget_per_day = 5000000
child_token_budget = 1000000      # optional
retain_s = 604800
# approval_ceiling = { ... }      # phase 3
```

| Key | Meaning |
|---|---|
| `node` | The spawning orchestrator's node, which must be a `[[distribution.peers]]` node. Two tables may not share a node. |
| `executor` and `workspace`, `pool` and `workspace`, or `directory` | Exactly one placement for every delegate session of this spawner. |
| `profile` | The `[profiles.<name>]` that seeds every delegate session. |
| `tools` | The tool ceiling. The default omits `agent_spawn`, the peer tools, `schedule_*`, `remember` and skill installation. |
| `max_depth` | The deepest child allowed, default 1, so children cannot spawn. |
| `max_live` | Live children across all of this spawner's delegate sessions. |
| `max_per_day` | Spawn admissions per rolling day. |
| `max_sessions` | Delegate sessions not yet released; at most an executor placement's scope capacity. |
| `max_within_s`, `default_within_s` | The deadline cap (default 4 h) and the deadline a spawn gets when it names none (default 30 min). |
| `token_budget_per_day`, `child_token_budget` | Tokens per rolling day across the spawner's children, and an optional ceiling per child. |
| `retain_s` | How long a delegate session with no live child and no message from its spawner is kept (default 7 days). |
| `approval_ceiling` | Phase 3: the grants the parent's operator may approve. Absent means none. |

The table requires `[distribution]`. The decoder refuses an unknown node, a
placement that does not resolve, an unknown profile, a `max_sessions` above an
executor placement's scope capacity, and a `default_within_s` above
`max_within_s`. A daemon with no `[spawners]` table accepts no spawns.

On the spawning daemon, an `[orchestrators.<name>]` row gains `subagents`, a
boolean that defaults to false. The keys of the rows that set it are the names
a model may pass as `on`.

### The orchestrator port (`client/remote/orchestrator_port.Message`)

Phase 1 adds five constructors. `parent` is `{session, strand}` on the
spawning orchestrator; `caller` is the parent's `{operation, step_id,
source_index, minter}`, with `minter` either `ToolCall` or `Program(ordinal)`.

- `Spawn(parent, caller, depth, parent_tools, request, reply)`. `request` is
  `{purpose, brief, model, tools, within_ms, result_schema, detach}`. The port
  resolves the sender's node to a `[spawners.<name>]` table, resolves or opens
  the delegate session for (spawner, parent session), and asks its Agency
  holder to admit the spawn. The holder checks the ended fence for
  `caller.operation` and the site fence, derives the child's name from the
  caller with the parent strand rendered as the reference `^{strand}`, adopts
  an existing child only when its lineage cell's `minted_by` equals the
  caller's call site, and otherwise checks the policy and caps and creates the
  child. The answer is `Ok(Spawned(handle, tools, model, model_id,
  remaining_ms))` or `Error(SpawnRefusal)`. A repeat from the same call site
  answers the same handle. Runs in a task linked to the port.
- `SpawnStatus(parent, caller, reply)` answers `Spawned(...)` when the call
  site's child exists, and otherwise writes the site fence and answers
  `Fenced`. Decided in the holder that admits spawns, so a spawn and a status
  for one site are serialized there.
- `Join(parent, handles, within_ms, reply)` waits, as the Agency's `wait`
  does, for children of `^{parent.strand}`, for at most 25 000 ms. It answers
  one entry per handle in order: `Ready(handle, outcome, report, result,
  notes, usage)` or `Pending(handle, waited_ms)`. `usage` is the four token
  buckets and the cost, summed over the child's run and priced by the remote.
  Runs in a task linked to the port.
- `RunEnded(parent, operation, reply)` writes the ended fence for
  `operation`, then stops every child whose current run is owned by that
  operation, and answers how many it stopped. A repeat stops nothing more.
- `Release(parent_session, reply)` stops every child of the delegate session,
  detached ones included, marks it released and deletes it once its cleanup is
  proven. It answers `Released` or `Releasing`, and a repeat answers the stored
  state.

A message from a node no `[spawners]` table names is refused. A daemon with no
`[spawners]` table starts the port without a spawn host and refuses all five,
as a daemon that receives no sessions refuses `Import`. Unlike `PeerCommand`,
these messages may open a delegate session that is not resident: it exists
only to serve its spawner, and a join on a settled child must be able to read
its result after the session was closed.

`SpawnRefusal` covers: unknown spawner, the ended fence (`ParentRunEnded`),
the site fence (`Fenced`), the depth cap, the remote's live, daily and session
caps (each naming its key), the token budget, a tool outside the ceiling, an
invalid argument (including a `within_ms` above `max_within_s` and
`context: "mine"`), `NameAlreadyMinted`, a released delegate session, and a
failure of the remote's store.

Phase 2 adds `ChildSend(parent, child, message_id, text, within_ms, reply)`,
delivered through the remote Agency's `send` with a receipt stored under the
message id, so a repeat answers the receipt. Phase 3 adds `Resolve(parent,
escalation, decision, expected_seq, reply)`, admitted only when every grant in
the decision is inside `approval_ceiling`, and the laptop's port gains
`ChildEscalation(parent, child, escalation, reply)`, sent by the remote.

### The sending end

Each call is made the way `remote_peer` makes a peer-mail call: connect to the
pinned peer if it is not connected, send to its `loom_orchestrator`, and wait
under a deadline (30 s for `Spawn`, the join window plus 2 s for `Join`, 7 s
otherwise). The result is `Result(answer, peer_mail.Failure)`: `Refused` for a
definitive answer, and `Unreachable` for `noconnection`, `noproc` or no answer
within the deadline. A spawn that is `Unreachable` is resent with a doubling
pause from 50 ms to 2 s until its 30-second window runs out, and never sent to
another orchestrator.

While a parent session holds a live remote child, a link keeper on the
spawning daemon reconnects to that remote every two seconds when the
connection is down, so the remote can reach the laptop's port in phase 2.

### Records

On the spawning daemon:

- `remote-child/{site digest}` in the parent session's store, reserved: the
  orchestrator and the derived name, then the handle, then the settled outcome
  and usage, or `Fenced`. Written before the first `Spawn` is sent.
- The lineage cell gains an optional `orchestrator`. A cell without it decodes
  as local. It is written when the spawn is answered.
- Two new row kinds in the session's peer outbox, drained by the existing
  `peer_outbox_drain`: `SpawnStatus(site)`, written when a spawn's window runs
  out unanswered, and `RunEnded(op)`, written at a run end for each remote
  orchestrator holding a child that run owns. Neither row is refused after an
  hour; each is retried until the remote answers. When a session opens it
  writes a `RunEnded` row for each live stub whose owning operation has ended
  and has none.
- Release rows in the catalogue, `remote_child_releases(orchestrator,
  parent_session)`, written in the registry turn that deletes a session with
  remote children and sent by a daemon-level drainer of the same shape until
  the remote answers.

On the remote:

- `delegate_sessions(spawner, parent_session, session_id, state,
  last_contact_ms)` in the catalogue, keyed by `(spawner, parent_session)`,
  with `state` one of `open`, `releasing` and `released`.
- `spawner_spend(spawner, day, tokens)` in the catalogue, updated by the
  delegate sessions' usage hook.
- In each delegate session's store, under a reserved prefix that
  `api.put_fact` refuses: `delegate/ended/{operation}`, read by spawn
  admission, and `delegate/fence/{site digest}`, written by `SpawnStatus`.

`create_strand` refuses a name that begins with `^`, so the parent reference
can never name a strand. At boot the remote releases the delegate sessions of
any spawner that no longer has a table, and reopens the delegate sessions that
hold a live child. Each child's deadline is enforced on the remote's clock by
the Agency's overdue check and by a timer for the session's earliest
deadline.

### The delegate session

An ordinary session of the remote daemon, owned by its owner, seeded from the
spawner's profile and placed by the spawner's placement with the
`session_only` memory domain. `sessions.move` answers `not_movable` for it, and
members cannot be invited to it. Its only peer grants are the phase 2 upward
grants below.

### Upward messages (phase 2)

A remote child's `agent_send` to its parent is peer mail from the delegate
session to the parent session, through `peers.send`, its outbox row and its
drainer. The endpoint is `remote_peer.at` for the delegate session's recorded
spawner node, not a directory lookup. At spawn the parent's Agency writes the
peer grant for (delegate session, child strand) to (parent session, parent
strand) with `may_wake = false`, so the parent admits the message exactly once
by its id and only as a steer into an open run.

### Model-facing changes

- `agent_spawn` gains `on`, an enum of the `[orchestrators]` keys with
  `subagents = true`, offered only in sessions the owner holds alone
  (`manager.unshared_sessions`). With `on`, `context: "mine"` is refused,
  `within_ms` must be within the spawner's cap, and `model` names the remote's
  catalogue.
- A remote handle renders as `{strand}#{operation}@{orchestrator}`.
  `agent.parse_handle` reads the orchestrator after the last `@` that follows
  the last `#`.
- `agent_wait` accepts local and remote handles together under one deadline.
  `agent_roster` lists remote children from the stubs.
- In phase 1, `agent_send` to a remote child, and a remote child's
  `agent_send` to its parent, are refused with a sentence that names the
  result and the notes as the way to report.
- `cap/strand` gains `with_on` on the assignment (phase 2).
- `child_run.Stop` gains `Released`, `SpawnerRemoved` and `TokenBudgetSpent`,
  and `tools/agent.Outcome` gains the matching variants. A record written
  before this change decodes as before.
- Remote usage, recorded on the stub, counts against the parent goal's token
  budget.

## What it costs

**No boundary against a compromised spawner.** A spawner is a pinned
distribution peer and can call any function on the remote, so the spawn policy
binds only an honest peer. This is #923's assumption for every orchestrator,
extended to a laptop. A spawner's bundle must be guarded like an
orchestrator's, and cutting a compromised one off means removing its pin from
every node and restarting them.

**Provisioning.** A laptop needs a provisioned bundle. Provisioning is
one-shot today, so adding a spawner to an existing deployment reprovisions
every node.

**The port does longer work.** `Spawn` can open a session and `Join` waits up
to 25 seconds, so both run in tasks off the port's loop, as `Activate` does. A
spawn still takes the delegate session's holder, so many spawns from one
parent serialize there, as local spawns serialize in the parent's holder.

**Each delegate session on an executor holds a scope,** so a spawner's
`max_sessions` takes capacity from the remote's executors.

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
owner holds alone, and the defaults above. Two points remain for the owner
(design note, section 17): confirming `[spawners.<name>]` over
`[orchestrators.<laptop>.spawn]`, and accepting one-shot provisioning for
adding a laptop. This document moves to ACCEPTED, with the implemented
spellings, when phase 1 lands.
