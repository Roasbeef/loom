# protocol-change/078: remote workspaces over trusted distribution

**Status**: ACCEPTED 2026-10-07 (direction approved by the owner). Field
spellings below are provisional until phase 1 lands; this document is updated
to the implemented spellings before the change merges.
**Affects**: the control command `sessions.create` and session records (one
optional field each, and a second pair for pools, see the addendum), the
catalogue schema (version 11, one column; version 12, one more; version 13,
one table for session movement),
`loom.toml` (a `[distribution]` table and `[executors.*]` rows on an
orchestrator, `[pools.*]` tables beside them, `[workspaces.*]` rows on an
executor, and `[orchestrators.*]` rows for a deployment with two
orchestrators), two refusal codes of `sessions.get` and `sessions.open`
(see the second addendum), one orchestrator-port message for peer mail (see
the peer mail addendum), the control command `sessions.move`, the members
`moving` and `moved` of `sessions.get`, three refusal codes (`moving`,
`orchestrator_unknown` and `not_movable`, see the session movement addendum),
`effects.ToolSurface`
(one slot), one `[mcp.<name>]` key (`runs_on`, see the addendum on background
code mode and MCP façades), and two new formats that are not Part 1 interfaces: the closed
message vocabulary between orchestrator and executor nodes, and the
executor's execution ledger. The helper wire (Part 1.4) is unchanged.
**Raised by**: issue #697 and the owner's takeover ruling of 2026-10-07.
**Design**: [docs/design-notes/distributed-runtime.md](../docs/design-notes/distributed-runtime.md).
**Supersedes**: the unmerged drafts carried by PR #819 under the numbers 066,
067, 071, 078 and 079 (remote workspace services, registered LSP, registered
generations and their October addenda). None reached main, so no frozen
interface is withdrawn; their numbers also collided with main's own 066, 067
and 071.

## Problem

A session's checkout, toolchains and native effects must be able to live on a
different machine from its conversation store, approvals and provider
credentials, with the checkout absent from the orchestrator. Today the daemon
assumes the workspace path is local in three places a client can see: the
`workspace` argument of `sessions.create` is canonicalized on the daemon's
filesystem, the catalogue stores it as a local path, and every tool runs
against it in the daemon's VM.

## What was considered

### A typed RPC per filesystem and process operation

PR #819's approach. Each operation (read, write, anchored edit, list, search,
stat, Git, Compile, Launch, LSP request) became a remote request with its own
codec, journal and custody record, and ordinary tools were reimplemented over
it. Rejected: it duplicates every tool's semantics behind a second interface,
it needs at-most-once custody for reads that are safe to repeat, and after
about 220k lines it had no production caller.

### A remote broker dispatcher or helper transport

Moving only the jailed command path (`broker/dispatch.Dispatcher` or the
helper port) to the executor. Rejected as the primary cut: harness-side tools
(`fs_*`, search, blobs, working-directory validation, the LSP door) would
still read the orchestrator's disk, and a code-mode satellite could not reach
its capability socket. It is kept in one narrow form, a remote `Broker`
handle, for non-tool callers.

### Whole tool calls at `ToolSurface.run`

Chosen. `ToolRun` and `ToolOutcome` are plain data, the runtime already makes
the call's intent durable before the effect, and the executor can run main's
unchanged workspace plane beside the checkout.

## Proposal

### Client protocol (Part 1.6)

`sessions.create` gains an optional `executor` string. When present,
`workspace` is the name of a workspace registered on that executor, not a
path, and the daemon never canonicalizes it locally; the executor validates
it when the scope attaches. When absent, behavior is exactly today's. A
session record gains an optional `executor` member that a client which does
not know it ignores. One refusal code is added, `executor_unknown`, for an
executor name this orchestrator has not configured. A configured executor
that cannot attach the scope is not a separate wire code: the opening fails
the way an unavailable workspace fails today, and `operations.get` reports
`start_failed` with a reason beginning `executor_unavailable:`. The
registration stays reserved, so a retry under the same creation key tries
again.

A registered workspace name is 1 to 128 bytes with no `/` and no NUL, so it
can never be mistaken for a local path, which always starts with `/`. A
session created with an `executor` defaults to the `session_only` domain
scope and refuses `workspace_private`, because the workspace aggregate is
keyed by path and two executors may register the same name. For the same
reason a registered session can never be a workspace default.

#### Addendum: the first-party clients

Both clients now send `executor`; the control protocol gains nothing for it.

The terminal takes `loom --executor <name> --workspace <registered name>`. With
an executor `--workspace` is a name, never a path: it is kept apart from the
launcher's canonicalized `Options.workspace`, validated against the shapes above
before a request is built, and refused together with `--session`, which names a
session that exists. The picker's `n` then sends `sessions.create` with
`workspace` set to the name and `executor` set. The terminal words
`executor_unknown` and an `executor_unavailable:` start failure as such, and
shows a session row's optional `executor` member (`box:proj` in listings, `PROJ
on box` as a picker group, since two executors may register the same name).

The web home learns the executor names in process and not over the wire: the
daemon hands them to the owner's page that holds the creation capability when the
page opens (`server.HomeAttachment.executors`, the startup capture of
`[executors.<name>]`), as it hands it the model profile names. The new-session
section then offers a form with an executor select, a typed registered name and
an optional session name. An executor travels as a position in the list the page
was given and is turned back into the name by the form's decoder, so a browser
can choose among the executors the page drew and name no other. The daemon's
creation (`ui_socket.create_for`) judges only the name's shape and the
executor's presence in the configuration, and makes the session session-only
whatever the form said. A session list entry carries the optional executor, and a
remote group is headed `executor:name` and offers no directory-style "New
session" button.

### Catalogue (version 11)

`Registration` gains `executor: String`, empty for a local session. The
migration from version 10 adds the column with an empty default. A
registration with a non-empty `executor` stores the registered workspace name
in `workspace`, never a path on the orchestrator.

Version 10 belongs to protocol-change/080, which pinned a session's main model
and shipped first. This proposal's migrations were numbered 10, 11 and 12 when it
was drafted and are 11, 12 and 13 now: the executor column, the pool column and
the move table, in that order, on top of the model column. A catalogue at
version 10 (from the model change) migrates through all three.

### Configuration

On both roles, `[distribution]` names the local node, the TLS credential
files (CA, certificate, key, cookie, all private to the operator) and the
pinned peers (node name and leaf SHA-256). On an orchestrator,
`[executors.<name>]` names a peer node. On an executor, `[workspaces.<name>]`
names a `root` (absolute, an existing directory, and nothing else for now),
and the machine's own toolchain, LSP, `[tools]`, `[workspace]` and `[jobs]`
tables apply. A daemon with at least one row starts the host. A daemon with no `[distribution]` table never starts distribution.
Every key is documented in `docs/configuration.md` and gated by
`make doc-check`.

The VM must boot with `-proto_dist inet_tls` and an `-ssl_dist_optfile`
before `net_kernel` starts; the release's launcher passes them when, and only
when, `[distribution]` is present.

### `ToolSurface.recover`

`effects.ToolSurface` gains `recover: Option(fn(ToolRun) -> Recovery)`. When it
is `Some`, the runtime recovers an orphaned tool call by spawning an effect
that calls it, exactly as it spawns `run`, and the effect reports through the
same `ToolDone` path. The function may block: it attaches if needed, then
queries the call key until the ledger settles.

```gleam
pub type Recovery {
  /// The executor holds the call's finished outcome; stage it.
  Recovered(outcome: ToolOutcome)
  /// The executor restarted mid-run; stage the unknown-outcome result.
  OutcomeUnknown
  /// The call never reached the executor and, after the attach, cannot.
  /// A `ReplaySafe` call takes the planner's existing replay arm; any other
  /// call is staged as not started.
  NotStarted
}
```

A local session's surface sets `recover: None`, so its recovery is unchanged.

### Node vocabulary

All messages between nodes are values of closed custom types holding only
strings, integers, bit arrays, lists, the existing plain-data runtime types
(`ToolRun`, `ToolOutcome`, `AgentMessage`, `escalate.Refused` and `Decision`)
and `Subject`s. No function, port, reference to node-local storage or atom
built from a peer's input crosses. Values read back from storage, the ledger's
stored outcomes among them, are decoded with total decoders.

The messages between the nodes are a different case. The two nodes are pinned,
mutually trusted peers, so a message is a typed Erlang term that the receiver
matches directly. It is not decoded from untrusted bytes and its size is not
bounded by a decoder. The only guard on its shape is `version` on `Attach`, and it
helps only while the `Attach` tuple still has the same fields. A peer built from a
different vocabulary whose message does not match is not refused: the receiver
fails to match it, which crashes the executor host and halts the executor daemon
(`ExecutorGone`). That is an availability fault under a mismatched build, not a
loss of isolation, because a pinned peer already has the full privileges of an
Erlang node. Both ends are therefore upgraded together, and the version is bumped
for every change of a constructor or field.

Orchestrator to executor:

| Message | Meaning |
|---|---|
| `Attach(version, session, workspace, incarnation, token, owner_port, reply)` | Sent each time the orchestrator opens the session. `version` is `protocol.version` (2); any other value is refused with `VersionMismatch`. Start or adopt the scope at this incarnation and make `token` its only valid attach token. The plane is built asynchronously and the reply, the census, the executor's clock reading when the reply is sent and the scope's unacked terminal keys or a refusal, is sent when the build lands. A rebound attach is answered at once from the plane it already has. While it builds, a second `Attach`, a `Run` and a `Close` for the session are refused with `PlaneBuilding`. |
| `Run(key, incarnation, token, run, authority, reply)` | Run one tool call. Idempotent by `key`. Admitted only if `incarnation` and `token` equal the scope's. The host monitors the sender: a DOWN other than `noconnection` cancels the run. |
| `Query(key, reply)` | Return the ledger state and outcome for `key`, in any scope state or incarnation. |
| `QueryOrFence(key, incarnation, reply)` | Like `Query`, but when no row exists, atomically insert a terminal "did not start" row so a stale `Run` for that key can never start. Used to recover an orphaned call that is not replay-safe. |
| `ListUnacked(session, reply)` | List the scope's terminal and unknown keys without attaching, for the orchestrator's acknowledgement reconciler. |
| `Ack(key)` | The orchestrator has durably staged this outcome. A settled row is retired and a tombstone keeps the key taken until the scope's incarnation changes, so `Run` for it is answered as lost and never starts. |
| `Close(session, workspace, incarnation, reply)` | Close the scope and report `all_retired` or `unknown(count)`. |

There is no cancel message. Abort kills the orchestrator's effect process,
and the host's monitor on it turns that into a cancel.

Executor to orchestrator, to the session's owner port:

| Message | Meaning |
|---|---|
| `Escalate(refused, remaining_ms, reply)` | Ask for an approval decision. `remaining_ms` is how long the call may still wait; the owner port rebuilds the deadline on its own clock. |
| `FactGet(key, reply)`, `FactPut(key, value, expected, reply)`, `FactPutBlind(key, value, reply)`, `FactDelete(key, reply)`, `FactList(prefix, reply)` | Read, compare-and-set, write without a comparison, delete or list a reserved owner fact (`client/working_directory/*`, `job/*`). |
| `Notify(strand, work, text, reply)` | Deliver a background job's completion notice to its strand. |
| `StrandActivity(strand, reply)` | Ask whether a strand has an open run. |
| `Wake(strand, text, reply)` | Wake an idle strand, for the idle heartbeat. |
| `Holds(caller, tool, reply)` | Ask whether a strand's active tool list holds a tool. |
| `Tail(run, tail)` | A live output hint, sent as a cast; may be dropped. |
| `Capability(call, reply)` | A satellite's owner-bound capability call. |

The host monitors the owner port. A DOWN while a callback is outstanding
settles that callback with an in-band failure, so the call reaches
`terminal` instead of waiting on a reply nobody will send.

The remote broker handle uses `broker.Msg` unchanged. A `CallSpec`'s absolute
deadline is sent as it is, and the executor's broker compares it with its own
clock, so the orchestrator builds it on `Half.call_clock`: its own clock
shifted by `Attached.executor_now_ms` minus the local reading when the reply
arrived (`workspace.rebased`). Only an escalation crosses as a remaining
duration. The workspace path in the spec comes from the census as an opaque
string.

A remote session refuses extension tools and operator-added directories in
this change; both read orchestrator-side state that has no executor
counterpart yet.

### Execution ledger

One SQLite file under the executor's state root, owned by one node-level
actor; rows are keyed by session:

```sql
CREATE TABLE scope (
  session TEXT NOT NULL,
  workspace TEXT NOT NULL,
  incarnation INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('open', 'closing', 'closed')),
  close_outcome TEXT,          -- 'all_retired' | 'unknown:<n>'
  attach_token BLOB NOT NULL,
  PRIMARY KEY (session, workspace)
);

CREATE TABLE call (
  session TEXT NOT NULL,
  op TEXT NOT NULL,
  step TEXT NOT NULL,
  source_index INTEGER NOT NULL,
  incarnation INTEGER NOT NULL,
  tool TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('admitted', 'terminal', 'unknown')),
  outcome BLOB,
  outcome_digest BLOB,
  outcome_bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session, op, step, source_index)
);
```

Admission inserts `admitted` in the same transaction that checks
`scope.state = 'open'` and compares the request's incarnation and attach token
for equality. A recovered
`admitted` row becomes `unknown` at startup and is never relaunched. An
executor admits at most 16 scopes that are not `closed` with
`all_retired`, and a byte budget bounds unacked outcomes. Reopen requires
`closed` with `all_retired` and increments `incarnation`.

### Addendum: executor pools

A session can be created in a pool of executors instead of on a named one, and
the orchestrator picks the executor when the session first opens. This is
phase 2 of the design note.

#### Wire and catalogue

`sessions.create` gains an optional `pool` string, which has the grammar of an
executor name and is exclusive with `executor`: a request that carries both is
`bad_request`. With a `pool`, `workspace` is a registered workspace name exactly
as it is with an `executor`, and the domain scope defaults to `session_only` and
refuses `workspace_private`, for the same reason. One refusal code is added,
`pool_unknown`, for a pool this orchestrator has not configured. A session record
gains an optional `pool` member. A session in a pool has no `executor` member
until its first open chooses one; from then on the record carries both.

The catalogue is at version 12. `Registration` gains `pool: String`, empty for a
session created without one, and the migration from version 11 adds the column
with an empty default. The pool is part of the immutable creation request, so a
retry compares it. The executor of a pooled session is the first open's choice
and not part of the request, so a retry compares the pool only, and a retry after
the choice still finds its reservation. The executor column is written once, by
`seed_executor`, and only for a registration that has a pool and no executor.

#### Configuration

`[pools.<name>]` lists `executors`, which must each be a configured
`[executors.<name>]`, in the order they are tried. An `[executors.<name>]` row
may also declare `platform`, `enforcement` and `toolchains`, and a pool may
require the same three. The declarations are what the operator says the machine
provides. They are not discovered, and nothing is added to the node vocabulary to
ask. A pool's candidates are the listed executors whose declarations satisfy its
requirements, in the listed order, computed from configuration alone. An executor
that declared nothing cannot satisfy a requirement. After a successful attach the
census is compared with the declaration; a contradiction closes the scope, which
returns its slot, and fails the open with a reason that names the declared and the
reported value. The environment variable `LOOM_EXECUTOR_MAX_SCOPES` lowers the
number of scopes an executor admits from the ledger's default of 16.

#### Placement

The orchestrator's scope record (`client/remote/scope`) gains the executor that
holds the scope, and the record is written after the connection succeeds and
before the `Attach` is sent. That makes an attach whose reply was lost
recoverable: the next open finds the record, goes to the same executor, and the
ledger's rebind makes the retry converge. A record that names an executor is the
only candidate its session ever has, so a reopen never chooses again, and a record
from before this addendum, which names none, takes the executor of the
registration.

A first open, which has no record, tries the candidates in order and goes to the
next one only while no executor can hold a scope for the session. That is the rule
in ledger terms: the connection to a candidate failed before the attach was sent,
or the candidate answered `CapacityExhausted`. The ledger checks capacity inside
the attach transaction, before it inserts the scope and before the host builds a
plane, so the refusal proves that nothing was created and the checkout was not
touched. The record is withdrawn after such a refusal, so the next open chooses
from the whole pool again. These are the only two cases. An attach that got no
answer may have created the scope, so it is retried against the same executor and
never against the next. A scope that was created but whose plane failed to build
is the session's, and the open fails with the record naming it. A
`CapacityExhausted` on a later open is `executor_unavailable:` and never a reason
to move, because the checkout exists only where the record says. This does not
conflict with "no fallback to a different mutable checkout": the rule forbids a
second checkout for a session that already has a scope, and the first open of a
session has none.

The balance is order and not load. Sixteen scopes per executor and a few
executors do not need a least-loaded choice; spreading sessions later means
rotating where the candidate list starts, which adds no message.

#### What it costs

An open into a pool whose first executors are unreachable is slow, because it
connects to each candidate in turn. A declaration can be wrong, and a wrong one is
found when a session attaches and not before: the first open into a pool whose
first executor mis-declared fails once and names the mismatch, and the record
then binds the session to that executor until the file is fixed. And the choice is
never revisited, so a session cannot move to a machine with more room; moving a
session is the controlled movement of phase 5.

#### First-party clients

The terminal takes `loom --pool <name> --workspace <registered name>`, exclusive
with `--executor`, and sends `sessions.create` with `pool`. It words `pool_unknown`
as it words `executor_unknown`. The web home does not offer pools yet.

### Addendum: two orchestrators

A deployment may run two orchestrators, each with its own catalogue, and a
client may connect to either. This is phase 3 of the design note. The
catalogue of each orchestrator stays the source of truth for the sessions it
owns. A session is created on, and owned by, the orchestrator the client is
connected to, and nothing registers it anywhere else: identities are UUIDv7, so
no two orchestrators mint the same one. The only new behavior is what an
orchestrator does when a client names a session its own catalogue lacks.

#### Wire

`sessions.get` and `sessions.open` gain two refusal codes, both sent only to the
owner principal and only after the daemon's own catalogue has no such session.
`not_owner` means a configured orchestrator holds the session. Its error body
carries `orchestrator`, the name of that orchestrator in the daemon's
`[orchestrators.<name>]` table, and `address` when that row configures one.
`owner_unreachable` means no orchestrator said it holds the session and at least
one could not be asked. Its body carries `orchestrators`, the names of those that
did not answer, in configuration order. A session that every orchestrator
answered it does not hold is `not_found`, as it was before, and so is every
miss for a member principal, because a member's standing on a session is the
owning daemon's to judge and the daemon asked cannot vouch for it. The other
commands that name a session keep their answers. Both bodies keep the `code` and
`message` members every control refusal has, and a client that does not know the
new members ignores them.

The session socket has no `not_owner`. A client reaches `/v2/sessions/<id>/ws`
only after `sessions.get` or `sessions.open` on the control endpoint, where the
redirect already happened, and the upgrade for a session the daemon does not hold
remains the HTTP 409 it is today.

No orchestrator advertises an address. A daemon binds loopback only and has no
routable address of its own; whatever reaches it (a tunnel, a proxy,
`--ui-origin`) is the operator's knowledge. So the address a client is told is
held by the daemon that tells it, in its own `[orchestrators.<name>]` row, and is
optional.

Nothing follows a redirect. Neither first-party client holds a credential for a
second daemon: the terminal reaches the local daemon through its own token files
and a remote one with `--addr` and a token, and a web page is bound to one
daemon by a ticket and cookie signed under that daemon's key. A redirect is
therefore a statement of where the session is, and the client prints the launch
line for it.

#### Configuration

`[orchestrators.<name>]` has `node`, which must be one of the
`[[distribution.peers]]` nodes as an executor's must, and an optional `address`,
a control address of the form `loom --addr` takes (`wss` to any host, or `ws` to
a loopback host, with the path `/v2/control` and no credentials, query or
fragment). Two names may not share a node, and the table requires `[distribution]`.
The table says whom this daemon asks, nothing more: a daemon that has
`[distribution]` answers a peer's question whether or not it lists that peer.

#### The question

The question travels over the pinned distribution connection to a new registered
name, `loom_orchestrator`, with its own closed message type. It is not a
constructor of the executor host's `HostMessage`, which every executor would
otherwise answer. One process per daemon answers `Owns(session)` with `Owned` or
`NotOwned` from the catalogue, counting a `reserved` registration and an archived
one as held. A catalogue that cannot answer produces no reply, so the asker's
deadline reports it as unreachable and a failed read is never taken for a
negative. Peer mail delivery, in phase 4, is a second constructor of the same
type.

A daemon with at least one `[orchestrators.<name>]` row asks them all at once on
a miss, each by connecting to the pinned peer if it is not connected and sending
the question, under one two-second deadline. No connection is made at startup,
none is retried, and nothing is cached. The result is decided by one rule: the
first orchestrator in configuration order that answers `Owned` is the owner,
whatever the others did; otherwise a missing answer makes the result
`owner_unreachable`; otherwise it is not found.

The lookup sits behind a `Directory` interface whose only operation is
`lookup(session) -> Here | Elsewhere(orchestrator) | Unknown | Unreachable`, shaped
so that a different backing could replace it and a write half could sit beside it.
Phase 5 added that half, `activate`, and kept the catalogues as the authority (see
the addendum on moving a session). A caller asks the directory and never reasons
that a record in its own catalogue settles ownership.

#### What it costs

A client must know which orchestrator to reconnect to, and for a session it names
by id the daemon says so but does not carry it there. The list a client shows is
the list of the orchestrator it is connected to: there is no merged
`sessions.list`, because nothing in phase 3 needs one and a merged list is what
would invite selecting a row owned elsewhere and following it. A lookup on a miss
costs a connection attempt to each peer that is down, up to the deadline. The two
orchestrators can disagree only if both hold the same identity, which a restored
backup can cause; the first in configuration order is reported. Failover and
movement of a session between orchestrators are still deferred to phase 5.

#### First-party clients

The terminal words both codes. For `not_owner` it prints the owner's name and,
when the response carries an address, the line to run on that machine
(`loom --addr <address> --session <id> --token-file <the owner token on that
host>`). The web home words them the same way, on the page of the session that was
asked for. Neither client connects to the owner itself.

### Addendum: session movement (catalogue storage)

Phase 5 moves a session between orchestrators under the source's control. This
addendum records the catalogue half. The next addendum records the command, the
views, the messages and the mover that drive it.

The catalogue is at version 13. The migration from version 12 adds one table,
`catalogue_session_moves(session_id, op, peer, state)`, keyed by session and
referencing `catalogue_sessions`. No row means the catalogue serves the session
and has never moved it, so every existing session reads back as resident. A row
is `moving` while this side hands the session to `peer`, `moved` once it has,
and `imported` on the side that received it. `op` identifies one move end to
end and `peer` is an `[orchestrators.<name>]` key.

The transitions are compare-and-set on the row, in one immediate transaction
each. The side that gives a session up runs `resident -> moving -> moved`, with
`moving -> resident` for an abort before anything reached the receiver. The side
that receives it runs `resident -> imported`. A session can travel more than
once, so two further transitions each take a new op: an `imported` session goes
`imported -> moving` to move onward, and a `moved` session goes `moved ->
imported` to come back, each replacing the row in one transaction. A repeat of
the same op answers the stored state and writes nothing. Any other op, and any
transition the stored state does not allow, is a conflict. The op that wrote a
`moved` row cannot undo it, which is what keeps a stale mover or a late message
from returning a session to a catalogue that handed it over. The read of a row that breaks the grammar fails
and is never taken as resident. Deleting a `moving` or `moved` session is
refused, because the row is the only record of who owns it.

Nothing is added to the node vocabulary or the client protocol by this change,
so no Part 1 interface moves.

### Addendum: moving a session between orchestrators

Phase 5 of the design note lets an owner hand a session from one orchestrator to
another. The two catalogue rows of the previous addendum are the whole
authority: the source's row says whether it still serves the session, the
receiver's says whether it does, and a write-ahead intent orders the two. No
third store decides, and no executor column records an owner. The executor's
incarnation fence stops a stale source on the machine that holds the checkout,
and the source's own rows stop it everywhere else.

#### Wire

`sessions.move` takes `session_id`, `to` and `epoch` and is owner-only. `to` is a
key of the daemon's `[orchestrators.<name>]` tables, and the daemon checks it
before it asks the registry. The reply is `{session_id, op, to, state:
"moving"}` and comes back as soon as the intent is committed: the move itself runs
on, and outlasts the connection. `op` is minted by the daemon, stored in the
source's row, in the receiver's row and in every file name, and a repeat of the
request toward the same orchestrator answers the stored one, so two owners asking
at once start one move. Toward another orchestrator it is `conflict`.

`sessions.get` gains one member while a move is in flight and another once it
finished. `moving` is `{op, to}` and `moved` is `{to}`. A session with neither
carries neither, so its record is what an older daemon sent. `sessions.open`
answers `moving` with `orchestrator` and `op` while the move runs. Once it has
finished, `sessions.open`, `sessions.archive`, `sessions.restore`,
`sessions.delete` and `sessions.move` answer `not_owner` with `orchestrator` and,
when the daemon's row configures one, `address`. The new owner comes from the
source's own tombstone through the directory and no peer is asked. The other new
codes are `orchestrator_unknown`, for a destination that is not in the
configuration, and `not_movable`, for a session with no executor yet, an archived
one and one that has not finished being created. A local session cannot move: its
checkout is a directory on the source's machine.

A client that does not know the two members ignores them, and one that does not
know `moving` or `orchestrator_unknown` reads them as an ordinary refusal with a
code. The terminal prints the launch line for `not_owner` as it does for any
redirect, and `loom sessions move <session-id> --to <orchestrator>` sends the
command and prints the move's identity. The web view gains nothing.

#### Who owns the session at each moment

1. **Before the intent**, the source's row is `resident` and it serves the session.
2. **The intent** commits `moving(op, to)` in the same registry turn that stops the
   slot. Admission refuses a session whose row is `moving` or `moved`, so after
   this commit no runtime on the source can open the file. The row is committed
   before the slot is cancelled, so a crash between the two leaves a `moving` row
   and no slot, which is the state a restart resumes from.
3. **Until the activation**, the receiver has no row, and the source's row is still
   the owner. A source that is unreachable to the receiver, or a receiver
   unreachable to the source, changes nothing about who owns the session.
4. **The activation** is the compare-and-set on the receiver's catalogue:
   `absent -> imported(op, from)` with the file in place. From it the receiver
   owns the session. Between it and the source's retirement both rows say that
   their side is not serving: the source's is `moving`, which refuses admission,
   and the receiver does not serve until a client opens the session.
5. **The retirement** moves the source's row to `moved(to)`, which has no way out
   under the same `op`, and sets the file aside. A late message of the same move
   cannot bring the session back.

The executor's fence is the belt: once the receiver attaches at `incarnation + 1`,
the old token is refused by value, and the source's scope was already closed
cleanly before the copy was cut, so the source has no live runtime to refuse in
the first place.

#### The six steps

| Step | Durable afterward | A crash leaves | Resumed by |
|---|---|---|---|
| 1 Intend and stop | the source's row `moving(op, to)`, the slot stopped | the row | a restart starts a mover for each `moving` row |
| 2 Close | the file's scope cell reads a clean close | the cell with no close recorded, or an unproven one | a cell with no close asks the executor to close again and writes the answer into the file; an unproven cleanup refuses the move |
| 3 Cut | `<id>.db.move.<op>`, with the file's lease held under `move:<op>` | a partial copy | the next cut replaces the copy and reclaims its own lease |
| 4 Send | the whole copy at `incoming/<id>.<op>` on the receiver | a partial copy under `.part` | the receiver says `Absent` or `Received`; absent is sent again in full |
| 5 Activate | the receiver's row `imported(op, from)` and the file in place | the row without the rename, or a lost reply | a repeat answers the stored result and finishes the rename |
| 6 Retire | the source's row `moved(to)`, `<id>.db.moved`, the lease released | the row without the file work | the next run finds `moved` and does the file work |

Every step starts from what is on disk, because a mover has no memory of its own:
each run reads the row, asks the receiver how far the move has got, and takes only
the steps that remain. A receiver that already activated the session sends the run
straight to step 6.

The cut copies the closed file with `VACUUM INTO` after the writer lease is claimed
under the reserved owner `move:<op>`, then deletes the lease row from the copy, so
the lease never travels. The copy is hashed, and the whole file is read into
memory to be hashed and cut into pieces, so a move refuses a file larger than 256
MiB. The pieces are 256 KiB and acknowledged one at a time. There is no resume
inside a file: any failure sends the whole file again.

Activation verifies before it writes. The receiver checks that the sender's node is
one of its `[orchestrators.<name>]`, that the copy's SHA-256 is the digest the
sender took, that the copy's scope cell reads `closed: AllRetired` at the
incarnation the sender claims, and that it has the `[executors.<name>]` the cell
names. The cell is read from a scratch copy, because opening a session file
rewrites its header and its lease. Then one registry turn registers the session
with a session-only domain mapping, confirms it, records the import and renames the
copy into place. The source's configuration path is not carried: it names a file on
the source's machine, and the session is registered with the receiver's default.
Memberships, claims and the memory domain stay on the source, as principals are per
daemon.

#### Messages on the orchestrator port

Three constructors join `Owns` on `loom_orchestrator`'s message type, and `Owns`
gains a third answer. `Import(chunk)` carries one piece of the copy and is
answered `Accepted`, `Refused` or `Failed`. `ImportStatus(session, op)` is
answered `Absent`, `Received` or `Activated`. `Activate(activation)` carries the
digest, the incarnation, the sender's node and the manifest, and is answered the
same way as a piece. `Owns` answers `Moved(to)` from a tombstone, and the
directory maps it to `Elsewhere`. A daemon that does not receive sessions starts
the port without an importer and refuses all three. `Directory` gains `activate` as
the second field the phase 3 note reserved.

A `Refused` verdict means the receiver looked and said no. `Failed` and silence
mean it could not decide. The distinction is what lets a mover decide whether to
give up.

One rule makes that distinction safe: once the receiver has committed `imported`
under an operation, every `Activate` for that operation is answered `Accepted`,
whatever else is true. A session already opened on the receiver, a sender renamed
or removed from `[orchestrators]` since, and a copy that is gone do not change the
answer, because the source abandons on a refusal and a refusal after the commit
would leave the session owned by both. The receiver reads the catalogue before it
resolves the sender, and the open-slot check applies to a first import only. The
status question has the same discipline: a catalogue that cannot be read gives no
answer, so the port sends nothing, and the source treats silence as a stall.
`Absent` is sent only when the catalogue was read and holds no such import. The
source, for its part, retires on a stage of `Activated` without activating again.

A session that was imported cannot be handed on before the source has retired. The
`imported` row is the record the source's retry depends on, and beginning a move
on the receiver replaces it with `moving`, which an abort then deletes. A move
back to the source would meet the source's own `moving` row and be refused, the
receiver would abandon it and become `resident`, and the source's retry would find
no `imported` row there and abandon too. So `sessions.move` for a session whose row
is `imported` first asks the orchestrator named in the row whether it holds the
session, outside the registry's turn, and begins the move only when it answers
`Moved`. `Owned`, `NotOwned`, silence, and an origin the daemon no longer lists
refuse with `not_movable`, and the owner asks again later. A retired source never
holds the session again under that move, so one `Moved` answer settles the
question. The cost is that an imported session whose origin is down or removed from
`[orchestrators]` cannot move on until the origin is listed and reachable.

`sessions.delete` follows the same rule, because a delete removes the `imported` row
and the source's retry would then import the session afresh and undo it. It is
refused `busy`, the code a delete already has for a session that cannot be removed
yet, until the origin answers `Moved`. Archive and restore change visibility and
not custody, so they are not held.

#### When a move stops

A move ends in one of three ways. It finishes, with the source's row `moved`. It is
abandoned, with the source's row back to `resident` and its lease released, and
that is allowed only on an answer: the executor could not prove the scope's cleanup
(`UnknownCleanup`), the file is corrupt or too large, or the receiver refused the
copy after at most one resend. It stalls, with the row still `moving`, and the
daemon retries it on a timer: an executor or a receiver that did not answer, a
lease that has not lapsed, a step that ran out of its deadline. An unreachable
receiver never abandons a move, because it may have activated the session and lost
the reply, and `moving` is still exactly one owner. A receiver's `Refused` after
the send is final and the copy it keeps is removed, except when it refused the
digest or reported no copy, which a new send cures.

Each step runs under a weft deadline of its own. The daemon owns the movers as one
actor beside the orchestrator port, and not the registry, whose turns are bounded
by five seconds while a move waits on an executor for a minute.

#### Configuration

Both orchestrators list the executor and each other. The source needs
`[orchestrators.<receiver>]` to name the destination and `[executors.<name>]` to
close the scope. The receiver needs `[orchestrators.<source>]` to recognise the
sender and the same `[executors.<name>]` to attach. The executor trusts both
orchestrators' nodes as distribution peers, as it does any orchestrator. No new
`loom.toml` key is added.

`LOOM_MOVE_CRASH_AFTER=<step>` is a test-only environment variable. The daemon
reads it once at startup and halts its VM the moment the named step is durable;
the steps are `intent`, `close`, `cut`, `send`, `activate` and `retire`. The
shipped test uses it to lose the source after each step and checks that a restart
finishes the move. It is not a setting for operators and has no counterpart in the
configuration file.

#### What it costs

The formal model `protocol/models/session-move/Move.tla` checks the six steps with
a crash possible between any two. Its mutations show what each rule buys: without
the write-ahead intent a crash lets two orchestrators serve the session, abort
after the send does the same, and retiring without having seen the receiver's row
leaves a session no one has, and a receiver that refuses an activation after its
row is `imported` does the same as an early abort (`RefuseActivate`, mutated by
`RefuseUncommitted`). The P model of the remote execution against the ledger
is phase 6 acceptance work.

Not built: a designated node or table that decides ownership, an owner column on
the executor's scope, resuming inside a file, abandoning after a send except on the
receiver's refusal, automatic failover, moving a workspace snapshot, moving the
memory domain, moving memberships and claims, moving a local session, and a web
view of a move. Events a client has not caught up on are not carried across: a
client reconnects to the receiver. A move of a session with a background job lets
the job die with the scope's clean close, as a stop does, and the receiver's
records for it are what the source wrote.

### Addendum: the sender outbox

Phase 4 of the design note carries peer mail between orchestrators. The first
half is a durable outbox on the sender, for the one case a synchronous call
cannot answer: the recipient's owner is unreachable. It changes no wire frame
and no frozen interface. It adds four `peer_mail.Command` variants that only a
session's own endpoint receives, one reserved fact namespace, and one
model-visible `peer_send` result.

#### Cells and commands

Each message the session sends has one reserved fact,
`client/peers/outbox/<digest(sending strand, recipient session, message id)>`,
in the sending session's store. Its value is the strand, the recipient session
and strand, the message id, `queued_at` in the session clock's milliseconds, and
a state: `pending` with the text, `admitted` with the recipient's receipt, or
`refused` with a reason. The key space is not in the catalogue and is not
readable through the blackboard tools.

`peer_mail.OutboxClaim` writes the row `pending` with a compare-and-set that
expects the key to be absent. A row already stored answers instead: the same
request that is `pending` is resumed, the same request that is `admitted` is
answered with its receipt, a `refused` row is replaced, and a different request
is refused with the recipient's own text, `message id was already used for
different content or target`. `OutboxSettle` records an attempt's outcome on a
`pending` row only, so the first outcome stands. `OutboxDue` lists the pending
rows after refusing any older than one hour, and `OutboxReceipt` reads an
admitted row's receipt. `Unlink` also deletes the pending rows to the removed
link.

An endpoint reports that nobody answered with the error text
`peer_mail.owner_unreachable` (`owner unreachable`). Every other error from a
recipient is definitive. A local endpoint never returns it.

#### The `queued` result

When the first attempt finds the owner unreachable, `peer_send` and
`peers.send` return `{"state": "queued", "session", "message_id", "note"}`
instead of a receipt, and the sender's drainer keeps attempting the message. A
program calling `cap/peer.send`, which is typed to return a receipt, receives
the denial code `peer_queued` with the same note, so `cap/peer` and the
capability prelude do not change. `peer.sent_receipt` returns the receipt from
the sender's own row once the message is admitted, and so does sending the same
message id again.

#### Bounds

A sending strand keeps at most 64 rows. Sending a new message at the bound
evicts the oldest finished row, and is refused with `outbox_full` when every row
is pending. A row pending for more than one hour is refused with
`owner unreachable`.

#### What it costs

Every `peer_send`, including one to a local session, writes one row and
updates it: two extra Agency calls and two small commits in the sender. A
finished row stays until it is evicted, so a strand that sends many messages
holds up to 64 rows of receipts, each about the size of the message. A message
queued for an hour and then refused has been attempted about 720 times, each a
bounded call. And a model that sends the same id again after an hour gets a new
attempt, because a refused row is not final.

### Addendum: peer mail between orchestrators

The second half of phase 4. A session on one orchestrator sends to a session on
another by way of the second orchestrator's port. It adds one constructor to the
orchestrator port's closed message type and changes the error type of two Gleam
interfaces. It changes no client-protocol frame and no Part 1 interface.

#### The wire command

`orchestrator_port.Message` gains
`PeerCommand(session, command, reply: Subject(Result(JsonValue, String)))`,
beside `Owns`. `session` is the recipient's canonical identity and `command` is
a `peer_mail.Command`, which is plain data. The port serves exactly four
commands, the ones a recipient receives from `client/peers`:

- `Allow(grant)` writes the recipient's grant, for `peers.link`.
- `Revoke(grant)` removes it, for `peers.unlink` and `peers.unlink_session`.
- `Deliver(source, target, message_id, text)` admits a message and stores its
  receipt under `client/peers/receipt/<digest(source session, strand, id)>`, for
  `peers.send` and the outbox drainer.
- `SentReceipt(source session, strand, id)` reads that receipt, for
  `peer.sent_receipt`.

Every other `peer_mail.Command` is answered `Error("that command is not served
to a peer orchestrator")` without reaching the session. The port forwards a
served command to the resident session's own endpoint (`manager.resolve`, then
the endpoint the daemon's `peer_endpoint` projects), and a session that is not
resident on that orchestrator is answered `that session is not running; the
owner has to open it`, the refusal a send within one daemon gets. Admission is
unchanged: `peer_mail.deliver` runs in the recipient's Agency, the recipient's
grant is the authority, and a repeated `Deliver` is answered with the stored
receipt. The command crosses the same pinned distribution connection as `Owns`.

#### Resolving a recipient

`Directory.resolve` answers a session resident on the asking orchestrator with
that session's endpoint, without asking the session directory. For any other
session it asks `session_directory.lookup`. `Elsewhere` gives a remote endpoint
that sends `PeerCommand` to the owner's `loom_orchestrator`. `Unreachable`, which
means some orchestrator could not be asked and none said it holds the session, is
unreachable. `Here` and `Unknown` keep the local refusal. The control commands
`peers.link`, `peers.send` and `peers.unlink` and a session's `peer_*` tools all
resolve this way, so a session on another orchestrator can be linked, written to
and unlinked from a control socket.

#### The typed failure

The outbox addendum above had an endpoint report that nobody answered with the
error text `owner unreachable`. That is replaced. `Endpoint.call` returns
`Result(JsonValue, peer_mail.Failure)` and `Directory.resolve` returns
`Result(Endpoint, peer_mail.Failure)`, where `Failure` is `Refused(reason)`, a
definitive answer, or `Unreachable`. `peers.send` and the drainer match on the
variant. The text `owner unreachable` remains in two places: the reason recorded
in a row that waited an hour, and what an operator or a model is shown when a
call other than a send finds the owner unreachable.

A remote call ends in `Unreachable` when the port's node is not connected
(`noconnection`), when no port is registered there (`noproc`), and when no answer
comes within seven seconds. A reply that arrives later is dropped. The recipient
may have committed the message by then, and the drainer's next attempt is
answered with the stored receipt.

#### What it costs

A `Deliver` on a remote orchestrator waits on the recipient's Agency inside the
port's loop, so a session that does not answer delays the next `Owns` question,
and with it the other orchestrator's directory lookups, by at most the Agency's
five-second holder timeout. `Roster` and `Describe` are not served, so a
recipient on another orchestrator is listed as running with no exported strands,
and `peers.inspect` shows no wake permission for the link. A message to a
recipient that its owner holds but has not opened is refused, not queued, as
protocol-change/077 requires, which means a recipient has to be opened again
after its owner restarts before a queued message can be delivered. And a granting
or revoking command from a pinned peer orchestrator is trusted on the same
footing as the pinned connection itself: the port limits the kinds of command so
that the sender cannot read a session's conversation, not to defend against a
peer the operator has already trusted with the node.

### Addendum: the review of the remote core

An independent review of phases 1 and 2 found two defects that need a wire or
operator change. The smaller items are fixed in code and noted where they
belong.

#### The executor's clock at each attach (protocol version 2)

`Attached` gains `executor_now_ms`, the executor's wall clock read by the host
when it sends the reply, and the field of the same name leaves the census.
`protocol.version` goes from 1 to 2, because the shape of a reply changed. The
census is built once, when the scope's plane is built, so a rebound attach that
read the clock from it rebased the orchestrator's `call_clock` on a timestamp
as old as the scope. Every absolute deadline a hook, a goal check or a Git
observation then put into a `CallSpec` was in the executor's past by that age.
Tool runs were unaffected, because their deadlines are made on the executor.

#### The operator's release of a stuck scope

The ruling that a scope with unknown cleanup gets no automatic successor left no
way out, and a restart of the executor's VM makes that scope the usual outcome. The
new VM has no plane for a scope it did not build, so when the session closes, its
close finds no witness and records `UnknownCleanup(0)`. Every later attach of that
session is refused as an unclean close, the scope holds one of the sixteen slots,
and the only remedy was deleting the ledger file, which also discards the
unacknowledged outcomes. A host that ends between `begin_close` and `finish_close`
leaves a `closing` scope with the same effect.

`loomd executor release SESSION [--state-dir PATH]` is the explicit, recorded
override. It runs on the executor with the executor daemon stopped, and it takes the
state directory's endpoint reservation first, which a live daemon holds, so it
cannot open the ledger beside one. It moves a `closing` scope, or a `closed` one
with unknown cleanup, to `closed` with `all_retired`, and refuses an `open` scope
and a clean one. The ledger is at schema version 2 for this: a `scope_release`
table gets one row per release, with the former state and the executor's clock,
written in the same transaction as the change. A version 1 file gains the table
when it is opened, and an older build refuses a version 2 file.

The orchestrator's record changes with it. A close with unknown cleanup used to
attach again at the stored incarnation, which a released scope refuses as stale,
because a reopen names the next incarnation. The record now attaches at the
incarnation after any close that ended one, clean or not. While the scope still
holds unknown cleanup the executor refuses that attach as before. The refusal now
names the command.

#### Acknowledgements leave a tombstone (ledger version 3)

The P model of remote execution (`protocol/models/remote-execution`) found that a
`Run` could start a key that recovery had fenced and the orchestrator had
acknowledged. A runtime restarts inside one open, so the attach token is
unchanged. The dead effect process's `Run` is delayed. Recovery's `QueryOrFence`
from a new process overtakes it, because Erlang orders messages only per sender
and receiver pair, and stores the fence. The model is told the call did not run,
the acknowledgement deletes the row, and then the late `Run` finds no row and a
current token and starts the call.

An acknowledgement no longer deletes the key. It deletes the row, which releases
its outcome and its reserved bytes, and leaves a tombstone, a row in a new
`call_ack` table. A key with a tombstone is never admitted again in that
incarnation: `Run` for it is answered `RunLost`, and a `Query` for it reports
`Unknown`. Tombstones are dropped when the scope reopens at a new incarnation,
which refuses the old incarnation's requests by itself, when it closes with every
child retired, and when an operator releases it. They are not counted in the byte
budget. The ledger is at schema version 3, and an older file gains the table when
it is opened. The wire does not change. The ledger's earlier rationale for a
deleted row, that the orchestrator never re-sends a `Run` for a settled key, was
true of the orchestrator and not of a dead runtime's in-flight message, which is
why the row's refusal has to outlive the acknowledgement.

#### A restarted executor answers a call it holds a row for

After the executor's VM restarts, the host holds no plane until the next attach,
and it refused every `Run` with `NoPlane`. The surface stages that refusal as one
that says the call did not happen, even for a key whose row the restart turned
`unknown`. The host now looks the key up in the ledger first: a stored outcome is
answered, a lost one is answered `RunLost`, and only a key with no row is refused
for the missing plane.

### Addendum: background code mode and MCP façades on a remote session

**Status**: ACCEPTED 2026-10-09, revised after an independent design review
(findings F1 to F7 below are folded in). Implemented at protocol version 3 on
the branch `distributed/remote-codemode`, stacked on PR #923; the P model
checks the execution path, and the shipped fixtures
`daemon_shipped_remote_background_test` and `daemon_shipped_remote_mcp_test`
drive both paths between two daemons.

A remote session refused four features that read orchestrator-side state. This
addendum adds two of them: background code mode (`async_runs`,
`async_codemode`) and the MCP façades inside code mode. Extension tools and
operator-added directories stay refused (see "What stays refused" below). The
owner's rulings are binding here: the orchestrator owns the durable record of a
background execution and the executor only runs the program; each MCP server is
placed on the orchestrator or on the executor by a key in its `[mcp.<name>]`
table; and the work lands as its own pull request on top of PR #923.

The change bumps `protocol.version` from 2 to 3. It adds two `HostMessage`
constructors, two `OwnerMessage` constructors and two `OwnerServices` functions,
one field on `Attach`, one field on `Unacked`, one variant on `Lookup`, and one
field on the census. The ledger gains one operation and one query, and its
tables and schema version (3) do not change. The execution record gains one
optional field. One `loom.toml` key is added. No Part 1 interface moves.

#### Background code mode: who does what

A local background execution has three parts. `async_runs` claims a durable
record, keeps the input journal, the volatile progress and delivery
observations, the cumulative and live ceilings and the idle expiry, sends the
completion notice and recovers after a restart. A worker closure runs
`codemode.execute` inside a weft scope with a fixed deadline. A router in
`async_codemode` binds the `execution.*` and `workflow.step` capabilities and
the execution's own Agency custody to that one record.

On a remote session the first part stays on the orchestrator unchanged. The
worker becomes a process on the orchestrator that asks the executor to run the
program and waits for its result, the way an effect process waits on a `Run`.
The program runs on the executor beside the checkout. The capabilities that
read the record already go back to the owner: `client/cap_placement` places
`execution.*`, `workflow.step`, `strand.*`, `notes.*`, `schedule.*` and
`peer.*` on the owner, and the executor's `owner_codemode.sent_to` sends them
over the owner port. So the program's inputs and progress need no new message.
A program reads its next input with `execution.receive` or
`execution.receive_enveloped` and publishes progress with `execution.progress`,
each a `Capability` call that `async_runs` answers from the journal it already
keeps.

#### The execution key

An execution's row in the executor's ledger has the key
`Key(session, op, "async/" <> id, 0)`. `op` is the launching call's operation
and `id` is the execution's identity, `agent.call_site_digest` over the
launching call's strand, operation, step and source index, as `async_codemode`
mints it today. `"async/" <> id` is already the record's `step` and the broker
step every effect of the program runs under. The source index is always 0,
because the step alone names one execution. No planner step starts with
`async/`, so an execution key never equals a tool call's key. The row's `tool`
column holds `execution`, a name no tool has, so the host and the reconciler
can tell an execution row from a tool call's row without parsing the step.

The row follows the ledger's existing rules: it is admitted once by key in the
transaction that checks the scope's state, incarnation and attach token; it is
`terminal` before any reply; it becomes `unknown` before a cancelled run's
worker is killed and when the executor's VM restarts; an acknowledgement turns
it into a tombstone for the rest of the incarnation.

An execution row reserves 1 MiB (`host.execution_result_bytes`), not the
16 MiB a tool call reserves. The ledger's 512 MiB budget belongs to the whole
executor and not to one session, and an execution can hold its reservation for
up to 15 minutes, so 32 executions at 16 MiB would refuse every tool call on the
machine with `BudgetExhausted` until one ended. At 1 MiB they hold 32 MiB. A
result larger than the reservation is replaced, exactly as `host.commit_outcome`
replaces an oversized tool outcome: the stored value is an errored execution
value that names both sizes. The completion notice quotes 2 KiB of a result,
and a program with more to return writes it with `report.emit` and returns the
reference. The stored value is the execution value that
`tools/codemode.execution_value` renders, under its own envelope in
`remote/codec` (`{"kind": "execution", "value": ...}`) and decoded totally.

#### New messages

Orchestrator to executor, two constructors join `HostMessage`:

| Message | Meaning |
|---|---|
| `StartExecution(key, incarnation, token, terms, remaining_ms, reply)` | Run one background program, idempotently by `key`. Admitted only if `incarnation` and `token` equal the scope's, exactly as `Run` is. A new row starts the program; an `admitted` row adds the sender to its waiters; a `terminal` row answers the stored value; an `unknown` row or a tombstone answers `ExecutionLost`. The host monitors the sender, and the last waiter's `DOWN` with any reason but `noconnection` cancels the program, as for `Run`. `remaining_ms` is the time left before the record's deadline, measured on the orchestrator's clock when the message is sent. The executor builds the program's deadline from it on its own clock at admission; a re-send carries a smaller value, and admission ignores it because the program is already running. |
| `StopExecution(key, incarnation)` | The orchestrator's record of this execution has closed: an owner's cancel, an abort of the launching operation, a session stop, the deadline, an idle expiry or a restart. The host calls the ledger's new `stop_or_fence` and then, if the row was running in this VM, cancels the program and aborts its broker step. There is no reply. |

`exec_ledger.stop_or_fence(key, incarnation)` is one `BEGIN IMMEDIATE`
transaction with an incarnation check and no token check. It turns an
`admitted` row `unknown` and releases its reservation; it inserts a key with no
row as `unknown` with `outcome_bytes` 0, so the fence costs no budget; and it
leaves a `terminal` row, an `unknown` row and a tombstone as they are. A request
at an incarnation other than the scope's changes nothing. It is the same shape
as `query_or_fence`, for the same reason: a late `StartExecution` then finds the
key taken. The inserted row is listed by `LedgerUnackedKeys` like any `unknown`
row, so the reconciler acknowledges it once the record is terminal and the key
becomes a tombstone. No token check is needed because a stop is always safe to
apply: an execution key is minted by one launching call, which runs once, so
the record a stop names is the only record the key will ever have.

The reply to `StartExecution` is a new type:

```gleam
pub type ExecutionAnswer {
  /// The program ended, and this is `execution_value` of its run.
  ExecutionFinished(value: JsonValue)
  /// The execution was admitted and its outcome is lost: the executor
  /// restarted, the program was stopped, or its worker died. It may have run.
  ExecutionLost
  /// The execution was not admitted.
  ExecutionRefused(refusal: Refusal)
}
```

The host's waiter, live-call and commit machinery is generalised over the two
kinds of call, a tool call and an execution, and not copied: a waiter holds
either reply subject, a live call records its kind, and the settled answer is
converted into the waiter's reply type when it is sent. `Lookup` gains
`Executed(value: JsonValue)`, the answer `Query` gives for a terminal execution
row, so recovery can read a stored execution value.

`ListUnacked`'s reply, `Unacked`, gains `executions: List(Key)`: the scope's
execution rows that are still `admitted`, read by a new ledger query. The
reconciler uses it to stop programs whose record has closed (see
"Acknowledgement and orphans" below).

`terms` is a new plain-data record, `ExecutionTerms`. It carries what the
launching tool call captured on the executor and nothing the executor can
derive again: the strand, the operation, the launching step and source index,
the program's source text (already loaded, so a `program_path` is read once, at
launch, beside the checkout), the seam's name, the requested `within_ms`, the
directory access and the grants the launching call held. Every field is a type
the vocabulary already carries (`Authority` holds the directory access and the
`Grant`s). The executor rebuilds the rest of the `tools/codemode.Request` at
admission from its own plane: the workspace root, the base policy, the
enforcement demand and the child environment. The child environment is resolved
from the executor's own `[tools] env` and `[secrets]`, so no environment value
crosses the wire in either direction. A background program's build output is
not streamed, because no running tool call is left to stream it to.

Executor to orchestrator, two constructors join `OwnerMessage`, backed by two
new `OwnerServices` functions:

| Message | Meaning |
|---|---|
| `LaunchExecution(terms, reply)` | The executor's `code_mode` tool was called with `mode: "launch"`. The owner builds the record (deadline on its own clock, `now + within_ms`), claims it with `async_runs.launch` and answers the handle, or the refusal `async_runs` gives today. |
| `InteractExecution(strand, handle, interaction, within_ms, reply)` | The executor's `code_mode` tool was called with `check`, `join`, `cancel` or `send`. The owner answers with `async_runs.interact`, which checks that the strand owns the handle. |

A local session never calls either function, as it never calls `capability`.
`owner_link` bounds `LaunchExecution` by its 15-second record budget and
`InteractExecution` by `within_ms` plus a two-second slack.

#### The launch, start to finish

1. The model calls `code_mode` with `mode: "launch"`. It is a workspace tool,
   so the orchestrator sends it as an ordinary `Run`.
2. On the executor the tool authorizes the call, loads the source and builds
   its request as it does locally. Its `Background.launch` is
   `OwnerServices.launch_execution`, which sends `LaunchExecution(terms)`.
3. On the orchestrator the owner port calls `async_runs.launch` with a worker
   that sends `StartExecution` through the host link the attach bound to the
   port. `async_runs` claims the record (`Running`) before it starts the
   worker, as it does locally, and answers the handle. The tool call on the
   executor returns the handle, and its `Run` finishes.
4. The worker sends `StartExecution`. The host admits the key and starts the
   program as a weft run that calls the plane's new `execute` function. The
   function runs `codemode.execute` with the step `async/<id>` and a fixed
   deadline of `remaining_ms` on the executor's clock.
5. The program's owner-bound calls cross the owner port as `Capability`
   messages. Its workspace calls are served on the executor under the broker
   step `async/<id>`.
6. When the program ends, the host commits the row `terminal` and answers
   `ExecutionFinished(value)` to every waiter. The worker returns the value,
   and `async_runs` saves `Finished(value)` and sends the completion notice as
   it does locally.

The worker reuses the surface's repair loop. When the connection drops it
reconnects with a pause that doubles from 50 ms to 2 s and sends the same
`StartExecution` again, until it gets an answer or is killed. `ExecutionLost`
and `ExecutionRefused` end the worker with a reason, and `async_runs` saves
`Lost(reason)`. For that, the work closure `async_runs` runs returns
`Result(JsonValue, String)`, and `Error(reason)` is saved as `Lost(reason)`
instead of the generic "execution worker lost".

If the reply to `LaunchExecution` is lost, the record is claimed and the
program starts, but the launching tool call reports the owner unreachable. The
executor can compute the handle from the launching call's coordinates, so the
failure text names it, says the execution may have been launched, and tells the
model it can `check` or `cancel` that handle.

#### Binding a background program's calls on the owner

Locally a background program's router is built per launch, so its
`execution.*`, `workflow.step` and `strand.*` calls are bound to its record and
its Agency custody (`AsyncCustody(strand, op, id, Owned)`) by closure. On a
remote session the owner receives an `OwnerCapCall`, whose `step_id` is the
step the executor's tool shell filled in, never a value from the program. A
background program's calls carry the step `async/<id>`. The owner answers such
a call in that execution's custody only when the record for `id` exists, its
`strand` and `operation` equal the call's, and its phase is `Starting` or
`Running`. A call whose record has closed is refused with `execution_closed`,
and a call naming an `async/` step with no record is refused with
`execution_unknown`. A foreground program's calls keep the planner's step and
are answered as they are today. The `OwnerCapCall` shape does not change.

The owner then composes the arms `async_codemode.launch` composes locally: the
input router, the workflow router and the Agency's `async_seam` over the
execution's custody. The local composition gives two identities. `strand.*`
calls are made by the caller `(strand, op, "async/<id>", source_index,
Program(ordinal))`, which the owner has from the call. `workflow.step` is made
by the launching call's caller, `(strand, op, <launching step>, source_index,
Program(ordinal))`, and the launching step is not in the call. So the record
gains an optional `launch` field holding the launching step and source index.
`async_codemode` writes it for every launch, local or remote, and the total
decoder reads an older record without it as `None`. A remote `workflow.step`
whose record has no `launch` is refused with `execution_unknown`, which can only
happen to an execution launched by an earlier build.

#### A link cut and the program's owner-bound calls

A typed-service program (`cap/execution.serve`) ends on the first failed
`execution.receive_enveloped`, because its loop treats any error as fatal. An
owner-bound call that is denied `owner_unavailable` at the first `DOWN` would
therefore end every such program on any link cut, however short. So a few
owner-bound calls wait for the link to come back instead.

When the owner port's node is disconnected, a monitor of the port fires at once
with `noconnection`. For the calls below, `owner_link` treats that `DOWN` as a
reason to wait, not to deny: it polls every 100 ms, re-reads the link's current
port each time (a rebound attach may have re-pointed it), and sends the same
request again once a monitor no longer fires with `noconnection`. The executor
never dials, so the link comes back when the orchestrator reconnects, which the
worker's repair loop does within two seconds of the network returning. A
`DOWN` for any other reason, such as a port that died because the session
closed, is denied at once as today.

| Call | Why retrying is safe | How long it waits | When the wait runs out |
|---|---|---|---|
| `execution.receive`, `execution.receive_enveloped` | Keyed by the program's cursor: the owner answers the first input after `after`, so a retry after a lost reply returns the same input and never the next one. Publishing the default endpoint's readiness is idempotent. | the call's own `within_ms` (at most 30 s) | the answer "no input yet" (`nil`), which is true: no input was delivered. `serve` then asks again. |
| `execution.ready` | Readiness is immutable; publishing the same set again answers as the first did. | 120 s | `owner_unavailable` |
| `execution.progress` | The snapshot is replaced by the same value; only its sequence number moves. | 120 s | `owner_unavailable` |
| `execution.delivery` | Keyed by the input's sequence; recording the same observation again changes nothing a reader can see. | 120 s | `owner_unavailable` |

Every other owner-bound call keeps today's immediate denial, because a retry
could act twice: `strand.spawn`, `strand.send`, `strand.wait` and
`workflow.step` admit or wake children; `notes.put` writes a cell another
writer may have changed in between; `schedule.*` and `peer.send` create
records. The read-only calls (`strand.roster`, `strand.notes`, `notes.get`,
`notes.list`, `notes.read`, the `peer.*` reads) are denied as well: retrying
them would be safe, but a program already handles their denial, and keeping the
retry list to the calls a typed service cannot do without keeps it short.

The idle clock is on the owner (`async_runs` measures it from readiness or the
last delivered input). No input can be delivered during a partition, so a
partition counts as idle time: an outage longer than the program's
`idle_within_ms` reaps it as `Lost("execution idle timeout")` on its first
receive after the link returns.

#### Cancellation

A program is cancelled only on a decision the orchestrator recorded, never on
`noconnection`. The decision is the record leaving `Starting` or `Running`.
`async_runs` makes it in the places it makes it today (`close`, `recover`,
`on_shutdown`, `abort_operation`, the deadline and idle sweeps), and for a
remote session its `abort` closure sends `StopExecution` for the execution's key
instead of aborting a local broker step. `async_runs` also cancels the worker,
and the host sees the worker's `DOWN` with a reason other than `noconnection`,
which cancels the program a second way. Both paths are idempotent.

A `noconnection` `DOWN` drops the worker as a waiter and leaves the program
running, so a link cut never stops it. When the record closes during a
partition, `StopExecution` and the worker's death are both lost with the
connection. The program then runs until the executor's deadline, which is the
record's deadline less the time the start took to arrive, or until the
reconciler stops it after the link returns. A background program's deadline is
at most `max_within_ms`, 15 minutes, which bounds how long such a program can
outlive its record. While it runs, its owner-bound calls are refused with
`execution_closed`, so it cannot spawn a child, read input or write a note.

#### Acknowledgement and orphans

The owner port's reconciler acknowledges an execution row by a different rule
from a tool call's row. `workspace.settled` accepts an execution key only when
the record for its `id` is terminal (`Finished` or `Lost`) or absent. The tool
call rule would accept it at once, because no planner batch lists an `async/`
step, and an acknowledgement that came before the worker read the result would
leave a tombstone. The worker's re-send would then get `ExecutionLost`, and a
finished program would be recorded as lost. "Absent" is safe because
`async_runs` claims the record before the worker exists, so a row implies a
record, and an absent record means a deleted session.

The reconciler also stops orphans. At attach and on every pass it reads
`Unacked.executions` and sends `StopExecution` for each key whose record is not
`Starting` or `Running`. That covers a stop lost to a partition and a program
left running by an orchestrator that restarted. A `StopExecution` that is lost
needs no retry of its own: a connection drop that loses it also loses any
`StartExecution` still in flight on the connection, and a `StartExecution` that
was delivered left an `admitted` row, which the next pass sees.

#### Recovery

**An orchestrator restart.** The program keeps running on the executor, because
its waiter left with `noconnection`. The new open attaches at the same
incarnation with a new token (`Rebound`), which re-points the scope's owner link
to the new owner port. `async_runs.recover` then asks the executor what it holds
for each record that was `Starting`, `Running` or `Draining` (a `Query` of the
execution key, bounded at five seconds). A row that is `terminal` holds a value
the ledger committed before the restart, and the record is saved
`Finished(value)`, the way a tool call recovers as `Recovered(outcome)`; only
the heap is gone, and a finished program no longer needs it. Any other answer
(still `admitted`, `unknown`, no row, or no answer at all) marks the record
`Lost("execution service restarted")`, and the `abort` closure sends
`StopExecution`. Either way the launching strand gets one completion notice.
The reconciler's attach pass is the second path for the stop. A program that
was still running is never resumed: the owner's ruling keeps the local meaning
of a restart for any execution that had not ended.

**An executor restart.** `exec_ledger.open` turns the `admitted` row `unknown`,
as for any call. The worker's re-send is answered `ExecutionLost`, and
`async_runs` saves `Lost` with a reason that says the executor restarted and
that the program may have done part of its work. Nothing is replayed. New
launches on the session fail as new tool calls do after an executor restart,
until the session is closed and reopened.

**A stale incarnation or token.** `StartExecution` is admitted under the same
check as `Run`, so a dead open's in-flight start is refused by value. Within one
open, a worker that died (because `async_runs` restarted) may have a
`StartExecution` still in flight while the new `async_runs` records the
execution as lost and sends `StopExecution` from another process. Either order
is safe: a stop that arrives first inserts the key as `unknown` and the late
start is answered `ExecutionLost`; a start that arrives first is admitted and
the stop cancels it.

**A scope close.** `Close` cancels the scope's live calls, and an execution row
is one of them. On a session stop, `async_runs` records `Lost("session
stopped")` first, because the session's services stop before its workspace.

#### Two clocks

The record's deadline is the orchestrator's (`deadline_ms`), and the sweep in
`async_runs` enforces it there. The program's deadline is built on the
executor's clock from `remaining_ms`. The two end at about the same moment, and
clock skew only decides which side ends the execution first and with which
reason. It never decides whether the program runs twice, because the row is
admitted once.

#### MCP: the placement key

Each `[mcp.<name>]` table on an orchestrator gains `runs_on`, with the values
`"orchestrator"` (the default) and `"executor"`. A local session ignores the key
and starts every server on its own daemon, as it always has, so the table keeps
`command` and `api_key_env` in both placements. On a remote session the key says
where the server is expected to answer. One program may import façades of both
placements.

#### MCP on the orchestrator

For an orchestrator-placed server the orchestrator does what a local session
does: it resolves `api_key_env` through its own secret store, spawns the server,
lists its tools and generates the façade (`codegen.Generated`: the module name,
the source text and the declaration surface). It does so before the attach,
which is where a local session starts its servers too. The key's value stays on
the orchestrator.

The executor receives only the generated façades, in the attach (below). It
uses them in the three places a local host uses its MCP layer and does not
need a client for: the vetting allowlist (`cap/mcp` and one `cap/mcp/<server>`
per server), the `code_mode` description and the `cap://mcp/<server>` reads,
and the generated table the hermetic build writes into the vendored prelude.
The fourth place, the router arm, stays on the orchestrator: `cap_placement`
already places `mcp.<server>` on the owner, so the executor sends the call over
the owner port, and `owner_codemode.answering` gains the `client/mcp.routing`
arm over the session's layer. A call's 60-second MCP timeout sits inside the
owner link's 120-second capability budget. The owner checks only that its layer
holds the server for the call's seam, as a local router does; vetting on the
executor is what limits a program to the servers it imported.

If the census shows that the executor offers no `code_mode`, the layer the
orchestrator started stays up for the session and answers no call, because no
program can import its façades. Spawns wasted this way are an accepted cost.

#### MCP on the executor

An executor-placed server runs on the executor, beside the checkout, from the
executor's own `[mcp.<name>]` table: its `command` argv and its `api_key_env`.
The executor reads the table with the same parser a local daemon uses, and
ignores `runs_on` in it, since a server in the executor's own file can only run
there. The orchestrator's table, with `runs_on = "executor"`, states only the
expectation that the server answers on the executor. The attach carries the
names of the servers the orchestrator expects there and nothing else about
them: no argv and no variable name crosses the wire. So the rule that
configuration naming a path on a machine lives on that machine holds without an
exception, and an orchestrator's configuration cannot make an executor run an
unjailed command.

The executor starts each expected server that its own file declares, resolving
`api_key_env` through its own `provider/secret` store (its `[secrets]` table,
then its environment), as a local daemon does. The value never crosses the wire.
A server the executor declares and the orchestrator does not expect is not
started. The census reports, for each expected name, either the tool count of a
server that started or the reason it did not: the executor declares no such
table, the key variable is not set there, or the server failed its handshake or
its listing. The orchestrator logs each refusal as `mcp.unavailable` with
`placement = executor`, and the program sees no module for that server, as
after a local `mcp.unavailable`. A missing table is therefore found at attach,
in words, and never at a call.

The executor's plane starts the servers when it is built and owns their clients
for the plane's life. The plane closes them when the scope closes, after the
helper pool and the workspace, in the order a local daemon retires the same
parts. A client whose server does not exit within its five-second grace
is killed, and it does not count toward the scope's `UnknownCleanup`: the
retirement witness protects the checkout from jailed children that may still
be writing, and an MCP server is neither jailed nor a helper child. On a local
daemon the same timeout is a log line, and the executor logs it the same way. A
server process is spawned unjailed on the executor, with the executor daemon's
privileges, which is the posture a local daemon has (#109 is still open). A
call to an executor-placed server is answered on the executor by the plane's own
`client/mcp.routing` arm and never crosses the network. The executor's router
therefore treats `mcp.<server>` as workspace-bound when the server started on
the executor, and owner-bound otherwise. The owner refuses an executor-placed
name it is sent with `unsupported_cap`, because its layer does not hold that
server.

An orchestrator that also runs local sessions starts an executor-placed server
locally for them, since a local session ignores `runs_on`. Such an orchestrator
needs the server's key variable on both machines, or its local sessions log
`mcp.unavailable` for that server.

#### MCP: what the attach carries

`Attach` gains `mcp: McpPlan`:

```gleam
pub type McpPlan {
  McpPlan(
    /// Façades of the servers the orchestrator runs, generated there.
    served: List(Facade),
    /// The servers the orchestrator expects the executor to run, by name.
    expected: List(String),
  )
}

pub type Facade {
  Facade(server: String, module_name: String, source: String, surface: String)
}
```

A plan is at most a few MiB: each façade is bounded by the generator at 512 KiB
of source and 64 KiB of surface. `surface.attach` re-sends the same `Attach`
while the executor is still building the plane, so each re-send carries the
plan again; on the links this design targets that is a few MiB per re-send for
at most 30 seconds, and it is accepted rather than adding a second message. The
census gains `mcp`, one entry per expected server, as described above.

The plan is fixed for the life of the plane, that is, for one incarnation. A
`Created` or `Reopened` attach builds the plane from the plan it carries. A
`Rebound` attach, which happens only when a new open takes over a scope after an
orchestrator restart, keeps the plane and the plan it was built with, and the plan the
new attach carries is not used. The census the rebound attach answers with is
the one the plane was built with, so the orchestrator's `mcp.ready` and
`mcp.unavailable` lines describe the plan in force. The reason is that the executor-placed servers live with the plane and may be in use
by a running program, and the `code_mode` description was rendered from the
plan when the plane was built. A stale orchestrator-placed façade fails in
band: a server removed from the configuration answers `unsupported_cap`, and a
tool the server no longer lists answers its own JSON-RPC error. A changed plan
takes effect at the next reopen.

#### Failures

| Failure | Background execution | MCP, orchestrator placement | MCP, executor placement |
|---|---|---|---|
| Link cut | The program keeps running. `execution.receive*` waits for the link within its own wait and then answers "no input yet", so `serve` keeps looping; `execution.ready`, `progress` and `delivery` wait up to 120 s. Other owner-bound calls are denied `owner_unavailable` at once. The worker re-sends `StartExecution` and joins the run, or reads the stored value if it ended. A partition counts as idle time, so one longer than `idle_within_ms` reaps the program as idle when the link returns. The model's `check`, `send` and `cancel` are `code_mode` calls, which run on the executor, so they wait for the link like any workspace tool. | A call in flight is denied `owner_unavailable`. The server may have acted, as it may after `mcp_timeout`. | Calls are unaffected: client and server are both on the executor. |
| Executor restart | The row becomes `unknown`. The worker's re-send gets `ExecutionLost`, and the record is `Lost` with a reason that says the program may have run part of its work. Nothing is replayed. | The servers on the orchestrator are unaffected; no program is left to call them. | The servers die with the VM. The reopen after `loomd executor release` builds a new plane and starts them again. |
| Orchestrator restart | The new open rebinds the scope. `async_runs.recover` queries each live record's key: a `terminal` row is saved `Finished(value)`; anything else is saved `Lost`, and `StopExecution` and the reconciler stop the program. The strand gets one completion notice either way. | The servers die with the orchestrator. Programs on the executor get `owner_unavailable` until the new open; the new open starts the servers again. | The servers keep running with the scope. A program keeps calling them. |
| Duplicate start | A re-sent `StartExecution` joins the live run or reads the stored row; the ledger admits the key once. A second `LaunchExecution` for one call is not sent, because `owner_link` sends once and `code_mode` is never replayed. If one arrived, `async_runs.admit` would find the record, compute a different deadline and refuse it as a handle collision; it never starts a second worker. | Not applicable. | A `Rebound` attach does not start the servers again. |
| Cancel racing a finish | The orchestrator's record decides. `async_runs` keeps the first terminal phase it settles on, as it does locally. If `StopExecution` reaches the host first, the row becomes `unknown` and the record is `Lost`. If the program's commit comes first, the stop changes nothing, and the record keeps whichever phase `async_runs` settled first. Either way the row is acknowledged once the record is terminal. | Not applicable. | Not applicable. |
| MCP server dies | Not applicable. | The client latches dead and every later call is `mcp_unavailable` in band. It is not restarted, as on a local session; the next open starts it again. | The same, on the executor. It starts again at the next reopen. |
| Expected server missing on the executor | Not applicable. | Not applicable. | Found at attach: the census says the executor declares no table, the orchestrator logs `mcp.unavailable`, and the module is absent. |
| Server slow to exit at close | Not applicable. | As on a local session: a log line. | Killed after five seconds and logged; the scope's close is not made unclean by it. |
| Launch reply lost | The record is claimed and the program starts, but the launching tool call reports the owner unreachable. Its failure text names the handle so the model can `check` or `cancel` it. | Not applicable. | Not applicable. |
| Ledger budget full | `StartExecution` is refused `BudgetExhausted` and the record becomes `Lost` with the refusal's text. The budget is the executor's, shared by every session; an execution holds 1 MiB of it while it runs. | Not applicable. | Not applicable. |

#### The P model

The P model `protocol/models/remote-execution` covers the background execution,
because its rules are the ones the model already checks, with two new senders on
the orchestrator: the worker and the process that sends `StopExecution`.

- **Machines.** An `Exec` machine on the orchestrator for the worker: it sends
  `StartExecution`, re-sends after a break, and reports to `Orch`. `Orch` gains
  one execution record per key, with the phases live, finished and lost, and a
  reconciler step that asks for `Unacked.executions`, stops the keys whose
  record is not live, and acknowledges the settled ones. `Host` gains
  `startExecution` (the `admitRun` path over execution keys) and
  `stopExecution`.
- **Faults.** `Chaos` gains an owner's cancel and a deadline (the record becomes
  lost, the worker is killed and a stop is sent) beside the existing breaks,
  executor crashes, open crashes and runtime restarts.
- **Specs.** `AtMostOnceStart` and `UnknownIsFinal` extend to execution keys
  unchanged. New: `ExecNoStartAfterStop` (once the host has processed a stop
  for a key, no program for the key starts); `ExecFinishedIsStored` (a record
  is finished with a value only if the ledger stored that value as terminal);
  `ExecLostOnExecutorRestart` (a key admitted when the executor restarts never
  ends finished, and its program never starts again); `ExecStopOnlyOnDecision`
  (a running program is cancelled only by a stop for a closed record or a
  killed waiter, never by `noconnection`); `ExecNotLostWhenFinished` (a
  program that committed its value while its record was live and no stop was
  decided ends finished); `ExecAckOnlyWhenRecordTerminal` (the reconciler
  acknowledges an execution key only while its record is finished or lost); and
  the liveness spec `EveryExecutionSettles` (every claimed record becomes
  terminal, and every admitted row whose record closed eventually becomes
  `unknown` or `terminal`).
- **Mutants.** `M8-stop-does-not-fence` (a stop for a missing key inserts
  nothing; caught by `ExecNoStartAfterStop`); `M9-noconnection-stops` (the
  worker treats a break as a cancel; caught by `ExecStopOnlyOnDecision`);
  `M10-settled-ignores-record` (the reconciler acknowledges a terminal execution
  row while its record is live; caught by `ExecAckOnlyWhenRecordTerminal`);
  `M11-restart-relaunches` (the host starts admitted execution rows again after a
  restart; caught by `AtMostOnceStart`); and `M12-reconciler-skips-executions`
  (orphans are never stopped; caught by `EveryExecutionSettles`).

The model leaves out time, the idle expiry, the input journal and owner-bound
calls. Input and progress travel over the owner port, which the model does not
cover, and the waiting rule for a link cut is a client behaviour tested in
Gleam against the executor's router, not a protocol rule.

#### What stays refused

- **Extension tools.** Extensions are installed under the orchestrator's home
  and run as jailed satellites with their own fixed authority. On a remote
  session they would have to run beside the checkout, which needs an executor
  installation as machine configuration and a census entry for it. Neither is
  designed.
- **Operator-added directories.** They are validated against the
  orchestrator's filesystem when added. A remote session would need the
  executor to validate them and to report the result, which is a new message
  with no current user.
- **Resuming a running background execution after an orchestrator restart.**
  The program's heap survives on the executor, but the local rule is that a
  restarted service records an unfinished execution as lost and never resumes
  it. Only a program that had already finished keeps its result.
- **Supervising an MCP server.** A dead server is not restarted on either
  placement, as on a local session.
- **Jailing an MCP server.** An executor-placed server is spawned unjailed, as
  a local one is, until #109 is decided.

#### What it costs

A background launch on a remote session crosses the network four times before
the program starts: the launching `Run`, `LaunchExecution` and its answer,
`StartExecution`. The model's `check`, `send` and `cancel` wait for the link,
because `code_mode` is placed on the executor by name; answering those modes on
the orchestrator would need placement by argument, which is not built. Every
owner-bound call from a background program reads its execution record on the
owner. An execution row holds 1 MiB of the executor's ledger budget for up to
15 minutes, and a result larger than that is stored as an error naming its
size. A program whose record closed during a partition may run on until its
deadline. An orchestrator-placed server is started before the orchestrator
learns whether the executor offers `code_mode`, and stays up for the session if
it does not. A changed MCP plan waits for the next reopen. An executor-placed
server needs a table on the executor as well as the orchestrator's `runs_on`.

## Impact

- `client`: the workspace plane is split out of `serve.assemble_in`; new
  executor role, workspace host, owner port and remote surface. Local sessions
  run the same assembly in-process.
- `runtime` and `machine`: one `ToolSurface` slot and one recovered tool
  observation. The machine stays pure.
- `broker`: a public constructor for a `Broker` over a remote subject.
- `storage`: catalogue versions 11, 12 and 13; the ledger's generated SQL.
- New Erlang FFI: the TLS distribution verify function and boot checks
  (about 185 lines), the only thing `gleam_erlang` cannot express. It lives in
  an `internal/ffi_*` module with the reason recorded.
- Formal models: a TLA+ model of a session move and a P model of remote
  execution against the ledger, both gated by `make model-check`. There is no
  directory model, because the directory holds no state of its own.

- Background code mode and MCP façades on a remote session: `client/remote/*`
  gains the execution messages and the MCP plan at protocol version 3;
  `storage/exec_ledger` gains `stop_or_fence` and a listing of running
  executions; `async_runs` takes a work closure that can fail with a reason and
  asks the executor before it marks an execution lost; `owner_codemode` binds a
  background program's calls to its record and answers orchestrator-placed MCP
  servers; `owner_link` waits out a link cut for the `execution.*` calls;
  `executor_plane` runs background programs and the executor's own MCP servers;
  `catalog` reads `runs_on`.

Local sessions see no behavior change. A daemon without `[distribution]`
never starts `net_kernel`, and its sessions never consult the ledger.
