# protocol-change/085: reading and operating a distributed deployment

**Status**: PROPOSED 2026-10-11. Nothing here is built, and every spelling is
provisional until slice 4 lands.
**Affects**: the client control protocol (Part 1.6: three new owner-only
commands, `deployment.status`, `deployment.node` and `sessions.elsewhere`; one
optional member on the reply of `directory.status`; two optional members on the
records of `sessions.list`), a new distribution port, `loom_admin`, with its own
closed message type, the web view's page scopes (a fourth, `Deployment`, with
three routes and a 051 addendum) and the owner's home page (capabilities, no new
event class), and the private surfaces they read: a read-only summary of the
execution ledger, a private event on the executor host, a function that lists
connected nodes, and a function that lists the directory's records. The
executor host's wire vocabulary (`HostMessage`), the orchestrator port's
`Message`, `protocol.version`, `sessions.create`, `sessions.move`, the catalogue
schema and `loom.toml` do not change.
**Raised by**: the owner's request of 2026-10-11 for a web admin that selects an
executor when making a session, shows unified sessions across orchestrators,
shows system health, and draws the topology.
**Design**: [docs/design-notes/distributed-admin-surface.md](../docs/design-notes/distributed-admin-surface.md).
**Builds on**: [protocol-change/078](078-distributed-runtime.md) (executors,
pools, the orchestrator port, moves) and [083](083-khepri-session-ownership.md)
(`directory.status`, abandon). It is compatible with the peer mail reach, remote
code mode and remote subagent proposals, and none of them is required.

## Problem

An operator of a distributed deployment can create a session on an executor,
and can move it, from the command line and with a typed form in the browser. Four
things the operator needs are not readable.

First, nothing says whether an executor can take a session before the session is
created. The web form offers executor names and a typed workspace name, and the
terminal takes flags. A wrong choice is learned when the open fails, after a
registration was reserved.

Second, there is no list of the sessions on the other orchestrators. A daemon
answers `not_owner` for a session it was named, and the Khepri copy on a member
knows the owner of every session, but no command returns either as a list.

Third, the state of the deployment is not readable from a client. An executor's
capacity, its scopes that block a reopen, its ledger budget and its helper pool
are in the executor's ledger and memory. Which nodes are connected is the BEAM's.
A move's stall reason goes to one log line. `directory.status` reports this
member's applied index and Ra's membership and cannot say whether this copy has
caught up.

Fourth, a person cannot see the shape: which orchestrators and executors exist,
who connects to whom, and where sessions sit.

## What was considered

**Add the reads to the executor host's and the orchestrator port's message
types.** This is the least new machinery and reuses the addresses peers already
know. It was rejected because both vocabularies are closed and matched without a
catch-all. An older node that receives a constructor it does not have crashes
its host, which halts the executor daemon, or its port, which is linked so that
its exit ends the daemon. A health probe is run during upgrades and failures,
which is when builds differ, and it must not be able to stop a node.

**Derive health from what the orchestrator already keeps.** The last attach
census per executor and the result of connecting would give reachability and the
platform with no wire change. This is slice 2 and it is kept as the first step.
It cannot show capacity, unclean scopes, the ledger budget, the connected nodes
or the workspace names, and it is stale after any executor restart, so it is not
the end state.

**One control command with an `include` list.** A single `deployment.status`
with options for the creation form, the page and the terminal. It was rejected
because the creation form must not wait on the directory and the movers, and
because a node's workspace names and unclean scopes are lists that would pass
the 64 KiB control message limit across 32 nodes. `deployment.node` carries the
long lists for one node.

**Put the cluster page inside the Admin page as a tab.** This reuses the page
scope, the routes and the guards. It was rejected because the Admin page is
fifteen minutes long and only reachable from a fresh home, for the reason that it
mints credentials, while a health page is watched for longer and holds no secret.
The cost of a fourth scope is the six places the Admin scope touched, all
mechanical.

**Merge foreign rows into `sessions.list`.** One list for the client. It was
rejected because `sessions.list` carries a catalogue revision and a per-credential
authorization that belong to the local catalogue, and a merged list could keep
neither. `sessions.elsewhere` is a separate command with its own cursor.

**Attach the local daemon to a foreign session.** Rejected for now; it needs a
credential for the second daemon or a gateway attach over the pinned link, and
the orchestrator port is limited on purpose so that a peer cannot read a
session's conversation through it. It is the owner's decision.

## Decision

### The admin port

Every daemon with a `[distribution]` table starts a process registered under
`loom_admin` (`default_name`), reachable as `{loom_admin, node}` the way the host
and the orchestrator port are (`client/remote/address`). It is a weft actor under
a supervisor with a restart policy, and it is not linked to the daemon's
termination: unlike the executor host and the orchestrator port, its exit does not
end the daemon. A daemon with no `[distribution]` table starts none. Its message
type is closed:

```gleam
pub type Ask {
  /// What this node is and how it is doing. Built without opening any session.
  Report(reply: Subject(NodeReport))

  /// One page of the rows this node's catalogue would list to its own owner.
  Sessions(after: String, limit: Int, reply: Subject(Page))
}
```

`limit` is clamped to 1 through 100. A node asks with `Report` and `Sessions` from
a weft task, so a reply that does not match the shape fails the task and not the
asker. The port answers any pinned peer. That is not an access boundary
(protocol-change/078, "Trust"): a pinned peer already holds an Erlang peer's
privileges, and the port exists so that a reader cannot be mistaken for a
writer. The message and reply types carry no function, port, credential, key,
cookie, pin or workspace path.

```gleam
pub type NodeReport {
  NodeReport(
    node: String,
    build_version: String,
    build_commit: String,
    /// The daemon's epoch, which changes at a restart.
    epoch: String,
    /// The node's own clock at start and now. A reader computes uptime from the
    /// two and never compares either with its own clock.
    started_ms: Int,
    now_ms: Int,
    /// The nodes this node holds a live distribution connection to, hidden and
    /// visible, at most 64.
    connected: List(String),
    /// The nodes of its configured `[[distribution.peers]]`.
    peers: List(String),
    orchestrator: Option(OrchestratorFacts),
    executor: Option(ExecutorFacts),
    directory: Option(DirectoryFacts),
  )
}

pub type ExecutorFacts {
  ExecutorFacts(
    protocol: Int,
    scopes: ScopeCounts,
    scope_limit: Int,
    /// Scopes that block a reopen: closing, or closed with unknown cleanup.
    /// At most `scope_limit`, because they hold the limit's slots.
    unclean: List(UncleanScope),
    ledger_bytes: Int,
    ledger_limit: Int,
    unacknowledged: Int,
    helpers: Option(Helpers),
    platform: String,
    /// Enforcement and toolchains from the most recent attach census; `None`
    /// until one has happened.
    observed: Option(executors.Observed),
    /// The names, never the roots, of the registered workspaces, at most 64.
    workspaces: List(String),
  )
}

pub type ScopeCounts {
  ScopeCounts(open: Int, closing: Int, closed_clean: Int, closed_unknown: Int)
}

pub type UncleanScope {
  UncleanScope(session: String, state: UncleanState)
}

pub type UncleanState {
  Closing
  UnknownCleanup(count: Int)
}

pub type Helpers {
  Helpers(size: Int, borrowed: Int)
}

pub type OrchestratorFacts {
  OrchestratorFacts(
    capacity: Int,
    occupied: Int,
    resident: Int,
    imports: Imports,
    /// The node of each `[executors.<name>]` row it configures.
    executor_nodes: List(String),
    /// Sessions by executor node and residency, from the catalogue's existing
    /// `executor` column, at most 32 rows.
    placements: List(Placement),
    moves: List(MoveFacts),
  )
}

pub type Imports {
  Receiving
  NotReceiving
}

pub type Placement {
  Placement(executor_node: String, resident: Int, saved: Int)
}

pub type MoveFacts {
  MoveFacts(
    session: String,
    op: String,
    to_node: String,
    phase: MovePhase,
    /// Milliseconds since the stall began on this node's clock, when stalled.
    stalled_ms: Option(Int),
    /// The last stall reason, cut to 200 bytes.
    reason: Option(String),
  )
}

pub type MovePhase {
  Running
  Waiting
}

pub type DirectoryFacts {
  DirectoryFacts(
    status: member.Status,
    copy: Copy,
  )
}

pub type Copy {
  /// A consistent read (a fence, then a read) completed within its deadline.
  Current
  /// It did not: no quorum, or the copy is too far behind to fence in time.
  Unconfirmed
}

pub type Page {
  Page(rows: List(Row), more: More)
}

pub type More {
  Last
  Further
}

pub type Row {
  Row(
    /// The members of a `sessions.list` record, in the same meaning.
    session_id: String,
    workspace: String,
    name: String,
    created_at: Int,
    status: ListedStatus,
    subtitle: Option(String),
    executor: Option(String),
    pool: Option(String),
    /// The node a move in flight is toward, when one is.
    moving_to: Option(String),
  )
}
```

`ListedStatus` is the closed type that `sessions.list` already encodes
(`reserved`, `saved`, `opening`, `resident`, `stopping`, `recovery_blocked`).
`Sessions` leaves out archived sessions and the tombstone of a session that
moved away. Every field of `NodeReport` and `Row` that holds text is drawn by a
reader as text and never as an identifier, an attribute or a path.

On the executor, the host answers the admin port through a private event of its
own (`Summary`), which only the in-VM admin port sends, and not through
`HostMessage`. The ledger gains a read-only `summary` query (scope counts, the
unclean scopes, bytes, unacknowledged results) that takes no row lock beyond a
read transaction. `Plane` gains an accessor for its helper pool's census
(`exec.pool_census`), summed by the admin port over the live planes. The
distribution FFI gains `connected_nodes/0` (`erlang:nodes(connected)`), because
`gleam_erlang` lists visible nodes only. The Khepri FFI gains a local read of
every session record. A node built before this proposal has no `loom_admin`
name. A send to it after a connection is dropped and the asker's deadline turns
into `unsupported`.

### Node states

`deployment.status` classifies each node as exactly one of:

| State | Meaning |
|---|---|
| `ok` | Answered, and no reason applies. |
| `degraded` | Answered, with the reasons below. |
| `down` | No connection within the deadline; the reason is the word `distribution.describe` gives. |
| `unsupported` | Connected, with no `loom_admin` port. |

The degraded reasons are the fixed words `unclean_scope`, `scopes_near_limit`
(unclean-capable scopes at 75 percent of the limit or more), `scopes_full` (at the
limit), `ledger_near_limit` (80 percent of the byte budget),
`declaration_contradicted`, `build_differs`, `protocol_differs`,
`directory_no_leader`, `directory_copy_unconfirmed` and `directory_quorum_lost`.
The thresholds are constants of `client/deployment`.

### `deployment.status`

Owner-only. Request body `{}`; it needs no epoch, as `directory.status` needs
none. The daemon connects to each configured peer and asks each `Report`, in one
weft run under a two second deadline, and answers with the asking
daemon's own facts included. A daemon with no `[distribution]` table answers with
itself and no peers.

```json
{"v":2,"id":21,"cmd":"deployment.status","body":{}}
{"v":2,"reply_to":21,"event":"deployment.status","body":{
 "as_of_ms":1760190131000,
 "self":"alpha@10.0.0.1",
 "state":"degraded",
 "reasons":[{"node":"exec2@10.0.0.9","reason":"down"},{"node":"box@10.0.0.2","reason":"unclean_scope"}],
 "nodes":[
  {"node":"alpha@10.0.0.1","name":"alpha","roles":["orchestrator","member"],"state":"ok","self":true,
   "build_version":"0.2.0","build_commit":"b4eeb50c","uptime_ms":86400000,
   "orchestrator":{"capacity":8,"occupied":2,"resident":2,"imports":"receiving"}},
  {"node":"box@10.0.0.2","name":"box","roles":["executor","member"],"state":"degraded","reasons":["unclean_scope"],
   "build_version":"0.2.0","build_commit":"b4eeb50c","protocol":2,"uptime_ms":3600000,
   "executor":{"scopes":{"open":3,"closing":0,"closed_clean":9,"closed_unknown":1},"scope_limit":16,
    "ledger_bytes":2097152,"ledger_limit":536870912,"helpers":{"size":4,"borrowed":1},
    "platform":"linux/x86_64","enforcement":"enforced","contradiction":null}},
  {"node":"exec2@10.0.0.9","name":"exec2","roles":["executor"],"state":"down","reason":"timeout"}],
 "edges":[
  {"from":"alpha@10.0.0.1","to":"box@10.0.0.2","kind":"serves","sessions":3,"link":"connected"},
  {"from":"alpha@10.0.0.1","to":"bravo@10.0.0.4","kind":"peer","link":"connected"},
  {"from":"alpha@10.0.0.1","to":"bravo@10.0.0.4","kind":"member","voter":true,"link":"connected"}],
 "placements":{
  "executors":[{"name":"box","node":"box@10.0.0.2","state":"degraded","free_scopes":12,
    "declared":{"platform":"linux/x86_64","enforcement":"enforced","toolchains":["codemode"]}},
   {"name":"exec2","node":"exec2@10.0.0.9","state":"down","declared":{"toolchains":[]}}],
  "pools":[{"name":"builders","executors":["box","exec2"],"eligible":["box"]}]},
 "orchestrators":[{"name":"bravo","node":"bravo@10.0.0.4","state":"ok","imports":"receiving","serves":["box"]}],
 "directory":{"members":["alpha@10.0.0.1","bravo@10.0.0.4","box@10.0.0.2"],"joined":true,
   "ra_members":[{"node":"alpha@10.0.0.1","voter":true}],"applied_index":412,"leader":"bravo@10.0.0.4","copy":"current"},
 "moves":[{"session_id":"0198c0de-0000-7000-8000-000000000001","op":"0198c0de-0000-7000-8000-000000000a01",
   "to":"bravo","phase":"waiting","stalled_ms":240000,"reason":"the receiver did not answer"}]}}
```

| Member | Type | Presence | Meaning |
|---|---|---|---|
| `as_of_ms` | integer | always | The asking daemon's wall clock when the reply was built. |
| `self` | string | always | The asking daemon's node. Every statement is from its point of view. |
| `state` | string | always | The worst node state, in the order `down`, `degraded`, `unsupported`, `ok`. |
| `reasons` | array | always | One entry per node that is not `ok`: `node` and a fixed `reason` word. Bounded by the node count. |
| `nodes` | array | always | At most 33 entries; the asking daemon first, then orchestrators, then executors, each by name. |
| `edges` | array | always | `serves`, `peer` and `member` relations with a `link` of `connected`, `one_way` or `none`. `sessions` on a `serves` edge; `voter` and `leader` on a `member` edge. |
| `placements` | object | always | `executors` and `pools` as the asking daemon's configuration names them. An executor's state is one of `ready`, `degraded`, `full`, `down`, `unsupported`. `free_scopes` is present when the executor answered. A pool's `eligible` lists its executors, in its trial order, that are not `down` or `full`. |
| `orchestrators` | array | always | The configured `[orchestrators.<name>]` rows: state, whether it can receive sessions, and `serves`, the asking daemon's executor names that it configures. |
| `directory` | object | on a directory member | `directory.status` plus `copy`. |
| `moves` | array | always | The moves in flight on the asking daemon. |

The node object carries `executor` and `orchestrator` summaries without the
long lists. Names are the asking daemon's keys for a node, as protocol-change/083
does for owners, and the bare peer name or node when it has none.

### `deployment.node`

Owner-only. Request `{"node": <name>}`, where the name is a key of the asking
daemon's `[executors]` or `[orchestrators]`, a `[[distribution.peers]]` name, or a
full node name. The reply is the node's whole report as JSON: everything in its
`deployment.status` entry plus `workspaces`, `unclean` (each with `session` and
`state`), `connected`, `peers` and, for an orchestrator, `placements` and
`moves`. Errors: `not_found` for a name that is none of those, `unavailable` when
the node is `down`, `forbidden`.

### `sessions.elsewhere`

Owner-only. Request `{"after": ""}`, a cursor as `sessions.list` takes, and no
epoch and no revision. The daemon asks `Sessions` of each configured orchestrator
and, on a directory member, reads its local copy of the directory's records, then
merges by session id and stops on a record boundary before 60,000 bytes. Reply:

```json
{"v":2,"reply_to":22,"event":"sessions.elsewhere","body":{
 "copy":"current",
 "orchestrators":[{"name":"bravo","node":"bravo@10.0.0.4","state":"answered","address":"ws://10.0.0.4:7000"},
                  {"name":"laptop","node":"laptop@10.0.0.7","state":"silent"}],
 "sessions":[
  {"session_id":"0198c1aa-0000-7000-8000-000000000002","orchestrator":"bravo","source":"catalogue",
   "workspace":"/src/loom","name":"docs pass","created_at":1756000100000,"status":{"state":"saved"}},
  {"session_id":"0198c2bb-0000-7000-8000-000000000003","orchestrator":"laptop","source":"directory","state":"unconfirmed"}],
 "after":"0198c2bb-0000-7000-8000-000000000003"}}
```

A `catalogue` row has the members of a `sessions.list` record, plus `orchestrator`
(the asking daemon's key for the owner, or the node) and an optional `moving` object
as `sessions.get` has it. A `directory` row has `orchestrator`, `source`, and
`state: "unconfirmed"`; it appears only when no `catalogue` row answered for the
same id. `copy` is present on a directory member. An orchestrator `state` is
`answered`, `silent` or `unsupported`. When two orchestrators list the same id,
the row without `moving` is kept. `address` is the configured control address, as
`not_owner` carries it. A daemon with no peers answers an empty list. A member
principal is refused `forbidden`.

### `directory.status` and `sessions.list`

`directory.status` gains `copy`, `current` or `unconfirmed`, defined as in the
admin port. It is a consistent read under a two second deadline, so the command
now may take that long. Its other members are unchanged.

Each record of `sessions.list` gains the optional `moving` and `moved` objects
exactly as protocol-change/078 phase 5 defines them for `sessions.get`. A client
that does not know them ignores them, as the protocol already says.

### Web view

A fourth page scope, `Deployment`, beside session, home and admin, in
`ui_sessions.Grant.scope`. It has its own exchange `GET /ui/deployment`, page
`GET /ui/p/<key>/deployment` and socket `GET /ui/p/<key>/deployment/ws`, checked in
the order the Admin routes are, and a ticket is honoured only at its own scope's
exchange (`OtherScope` otherwise). A ticket comes from one button on the owner's
operating home (`home_deployment_capability`, given on the condition that
`home_admin_capability` is, less the freshness rule). The page's lifetime is one
hour, or the minting home's deadline if that is earlier. The page is read-only
for a resumed home. Its two actions, Move and Abandon, run `ui_socket`'s
re-derivation from the grant at the click (the page is open, the ceiling is
Operator, the credential authenticates as the owner, the grant's origin is
`Fresh`), and then call the same function the control command calls. Its reads run
in weft tasks with a read number, and the runtime never waits on the registry or a
peer. The socket admits a click or submit beneath one fixed path and nothing else.

The owner's operating home gains capabilities, given on the owner condition the
creation form has: the placements for the creation cards, the elsewhere list, the
move chooser (fresh homes only) and the strip. No new event class is admitted:
the cards and buttons are clicks, and the form is the submit already admitted
beneath the home's table. Every name, path, reason and workspace name drawn on
any page is a text node, and no class, attribute, key or URL is built from them.
Colours come from existing tokens; there are no left-edge accent bars and no
shadows. The content security policy does not change. A 051 addendum records the
scope, the three routes, the admissions and the lifetime, and is written with
slice 8.

### Terminal

`loom deployment status [--json]`, `loom deployment node NAME [--json]`, `loom
deployment executors [--json]`, `loom directory status [--json]`, `loom sessions
list` with the elsewhere section (`--local` to omit it), and `loom sessions move
<id>` with no `--to` (it prints the eligible destinations) and `--abandon`. The
terminal decodes each reply with a total decoder of its own, since it cannot
import the daemon's types, and treats `bad_request` with `unsupported control
command` as "this daemon does not have deployment views".

### Compatibility

Everything is a new name or an optional member. An older daemon answers the new
commands `bad_request`, and the clients hide the views. An older node has no
`loom_admin` port and is `unsupported`. A newer node that sends an `Ask` an
older admin port cannot match restarts that port and costs the asker its deadline;
nothing else stops. The admin port assumes peers of one build for the shape of
`NodeReport` and `Row`, as the other ports do, and contains a mismatch instead of
tolerating it: a changed field is an upgrade of every node, the same rule as
`protocol.version`.

## What it costs

- A fourth process type per daemon with a closed vocabulary to keep in step.
- A connection to every configured peer on each status poll, including executors
  with no sessions.
- Two small Erlang functions, in modules that already hold FFI of their kind.
- A fourth page scope and its routes, tests and addendum.
- Thresholds that are policy in code. They are constants and the owner can move
  them.
- A consistent read, up to two seconds, in `directory.status`.
- No history: a node that was down shows only that it is down.

Not changed: `sessions.create`, the wire of `sessions.move`, the executor host's
messages, `protocol.version`, the catalogue, configuration, formal models.
