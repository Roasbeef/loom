# protocol-change/085: reading and operating a distributed deployment

**Status**: PROPOSED 2026-10-11, revised after review. Nothing here is built, and
every spelling is provisional until slice 4 lands.
**Affects**: the client control protocol (Part 1.6: two new owner-only commands,
`deployment.status` and `sessions.elsewhere`, and two optional members on the
records of `sessions.list`), the orchestrator port's closed message type (two
constructors, `Report` and `Sessions`), the owner's home page (capabilities, no new
event class), the Admin page (a Deployment section, no new scope), and the private
surfaces they read: a read-only summary of the execution ledger and a private
event on the executor host. `directory.status`, the executor host's wire
vocabulary (`HostMessage`), `protocol.version`, `sessions.create`, `sessions.move`,
the catalogue schema, `loom.toml` and the Erlang FFI do not change.
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
answers `not_owner` for a session it was named, but no command returns the other
orchestrators' sessions as a list.

Third, the state of the deployment is not readable from a client. An executor's
capacity, its scopes that block a reopen and its ledger budget are in the
executor's ledger. A move's stall reason goes to one log line. `directory.status`
reports this member's applied index and Ra's membership and cannot say whether this
copy has caught up.

Fourth, a person cannot see the shape: which orchestrators and executors exist,
who relates to whom, and where sessions sit.

## What was considered

**A new port for the reads, `loom_admin`.** The first draft did this, so that a
probe sent to an older node could not stop it. It was rejected in review. The
orchestrator port already grew `PeerCommand`, `Import`, `ImportStatus` and
`Activate` with no gate, and the architecture page already says that both ends are
upgraded together and that a mismatched vocabulary can halt a node. A second port
would add a process, a supervisor, a name and an ask module to protect one class of
constructor from a risk the others already carry. Mixed builds stay unsupported,
as for every other constructor.

**Reads on the executor host's message type.** Rejected because the host is the
executor's custody of tool calls, and `HostMessage` is guarded by
`protocol.version`. A private host event that only the in-VM closure sends has the
same effect without touching the wire.

**A separate `deployment.node` command.** Folded into `deployment.status` as an
optional `node` filter, so there is one command to document and test. The filter
accepts configured names only.

**A new page scope for the cluster page, or a tab inside the Admin page.** The
first draft added a fourth page scope. It was rejected in review: the section
belongs to the Admin page, under its rules (a fresh home, fifteen minutes), and adds
no scope, route, ticket or lifetime. No 051 addendum is needed.

**Merge foreign rows into `sessions.list`.** One list for the client. It was
rejected because `sessions.list` carries a catalogue revision and a per-credential
authorization that belong to the local catalogue, and a merged list could keep
neither. `sessions.elsewhere` is a separate command with per-orchestrator groups.

**List sessions from the Khepri copy, and report connected nodes.** Rejected: the
copy holds no names and listing it needs a new Erlang function, and a node's list
of connected nodes needs another, because `gleam_erlang` lists visible nodes only.
Reachability is the asker's own connect attempt.

**Attach the local daemon to a foreign session.** Rejected. It needs a credential
for the second daemon or a gateway attach over the pinned link, and the
orchestrator port's closed vocabulary exists so that a peer cannot read a session's
conversation through it.

## Decision

### The port constructors

`orchestrator_port.Message` gains two constructors:

```gleam
/// What this node is and how it is doing. Built without opening any session.
Report(reply: Subject(NodeReport))

/// One page of the rows this node's catalogue would list to its own owner.
Sessions(after: String, limit: Int, reply: Subject(Page))
```

`answer` serves both through `detached`, the path `Activate` uses, so the work
runs in a run that dies with the requester and the port. `start_with` takes one
more closure record, `Reads`, built by `start_orchestrator_port` from the registry,
the movers and the executor host the way `catalogue_holds` and `peer_command` are.
The port starts on every daemon that has a `[distribution]` table, executors
included. A daemon with no catalogue to describe answers `Report` with no
orchestrator facts and `Sessions` with an empty page. `limit` is clamped to 1
through 100. The port answers any pinned peer; that is not an access boundary
(protocol-change/078, "Trust"). The types carry no function, port, credential, key,
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
    /// The nodes of its configured `[[distribution.peers]]`, at most 32.
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
  DirectoryFacts(status: member.Status, copy: Copy)
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
  )
}
```

`ListedStatus` is the closed type that `sessions.list` already encodes (`reserved`,
`saved`, `opening`, `resident`, `stopping`, `recovery_blocked`). `Sessions` leaves
out archived sessions and every session whose custody is `moving` or `moved`, so no
id is ever listed by two orchestrators. The helper pool's census is deliberately
absent: `pool_census` blocks for each plane. Every text field of `NodeReport` and
`Row` is drawn by a reader as text and never as an identifier, an attribute or a
path.

On the executor, the host answers the closure through a private `Summary` event
that only the in-VM closure sends, on a subject only it holds, and not through
`HostMessage`. The ledger gains a read-only `summary` query (scope counts, the
unclean scopes, bytes, unacknowledged results) that takes no row lock beyond a read
transaction. The movers' entry keeps the last stall reason that `Stalled` already
carries, and the movers' control gains a read of the moves in flight. No Erlang
function is added.

### Node states

`deployment.status` classifies each node as exactly one of:

| State | Meaning |
|---|---|
| `ok` | Reachable, and no reason applies. |
| `degraded` | Reachable, with the reasons below. |
| `down` | No connection within the deadline; the reason is the word `distribution.describe` gives. |

The degraded reasons are the fixed words `unclean_scope`, `full` (the scopes that
are not cleanly closed are at the limit), `declaration_contradicted`,
`build_differs`, `protocol_differs`, `directory_no_leader`,
`directory_copy_unconfirmed` and `directory_quorum_lost` (fewer reachable voters
than a majority, from the asker's connect attempts). There are no near-limit
thresholds: scope counts and ledger bytes are reported as numbers.

### `deployment.status`

Owner-only. Request body `{}`, or `{"node": <key>}`; it needs no epoch, as
`directory.status` needs none. The daemon connects to each node in its own
configuration (its `[executors]` and `[orchestrators]` rows and the directory
members), each connection bounded at one second, and asks each reachable node
`Report`, bounded at one second, all in one weft run under a three second deadline.
The inner bounds sum to two seconds and the third second is slack for scheduling
and for the tasks the deadline abandons. A first handshake to a loaded machine may
outlast its second; the node is then `down` in this reply and the handshake
finishes in the background. The reply includes the asking daemon's own facts. A
daemon with no `[distribution]` table answers with itself and no peers.

With `node` set, the value must be a configured `[executors.<name>]` or
`[orchestrators.<name>]` key. Any other value is `not_found`, and nothing is
dialled: a name taken from a request body is never connected to. The reply then
holds that one node in `nodes`, with its long lists (`workspaces`, `unclean`, and
for an orchestrator `placements` and `moves`), and omits `edges`, `placements`,
`orchestrators`, `directory` and `moves`.

From the first slice only `node`, `name`, `roles` and `state` (and `reason` when
`down`) are required on a node. Every other node member is optional and a client
treats an absent one as unknown, so a later slice adds members and replaces none.

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
    "ledger_bytes":2097152,"ledger_limit":536870912,
    "platform":"linux/x86_64","enforcement":"enforced","contradiction":null}},
  {"node":"exec2@10.0.0.9","name":"exec2","roles":["executor"],"state":"down","reason":"timeout"}],
 "edges":[
  {"from":"alpha@10.0.0.1","to":"box@10.0.0.2","kind":"serves","sessions":3,"link":"connected"},
  {"from":"alpha@10.0.0.1","to":"bravo@10.0.0.4","kind":"peer","link":"connected"},
  {"from":"bravo@10.0.0.4","to":"box@10.0.0.2","kind":"serves","sessions":1}],
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
| `state` | string | always | The worst node state, in the order `down`, `degraded`, `ok`. |
| `reasons` | array | always | One entry per node that is not `ok`: `node` and a fixed `reason` word. |
| `nodes` | array | always | At most 33 entries; the asking daemon first, then orchestrators, then executors, each by name. |
| `edges` | array | without `node` | `serves`, `peer` and `member` relations. `link` (`connected` or `none`) is present only on an edge that touches the asking daemon, which is the only link it observes. `sessions` on a `serves` edge; `voter` and `leader` on a `member` edge. |
| `placements` | object | without `node` | `executors` and `pools` as the asking daemon's configuration names them. An executor's state is one of `ready`, `degraded`, `full`, `down`. `free_scopes` is present when the executor answered. A pool's `eligible` lists its executors, in its trial order, that are not `down` or `full`. |
| `orchestrators` | array | without `node` | The configured `[orchestrators.<name>]` rows: state, whether it can receive sessions, and `serves`, the asking daemon's executor names that it configures. |
| `directory` | object | on a directory member, without `node` | The body of `directory.status` plus `copy`. |
| `moves` | array | without `node` | The moves in flight on the asking daemon. |

Names are the asking daemon's keys for a node, as protocol-change/083 does for
owners, and the bare node when it has none.

### `sessions.elsewhere`

Owner-only. Request `{}` for the first page of every group, or `{"orchestrator":
<key>, "after": <session id>}` for one group's next page. The key must be a
configured `[orchestrators.<name>]` key, or the answer is `not_found` and nothing is
dialled. The daemon asks `Sessions` of each configured orchestrator, each connection
bounded at one second and each ask at one second under a three second deadline.
There is no global cursor. An unfiltered reply gives each group at most 20 rows, and
fewer if the reply would pass 60,000 bytes, the bound `sessions.list` uses; a group
cut by the bound reports `more`. Reply:

```json
{"v":2,"reply_to":22,"event":"sessions.elsewhere","body":{
 "orchestrators":[
  {"name":"bravo","node":"bravo@10.0.0.4","state":"answered","address":"ws://10.0.0.4:7000","more":false,
   "sessions":[{"session_id":"0198c1aa-0000-7000-8000-000000000002","workspace":"/src/loom","name":"docs pass",
                "created_at":1756000100000,"status":{"state":"saved"}}]},
  {"name":"laptop","node":"laptop@10.0.0.7","state":"silent","more":false,"sessions":[]}]}}
```

A session is a record with the members of a `sessions.list` record. `state` is
`answered` or `silent`. `address` is the configured control address, as
`not_owner` carries it. A daemon with no peers answers an empty `orchestrators`
list. A member principal is refused `forbidden`. Rows show the answering machine's
workspace paths to the asking owner, which is acceptable because it is the same
operator.

### `sessions.list`

Each record gains the optional `moving` and `moved` objects exactly as
protocol-change/078 phase 5 defines them for `sessions.get`. A client that does not
know them ignores them, as the protocol already says. `directory.status` is
unchanged.

### Web view

The Admin page gains a Deployment section under Admin's rules: reached from the
owner's fresh home by the existing Admin button, `admin_ms` (fifteen minutes) long,
and not reachable from a resumed home. There is no new scope, route, ticket,
lifetime or content security policy change, and every handler of the section sits
beneath `admin.body_path`, which `admin_accepts` already admits, so no 051 addendum
is needed. The section reads `deployment.status` in a weft task with a read number,
beside the people and session reads, and a change it makes (a web Abandon, if the
owner asks for one) is an Admin change run by `admin_for` with Admin's fresh-and-
owner re-check.

The owner's operating home gains capabilities, given on the owner condition the
creation form has: the placements for the creation cards, the elsewhere group, the
move chooser (fresh homes only, through `manage_for`'s existing re-check) and the
strip. No new event class is admitted: the cards and buttons are clicks, and the
form is the submit already admitted beneath the home's table. Every name, path,
reason and workspace name drawn on any page is a text node, and no class, attribute,
key or URL is built from them. Colours come from existing tokens; there are no
left-edge accent bars and no shadows.

### Terminal

`loom deployment status [--json]`, `loom deployment executors [--json]`, `loom
directory status [--json]`, `loom sessions list` with the elsewhere section in its
text output (`--local` to omit it; any machine-readable output is unchanged and
local only), `loom sessions elsewhere --json`, and `loom sessions move <id>` with
no `--to` (it prints the eligible destinations) and `--abandon`. The terminal
decodes each reply with a total decoder of its own, since it cannot import the
daemon's types, and treats `bad_request` with `unsupported control command` as
"this daemon does not have deployment views".

### Compatibility

Everything is a new name or an optional member. An older daemon answers the new
commands `bad_request`, and the clients hide the views. Mixed builds across
orchestrators and executors stay unsupported, as for every other constructor of the
port: a changed field or constructor is an upgrade of every node, the same rule as
`protocol.version`.

## What it costs

- Two more constructors on a closed vocabulary that peers must upgrade together.
- A connection to every configured peer on each status poll, including executors
  with no sessions.
- A fan-out of up to three seconds when a node is slow.
- No history, and link state only for edges that touch the asking daemon.
- No helper pool figures, until the pool can publish its census without a call.

Not changed: `sessions.create`, the wire of `sessions.move`, `directory.status`,
the executor host's messages, `protocol.version`, the catalogue, configuration, the
Erlang FFI, formal models.

## Implementation notes: `deployment.status` without the port

The command shipped ahead of the orchestrator port constructors, so a reachable
node is `ok` with no optional members. Where the code differs from the text
above, or settles something the text left open, it is recorded here.

- **The reason word of a `down` node** is one of `timeout`, `unreachable` and
  `unavailable`, chosen from the connection layer's fault in
  `client/deployment.why_of`. The text above says "the word `distribution.describe`
  gives", but `describe` returns an operator's sentence with a remedy, and the
  example reply shows `"reason":"timeout"`. The three words follow the example.
  `TimedOut` is `timeout`, `Unavailable` (a refused handshake, a wrong pin, an
  unreachable host) is `unreachable`, and every other fault, together with a node
  the daemon did not pin and a daemon with no distribution, is `unavailable`.
- **The deployment's `state`** is the worst node state, as the table above says.
  Both examples in this proposal and in the design note show `degraded` for a
  deployment in which one node is `down`, which that rule would call `down`; the
  code follows the rule, and the examples need a ruling. If a deployment with one
  unreachable optional executor should read `degraded`, the change is one
  function (`deployment.worst`).
- **The `node` filter** is implemented in this slice, although the plan lists it
  with the node reports. It has nothing to select among but `node`, `name`,
  `roles` and `state` until the reports exist, and the rule that a name from a
  request is never connected to is worth having tested from the first command.
  `deployment.status` resolves the key against `[executors]` and
  `[orchestrators]` before any connection, and a key that matches nothing is
  `not_found`. A key shaped unlike a configuration key is `bad_request`. A key
  that matches an executor and an orchestrator selects both.
- **The asking daemon's node** has `name` equal to its node name, the "bare node
  when it has none" rule, and `roles` `["orchestrator"]`, with `"member"` added
  when `directory.standing` is `Member`. It is never connected to and is always
  `ok`.
- **What is not in the reply yet:** the `directory` and `moves` members, `member`
  edges, `sessions` counts on a `serves` edge, and the `imports` and `serves`
  members of an `orchestrators` entry. All need node reports or a directory read
  that is part of the next slice. `orchestrators` entries carry `name`, `node` and
  `state`. An executor placement carries `name`, `node`, `state` (`ready` or `down`)
  and `declared`; `free_scopes` and `contradiction` are absent. A pool placement
  lists the executors `pools.candidates` admits, which are fewer than the pool's
  `executors` key when its requirements reject one.
- **`server.Config`** gains a `deployment` field, the daemon's node name and the
  function it connects with, so a test can script the connections. Nothing else of
  the daemon's configuration changes, and no `loom.toml` key is added.
