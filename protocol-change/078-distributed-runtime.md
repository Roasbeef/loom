# protocol-change/078: remote workspaces over trusted distribution

**Status**: ACCEPTED 2026-10-07 (direction approved by the owner). Field
spellings below are provisional until phase 1 lands; this document is updated
to the implemented spellings before the change merges.
**Affects**: the control command `sessions.create` and session records (one
optional field each, and a second pair for pools, see the addendum), the
catalogue schema (version 10, one column; version 11, one more; version 12,
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
(one slot), and two new formats that are not Part 1 interfaces: the closed
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

### Catalogue (version 10)

`Registration` gains `executor: String`, empty for a local session. The
migration from version 9 adds the column with an empty default. A
registration with a non-empty `executor` stores the registered workspace name
in `workspace`, never a path on the orchestrator.

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
| `Ack(key)` | The orchestrator has durably staged this outcome. |
| `Close(session, workspace, incarnation, reply)` | Close the scope and report `all_retired` or `unknown(count)`. |

There is no cancel message. Abort kills the orchestrator's effect process,
and the host's monitor on it turns that into a cancel.

Executor to orchestrator, to the session's owner port:

| Message | Meaning |
|---|---|
| `Escalate(refused, reply)` | Ask for an approval decision. |
| `FactGet(key, reply)`, `FactSwap(key, expected, new, reply)`, `FactList(prefix, reply)` | Read, compare-and-set or list a reserved owner fact (`client/working_directory/*`, `job/*`). |
| `Notify(strand, text, reply)` | Deliver a background job's completion notice to its strand. |
| `Tail(...)` | A live output hint; may be dropped. |
| `OwnerCapability(request, reply)` | A satellite's owner-bound capability call. |

The host monitors the owner port. A DOWN while a callback is outstanding
settles that callback with an in-band failure, so the call reaches
`terminal` instead of waiting on a reply nobody will send.

The remote broker handle uses `broker.Msg` unchanged, except that a
`CallSpec`'s absolute deadline is sent as the remaining duration and rebased
on the executor's clock, and the workspace path in the spec comes from the
census as an opaque string.

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

The catalogue is at version 11. `Registration` gains `pool: String`, empty for a
session created without one, and the migration from version 10 adds the column
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

The catalogue is at version 12. The migration from version 11 adds one table,
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

## Impact

- `client`: the workspace plane is split out of `serve.assemble_in`; new
  executor role, workspace host, owner port and remote surface. Local sessions
  run the same assembly in-process.
- `runtime` and `machine`: one `ToolSurface` slot and one recovered tool
  observation. The machine stays pure.
- `broker`: a public constructor for a `Broker` over a remote subject.
- `storage`: catalogue versions 10 and 11; the ledger's generated SQL.
- New Erlang FFI: the TLS distribution verify function and boot checks
  (about 185 lines), the only thing `gleam_erlang` cannot express. It lives in
  an `internal/ffi_*` module with the reason recorded.
- Formal models: the TLA+ directory and handoff specs and a P model of the
  ledger states, gated by `make model-check`.

Local sessions see no behavior change. A daemon without `[distribution]`
never starts `net_kernel`, and its sessions never consult the ledger.
