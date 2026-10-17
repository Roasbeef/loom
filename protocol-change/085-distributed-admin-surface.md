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
| `down` | No connection within the deadline. The reason is one of `timeout` (the connection did not settle in time), `unreachable` (refused, or the host could not be reached; a wrong pin or certificate reads this way) and `unavailable` (the daemon has no distribution, or the node is not one it pinned). `distribution.describe` returns an operator's sentence with a remedy, so the word is chosen from the fault instead (`client/deployment.why_of`). |

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
| `state` | string | always | The whole deployment, from the nodes the asking daemon is configured with, not counting itself: `ok` when every node is `ok`, `down` only when no node is reachable, and `degraded` otherwise. One dead executor among several is a degraded deployment, not a dead one. A reachable node that is itself `degraded` counts as reachable and not `ok`. |
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
form is the submit already admitted beneath the home's table.

The creation cards work as follows. The page is given the executor and pool names
when it opens (`Start.executors` and `Start.pools`) and starts a read of their
states each time the panel opens (`Start.placements`). The read connects to the
executors alone and runs in a weft task. The panel is drawn at once from the
names, each card marked "not checked", and the numbered answer replaces them; a
read that gives nothing leaves the names and says so. A state is advice and never
blocks a choice, so a `down` executor can be chosen. The chosen card is the page's
own state and not a field of the form, so the submit carries only the workspace
and session names and a forged executor or pool field refuses the event. A pool
creation is a `creations.Pooled` place beside `creations.Registered`; the daemon
makes either session-only and re-checks the name against its configuration. A
card says what the executor's operator declared as a claim, and "N scopes free"
and the contradiction text when the executor's report supplies them. The
workspace is typed until the reports carry the registered names. Every name, path,
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


## Implementation notes: what slices 2 and 3 leave for slice 4

`deployment.status` and the creation cards ship without the orchestrator port's
`Report`, so a reachable node is `ok` with no optional members. Slice 4 adds the
rest:

- The `directory` and `moves` members, the `member` edges, the `sessions` counts
  on `serves` edges, and the `imports` and `serves` members of an `orchestrators`
  entry. Until then an `orchestrators` entry carries `name`, `node` and `state`.
- An executor placement carries `name`, `node`, `state` (`ready` or `down`) and
  `declared`. `free_scopes` and `contradiction`, and the states `degraded` and
  `full`, wait for the executor's own report. The web page does not carry them
  in this slice: `web_view/placements` has the states `ready` and `down` and no
  member for a scope count or a contradiction. Slice 4 adds the two members and
  the two states to the page's vocabulary and to its drawing together with the
  report that produces them. The terminal's decoder already accepts the optional
  members and the reserved states, so that an older `loom` reads a newer daemon.
- A node's own `degraded` state and its reasons. The whole-deployment rule counts
  a reachable node that is not `ok` as degrading the deployment, and
  `client/deployment.verdict` will be extended to read it; today it sees only
  reachable and down.
- The registered workspace names that the `node` filter returns, and the workspace
  select that replaces the typed field in the cards' form. Today the filter
  returns the one node with the same four members as any other read.
- The page has no value for a placement read that gave nothing, because this
  slice's daemon always answers with a report. A daemon that can fail to answer
  adds one with the code that produces it.
- The asking daemon is a node named by its node name (the "bare node when it has
  none" rule) with the roles `orchestrator`, and `member` when it stands in the
  directory's cluster. It is never connected to and is always `ok`.
- `server.Config` gained a `deployment` field, the daemon's node name and the
  function it connects with, so a test can script the connections. No `loom.toml`
  key was added.
- The page's stylesheet records a digest of every `web_view` source, so a branch
  that changes another `web_view` source and regenerates it conflicts in
  `packages/web_view/priv/static/web_client.css`'s header. The conflict is
  resolved by running `make gen-client` once after the merge.


## Addendum 2026-10-16: the spellings slice 4 part b chose

Slice 4 part b builds what the implementation notes above left for it: the
orchestrator port's `Report` is asked of every reachable node, the asking daemon
reports on itself, `classify` states the eight reasons, and `deployment.status`,
the creation cards and the terminal carry the result. 085 is silent or
ambiguous on the points below, and this is what the code does. A reader of a
reply treats every member named here as optional, as the decision states.

- **One run, two bounds.** For each configured node the daemon connects
  (`connect_ms`, one second) and then asks for the report (`report_ms`, 2.6
  seconds, longer than the node's own 2.5 second bound on its sources, so a live
  node with a slow directory still answers with the facts it read), and the asking
  daemon builds its own report in the same run, under a four second deadline. Each
  target holds a slot of its own, so a few black-holed hosts cannot starve the
  others. A node that connected and gave no report reads `down`: `silent` when the
  ask failed at once (no port is registered, or it ended), and `timeout` when it
  waited out its bound. `silent` is a fourth `down` word and is additive.
- **A node's members.** A node that reported carries `build_version`,
  `build_commit` and `uptime_ms` (its own clock at the answer less its clock at
  start). An executor adds `protocol` at the node level and an `executor` object
  with `scopes`, `scope_limit`, `ledger_bytes`, `ledger_limit`, `unacknowledged`,
  `platform`, `enforcement` and `toolchains` (the last two from its latest attach
  census, absent before one), and `contradiction` (`null` or the words). An
  orchestrator adds an `orchestrator` object with `capacity`, `occupied`,
  `resident`, `imports` (`receiving` or `not_receiving`) and `moves_in_flight`, a
  count, because `moves` is the long list. The asking daemon's own entry carries
  `self: true`. A `degraded` node carries `reasons`, an array of the words, and
  a `down` node carries `reason`.
- **The top-level `reasons`.** One entry for a `down` node and one for each reason
  of a `degraded` node, not one for each node. The example above shows one entry
  for a node with one reason.
- **Free scopes and `full`.** The scopes that count against `scope_limit` are the
  open ones, the closing ones and the ones closed with unknown cleanup, because an
  open scope holds a slot as the others do. `free_scopes` is the limit less that
  count, never below zero, and `full` holds when it is zero. `unclean_scope` holds
  when any scope is closing or closed with unknown cleanup. A pool's `eligible`
  lists the executors that are neither `down` nor `full`; a `degraded` executor can
  still take a session.
- **Edges.** A `serves` edge has `sessions`, the resident and the saved sessions the
  orchestrator reports on the executor. The asking daemon has one to each
  configured executor, with its link. A `peer` edge always touches the asking daemon: a report's
  `peers` are not drawn as edges between other nodes. A `member` edge runs from the
  asking daemon to each directory member that appears in `nodes`, with the asking
  daemon's link to it, and `voter` and `leader` (booleans) describe the node at
  `to`. The daemon does not state a `member` edge between two other nodes, so a
  deployment of n members has n minus one such edges and not a mesh. The terminal
  merges the edges between one pair of nodes into one row.
- **What another orchestrator serves** is its `serves` list in `orchestrators`
  only. The decision's third-party `serves` edges repeated it, so the daemon states
  no `serves` edge between two other nodes, and a `serves` edge always touches the
  asking daemon.
- **Moves** have one spelling, `session_id`, `op`, `to` (the destination's name),
  `phase`, `stalled_ms`, `reason`, at the top level and in an orchestrator's own
  list for a read that names one node.
- **The size of a reply.** The terminal refuses a frame over 64 KiB, so the daemon
  encodes a reply, measures it, and keeps it at or under 60,000 bytes. An overview
  that is over drops, in order, the `moves`; the per-node facts beyond scope counts
  and build, the executors' `declared` and the `pools`; and the `edges`,
  `placements` and `serves` lists, and names what it dropped in `omitted`. A reply
  for one node cuts its long lists to 16 entries, then to none, and names them in
  `more`. Both members are absent from a reply that fits. A client that sees
  `omitted` reads one node for the rest.
- **The verdict includes the asking daemon's own impairment.** An asking daemon
  with a reason of its own makes an otherwise `ok` deployment `degraded`, so that
  `state` and `reasons` agree.
- **Two directory signals.** `directory_no_leader` is the authoritative signal,
  from the member's own cluster view. `directory_quorum_lost` is a prediction from
  the asking daemon's connect attempts, and it can be wrong in either direction for
  a moment.
- **`directory_quorum_lost`.** It is stated of the asking daemon's own entry only,
  from its cluster view and its connect attempts. The daemon counts itself as
  reached, and a voter it has no attempt for is counted as reached, so the reason
  is stated only when a majority is out of reach even if every unasked voter is up.
- **Directory members that are not configured.** The daemon dials the nodes of its
  `[orchestrators]` and `[executors]` tables, as the decision says of its
  configuration, and no other node. A directory member it does not configure is
  named in the `directory` block and gives the `member` role to the nodes that
  are members, and is not dialled.
- **The `directory` and `moves` members.** `directory` is the body of
  `directory.status` and `copy`, on a daemon that is a member. `moves` names each
  destination by the asking daemon's key for it, or by node when it has none. Both
  are absent from a reply that names a node.
- **A node filter.** The reply holds the node, classified as in an overview, with
  an executor's `workspaces` and `unclean` (each scope with its `session`, its
  `state` of `closing` or `unknown_cleanup`, and `count` for the latter) and an
  orchestrator's `placements` and `moves`. It has no `edges`, `placements`,
  `orchestrators`, `directory` or `moves`.
- **The page.** `web_view/placements` regains the states `Degraded` and `Full`, and
  its report gains `free_scopes` and `contradiction`. A card draws "N scopes free"
  and the contradiction as text, and the pill tints are `online`, `pending` and
  `ended`.
- **The terminal.** `loom deployment status` draws the example of the design note
  (section 8) from the reply: the time is the reply's `as_of_ms` in UTC, a node's
  `SCOPES` is the scopes held against the limit, and the session of a scope that
  needs a release is named only when the reply carries the node's long lists
  (`--node`), so an overview says how many. `loom directory status` draws the
  `directory.status` body and has no member of its own.

## Addendum 2026-10-16: the spellings slice 5 chose

Slice 5 builds `sessions.elsewhere`: the orchestrator port's `Sessions`, the
control command, the terminal's section and `loom sessions elsewhere`, and the
owner's home group. 085 is silent or ambiguous on the points below, and this is
what the code does. A reader of a reply treats every member named here as
optional.

- **`Row.executor_node`.** A row gains the optional member `executor_node`. A
  row's `executor` is a key of the answering orchestrator's own `[executors]`
  table, and two orchestrators need not call one executor by one name, so a reader
  that attributes a row to a machine needs the node. The answering orchestrator
  fills it from its own table, and leaves it out when the table does not list the
  executor. It is not in the page vocabulary of the web view, which draws the
  executor's key as the row's placement.
- **A failed read is not an empty page.** `Sessions` is answered with
  `Result(Page, Nil)`, as `Holds` is. A catalogue that cannot be read sends
  `Error(Nil)`, and the asking daemon reports the orchestrator `silent`. The
  decision says "a daemon with no catalogue to describe answers `Sessions` with an
  empty page", which is the port started without a catalogue (`unreported`), and
  not a catalogue that failed.
- **How a page is read.** The answering daemon reads catalogue pages from the
  identity it is given, drops the sessions that are archived, `moving` or `moved`,
  and stops when it holds one row more than it was asked for. The extra row
  decides `more`, so a page that ends exactly at the end of the catalogue is last.
  If it has read `ledger_holdings.max_pages` catalogue pages and holds no row, it
  cannot say where the next one is and does not answer; if it holds some, it
  answers them with `more`.
- **The request.** `orchestrator` alone is that group's first page, and `after`
  without `orchestrator` is `bad_request`: identities are not ordered across
  orchestrators, so a cursor into every group means nothing. A value of
  `orchestrator` that is not shaped like a configuration key is `bad_request`, and
  one that is shaped like a key and absent from the configuration is `not_found`.
  Both are decided before any connection.
- **The size of a reply.** The daemon asks for 20 rows for each group, then keeps
  the body at or under 59,700 bytes, which with its envelope is under 60,000. It
  removes the last row of whichever group has the most rows, the later group on a
  tie, until the body fits, and marks that group `more`. A silent group is one
  line and is never cut.
- **The terminal.** `loom sessions list` appends the section to both of its text
  forms, the table and the plain lines, after a blank line, unless `--local` is
  given. A script that parses the lines uses `--local`. A daemon that does not know
  the command has no section, and a read that failed for another reason adds one
  line saying the other orchestrators were not read, because the listing above it
  is still true and a missing section would read as "none". `loom sessions
  elsewhere` prints only the section, and takes `--orchestrator <key>` and `--after
  <id>` for a group's next page and `--json` for the reply as it was sent.
- **The web home.** The owner's operating home reads the first page of every other
  orchestrator in a weft task after each list read, numbered so that an answer a
  newer read overtook is dropped, and "Show more" asks for one group's next page
  after the last row the page holds for it. A row's "Where" opens a detail with the
  launch line, in a `<loom-copy>` box. The page is given the configuration key, the
  address and each row's fixed state and text, and no node. It adds no event class,
  scope, route or content security policy change, and no stylesheet rule: the group
  reuses the existing boxes. The launch line is the words the terminal prints for a
  `not_owner` answer, which now live in `session_view/launch_words`.
- **`<loom-copy>` takes a seventh subject.** The launch line is not any shape the
  element copied, so `launch` is added to `web_client/copy_rule`: `loom --addr`, an
  address of the characters an address has or the placeholder for none, `--session`,
  an identity of hexadecimal digits and hyphens, and the fixed `--token-file`
  ending. The built bundle and stylesheet are regenerated in their own commit.

## Addendum 2026-10-16: the Admin page's machines list and read-only machine pages

Slice 6 is built as a machines list and a read-only page for each machine, in place
of a terminal and buttons on a page. The page's rules are Admin's: no new scope,
route, ticket, event class or content security policy change, and every handler is a
click beneath `admin.body_path`.

- **The list shows every ledger member.** The Deployment section lists the nodes the
  daemon dials and also the members of the membership ledger that it does not. A
  member this daemon is not linked to is marked "not linked from here" and is never
  dialled. The list is merged by node name.
- **The page shows the certificate pin.** The Access tab states each member's pin, the
  hex SHA-256 of the leaf certificate, a public value the pin table already holds.
  `ledger.status` members gain optional `links` and `pin` for it (the 2026-10-16
  addendum to protocol-change/086).
- **Machine pages run nothing.** There is no terminal and no enroll, renew, revoke or
  release button. A page states the exact command in a `<loom-copy>` box for the
  operator to run on the right machine: `loom distribution renew NAME`, `loom
  distribution revoke NAME --reason 'REASON'`, `loom distribution enroll NAME --node
  NODE --role executor|orchestrator --links THIS` for a node the ledger does not list,
  and `loomd executor release SESSION` for each scope that blocks a reopen. Each name
  is written as one safely quoted shell word and a name that cannot be quoted gets no
  command. `<loom-copy>` takes an eighth subject, `operate`, whose rule is that
  grammar.
- **Four tabs.** Overview, Sessions, Access and Activity, switched by a click
  (`TabChosen`); choosing a machine (`MachineChosen`) reads that one node through
  `deployment.status` with `node`. The asking daemon is listed and not read.
- **The reads.** `server.AdminAttachment` gains `deployment` and `elsewhere`, each run
  in a weft task of its own behind the owner check. The Sessions tab matches another
  orchestrator's rows to a machine by `executor_node`, which the page's row now
  carries.
- **The home strip.** The owner's operating home draws a one-line strip under the bar
  naming the peer orchestrators, as text.
- **Abandon is not part of this slice.** It is on the Activity tab, built in slice 5 (the addendum below).


## Addendum 2026-10-16: Move with candidates, Abandon, and where a session runs

Slice 5 gives the owner's pages and the terminal the move the control socket already
had (protocol-change/078, phase 5, and protocol-change/083), and adds no wire member.
`sessions.move` already carries `abandon`; the terminal now sends it.

- **One daemon function for each.** `server.move_session` and `server.abandon_move`
  are the bodies of the control arms, and the home's Move and the Admin page's
  Abandon call them, so the checks cannot differ between the terminal and a page.
  A refusal is a typed `MoveRefusal`, which the control socket words as the codes it
  always answered (`move_refusal_code`) and a page words in fixed sentences.
- **The Move candidate rule.** A session on an executor can move to an orchestrator
  the asking daemon lists when the daemon reached it, its report says
  `imports: receiving`, and the executors it serves (`executor_nodes`) include the
  session's executor node. The asking daemon is never a candidate. An orchestrator
  that fails the rule is still listed, with the first reason that applies:
  unreachable, no report, does not accept moved sessions, or does not serve the
  executor. The rule is pure and lives in `session_view/move_candidates`, below both
  hosts, with its words. `deployment.candidates` applies it to the judged nodes of a
  `deployment.status` read, and the terminal applies it to the `orchestrators` member
  of the same reply (`tui/deployment_view.candidates`). A session with no executor has
  no destination.
- **Web Move is the owner's fresh home only.** A saved row has a Move button; a row
  with no executor has it disabled and its title says only a session on an executor
  can move. The first press is an action of its own, `Destinations`, which changes
  nothing: the daemon reads the deployment (up to its four-second bound, in a task)
  and answers `Heard`, and the row's words are replaced by a button for each eligible
  destination and a line for each ineligible one with its reason. A destination opens
  the confirmation Delete uses, "Move this session to bravo?", and only its button
  asks the daemon for `Move(to)`. Each step acts only for the stage the one before it
  left, and `manage_for` decides every press again with its `fresh_home` and
  `owner_operating` checks, so a resumed home, a member and a read-only page are
  refused and reach nothing. The page then reads "moving to bravo" from the row's
  residency. `move_session` checks that
  the destination is one of the daemon's `[orchestrators.<name>]`. It does not judge
  eligibility again, so a destination that stopped qualifying since the read is
  accepted and the move stalls and retries like any move toward a silent receiver.
- **Where a session runs.** The session page's Session tab says `runs on box (pool
  builders)` under the workspace, as text, from the registration's executor and pool.
  Only the owner's page says it; a member's page carries neither.
- **Web Abandon is on the Admin Activity tab only.** It is not on the home row. It is
  `grants.Action.AbandonMove(session)`, not a parallel action, because it is an owner
  change that the Admin page's request machinery already carries: one request at a
  time, the `administering` re-check, the `Armed` two-step, and the notice beside the
  control. It costs no allowance. The button is drawn beside each move the asking
  daemon has in flight, and only when that daemon is a directory member, since only a
  member can abandon (`NotAMember` otherwise, and `NotMoving` for a move that has
  ended). It is two presses, and the question reads "If bravo has already taken the
  session, the move finishes instead", which is what the compare-and-set does.
- **Terminal.** `loom sessions move ID` without `--to` reads the session's executor and
  the deployment, prints the candidates with reasons, and exits nonzero because it
  moved nothing. `loom sessions move ID --abandon` sends `abandon: true`. The two
  flags do not combine.
- **No new scope, route, ticket, event class or content security policy change.** Every
  name, reason and executor is a text node, and every class is a literal.
