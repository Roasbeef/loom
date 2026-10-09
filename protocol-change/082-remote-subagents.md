# protocol-change/082: subagents on another orchestrator

**Status**: PROPOSED 2026-10-09, awaiting the owner's rulings on the open
questions of the design note. Nothing here is built, and every spelling below
is provisional until phase 1 lands.
**Affects**: the client control protocol (Part 1.6: one principal kind,
`delegate`; one owner command, `access.delegate`; the `delegate.*` command
family; and refusal codes on both), the remote daemon's catalogue (one table
for grants and one for delegate sessions, at the next version after 078 and
081), `loom.toml` on the spawning daemon (a `[subagent_hosts.<name>]` table),
the model-facing `agent_spawn` (one argument, `on`) and its handle text,
`cap/strand` (one assignment field), and three durable cells that are not
Part 1 interfaces: the parent's `remote-child/` stub, an optional `host` on
the lineage cell, and the delegate session's fences.
`runtime/child_run.Stop` gains three variants. Nothing is added to the node
vocabularies of protocol-change/078; this change does not use distribution.
**Raised by**: the owner's question of 2026-10-09, whether an orchestrator on
a laptop can start and direct subagents on a remote orchestrator.
**Design**: [docs/design-notes/remote-subagents.md](../docs/design-notes/remote-subagents.md).
**Builds on**: [protocol-change/078](078-distributed-runtime.md) (remote
workspaces, pools, peer mail and moves between orchestrators),
[053](053-owner-admin-and-claims.md) (claims and credentials),
[076](076-config-profiles.md) (profiles) and, where present,
protocol-change/081 on PR #934 (the Khepri directory).

## Problem

A subagent is a strand in its parent's session. The parent session's Agency
mints its name from the parent's call site, records its lineage, enforces
the addressing rule, the depth and fan-out caps and the result contract,
joins it, and reaps it when the parent's run ends or its deadline passes.
Every one of those reads and writes one session store on one machine, so a
model cannot have a child that runs on another orchestrator, with that
machine's checkout, toolchains, provider keys or capacity.

Nothing in protocol-change/078 supplies it. An executor runs a session's tool
calls but holds no conversation; peer mail carries messages between sessions
that already exist; a move transfers a whole session. And the model cannot
create a session anywhere, because `sessions.create` is an owner command.

A cross-machine child also changes who must be trusted. The machine that asks
for a child (typically a laptop) is the one most likely to be compromised,
and the machine that runs it spends its own provider keys and exposes its own
workspace. The remote's checks have to bind a compromised laptop.

## What was considered

### Transport: the orchestrator port over TLS distribution

Add `Spawn`, `Wait` and the rest as constructors of the orchestrator port's
`Message`, beside `PeerCommand`, with the laptop as a pinned distribution
peer of the remote. This is the shortest path and matches the owner's
phrasing. Rejected for the laptop case: a connected node holds the full
privileges of an Erlang peer and can call any function on the remote, so no
authorization the remote writes binds a compromised laptop, and with
protocol-change/081 every member also holds a replica of the store that
decides session ownership. A laptop that sleeps and roams is also a poor
distribution member.

### Transport: the control connection with a scoped principal

The laptop's daemon is a client of the remote daemon over `wss`, the endpoint
the terminal uses, authenticated by a credential bound to a principal whose
authority is a grant the remote owner wrote. The daemon already ships the
client (`host/websocket`, `host/access`), and the remote already
authenticates principals and revokes credentials (053). Chosen.

### Shape: a strand in an existing remote session

Rejected: the child would share a session, its lineage namespace and its
visibility with the remote's own owner and members.

### Shape: one new session per child

Rejected: each child would need its own store, runtime and, on an executor,
its own scope, of which an executor admits 16; and lineage, caps and reaping
would have to be rebuilt across sessions.

### Shape: one delegate session per (delegate, parent session)

Each child is a strand in a session the remote creates for one parent
session, and the remote's own Agency mints and judges it. Children of one
parent share one workspace, as local siblings share a checkout. Chosen.

### Model surface: a new tool

Rejected in favor of an `on` argument to `agent_spawn`, so a remote child is
waited on, listed and reaped with the tools that already do so.

## Proposal

### Spawning daemon configuration

```toml
[subagent_hosts.box]
address = "wss://box.example/v2/control"   # the shape [orchestrators].address takes
credential = "~/.loom/remotes/box/delegate.token"
tls_pin = "sha256:..."                      # optional leaf pin (design note, open question 9)
```

The key (`box`) is the name a model passes as `on`. The table requires no
`[distribution]`. `loom delegate claim --addr ADDRESS --as NAME` redeems a
delegate claim, stores the credential at mode 0600 and writes the table.

### The delegate principal (Part 1.6)

A principal gains a kind, `delegate`, beside the owner and members. A
delegate holds no session membership. Its credential authorizes the
`delegate.*` commands and nothing else: every other control command answers
`forbidden`, and the session socket and web routes refuse it as they refuse
an unknown credential.

`access.delegate` is owner-only. It takes a principal id, a display name and
a grant, creates the principal and the grant in one transaction, and answers
a single-use claim exactly as `access.invite` does (053), or binds a
`credential_digest` the owner was sent. `loomd access delegate` and `loom
access delegate` are its command-line forms. `access.show` and `access.list`
show a delegate's grant and its spend for the current day. `access.revoke`
and `credentials.revoke` end a delegate as they end a member, and additionally
stop every child of that delegate with the reason `revoked`.

A grant has:

| Field | Meaning |
|---|---|
| `placement` | One placement: `{executor, workspace}`, `{pool, workspace}`, or `{directory}` on the remote. Validated against the remote's configuration at grant time and at delegate session creation. |
| `profile` | A `[profiles.<name>]` key on the remote; seeds every delegate session. |
| `tools` | The tool ceiling. The default omits `agent_spawn`, the peer tools, `schedule_*`, `remember` and skill installation. |
| `max_depth` | The deepest child allowed, default 1, so children cannot spawn. |
| `max_live` | Live children across all of the delegate's sessions. |
| `max_per_day` | Spawn admissions per rolling day. |
| `max_sessions` | Delegate sessions not yet released. Must not exceed an executor placement's scope capacity. |
| `max_within_ms`, `default_within_ms` | The deadline cap (proposed 4 h) and default (30 min). Every child has a finite deadline. |
| `token_budget` | Tokens per rolling day across the delegate's children; optionally `child_tokens`, a per-child ceiling. |
| `retain_ms` | How long a delegate session with no live child and no contact is kept before the remote deletes it (proposed 7 days). |
| `approval_ceiling` | Phase 3. Absent means a delegate approves nothing. |

### The `delegate.*` commands (Part 1.6)

Every command is sent by a delegate principal on the control endpoint, names
a `parent_session` (an identifier the delegate chose, which the remote uses
only to find that delegate's own delegate session), and is decoded totally.
A command naming a parent session that has no delegate session for this
delegate answers `not_found`, except `delegate.spawn`, which creates one.

**Phase 1.**

- `delegate.info {}` answers the grant as it applies now: the placement's
  label, the profile's model names, the tool ceiling, the caps, the deadline
  cap and default, the budget and today's spend.
- `delegate.spawn {parent_session, caller, depth, parent_tools, request}`.
  `caller` is the parent's `{strand, operation, step_id, source_index,
  minter}`, where `minter` is `{"kind": "tool"}` or `{"kind": "program",
  "ordinal": n}`. `request` is `{purpose, brief, model?, tools?, within_ms?,
  result_schema?, detach}`. The remote resolves or creates the delegate
  session, checks the ended fence for `caller.operation` and the site fence,
  derives the child's name from `caller` with the parent's strand rendered as
  the reference `^{strand}`, adopts an existing child only when its lineage
  cell's `minted_by` equals the caller's call site, and otherwise checks the
  grant and the caps and creates the child. It answers `{handle: {strand,
  operation}, tools, model, model_id, remaining_ms}`. A repeat from the same
  call site answers the same handle.
- `delegate.status {parent_session, caller}` answers `{state: "spawned",
  ...}` with the same body as a spawn when the call site's child exists, and
  otherwise writes the site fence and answers `{state: "fenced"}`. Both are
  decided in the delegate session's Agency holder, which also admits spawns,
  so a spawn and a status for one site are serialized.
- `delegate.wait {parent_session, parent_strand, handles, within_ms}` waits,
  as the Agency's `wait` does, for children of `^{parent_strand}`, at most
  25 000 ms. It answers one entry per handle in order: `{state: "ready",
  handle, outcome, report, result, notes, usage}` or `{state: "pending",
  handle, waited_ms}`. `usage` is `{input, output, cache_read, cache_write,
  cost}`, summed over the child's run and priced by the remote.
- `delegate.run_ended {parent_session, operation}` writes the ended fence for
  `operation` and stops every child whose current run is owned by that
  operation. It answers `{stopped: n}`, and a repeat answers `{stopped: 0}`.
- `delegate.release {parent_session}` stops every child of the delegate
  session, detached ones included, marks it released and deletes it once its
  cleanup is proven. It answers `{state: "released"}` or `{state:
  "releasing"}`, and a repeat answers the stored state.

**Phase 2.** `delegate.send {parent_session, parent_strand, child,
message_id, text, within_ms?}` delivers into a child and stores a receipt
under the message id, so a repeat answers the receipt. `delegate.notes
{parent_session, parent_strand, child, prefix?}` reads a child's blackboard.
`delegate.pull {parent_session, after}` answers the delegate outbox entries
after a cursor (upward messages, and in phase 3 escalations), and
`delegate.ack {parent_session, through}` lets the remote drop them.

**Phase 3.** `delegate.resolve {parent_session, escalation, decision,
expected_seq}` answers an escalation when every grant in the decision is
inside the grant's `approval_ceiling`; otherwise it answers `forbidden` and
the escalation stays pending for the remote owner.

**Refusal codes**, each with the `code` and `message` every control refusal
has: `forbidden` (not a delegate, or outside the grant), `not_found`,
`fenced` (the call site was fenced by a status), `parent_run_ended` (the call
site's operation has an ended fence), `depth_cap`, `fan_out_cap` (the
remote's own caps), `grant_exceeded` (naming the grant field), `budget_spent`,
`unknown_tool`, `invalid_argument`, `name_already_minted`, `released` (the
delegate session was released) and `unavailable` (the remote could not
decide; the parent treats it as no answer).

### The remote's catalogue

Two tables at the next catalogue version after 078 and 081:

- `delegation_grants(principal_id, grant, spent_day, spent_tokens)`, one row
  per delegate principal, referencing its access row and deleted with it.
- `delegate_sessions(principal_id, parent_session, session_id, state,
  last_contact_ms)`, keyed by `(principal_id, parent_session)`, with `state`
  one of `open`, `releasing` and `released`.

### The delegate session

An ordinary session of the remote daemon, owned by its owner, seeded from the
grant's profile and placed by the grant's placement with the `session_only`
memory domain. `sessions.move` answers `not_movable` for it, `access.invite`
refuses it, and peer links to and from it are refused. Its store holds,
beside the ordinary Agency cells:

- `delegate/ended/{operation}`: the parent run `operation` has ended. Written
  by `delegate.run_ended` before it stops anything; read by spawn admission.
- `delegate/fence/{site digest}`: `delegate.status` found no child for the
  site. Read by spawn admission.
- Phase 2: `delegate/receipt/{message id}` and `delegate/outbox/{seq}`.

These live under a reserved prefix that `api.put_fact` refuses, like
`lineage/`. `create_strand` refuses a name that begins with `^`, so the
parent reference can never name a strand.

The remote reopens a delegate session with a live child when it boots, and
each child's deadline is enforced on the remote's clock by the Agency's
overdue check and by a timer for the session's earliest deadline.

### The spawning daemon's records

- `remote-child/{site digest}` in the parent session's store, reserved: the
  host and the derived name, then the handle, then the settled outcome and
  usage, or `fenced`. It is written before the first `delegate.spawn` is
  sent, so every retry of the call site goes to the same host and no remote
  failure becomes a local spawn.
- The lineage cell gains an optional `host`. A cell without it decodes as
  local. It is written when the spawn is answered.
- `delegate_releases(host, parent_session)` in the spawning daemon's
  catalogue, written in the registry turn that deletes a session with remote
  children and drained by a daemon-level weft state machine until the host
  acknowledges `delegate.release`.

A reconciler in each parent session (at open, then every 60 s) sends
`delegate.status` for each stub still `Requested` and `delegate.run_ended`
for each stub whose owning run has ended and whose end was not acknowledged.

### Model-facing changes

- `agent_spawn` gains `on`, an enum of the `[subagent_hosts]` keys, offered
  only in sessions the owner holds alone. With `on`, `context: "mine"` is
  refused, `within_ms` must be finite and within the host's cap, and `model`
  names the remote's catalogue.
- A remote handle renders as `{strand}#{operation}@{host}`.
  `agent.parse_handle` reads the host after the last `@` that follows the
  last `#`.
- `agent_wait` accepts local and remote handles together under one deadline.
  `agent_roster` lists remote children from the stubs.
- In phase 1 `agent_send` to a remote child, and a remote child's
  `agent_send` to its parent, are refused with a sentence that names the
  result and the notes as the way to report.
- `cap/strand` gains `with_on` on the assignment (phase 2).
- `child_run.Stop` gains `Released`, `Revoked` and `TokenBudgetSpent`, and
  `tools/agent.Outcome` the matching variants. A record written before this
  change decodes as before.

## What it costs

A second way for two daemons to talk. Orchestrators in one deployment still
use distribution for directory lookups, peer mail and moves; a delegate uses
the control protocol. They answer different trust questions, and an operator
has to know which one a feature rides.

Every `delegate.*` request is untrusted input to the remote and must be
decoded totally, with every field length and count bounded. The remote's
Agency gains a caller that comes from the wire: its depth is advisory, its
base configuration is the grant's profile, and its parent is a reference with
no strand behind it. That is new code on the path that decides authority, and
it needs its own tests against a hostile delegate.

Each delegate session on an executor holds a scope, so a grant's
`max_sessions` takes capacity from the remote's executors.

Upward messages (phase 2) are weaker than local ones. Locally a child is told
in its own turn that its parent's run has ended. Remotely the child is told
only that the message was queued, and a delivery into a parent that went idle
is refused at the laptop and recorded on the outbox row.

Usage is reported by the remote and recorded on the stub, not metered by the
laptop. The laptop's provider usage ledger keeps recording only requests the
laptop made.

The formal model is a new P model, `protocol/models/remote-subagents`, with
the specs and mutants listed in the design note's section 13. It is phase 1
acceptance work, and `make model-check` would run it.

## Decision

Proposed. The design note's section 16 lists the questions the owner has to
settle, each with a recommendation. The first one, the transport, decides
the rest of this document: if the owner prefers the orchestrator port over
distribution, the commands above become constructors of the orchestrator
port's `Message`, the delegate principal and its claim are dropped, and the
grant moves to the remote's `loom.toml` as hygiene rather than as a
boundary.
