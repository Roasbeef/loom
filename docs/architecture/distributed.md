# The distributed runtime

A distributed Loom runs one session on two machines. The orchestrator keeps the
conversation: the runtime, the session's SQLite store, approvals and the
provider keys. The executor keeps the checkout and runs the session's workspace
tool calls beside it. Both are the same release, joined by TLS Erlang
distribution with pinned certificates, and a single machine that plays both
roles is the ordinary local daemon. This page is for an engineer who knows the
single-machine architecture and needs to reason about the distributed one, and
in particular about what happens when something fails.

The design of record is
[the distributed runtime note](../design-notes/distributed-runtime.md). The
wire, durable formats and rules, with every addendum, are in
[protocol-change/078](../../protocol-change/078-distributed-runtime.md). The
operator's side is [the setup guide](../distributed-setup.md). The work is
issue #697 and PR #923. This page explains how the parts fit and links to those
documents for detail rather than repeating it.

## The cut: `ToolSurface.run`

Every tool effect already leaves the runtime through one function slot,
`run: fn(ToolRun) -> ToolOutcome` on `effects.ToolSurface`
(`runtime/effects.gleam:321`). The strand driver calls it on an effect process
after the call's intent and effective arguments are committed. Both sides of
the slot are plain data: a `ToolRun` carries the operation, step, source index,
strand, call, arguments, replay policy and consumed grants, and a `ToolOutcome`
carries a finished `AgentMessage` or a failure reason. No closure, port or
local handle crosses it. The distributed runtime puts the machine boundary at
that slot, so a remote session sends whole tool calls to the executor and gets
outcomes back: one round trip per call, never one per file access.

```mermaid
flowchart LR
    clients["clients<br/>(terminal, web)"]
    subgraph orch["orchestrator"]
        o["runtime, session SQLite,<br/>catalogue, approvals, clearance,<br/>provider keys, hooks trust,<br/>owner tools"]
    end
    subgraph exec["executor"]
        e["checkout, broker,<br/>helper pool and jail, jobs,<br/>LSP, code mode,<br/>execution ledger"]
    end
    clients --> o
    o -- "Attach, Run, Query, Ack<br/>(TLS Erlang distribution)" --> e
    e -- "replies, owner callbacks" --> o
```

The cut sits there for three reasons. The runtime already makes a call durable
before the effect starts and already stages an outcome that is unknown, so a
remote call needs no second custody system. The executor can run main's own
workspace plane unchanged: `serve.assemble_in` was split into a
conversation half and a workspace half, and a remote session asks the executor
to run the same workspace half that a local session runs in-process. Local and
remote therefore share one assembly and cannot drift apart. And everything below
the cut (code mode, the LSP manager, the jobs actor, the broker) runs beside the
files it reads, so no LSP byte, capability socket or helper frame crosses the
network.

Protocol-change/078 records the two rejected cuts: a typed RPC per
filesystem operation, which is what PR #819 built, and a remote broker
dispatcher, which would have left harness-side tools reading the
orchestrator's disk.

### What stays on the orchestrator

The orchestrator keeps everything that belongs to the conversation or to the
user. That is the runtime and its strands, the session store (conversation
tree, registers, facts, approvals, grants, budgets), the catalogue, peer mail,
memory, the provider credentials, MCP clients, `~/.loom`, user-level hooks and
the hook trust record. Clearance stays here: `wiring.clear` is pure over the
tool declarations, so the orchestrator builds declarations for the workspace
tools from the executor's census and clears every call before it is sent.
Approvals park here, beside the durable escalation record.

Tools that act on the conversation rather than on the checkout also run here:
`agent_*`, `history_search`, `remember`, `schedule_*`, `context`, `advise`,
skills and the peer tools. `client/tool_placement` is the name table that says
which side runs each tool, and its test asserts that every registered tool is
placed exactly once. A remote session refuses a tool with no placement instead
of running it on the orchestrator.

### What runs on the executor

The executor runs the workspace plane: the broker, the helper pool and its
jail, the executor service, the workspace tools (`fs_*`, `bash`, `grep`,
`working_directory`, `code_mode` and the job tools), the jobs actor, the LSP
manager and the code-mode host. It holds the checkout, the `.codemode` work
directory, toolchains and caches, a session's blob store, and its own machine
configuration (`[tools]`, `[workspace]`, `[lsp]`, `[jobs]`, `[secrets]`). The
blob store (the overflow of a large tool result, and the artifacts a code-mode
program emits) is `<state>/blobs/<session>` in the executor's state directory,
outside the checkout and outside the scope directory. A close removes the scope
directory but not the blobs, because a reopened session still reads the blobs
its transcript names, and every jail on the executor masks the directory. The
rule behind the split is that configuration naming a path on a machine lives on
that machine. The orchestrator never interprets an executor path, and the
executor never opens the conversation store.

When a workspace host starts a session's plane it returns a census: platform
and enforcement level, the toolchain probe, language servers, the shell, the
Git program, the workspace root as an opaque string, the text of the
workspace's guidance files, the bytes of its project hook files and the base
policy summary. The orchestrator renders and pins the system prompt from that
census, and checks the hook bytes against its own trust record before any hook
runs.

### Callbacks from the executor

A workspace tool sometimes needs the orchestrator while it runs. The executor's
plane receives an `OwnerServices` record of functions, exactly as a local plane
does, and for a remote session each function is a message to a per-session
owner port on the orchestrator (`remote/owner_link` sends, `remote/owner_port`
answers). The plane cannot tell which kind it holds. The callbacks are an
escalation for approval, the reserved facts (`client/working_directory/` and
`job/` only, fenced in `owner_services`), a background job's completion notice,
strand activity and wakes, live output tails (casts that may be dropped), and a
code-mode satellite's owner-bound capabilities (`strand.*`, `notes.*`,
`schedule.*`, `peer.*`). A satellite's `fs.*`, `kv.*`, `report.*`, `proc.*`,
`jobs.*` and `lsp.*` requests are served on the executor beside it.

Every callback is a monitored call with a budget. If the owner port dies, the
connection drops or the budget runs out, the function returns the in-band
failure its type allows: an escalation settles as refused, a fact operation
fails with `owner unavailable`, a capability is denied with
`owner_unavailable`. The tool run that asked therefore reaches a terminal
outcome instead of waiting on a reply nobody will send. An escalation's budget
is the call's remaining time plus a two-second slack, and it crosses the wire as
a remaining duration because the two clocks differ.

### Callers that are not tools

Hooks, goal checks, Git observation and the worktree diff run commands through a
`broker.Broker`, which is a subject and a clock. A remote session holds
`broker.over(census.broker, clock)`, a handle on the executor's broker subject,
so `clear_call`, `cancel` and `abort` work as they do locally and output streams
back to the caller. A `CallSpec` carries an absolute deadline that the
executor's broker compares with its own clock, so these callers read
`Half.call_clock` rather than the local clock (see "Two clocks" below). The
workspace path they put in a spec comes from the census as an opaque string.

### What a remote session refuses

Two features read orchestrator-side state that has no executor counterpart
yet, and a remote session refuses them rather than half running them: extension
tools and operator-added directories. Foreground and background `code_mode`
work, and so do MCP façades inside code mode; see "Background code mode and MCP
on a remote session" below. A remote failure never falls back to a local path,
because a remote session's orchestrator has no workspace path to fall back
to.

## Trust and transport

Orchestrators and executors are mutually trusted and administered by one
operator. A connected node has the full privileges of an Erlang peer: it can
spawn processes and call any function on the other node. So compromising an
executor's VM compromises the orchestrators it talks to, and the operator
accepts that cost when enrolling a machine. The design therefore draws its
boundary around who may connect, and does not try to defend one connected node
against another.

### Who may connect

`client/distribution` is the membership layer. It starts distribution and
connects to configured peers, and sends no message of its own. The checks are
these:

- **TLS with pinned leaves.** Nodes connect over `inet_tls_dist`. The verify
  function (`verify/4` in `client_distribution_ffi.erl`) keeps every PKIX
  failure, and for the leaf it requires a SHA-256 that matches a configured pin
  and a single node-name SAN (the certificate's only DNS name containing an
  `@`) equal to that same pin's node name. Both directions check, so a stolen
  certificate for another node, or a matching pin issued by another CA, is
  refused.
- **No automatic connection.** `dist_auto_connect` is `never`. A send to a node
  nobody connected to is dropped rather than dialled, and the only connections
  are the ones `distribution.connect` makes, under a weft deadline, to
  configured peers.
- **Hidden nodes and an allow list.** The node starts hidden, so two
  orchestrators connected to the same executor do not become connected to each
  other through it. `net_kernel:allow` lists only the configured peers, between
  one and 32 of them.
- **A shared cookie.** All nodes of a deployment hold one cookie, which must be
  the VM's own `$HOME/.erlang.cookie` with mode 0600; the emulator reads the
  cookie from there and nowhere else. The cookie is a second check behind TLS,
  not the boundary.

The verify function does not compare the certificate's node name with the name
the peer claims in the distribution handshake. Among pinned peers no per-node
identity is established at the distribution layer, so a pinned node can present
itself as another pinned node. That stays inside the trust envelope, since every
pinned node already holds full Erlang privileges, but nothing in the design may
assume a message came from the node it names on the strength of the connection
alone.

### Who dials whom

Orchestrators dial; executors never do. An orchestrator connects to an
executor when a session opens, and to a peer orchestrator when it asks the
session directory, sends peer mail or moves a session. No connection is made at
startup. An executor's owner callbacks travel back over the connection the
orchestrator made, and when that connection is gone they fail in-band. An
executor therefore needs two inbound ports (`epmd` and its fixed
`listen_port`). An orchestrator with no peer orchestrators is dialled by nobody
and can run without a reachable listener; in a deployment with two, each is
dialled by the other.

### Ledger mode

`[distribution] ledger` replaces `[[distribution.peers]]`
([protocol-change/086](../../protocol-change/086-membership-ledger.md)); a
document with both is refused when it is read. The two modes differ in where
the pins come from and nothing else: the PKIX checks, the exact node-name
check, the cookie, `dist_auto_connect = never` and the hidden node are the
same.

In ledger mode the options file names no pin. The verify state is the atom
`live`, so the file is a function of the credential paths and an enrollment
never changes it, and the boot check that compares the loaded file with what
the configuration generates is unchanged. For a leaf, `verify/4` reads the row
`pins` of the protected ETS table `loom_dist_pins`, a map from a 32-byte pin to
the node name that pin must present. A pin missing from the map is refused with
`peer_identity_mismatch`, and a missing table or row with `ledger_unavailable`.

**The ledger process owns the table.** `loom_ledger` (`client/ledger_service`)
creates it and is the only process that writes it, through the observer of
`client/ledger_trust`. The table is created when the process starts, from the
ledger the file replayed to, and its `pins` row is replaced with one insert
after each entry has been appended to the file, so a handshake reads the old map
or the new one. The table is deleted when the process ends, and every handshake
is then refused until it restarts. The pin table of a node is a function of the
applied prefix, and that is the whole of what `ledger_trust` publishes: the
pins of the active members this node is linked to. A node that is not an active
member publishes the empty table. The table holds at most 63 pins, because the
fold allows 64 active members (`ledger_trust.max_peers`), and the allow list
grows by one name for each node an entry names, so by at most the file's 10,000
entries: the 256 names ever enrolled bound member names, and re-upserting a name
with a new node is legal. The 32-peer cap of static mode does not apply.

**The order at boot** is fixed by the table. `client/ledger_boot` opens and
verifies the file, requires this node to be an active member, starts the ledger
process, which publishes the table, and only then calls `distribution.start`.
The listener never exists without a table, so there is no window in which the
first peer is refused with `ledger_unavailable`. The process does not need
distribution to start: `net_kernel:monitor_nodes` is valid on a VM that is not
yet distributed. Once distribution is up, the linked members are added to the
allow list and the process is told to dial. The daemon keeps the process's
handle in `daemon/main.Config.ledger`.

**What an entry does.** After the append, in this order, the process publishes
the new table, adds the linked members to `net_kernel:allow/1`, and disconnects
every connected node that the new table no longer lists or whose pin the entry
replaced (`ledger_trust.stale`). The allow list only grows and a revoked name
stays on it. It checks the name of an outbound connection and the host of an
inbound one, so the pin is what refuses a revoked member. A pin is checked
only at a handshake, so the disconnect is what ends a connection that is
already up. A renewed member's connections are dropped as well as its pin
replaced, since the old certificate may be the reason for the renewal.

**What a node-up does.** The process subscribes to node changes of all types.
On each node-up it judges the node against the ledger it holds when it handles
the message, and disconnects it unless it is a linked active member. The
message is behind any publish in the process's mailbox, so a handshake that
read the old row and completed after a revoke was published ends here, and no
timing assumption is involved. `ledger_live_test` orders exactly that: a hook
holds the process in front of the publish, a node connects on the old row,
the process is let go, and with the sweep of the entry left out the node-up
check alone ends the connection. Removing the check makes the test time out.

**A node whose own entry is revoked** is left with the empty table. Every
handshake is refused in both directions and every connection is dropped. Its
`net_kernel` keeps running, but no entry can reach it over the network
afterwards: its peers have swept it, it dials nobody and it accepts nobody. The
entry that enrolls it again arrives through `import` on its own machine, or
through a new bundle and a restart. A node that was down across its own revoke and
re-enrolment, and receives the revoke at the end of one 64-line pull batch and the
re-enrolment in the next, self-revokes and drops its connections in between;
recovery is `import`.

**Dialing.** An orchestrator keeps trying to reach the executors it is linked
to that are not connected and have not reported the current head. A pass every
5 seconds attempts each one that is due: the first at once, then 5 seconds
later, doubling to 5 minutes. An attempt runs in a process of its own through
`distribution.connect`, which resolves the name against the published table, so
a slow handshake never holds up heads or offers. Its outcome is not reported: a
connection that comes up is a node-up and the head the executor then reports
ends the dialing. Executors do not dial.

**Peer tables.** `[executors.<name>]`, `[orchestrators.<name>]`, `[spawners.<name>]`
and `[directory] members` name a peer by node. In static mode the node must be
a `[[distribution.peers]]` row. In ledger mode parsing a table checks its shape and
never reads the ledger, because a session parses these tables on every create and
open and the ledger changes while the daemon runs. The daemon compares the rows
with the ledger once, at start (`client/ledger_reference.audit`, called from
`daemon/main` after the ledger process holds the file). A row naming a node that no
entry ever named is refused. A row naming a node that was a member and is no longer
an active member this node is linked to is accepted as inert and logged as
`daemon.ledger_row_inert`; a call through it fails because `distribution.peer`
resolves only names in the current pin table. A daemon with a ledger has no
`[directory]` table: the session directory's members are the ledger's members whose
`directory` standing is `voter` or `learner`, derived at start by
`daemon/main.ledger_directory` and read again by the member actor on every tick, and
the Ra leader removes the members the ledger unseats
([the directory page](directory.md), "Following the membership ledger").

The executor names that a pool lists and a spawner places on get the same
treatment (`ledger_reference.audit_names`, logged as `daemon.ledger_name_inert`),
because the ledger can give an executor a row that no table defines.

**Derived rows.** An orchestrator does not need a table for a machine the ledger
says it is linked to. `client/ledger_rows` turns the members of its pin table into
`[executors.<name>]` rows (the executor members) and `[orchestrators.<name>]` rows
(the orchestrator members), named as the ledger names them, with no declaration and
no address. A row the operator wrote wins: a derived row is dropped when a written
row has its name (the written row overrides it, as design note section 12 says) or
its node (so one machine is never listed twice, and an orchestrator's node stays
unique). A node that is not an active orchestrator derives nothing, and an
orchestrator in the session directory derives only the orchestrators that are in it
too. Spawners are never derived.

A part of the daemon that outlives a request holds a `client/roster.Roster`, a
function that returns the rows. The session importer, the movers, the session
directory, the remote spawner and the server read it when they decide, and a
ledger-backed roster asks the ledger process, so an executor enrolled after the
daemon started is the next `sessions.create`'s and a revoked one stops being
offered. A session already open keeps the rows it was assembled with, and the
connection to a revoked member fails as one to a machine that is down. A ledger
process that does not answer leaves only the written rows, so a member that cannot
be confirmed is not offered. A static daemon wraps its parsed lists in a fixed
roster, and nothing else about it changes.

**Control commands.** `ledger.append`, `ledger.entries`, `ledger.status` and
`ledger.holdings` are owner-only commands of the control socket
(`client/ledger_control` holds both halves). `ledger.append` offers lines to the process in order through the
acceptance procedure, so the socket adds no trust beyond the owner check, and a
refused line is `ledger_invalid` with the step as its message. `ledger.entries`
is the local twin of a `Pull`. `ledger.status` reports the head, this node's
standing (`ok`, `revoked`, `not_enrolled`), each active member with the head it
last reported, and the last refusal. A frame is 64 KiB in both directions, so a
page of entries and an append are cut to 48,000 bytes of lines as well as 64
lines. A daemon with no ledger answers `not_found`. `ledger.holdings` asks the
orchestrators the daemon is linked to, and the daemon itself, what their catalogues
hold (`client/ledger_holdings`), and the daemon's own `deployment.status` carries the
body of `ledger.status` under `ledger`, so one read shows the head, which members
reported it, how long ago, and the last refusal.

**Holds.** The orchestrator port answers one more question,
`orchestrator_port.Holds`: how many sessions the catalogue owns, and how many are
placed on each executor, by node. It is the subset of protocol-change/085's `Report`
that the operator's check needs, and it runs apart from the port because it walks
the catalogue. A catalogue that cannot be read produces no answer, never a zero.

**A node tells the peer it pulled from.** After a pull that moved the head, the
node sends its head to the peer it pulled from as well as to the others. The
source already holds the entries but cannot know they were applied, and it learns
a peer's head only from a `Head` message, so without this the origin of an entry
would see no peer confirm it until the next 60 second tick.

### The operator's commands

`client/daemon/ledger_cli` holds `enroll`, `revoke`, `renew`, `log` and `import`,
which run on the operator's machine and need no daemon of their own. A signing
command unlocks the kept authority key, takes a lock on the operator's copy of
the ledger (`<authority dir>/ledger.log`), and asks a daemon for its head. A
daemon that is ahead has its lines pulled and verified into the copy first
(`client/ledger_sync`), and a daemon that holds a different entry at a sequence
number the copy has stops the command, so two machines holding the key cannot
fork the ledger by accident. The entry is built from the fold state by
`client/ledger_operator`, run through `membership_ledger.check`, signed and
appended to the copy. The daemon then gets every line it lacks, and the command
polls `ledger.status` for at most `--wait` seconds (10 by default) and prints
which members hold the new head. The member just enrolled or renewed is listed
and not waited for, since it cannot confirm before its bundle is installed. With
no reachable daemon the entry stays in the copy and the output says to run
`import` on a member's machine.

`enroll` and `renew` mint a certificate under the kept authority and write a
`/2` bundle with the whole ledger as of the new entry. The cookie in it is the
deployment's, kept in `<authority dir>/cookie`. A renewal's bundle carries no
`[executors]` rows or workspaces, so installing it over the node's old install
does not conflict with edits the operator made to them. `revoke` refuses when it
would leave an executor with no orchestrator linked to it or cut members off from
the rest, and when it would strand sessions, unless `--force`. The second check asks
the daemon the command talks to for `ledger.holdings` before anything is signed.
For an orchestrator it reads that orchestrator's own count of sessions. For an
executor it adds up what the orchestrators linked to it placed on its node, which
still works when the executor is the machine that is gone. An orchestrator that does
not answer, and a daemon that cannot be asked, are unknown and refuse the revoke as
a count above zero does, so the revoke of a laptop that is off needs `--force`. The
ledger itself never vetoes: a log fold cannot see sessions, and a veto at apply time
would give two nodes different tables from one log.

### Booting a distributed VM

The daemon boots without a node name and starts distribution itself, from
`daemon/main.prepare_startup`, before the catalogue or any session is opened.
`distribution.start` refuses a VM that was not booted for it, each with its own
`BootRefusal`: it requires OTP 29 or newer, `-proto_dist inet_tls`, an
`-ssl_dist_optfile` whose content equals what `tls_options` generates from this
configuration and is private, and no `-name`, `-sname`, `-setcookie`,
`-nocookie` or `-ssl_dist_opt`. The launcher `bin/loomd` adds the two flags when
`LOOM_DISTRIBUTION_OPTFILE` is set and changes nothing otherwise. A daemon with
no `[distribution]` table never starts `net_kernel`, and its sessions never
consult a ledger.

### How `epmd` is found or started

Distribution needs an `epmd` to register the node's name and port. `erl -name`
launches one at boot, but the daemon boots without a name and calls
`net_kernel:start/2` later, and that dynamic start never launches `epmd`. On a
machine where nothing had started one, the node would fail to register. So
`ensure_epmd` in the FFI, called by `distribution.start` before
`net_kernel:start/2`, asks the loopback `epmd` for its names under a deadline.
When nothing answers it runs `epmd -daemon` from the release's
`erts-<version>/bin`, or from `PATH` when the release carries none, and polls
for up to three seconds. It does nothing under `-start_epmd false`, which is how
an operator says `epmd` is managed elsewhere (a system service, or a forwarded
port). The port is the VM's `epmd_port`, which `ERL_EPMD_PORT` sets. When no
`epmd` can be had, the daemon exits with `EpmdUnavailable`, a fault distinct
from a credential failure. The `epmd` it starts outlives the daemon and is
shared by later Erlang nodes on the machine, as any `epmd` is.

### What the closed vocabularies limit

The messages between nodes are values of closed custom types: `HostMessage` to
the executor host, `OwnerMessage` to the owner port, and `orchestrator_port`'s
`Message` between orchestrators. They hold only plain data and subjects, and no
function, port or atom built from a peer's input. The owner port serves only
the two reserved fact prefixes, and the orchestrator port serves only five of
peer mail's commands, one read of the catalogue, the session-move messages and
the three subagent messages, so a peer cannot read a session's conversation
through them. Those limits are scope hygiene: they keep each port to its job. They are
not a security boundary, because a peer that wanted more could call any
function on the node directly.

Because the peers are trusted, a message is a typed Erlang term matched
directly, not decoded from untrusted bytes. The only guard on its shape is
`Attach.version` (`protocol.version`, 3 today). `Attach` keeps the shape it had
in version 2, so a peer of either version reaches that check, and the host
refuses a different version with `VersionMismatch`, creates nothing and stays
up. Anything newer a peer needs at attach, such as the MCP plan, is asked for
after the check. Every other message assumes a peer built from the same source:
one that does not match crashes the executor host, which halts the executor
daemon. So the upgrade order is to stop the remote sessions (or their
orchestrator), upgrade the executors and the orchestrators, and open the
sessions again; an open that still pairs two versions is refused at its attach.
The version is bumped for every changed constructor or field.

Jailed payloads stay outside all of this. Code-mode satellites, MCP servers and
language servers boot with `-proto_dist none`, their environment is built from
an allow list so `ERL_FLAGS` is not inherited, and no credential, cookie or
options file is mounted into a jail.

## Provisioning

`loom distribution` (`dist` for short, and `loomd distribution` on the daemon)
takes an operator from nothing to a trusted deployment without `openssl`. `init`
writes an example plan; `provision` reads the plan, mints one authority, one
ECDSA P-256 certificate per node and one cookie, signs a membership ledger and
writes one `<node>.loombundle` per node plus a secret-free `system.json` and
`ledger.log`; `show` prints the deployment; `install` puts one bundle's files in
place and merges its role tables into `loom.toml`; `options` renders the TLS
options file; `enroll`, `renew`, `revoke`, `log` and `import` change and read the
ledger afterwards (see The operator's commands, above). A bundle holds the node's
private key and the cookie, and no command prints either. The plan and bundle
rules call the daemon's own validators, so a bundle that installs is one the
daemon accepts. The setup guide, section 3, has the commands and the files they
produce.

The ledger is what `provision` writes by default
([protocol-change/086](../../protocol-change/086-membership-ledger.md)): a genesis
entry and one `member` entry per plan node, whose `links` and directory standing
reproduce the peer lists static mode would have written. Each node's pin table,
derived from the ledger, equals that list, and a test holds the two equal. Each
bundle (`loom-distribution-bundle/2`) carries the ledger in place of the peer
list, `decode` replays it against the bundle's own CA, and `OUT/ledger.log` holds
the same file. `install` writes the ledger beside the credentials, writes a
`[distribution]` table with a `ledger` key and no peer rows, and renders the live
options file. The ledger file is compared as a chain: a file the bundle extends is
replaced, a file that extends the bundle is kept, and two files that diverge are
refused unless `--force`. A plan with a session directory is provisioned like any
other: its directory members become voters in the ledger, the bundles list no
directory members, and the configuration `install` writes has no `[directory]`
table.

The authority key is kept: `client/authority_key` seals it with
PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM under a passphrase, in
`~/.loom/authority/<deployment id>` (directory mode 0700, files 0600), beside the
authority certificate, the operator's copy of the ledger and the cookie. The
passphrase comes from a terminal prompt that does not echo, or from
`--passphrase-file`, never from an argument. `--drop-authority` keeps no key, and
the ledger can then never be extended. `provision --static` is the older mode:
each bundle (`loom-distribution-bundle/1`) lists its peers' pins, the key is
dropped when `provision` returns, and adding a node or renewing a certificate
means provisioning again and reinstalling every bundle.

## One tool call, end to end

A remote call goes through four stages: the session open attaches once, each
call is sent as a `Run` and admitted by key into the executor's ledger, the
outcome is committed before any reply, and the orchestrator later acknowledges
it. Recovery and reconnection reuse the same messages.

```mermaid
sequenceDiagram
    participant O as orchestrator
    participant E as executor host + ledger
    Note over O: session open:<br/>connect peer, write scope record
    O->>E: Attach(version, session, workspace,<br/>incarnation, token, owner_port)
    Note over E: attach in one transaction:<br/>Created | Rebound | Reopened<br/>build plane (weft run)
    E-->>O: Attached(census, executor_now_ms, unacked keys)
    Note over O: strand driver commits intent<br/>effect process: surface.run
    O->>E: Run(key, incarnation, token, run, authority)
    Note over E: admit in one transaction:<br/>token and incarnation equal?<br/>no row: insert admitted, start<br/>admitted: join waiters<br/>terminal: stored outcome<br/>unknown or acked: RunLost
    E-)O: owner callbacks over the owner port
    Note over E: tool finishes<br/>finish: row terminal (committed)
    E-->>O: RunFinished(outcome)
    Note over O: runtime stages the outcome
    Note over O: owner port reconciler<br/>(at attach, then every 60 s)
    O->>E: Ack(key)
    Note over E: delete row, write tombstone
```

### Attach, once per open

Each time the orchestrator assembles a session it calls `surface.attach`
exactly once, before the first `run` or `recover`. The attach carries a fresh
32-byte random token and an incarnation, and the ledger makes that token the
scope's only valid one. Every strand, every strand-driver restart and every
runtime restart inside the open shares that one surface and token. A second
attach inside one open would rotate the token and get another strand's live
`Run` refused as `StaleToken`, so nothing below `remote/workspace` attaches
again.

The token is the fence against an earlier open. A crashed orchestrator, or an
open that was closed, may leave `Run` messages in flight, and Erlang orders
messages only per sender and receiver pair, so a later open cannot assume its
messages arrive after the dead open's. The ledger compares the token by value in
the transaction that admits a call, so a dead open's late `Run` is refused
however the network ordered it.

The host builds the session's plane as a weft run and answers the attach when
the build lands; a rebound attach reuses the plane it already has and is
answered at once. While a build is in flight, a second `Attach`, a `Run` and a
`Close` for that session are refused with `PlaneBuilding` before the ledger is
touched, and `surface.attach` re-sends the same attach with the same token
until its 30-second window runs out. The reply carries the census, the
executor's clock reading at the moment of the reply, and the session's
unacknowledged terminal and unknown keys.

### Run, keyed by the planner's identity

A call's key is `(session, op, step, source_index)`, the identity the planner
already uses. The host admits a `Run` by inserting an `admitted` row in the same
`BEGIN IMMEDIATE` transaction that checks the scope is open and that the
request's incarnation and token equal the stored ones. A second `Run` for the
same key never starts a second run: it joins the live run's waiters, or gets the
stored outcome, or is told the outcome is lost.

| Call row | Meaning | A `Run` for the key gets |
|---|---|---|
| none | never admitted in this scope | admitted, and the tool starts |
| `admitted` | running in this VM | added to the waiters |
| `terminal` | finished, outcome stored with its digest | the stored outcome |
| `unknown` | lost to an executor restart or a cancel | `RunLost` |
| tombstone (`call_ack`) | acknowledged in this incarnation | `RunLost`, never a start |

When the tool finishes, the host commits `finish` (the row becomes `terminal`
with the encoded outcome) before it answers any waiter. A cancelled run's row
becomes `unknown` before its worker is killed. A request for an `unknown` key
never starts the call again. The model reads `unknown_outcome_text` for a lost
call, which says plainly that the call may have run.

Admission reserves 16 MiB for each call, twice the largest file `fs_read`
returns, inside a ledger budget of 512 MiB. `finish` shrinks the reservation to
the outcome's real size, and an acknowledgement releases it. A call that would
pass the budget is refused with `BudgetExhausted`. Sixteen live calls hold
256 MiB, and the other half is room for results the orchestrator has not
acknowledged yet.

### Reconnecting re-sends the same `Run`

The orchestrator's effect process monitors the executor host while it waits.
When the connection drops, `surface.run` reconnects with a pause that doubles
from 50 ms to 2 s, and sends the same `Run` again. It keeps doing so until the
executor answers or the effect process is killed. It has no deadline of its
own, because the call's deadline lives on the executor. Messages lost with a
dropped distribution connection are never delivered later, so the re-send cannot
start a second run; admission treats it idempotently by key.

### Which `DOWN` cancels

There is no cancel message. The runtime aborts a call by killing its effect
process, and the host monitors the process that owns each `Run`'s reply subject.
A `DOWN` with any reason except `noconnection` means someone asked to stop, and
when the run's last waiter is gone the host cancels it
(`cancels_run`, `remote/host.gleam:481`). A `noconnection` `DOWN` means only
that the orchestrator is unreachable. The run continues to completion or to its
own deadline, which is built on the executor's clock, and its outcome waits in
the ledger. An abort issued during a partition arrives only as `noconnection`,
so that call's cancellation is unconfirmed: the run finishes, and its outcome
stays in the ledger until the reconciler acknowledges it.

### Acknowledgements and tombstones

An acknowledgement tells the executor that the orchestrator has durably staged
an outcome, so its row may go. The acknowledgement comes from the owner port's
reconciler. When a runtime attaches, the reconciler takes the unacknowledged
keys the attach reported; every 60 seconds it asks again with `ListUnacked`. It
acknowledges a key only when `workspace.settled` says the session no longer
holds that call pending, that is, the operation's state is gone or its batch no
longer lists the call as planned or running. A lost `Ack` is therefore found
again on the next pass, and no row leaks.

`exec_ledger.ack` (`storage/exec_ledger.gleam:778`) deletes a `terminal` or
`unknown` row, releases its bytes, and writes a tombstone in `call_ack`. A key
with a tombstone is never admitted again in that incarnation. The tombstone
closes a race the P model found. When a runtime restarts inside one open, the
token stays the same, and the dead effect process's `Run` can still be in
flight. Recovery's fence, sent from a new process, can overtake that `Run`, and
the acknowledgement follows the fence. Without the tombstone, the late `Run`
then found no row and a current token, and started a call the language model
had been told never ran. Tombstones hold no outcome
and no bytes. They are dropped when the scope reopens at a new incarnation,
closes with every child retired, or is released by the operator.

### Recovery and the per-key fence

When a strand driver or runtime restarts, its effect processes are killed, and
the planner finds orphaned calls whose intent is durable but whose result was
never staged. A remote session's surface offers `ToolSurface.recover`, so the
runtime spawns a recovery effect for each, which reports through the same
`ToolDone` path as a fresh run. A local session sets `recover: None` and keeps
the old orphan rule.

`surface.recover` asks the ledger. A call whose replay policy is `ReplayNever`
is asked with `QueryOrFence`, which in one transaction either returns the row
that exists or, when there is none, inserts a terminal "did not start" row. If
a dead runtime's stale `Run` arrived first, the fence finds it admitted and
recovery waits by re-sending `Run`. If the fence arrived first, the stale `Run`
finds the key taken and never starts. A `ReplaySafe` call is asked with a plain
`Query`, because the planner may replay it under the same key and admission
deduplicates the replay against any stale `Run`.

| Ledger answer | Recovery | The runtime stages |
|---|---|---|
| `terminal` | `Recovered(outcome)` | the stored outcome |
| `admitted` | re-sends `Run` and waits | the outcome, or unknown if it is lost |
| `unknown`, or a tombstone | `OutcomeUnknown` | "the outcome is unknown" |
| no row, `ReplaySafe` | `NotStarted` | nothing yet: the planner replays it |
| no row, `ReplayNever` (fenced) | `NotStarted` | "the call never reached the executor and did not run" |
| refused or unreachable | `OutcomeUnknown` | "the outcome is unknown" |

Recovery assumes the attach of the current open ran first, because "no row"
means "never started" only after the token has taken effect.

### Two clocks

The orchestrator and the executor do not share a clock, and the design never
lets one machine's clock decide a timeout on the other. Tool deadlines are built
and enforced on the executor, where the broker budget and tool timeouts are
constructed. Escalations cross as a remaining duration, and the owner port
rebuilds the deadline on its own clock. Non-tool callers are the one case that
builds an absolute deadline on the orchestrator. For them, `workspace.rebased`
shifts the local clock by the executor's reading in the `Attached` reply minus
the local reading at receipt, and `Half.call_clock` is that shifted clock. The
skew is measured at every attach, a rebound one included. Protocol version 2
moved the clock reading from the census, which is built once per plane, into the
reply, after a review found that a rebound attach rebased the clock on a reading
as old as the scope.

## Scope lifecycle

A scope is the executor's record of one session's workspace. The ledger has one
scope row per session, with a workspace, an incarnation, a state (`open`,
`closing` or `closed` with `all_retired` or `unknown:<n>`) and the current
attach token.

### Incarnations

The incarnation rises only on a reopen, and by exactly one. The orchestrator
keeps a scope record in the session's own store (the reserved cell
`client/remote/scope`, holding the incarnation, the last close outcome and the
executor), and `scope.attach_at` picks the incarnation from it: 1 with no
record, the stored incarnation plus one after any close that ended, clean or
not, and the stored incarnation otherwise. The ledger then answers:

- no scope: create it (`Created`), if capacity allows;
- `open` at the same incarnation: replace the token (`Rebound`), which is how a
  new open after an orchestrator crash takes over a scope the executor still
  holds;
- `closed, all_retired` and exactly the next incarnation: reopen (`Reopened`),
  if capacity allows, and drop the old incarnation's tombstones;
- anything else: refuse, with `StaleIncarnation`, `ScopeClosing` or
  `UncleanClose`.

A request from a closed incarnation fails the incarnation check, and a request
from an earlier open of the same incarnation fails the token check. An executor
admits at most 16 scopes that are not cleanly closed, and refuses the
seventeenth attach with `CapacityExhausted` inside the attach transaction,
before it builds anything. `LOOM_EXECUTOR_MAX_SCOPES` lowers the limit. A clean
close frees its slot at once.

### Clean and unknown cleanup

Close is a ledger transition. The host commits `closing` first, which is the
fence: nothing is admitted after it. It then cancels the session's live calls,
telling their waiters the outcome is lost, and runs the plane's close as a weft
run. The plane retires its parts in order (the language servers, the scope's
supervised children, the broker, then the helper pool) and reports `AllRetired`
only when nothing failed and `exec.close_pool` returned its retirement result.
Job runners, language servers and satellites are all helper children, so pool
retirement covers them. A missing helper witness is `UnknownCleanup`. A monitor
`DOWN`, a timeout or a lost reply never counts as a witness. The host then
records `closed` with the outcome, and removes the scope's directory only on
`AllRetired`.

A repeated `Close` at an incarnation that already closed answers the stored
outcome without asking the plane again. That is how an orchestrator whose reply
was lost, or a mover resuming after a restart, learns the cleanup finished: the
scope row is the evidence, not the host's memory. On the orchestrator,
`plane.close` records whatever the executor reports. An unanswered close records
nothing and still lets the session's custody finish, because the scope is then
still open on the executor and the next open rebinds it.

### The operator's release

A scope whose cleanup was not proven gets no automatic successor: the executor
never infers that a session's processes are gone. The explicit exit is
`loomd executor release SESSION`, run on the executor with its daemon stopped.
It takes the state directory's endpoint reservation first, which a live daemon
holds, so it cannot open the ledger beside one. It moves a `closing` scope, or a
`closed` one with unknown cleanup, to `closed, all_retired`, and writes a
`scope_release` row with the former state and the time in the same transaction.
It refuses an `open` scope and a clean one. Because the orchestrator attaches at
the next incarnation after any close, the same attach that the executor refused
as `UncleanClose` before the release reopens the scope after it.

### What an executor restart does

The executor host is a node-level actor that owns the one ledger connection.
The daemon starts it unlinked and monitors it, and any end of the host halts
the executor daemon with `daemon.executor_lost`. The host is never restarted on
its own, because the planes it builds are not in its link set, and a lone
restart would leave their helper pools and jobs actors running beside the
second set the next attach builds. Ending the VM retires them.

On the next boot, `exec_ledger.open` turns every `admitted` row into `unknown`;
nothing is relaunched. The new host holds no plane for any scope. A `Run` for a
key the ledger holds a row for is answered from that row first: a stored outcome
is returned and an unknown row gets `RunLost`. Only a key with no row is refused
with `NoPlane`, whose text says nothing started. A session that stays open
across the restart therefore keeps failing new calls until it is closed and
reopened. Its close finds no plane, so no witness, and records
`UnknownCleanup(0)`. The reopen is then refused as an unclean close until the
operator runs `loomd executor release`. That is the routine way out of an
executor restart, and the setup guide's troubleshooting section walks through
it.

## Pools and placement

A session can name a pool instead of an executor (`sessions.create` with
`pool`). `[pools.<name>]` lists executors in the order they are tried, and may
require a `platform`, an `enforcement` level and `toolchains`. Each
`[executors.<name>]` row may declare the same three. The declarations are the
operator's claims, and `pools.candidates` is a pure function of configuration:
an executor that declared nothing cannot satisfy a requirement, and no message
asks a machine what it has. The balance is order, not load.

The rule that matters is that a session's checkout exists only where its scope
record says. `remote/workspace` writes the record, naming the executor, after
the connection succeeds and before the `Attach` is sent. A session whose record
names an executor has only that candidate, ever. A first open, with no record,
moves to the next candidate in exactly two cases, both of which prove that no
scope exists: the connection failed before the attach was sent, or the executor
answered `CapacityExhausted`. The record is withdrawn after that refusal. Every
other outcome fails the open and keeps the record: an attach with no answer may
have created the scope, and the ledger's rebind makes a retry against the same
executor converge. A capacity refusal on a later open is `executor_unavailable:`
and never a reason to move.

After an attach, the census is compared with the declaration. A contradiction
closes the scope, which returns its slot, and fails the open naming the declared
and the reported value. The catalogue learns the chosen executor through
`manager.seed_executor`, which writes the executor column once and only for a
pooled registration with none.

## Reading the deployment

Before this command an operator learned that an executor did not answer when a
session placed on it failed to open. `deployment.status` (owner-only, protocol
change 085) reads the nodes the daemon is configured with, and says which of
them its own connection attempts reached, before any session exists.

`client/deployment` makes the read. It lists the daemon's `[orchestrators]` rows
and then its `[executors]` rows, connects to all of them at once in one weft run
(each attempt bounded at one second, the run at three), and reports each node as
`ok` when `distribution.connect` succeeded and `down` when it did not, with one
of three reason words: `timeout`, `unreachable` or `unavailable`. Nothing is
cached; the next read connects again. A first TLS handshake can outlast its
second, in which case the node is `down` in that reply and `ok` in the next. The
deployment as a whole is `ok` when every configured node is, `down` only when none
is, and `degraded` between: one dead executor among several is a degraded
deployment, not a dead one. The
daemon asks about itself too, as the first node, and a daemon with no
`[distribution]` table answers with itself and its executors `down`.

Every statement is "as seen from this daemon", so a link is only known for edges
that touch it: the reply has one `peer` edge to each orchestrator and one `serves`
edge to each executor, each with the asking daemon's own link (`connected` or
`none`). It also holds the placements a session-creation form draws: each
executor with the state `ready` or `down` and what its operator declared, and each
pool with the executors `pools.candidates` admits, in its trial order, and which
of them were reachable. The pool is not reordered by health; the first open still
tries its order and moves on only for a failed connection or `CapacityExhausted`.

The request may carry `node`, a key of `[executors]` or `[orchestrators]`. The
key is resolved against the daemon's own configuration before anything is
connected to, so a name taken from the request body never reaches the connection
layer; a key the configuration lacks is `not_found` and connects to nobody. A
member principal is refused `forbidden`, as for `directory.status`.

This is health from reachability only. What a node says about itself (its
capacity, its scopes that block a reopen, its build) needs a question the
orchestrator port does not yet carry, and every node member beyond `node`, `name`,
`roles` and `state` is optional so that it can be added later without replacing
anything. `loom deployment status` and `loom deployment executors` print the
reply (`--json` prints it as sent); `tui/deployment_view` decodes it with a total
decoder of its own.

## Two orchestrators

A deployment may run two orchestrators, each with its own catalogue, and a
client may connect to either. A session is created on, and owned by, the
orchestrator the client is connected to. Identities are UUIDv7, so no two
orchestrators mint the same one, and nothing registers a session anywhere else.
Each catalogue stays the source of truth for the sessions it owns.

Finding a session that another orchestrator owns follows option C of the phase 3
ruling: `client/session_directory` is an interface, not a store. Its `lookup`
answers `Here`, `Elsewhere(orchestrator)`, `Unknown` or `Unreachable(names)`.
The backing asks the local catalogue first, then every `[orchestrators.<name>]`
peer at once, in one weft run under a two-second deadline: each task connects to
the pinned peer and sends `Owns(session)` to its `loom_orchestrator` port. The
port answers `Owned`, `NotOwned` or `Moved(to)` from its catalogue, counting a
reserved or archived registration as held, and a catalogue that cannot answer
sends nothing, so a failed read is reported as unreachable and never taken for a
negative. `session_directory.decide` is the policy: the first holder in
configuration order wins over any silence; with no holder, any silence is
`Unreachable`; only a full set of "not held" answers is `Unknown`. Nothing is
cached, registered or retried. The interface is shaped so that a replicated
store could later replace the backing (Khepri is planned as a follow-up), and
phase 5 added its write half, `activate`.

The control commands use the directory only on a miss. When `sessions.get` or
`sessions.open` finds no session in the daemon's catalogue and the principal is
the owner, the daemon asks the directory. `Elsewhere` becomes the refusal
`not_owner`, carrying the owning orchestrator's name and, when this daemon's
row configures one, its `address`. `Unreachable` becomes `owner_unreachable`,
carrying the names that did not answer. A member principal always gets
`not_found`, because a member's standing is the owning daemon's to judge.
Nothing follows a redirect: neither first-party client holds a credential for a
second daemon, so the terminal prints the launch line for the owner and stops.
There is no merged session list.

## Peer mail across orchestrators

Peer mail already deduplicated on the recipient by message id, and its only
same-node assumption was the recipient's `peer_mail.Endpoint`. The distributed
runtime adds a second kind of endpoint and a durable outbox on the sender.
[Messaging](messaging.md#peer-mail-across-orchestrators) describes the whole
path; the parts that matter for failures are these.

`peers.routed` answers a session resident on this orchestrator locally and asks
the directory for any other. `Elsewhere` yields `remote_peer.at`, an endpoint
that sends `PeerCommand(session, command, reply)` to the owner's
`loom_orchestrator` port. The port serves five commands (`Allow`, `Revoke`,
`Deliver`, `SentReceipt`, `Roster`) and refuses every other `peer_mail.Command`.
It forwards a served command to the resident session's own endpoint, and
admission runs in the recipient's Agency as it does within one daemon, so a
repeated `Deliver` gets the stored receipt and a `Roster` lists the strands the
recipient granted the asking session. A remote call is `Unreachable` on
`noconnection`, on `noproc`, or after seven seconds with no answer (two seconds
for a `Roster`, which is a read for a listing).

A listing also shows what the owner's catalogue says about a recipient, so the
port has a sixth message, `Describe(session, reply)`. It is answered from the
daemon's catalogue in the port's own turn and never opens the session, so a
saved recipient is described as `saved`. `peers.described` asks the owner
(`Directory.describe`) only when this daemon's catalogue has no row, and a
session this catalogue gave away is not described from its tombstone. An owner
that cannot be asked leaves the row `unavailable`, and the listing is whole.
The roster row, `describe` and the `wake` of `peers.inspect` for a recipient on
another orchestrator are therefore the owner's own answers, under the same rules
a local recipient is held to: the sender lists only sessions its own links and
grants name, and the owner lists only the strands the recipient granted the
asking session.

`peer_mail.Failure` separates `Refused(reason)`, a definitive answer, from
`Unreachable` and `NotOpen`. `NotOpen` is the owner's answer that its catalogue
holds the session and it is not resident: the owner replies with the fixed text
`peer_mail.not_open_reason`, and `remote_peer` turns it back into the variant. A
session that no catalogue holds, or that its owner archived, is `Refused`, because
nothing a message does will open it.
Before it asks, `peers.send` writes an outbox row (`client/peers/outbox/<digest>`)
in the sending session's store. When the first attempt finds the owner
unreachable, or the recipient saved, the tool returns `queued`, and a weft state
machine per resident session, `peer_outbox_drain`, retries the row. It waits five
seconds between attempts while an owner does not answer. While the owner answers
that the recipient is saved, nothing the sender does hurries the owner's decision
to open it, so the wait doubles from five seconds to five minutes. Each attempt
resolves the recipient again, so a session moved to another orchestrator is
followed and one that was deleted ends the message. A strand keeps at most 64
rows, and a row pending for an hour is refused: as `owner unreachable` if its last
attempt found no owner, and as `recipient not opened in time` if it found the
recipient saved. A reply that arrives after the deadline reaches nobody; the
drainer's next attempt gets the receipt the recipient stored.

## Moving a session between orchestrators

An owner can hand a session that lives on an executor to another orchestrator
with `sessions.move` (`loom sessions move <id> --to <orchestrator>`). The
conversation file moves; the checkout and the executor stay where they are. A
local session cannot move, because its checkout is a directory on the source.

### Who owns the session

Two catalogue rows are the whole authority, ordered by a write-ahead intent.
The source's row in `catalogue_session_moves` goes `resident -> moving(op, to)
-> moved(to)`, and the receiver's goes `resident -> imported(op, from)`. Each
transition is a compare-and-set in one immediate transaction, keyed by the
move's `op`. No third store takes part, and the executor records no owner. Its
incarnation fence is a second guard: it records which token is current, not
which orchestrator owns the session.

- Before the intent, the source serves the session.
- The intent commits `moving` in the same registry turn that stops the slot,
  and admission refuses a `moving` or `moved` session, so no runtime on the
  source can open the file afterwards.
- Until the receiver activates, the source's `moving` row is still the one
  owner. Neither side being unreachable changes that.
- The activation is the receiver's compare-and-set, `absent -> imported`, with
  the file put in place. From then the receiver owns the session.
- The retirement moves the source to `moved(to)`, which the same `op` cannot
  undo, so a late message of that move cannot bring the session back.

### The six steps

The source's mover (`session_mover`, run by the daemon's `session_movers`
actor) takes the steps in order, each durable before the next:

1. **Intend and stop.** Commit `moving(op, to)` and stop the slot.
2. **Close.** The session's cleanup closes its executor scope and writes the
   outcome into the file's scope cell. A cell with no close, because the
   orchestrator died first, is settled by asking the executor to close again,
   which answers the stored outcome. An unproven cleanup refuses the move.
3. **Cut.** Copy the closed file with `VACUUM INTO` under the writer lease
   `move:<op>`, drop the lease row from the copy, and hash it.
4. **Send.** Send the copy in 256 KiB pieces, each acknowledged, up to 256 MiB.
   Any failure sends the whole file again.
5. **Activate.** The receiver checks the sender's node against its
   `[orchestrators.<name>]`, the digest, that the copy's scope cell reads a
   clean close at the claimed incarnation, and that it configures the executor
   the cell names. Then one registry turn registers the session, records
   `imported` and renames the copy into place.
6. **Retire.** The source's row becomes `moved(to)`, its lease is released and
   its file is set aside as `<id>.db.moved`.

Every run starts from what is on disk. A mover reads the source's row and asks
the receiver how far the move has got (`Absent`, `Received` or `Activated`)
before it takes a step, and the daemon resumes every `moving` row at boot. Each
step runs under a weft deadline of its own, and a stalled move is retried every
five seconds.

### The rules

Three rules carry the protocol's safety. The TLA+ model checks the first two
with a mutation each; the third concerns a second move, which that model
leaves out.

**Only an answer abandons a move.** A move is abandoned, returning the source's
row to `resident`, only on an unproven cleanup, a refused close, a corrupt or
oversized file, or the receiver's `Refused`. Silence, an unanswered close and
an expired deadline are stalls, because an unreachable receiver may have
activated the session and lost the reply. Abandoning on silence could leave two
owners.

**A committed activation is always accepted.** Once the receiver has committed
`imported` under an operation, every `Activate` for that operation is answered
`Accepted`, whatever else is now true: the session may already be open there,
the sender may have been renamed in the configuration, the copy may be gone.
The receiver reads its catalogue before it resolves the sender for that reason.
A refusal after the commit would make the source abandon and leave the session
owned by both.

**An imported session holds move-on and delete until its origin has retired.**
The receiver's `imported` row is the record the source's retry depends on.
Moving the session onward replaces that row, and deleting the session removes
it, after which the source's retry would import the session afresh. So
`sessions.move` refuses `not_movable`, and `sessions.delete` refuses `busy`,
until the origin answers `Moved` for the session. The web page's delete does
not apply this hold yet.

### The executor fence

The receiver attaches at the incarnation the copied cell implies, one above the
clean close, so the executor reopens the scope with the receiver's token and
refuses the source's old one by value. The source's scope was already closed
cleanly before the copy was cut, so the source has no live runtime to refuse in
the first place.

A move carries no running processes. A background job dies with the scope's
clean close, as it does on a stop. Memberships, claims and the memory domain
stay on the source, and a client reconnects to the receiver and catches up from
there.

## Background code mode and MCP on a remote session

**Status: built, at protocol version 3.** The rules are in the protocol-change/078
addendum "background code mode and MCP façades on a remote session", together
with the failure table for both paths. This section shows how the parts fit.

### A background execution

The orchestrator keeps the execution's durable record in `async_runs`, exactly
as a local session does: the record, the input journal, progress, the ceilings,
the idle expiry, the completion notice and recovery. The executor only runs the
program. A worker process on the orchestrator asks the executor to run it with
`StartExecution` and waits for the result, the way an effect process waits on a
`Run`. The execution has a row in the executor's ledger keyed
`(session, op, "async/<id>", 0)`, so it is admitted once, committed before any
reply, lost on an executor restart and fenced against a stale token like any
tool call.

The program's inputs and progress need no new message. `execution.receive`,
`execution.receive_enveloped` and `execution.progress` are owner-bound
capabilities, so they cross the owner port as `Capability` calls, and
`async_runs` answers them from the journal and the progress snapshot it already
keeps. The owner binds such a call to its execution by the step `async/<id>`
that the executor's tool shell filled in, and refuses it once the record has
closed. A typed-service program ends on its first failed receive, so on a link
cut the executor's `execution.receive*` calls wait for the orchestrator to
reconnect, within their own wait, and then answer "no input yet" rather than
fail; `execution.ready`, `progress` and `delivery` wait up to 120 seconds.
Each of those calls is safe to send twice, because the receive is keyed by the
program's cursor and the others record the same observation again.

The diagram follows one execution from the launch through progress, an input,
a link cut and the report.

```mermaid
sequenceDiagram
    participant M as model (strand)
    participant O as orchestrator<br/>runtime + owner port
    participant A as async_runs + worker
    participant H as executor host + ledger
    participant P as program (satellite)
    M->>O: code_mode mode=launch
    O->>H: Run(launch call)
    Note over H: code_mode tool loads the source,<br/>builds the terms
    H-)O: LaunchExecution(terms)
    O->>A: async_runs.launch
    Note over A: claim the record (Starting)<br/>before the worker starts
    A-->>O: handle
    O--)H: handle
    H-->>O: RunFinished(handle)
    O-->>M: handle
    A->>H: StartExecution(key, incarnation, token, terms, remaining_ms)
    Note over H: admit the key in one transaction<br/>row admitted
    H->>P: codemode.execute under step async/id
    P-)O: Capability execution.progress
    O->>A: Progress
    M->>O: code_mode mode=send
    O->>H: Run(send call)
    H-)O: InteractExecution(send)
    O->>A: append to the input journal
    P-)O: Capability execution.receive
    O-->>P: the input
    Note over A,H: link cut
    Note over H: worker DOWN noconnection:<br/>waiter dropped, program runs on
    Note over P: execution.receive waits<br/>for the link, within its wait
    Note over A,H: link back
    A->>H: StartExecution (same key, re-sent)
    Note over H: row admitted: join the waiters
    P-->>H: program ends
    Note over H: commit the row terminal
    H-->>A: ExecutionFinished(value)
    Note over A: save Finished(value),<br/>notify the strand
    O->>H: Ack(key), once the record is terminal
```

A program is cancelled only on a decision the orchestrator recorded: an owner's
cancel, an abort of the launching operation, a session stop, the deadline, the
idle expiry or a restart. Each sends `StopExecution`, which in one ledger
transaction marks a running row `unknown` before the program is stopped, and
inserts a missing key as `unknown` so that a late start never runs it. A
`noconnection` never cancels. A stop lost to a partition is repeated by the
owner port's reconciler, which also stops programs left running by an
orchestrator that restarted. The reconciler acknowledges an execution's row only
once its record is terminal, so a result the worker has not read yet is never
discarded. After an orchestrator restart, recovery asks the executor for each
execution that was live: one that had already finished keeps its stored result,
and any other is recorded as lost and stopped.

### An MCP call in each placement

Each `[mcp.<name>]` table gains `runs_on`, `"orchestrator"` by default or
`"executor"`. A local session ignores it. On a remote session an
orchestrator-placed server runs on the orchestrator with the keys it holds, and
the executor receives only the generated façade, in the MCP plan it asks the
owner port for while it builds the plane (`AskMcpPlan`): the source it compiles
into a program's build, the surface the model reads, and the module name
vetting admits. The call goes back over the owner port, because `cap_placement` already
places `mcp.<server>` on the owner.

```mermaid
sequenceDiagram
    participant P as program (satellite, executor)
    participant R as executor router<br/>(owner_codemode.sent_to)
    participant OP as owner port (orchestrator)
    participant C as mcp client actor (orchestrator)
    participant S as server process (orchestrator)
    Note over OP,S: before the attach: resolve api_key_env here,<br/>spawn, tools/list, generate the façade
    Note over R: the plan the plane asked for carried the façade:<br/>allowlist, description, build source
    P->>R: cap_call mcp.github (tool and arguments)
    R->>OP: Capability(call) over distribution
    OP->>C: client/mcp.routing arm
    C->>S: tools/call
    S-->>C: result
    C-->>OP: cap_result
    OP-->>R: cap_result
    R-->>P: typed result, or an in-band error
```

An executor-placed server runs on the executor, beside the checkout, from the
executor's own `[mcp.<name>]` table. The orchestrator's `runs_on = "executor"`
only states the expectation: the plan the executor asks for carries the
expected server names and nothing else, and the census reports which of them
started and why any did not.
The executor resolves `api_key_env` from its own `[secrets]` table and
environment, so neither an argv nor a key crosses the wire. The server's client
belongs to the scope's plane, starts when the plane is built and is closed when
the scope closes. Closing kills the server with SIGKILL at once and waits up to
five seconds to see the process exit; a missing witness is logged and is not
counted as unknown cleanup. Its calls never leave the executor.

```mermaid
sequenceDiagram
    participant O as orchestrator
    participant H as executor host + plane
    participant C as mcp client actor (executor)
    participant S as server process (executor)
    participant P as program (satellite, executor)
    O->>H: Attach(version, session, workspace, incarnation, token, owner port)
    H->>O: AskMcpPlan, during the plane build
    O-->>H: McpPlan(served façades, expected server names)
    Note over H: plane build: read the executor's own<br/>[mcp.name] table, resolve api_key_env<br/>from the executor's own secrets
    H->>C: start client
    C->>S: spawn argv, initialize, tools/list
    Note over H: generate the façade here
    H-->>O: Attached(census with mcp statuses)
    P->>C: cap_call mcp.repo, answered on the executor
    C->>S: tools/call
    S-->>C: result
    C-->>P: typed result, or an in-band error
```

One program may import façades of both placements. The executor's router sends
`mcp.<server>` to the owner unless the scope's plan names that server as
executor-placed. The plan is fixed when the plane is built, for one
incarnation. A later open that rebinds the scope after an orchestrator restart
keeps the plane and its plan, and answers with the census the plane was built
with, so a changed plan takes effect at the next reopen.

## Subagents on another orchestrator

[The design note](../design-notes/remote-subagents.md) and
[protocol-change/084](../../protocol-change/084-remote-subagents.md) give a model
on one orchestrator, a laptop, children that run on another, the box. Both sides
exist: the box's policy, the orchestrator port's messages and the delegate
sessions that serve them, and the laptop's stubs, drainer and tools that send the
messages. The shipped two-orchestrator test and the formal model are a later
slice.

The box lists each orchestrator that may spawn on it in a
`[spawners.<name>]` table (`client/spawners`, read once at startup like
`[executors]`). The table names the spawner's pinned node, one placement for its
delegate sessions (an executor or a pool with a workspace, or a directory), a
profile, a tool ceiling, `max_depth`, `max_sessions` (at most 16, an executor's
scope limit), `max_within_s`, `default_within_s` and `retain_s`. The decoder
requires `default_within_s <= max_within_s <= retain_s`. The limits bound an
honest spawner and a model that spawns too much; a pinned peer is fully trusted,
so they are not a boundary against a compromised one.

The orchestrator port gains three constructors, whose plain-data vocabulary is
`client/remote_spawn`. `Spawn` starts a child, or answers the handle of the one
the same call site already made. `Join` waits for at most 25 seconds and answers
one `Ready` or `Pending` per handle. `RunEnded` stops the children a finished
run owns and counts them; the laptop does not send it in phase 1, because a
remote child is detached. Each answer is `Ok(..)` or `Error(SpawnRefusal)`, and
a refusal is definitive. All three run in a task linked to the port and
cancelled with the requester, as `Activate` does, so a question about ownership
is never kept waiting behind one. The sender's node comes from the process that
asked, and the host judges it against the spawner table.

A daemon supplies the port a `SpawnHost`. One with no `[spawners]` table gives
every message `UnknownSpawner`. One with a matching spawner serves the message
from that spawner's delegate session, below. A host that crashes sends nothing,
which the asker reports as `Unreachable`, and the sender resends a spawn because
the receiver adopts the child its call site made.

### The delegate session

A spawner's children do not run in any session of the box's owner or members.
The first message for a (spawner, parent session) pair creates a session for the
pair through the registry (`manager.delegate_session`), with the spawner's
placement and profile and the `session_only` memory domain, and records it in
the catalogue table `catalogue_delegate_sessions` (catalogue version 15). The
row is the pair, the session and the time of the last message. It is also the
marker that makes the session a delegate session, which the registry's `movable`
check reads, so `sessions.move` answers `not_movable` for it. The spawner's
`max_sessions` is the count of its rows. The count, the creation and the record
are one turn of the registry, which is already the one process that serializes
session creation, so two first spawns cannot both pass the cap, and the
creation's request key is derived from the pair, so a crash between the
registration and the row is retried onto the same registration.

Every later message for the pair finds the row and admits the session if it is
not resident, so a restart or a close needs no step of its own. The message
waits in `client/delegate_host` for the session to become resident, up to 20
seconds. The registry's resident projection (`serve.Resident`) carries a
`DelegateEndpoint`, three closures over the Agency holder's name that stay small
because the registry copies the projection to whoever looks it up.

The parent is not a strand of the delegate session. Its children's lineage names
the reference `^main`, and `runtime/api` refuses any strand name that begins
with `^`, so the reference cannot name a real strand. The Agency (`client/agency`)
takes a `Source` that says whether a spawn comes from a strand of its session or
from such a parent. For a remote parent the depth, the parent's tools and the
spawner's terms (`remote_spawn.Delegation`) come from the message in place of a
parent strand's cells, the base configuration is the delegate session's own
`main`, which the spawner's profile seeded, and the child's brief is attributed
to a `PeerOrigin` for the parent's session and strand. The child's tools are the
parent's tools under the spawner's ceiling, narrowed by the request. The
request's deadline is always finite: absent means `default_within_s`, and a value
above `max_within_s` is refused and not clamped.

`Join` is the Agency's `wait` for the named children, asked as `^main`, with a
window cut to 25 seconds inside the receiver whatever the sender asked, and each
settled child's usage added from the session's usage ledger. A child's entries
are its whole branch, since a delegate child starts from no fork point, so its
usage is the sum of the ledger rows priced on that branch. The remote prices
once, and the sender records the result without repricing it.

A run of the parent can end while a `Spawn` for it is still in flight, because
the two travel from different processes and distribution orders only per sender.
`RunEnded` therefore writes the fence `delegate/ended/{operation}` (a reserved
fact prefix) and then reaps the children whose current run that operation owns,
both inside the holder. A spawn that would create or finish a child reads the
fence first and is refused with `ParentRunEnded`. A spawn that finds the child
its call site already made adopts it whatever the fence says, since adopting
creates nothing for the run end to have missed.

### The parent's side

`agent_spawn` takes an optional `on`, an enum of the `[orchestrators.<name>]`
keys the session reaches. The schema leaves the argument out when there are
none, so a session that cannot use it does not carry it in the cached tool array.
The daemon fills each session's `Config.remote` (`client/remote_reach.Reach`) from
its membership and its orchestrators (`client/remote/remote_spawner`): two
functions, `spawn` and `join`, that connect to the pinned peer on demand and answer
`Ok`, `Refused(reason)` or `Unreachable`, as `remote_peer` does for peer mail.
The record is in its own module because the orchestrator port sits above the
Agency in the module graph, so the Agency cannot import the port. The reach also
holds `offered`, asked at each spawn: it is true only in a session the owner
holds alone (`manager.unshared_sessions`), and inviting a member makes the next
spawn refuse.

**The stub is written first.** The holder admits a remote spawn: it checks the
depth cap and the fan-out caps and writes `remote-child/{call site digest}`
(`client/remote_child`), a reserved fact holding the orchestrator, the parent
strand, the call site, the parent's depth and tools, the whole request and the
child's derived name. The write expects the cell to be absent, so a replay and an
interrupted first attempt arrive at the same stub, and a stub whose recorded call
site is not the caller's is refused as `NameAlreadyMinted`, as an adopted child's
is. The network then runs on the caller's own process, not in the holder, so a
silent orchestrator cannot hold up the session's other spawns.

```mermaid
stateDiagram-v2
    [*] --> Requested: holder writes the stub
    Requested --> Spawned: Spawn answered
    Requested --> Refused: a refusal, heard by the model or the drainer
    Refused --> Spawned: a later answer names a child
    Spawned --> Settled: a Join reports it finished
    Refused --> [*]
    Settled --> [*]
```

The spawn is sent, and resent with a pause that doubles from 50 ms to 2 s, for 30
seconds. The receiver adopts the child its call site made, so a reply lost on the
way back returns the same handle. An answer writes the lineage cell, which names
the orchestrator, and then moves the stub to `Spawned`; every step is a
compare-and-set that leaves a stub alone once it has left the state the step
starts from, because the effect process and the drainer can both hear the same
answer. A refusal, wherever it is heard, leaves the stub in `Refused` with the reason:
it can be transient, and a second asker of the same call site may still be
answered with a child, which needs the stub to land on. When the window runs out the stub stays `Requested`, the model is told the child
may exist (`RemoteSilent`), and the drainer is rung.

**The drainer.** `peer_outbox_drain.Options` holds a `pass`, so one machine can
drain peer mail and a second can drain this: `client/remote_drain.pass` resends
each `Requested` stub every five seconds, asks a silent orchestrator once per
step, and has no time to live. A refusal it learns after the model has moved on
keeps the stub in `Refused`, with the reason, so the roster can show it. The
pass also settles children that finish while nobody waits on them: it sends each
orchestrator one `Join` with a window of 0 per parent strand for the `Spawned`
stubs whose deadline has not passed, and records each `Ready` as `Settled`
without keeping the report, which a later `agent_wait` reads again from the box.
The pass is owed while any child is running, so the drainer ticks, and clear when
none is, so it goes idle. The stub is not a peer-mail outbox row, and
`peers.resend` and `OutboxDue` are untouched.

**Capacity.** `is_live` reads a strand's own state, which a remote child lacks,
so `check_capacity` counts live stubs beside the live cells, against the same
`fan_out` and `session_strands`: a `Requested` stub, and a `Spawned` one until its
child's deadline passes. The deadline needs no message, so a child on a machine
that is down frees its slot on time. A stub whose orchestrator has not answered
still counts, which errs toward refusing a spawn.

**Waiting.** `agent_wait` takes local and remote handles in one call. A handle is
remote because a stub of this session holds it; its `@orchestrator` suffix is
parsed and dropped, so a suffix a model typed is not evidence of anything. The
Agency runs the local wait and one `Join` per orchestrator as tasks beside each
other, so the whole is as long as the longest, with each join's window cut to 25
seconds. A join that is `Unreachable` is not queued: its handles come back
`Pending` naming the orchestrator that did not answer, and the model may wait
again. A `Ready` entry moves the stub to `Settled` with the child's usage, which
is recorded and not yet metered or counted against a goal.

**The roster** lists remote children from the stubs with the orchestrator and how
the record stands: unknown (no answer yet), running, past its deadline (nothing
has read how it ended), settled with its outcome, or refused with the reason. A message to a remote child is refused with a sentence
saying it reports through its answer and notes, and a remote child's message to
its parent reads that its parent runs on another orchestrator. `context:
my_conversation` is refused with `on`.

**The end of a run.** A remote child is always detached, and the laptop sends
nothing when a run ends. The run-end hook spawns `reap_run` off the strand driver
as before and it aborts the local children only. The remote child runs on to its
deadline on the box, which the retention sweep follows, and a later `agent_wait`
reads its result. `agent_spawn` says so in the `on` description. Phase 1 has no
remote token metering, so a child nobody waits on spends what it spends until its
deadline, at most `max_within_s`. The port's `RunEnded` and the box's ended fence
remain for phase 2, where `Release` reuses them.

## Failures

This table lists each failure, what the system does, and what an operator or
the model sees. "Unknown" below always means the model reads
`unknown_outcome_text`, which says the call may have run.

| Failure | What the system does | What is seen |
|---|---|---|
| Orchestrator VM crashes during a call | The host receives a `noconnection` `DOWN`, so the run continues and its outcome waits in the ledger. On reopen the orchestrator attaches at the same incarnation, which rebinds the scope with a new token, and recovery reads each orphaned call's row. | After the dead daemon's writer lease lapses (up to 60 s), the model gets the stored outcome. The tool ran once. |
| Strand driver or runtime restarts inside one open | Effect processes die with a reason other than `noconnection`, so their runs are cancelled once no waiter is left and the rows become `unknown`. Recovery fences `ReplayNever` keys; the token stays the same. | Cancelled calls stage as unknown. A finished call stages its outcome. |
| Executor VM restarts, or the host dies | The daemon halts on the host's death. On boot every `admitted` row becomes `unknown`. Re-sent `Run`s for known keys are answered from the ledger. | In-flight calls stage as unknown. New calls fail with "no workspace for this session ... attach first" until the session is closed and reopened, and the reopen needs `loomd executor release` (refusal: `could not prove 0 children of the closed scope are gone`). |
| Partition during a call | The surface reconnects with a doubling pause and re-sends the same `Run`. The run continues on the executor. | The session waits. The call completes once, and its outcome arrives after the link returns. |
| Abort while partitioned | The kill reaches the host only as `noconnection`, so the run continues. | Cancellation is unconfirmed. The run finishes once, and its outcome stays in the ledger until it is acknowledged. |
| Partition during attach | `surface.attach` re-sends the same attach and token for up to 30 s. A repeat finds the scope rebound or still building. | Within the window, the open succeeds. After it, `operations.get` reports `start_failed` with `executor_unavailable:`; the scope record names the executor, so the next open retries the same machine and converges. |
| Executor unreachable at open | The connection fails before any state is touched. A first open into a pool moves to the next candidate. | `executor_unavailable:` with OTP's reason. A first-ever open leaves the registration `reserved`, and only a `sessions.create` retry under the original key finishes it. |
| Executor full | The attach is refused inside the ledger transaction before a plane is built. | A first pooled open moves on. Otherwise the open fails with an `executor_unavailable:` reason saying the executor already holds its limit of scopes that are not cleanly closed. |
| Ledger budget full | Admission refuses the call. | The model reads `the executor's ledger is full at N bytes of unacknowledged results`. |
| Owner port dies during a callback | The executor's call fails in-band. | The approval stands as refused, a fact operation fails with `owner unavailable`, a capability is denied; the tool reaches a terminal outcome. |
| Peer orchestrator unreachable on lookup | The directory's two-second fan-out reports silence. | `owner_unreachable` naming the orchestrators that did not answer, unless another one answered `Owned`. |
| Recipient's owner unreachable for peer mail | The outbox row stays pending and the drainer retries every 5 s for up to an hour. | `peer_send` returns `queued`; after an hour the row records `owner unreachable`. |
| Recipient saved on its owner (here or on another orchestrator) | The outbox row stays pending; the drainer retries after 5 s, then 10 s, doubling to 5 min, for up to an hour. Nothing opens the session. | `peer_send` returns `queued` with a note that the session is saved; the message is delivered once, after the owner opens it; after an hour the row records `recipient not opened in time`. |
| Source crashes during a move step | The `moving` row survives. The restarted daemon resumes the mover, which asks the receiver how far the move got and takes the remaining steps. | `daemon.move_finished` after the restart. The shipped test halts the source after each of the six steps. |
| Receiver crashes or is unreachable during a move | The mover stalls and retries; it never abandons on silence. A receiver restarted mid-send holds only a `.part` file, never taken for a copy. | `daemon.move_stalled` with the reason, repeated until it clears. The session stays `moving` on the source, which is one owner. |
| Executor does not answer the move's close | The mover stalls. An unproven cleanup aborts the move. | `daemon.move_stalled`, or `daemon.move_aborted` naming the cleanup. |
| No `epmd`, or its port held by something that does not answer | `distribution.start` fails before the catalogue opens. | The daemon exits: `no epmd answers on port N and Loom could not start one`. |
| VM booted without the TLS flags, or a stale options file | `distribution.start` refuses with a `BootRefusal`. | The daemon exits with a plain line naming the check. |
| Pin, name or CA mismatch | The TLS handshake is refused in whichever direction fails. | `executor_unavailable:` with a deliberately plain reason. |
| Spawn for a run that already ended | The delegate session's `delegate/ended/{operation}` fence refuses it with `ParentRunEnded`, and no child is made. | The spawn refusal; a resend of a spawn whose child already exists is still answered with that child. |
| Spawner past `max_sessions` | The registry refuses to create a session for a new parent. | `CapReached(MaxSessions)`; parents that have a session still reach it. |
| Orchestrator silent during `agent_spawn` | The spawn is resent for 30 s. The stub stays `Requested` and the drainer resends from it. The receiver adopts the child the call site made. | `RemoteSilent`: the child may exist. Within the window an ordinary spawn. The roster shows the stub as unknown until the drainer settles it. |
| Orchestrator refuses a spawn | Definitive. The stub is kept as `Refused`, wherever the refusal is heard, and does not count against the caps. | `RemoteRefused` with the box's reason, naming the rule or cap; the roster shows the stub as refused. |
| Laptop restarts with a stub on disk | The drainer's first pass at session open resends each `Requested` stub, and a replayed `agent_spawn` finds its stub. | The same handle, once. |
| Box unreachable while a child runs unwaited | The drainer's zero-window `Join` is `Unreachable`, the pass stays owed and asks again every 5 s. The child's deadline frees its slot regardless. | Nothing; the roster shows the child as running, then past its deadline. |
| Join to an unreachable orchestrator | Not queued. | Its handles are `Pending`, naming the orchestrator. |
| Mismatched builds | `Attach` has one shape in every version, so a different `protocol.version` is refused at attach by value, in either direction, and the host stays up. Any other message the receiver cannot match crashes the host, which is why sessions are stopped before either machine is upgraded. | At attach: `the executor speaks protocol version N and this orchestrator does not`, and the open fails. Later: `daemon.executor_lost` on the executor. |

**Quorum does not apply.** No state in this design is replicated or decided by a
vote. Each fact has exactly one writer: a session's conversation is in its
owner's store, a call's state is in its executor's ledger, and ownership is in
the two catalogue rows the move orders. Losing a node never changes who owns
anything; it makes that node's facts unavailable until it returns. Automatic
failover would mean one node taking over facts another node wrote, which needs a
replicated store, and that is deferred.

## What the formal models check

`make model-check` runs two models of this design, each with mutants that must
be caught. It needs Java with the TLA+ jar and the P tool, so it is not part of
`make check` or CI.

The TLA+ model `protocol/models/session-move` (`Move.tla`) checks one move with
a crash possible between any two writes, over two orchestrators and one
executor. Its invariants are that two orchestrators never serve the session at
once, that `moved` is never left, that the receiver is active only over a
complete copy and the source retires only over an active receiver, and that a
serving node holds the executor token. It checks liveness too: a `moving` move
settles under fairness. Four mutants (no durable intent, abort after the send, a
refusal after the receiver's commit, retiring without observing the receiver)
each violate their invariant. The model does not cover the copy's contents, the
directory, a second move, or an unproven cleanup.

The P model `protocol/models/remote-execution` checks the surface against the
host and ledger over a wire that reorders across sender pairs and loses
everything in flight on a break. Its specs are that a key starts at most once,
that a fenced key never starts, that an unknown key is final, that a staged
outcome is the stored one, that a stale token never starts a body, that only a
killed waiter cancels, that every durable call is eventually staged, and that a
refusal means the executor never started the call. Seven mutants, from ignoring
the token to deleting the row on acknowledgement, are each caught. The model
found the two defects fixed under protocol version 2 and ledger version 3: a
restarted executor refusing a call it may have run, and a late `Run` starting an
acknowledged key. It leaves out scope states other than `open`, reopening,
capacity, the byte budget, the plane build, owner callbacks and time.

The same project models background executions on the same host and ledger: the
orchestrator's records and their workers, the stop, the reconciler, and
recovery after an orchestrator restart. Its specs are that no program starts
after the host processed its stop, that a finished record holds the value the
ledger stored, that only a closing decision stops a program, that a program
which stored its value while its record was live is not recorded lost, that the
reconciler acknowledges a row only once its record is finished or lost, and
that every record and program settles. Five more mutants, from a stop that does
not bar a missing key to a reconciler that skips executions, are each caught.
The input journal and progress travel over the owner port and are tested in
Gleam instead.

Neither model covers trust and transport, pools, the directory or peer mail.
The directory holds no state of its own, so it has no model.

## Limits and deferred work

- **No failover, and no moving a session between executors.** A session keeps
  the executor its first open chose. If that executor is down the session waits.
  A replicated store behind `session_directory` (Khepri) is planned for a
  follow-up PR and is the prerequisite for failover.
- **Remote sessions refuse** extension tools and operator-added directories.
- **Background code mode on a remote session** answers the model's `check`,
  `send` and `cancel` through the executor, because `code_mode` is placed there
  by name, so those modes wait for a cut link like any other tool call. A
  running execution does not survive an orchestrator restart: only one that had
  already finished keeps its result. Each execution reserves 1 MiB of the
  executor's ledger budget, which is per executor and shared by its scopes.
- **MCP on a remote session**: the plan is fixed for an incarnation, a server is
  never restarted or jailed on either machine, and an orchestrator-placed server
  is started even when the executor offers no `code_mode`.
- **After an executor restart**, an open session fails new calls until it is
  closed and reopened, and the reopen needs the operator's release. Runs left
  by an orchestrator that died hold their budget until the session is reopened
  and closed; there is no listing of them on the executor.
- **Imported sessions whose origin is gone** (decommissioned, renamed or
  reinstalled) can never move on, and have no override yet.
- **Mixed builds across orchestrators.** The orchestrator port's message type is
  closed and matched without a catch-all, as the executor host's is, so a newer
  peer that sends a constructor an older port lacks (`Describe`, in this
  release) halts the older port until that daemon restarts. Upgrade both
  orchestrators together, or the one that owns the sessions first.
- **Peer mail across orchestrators** has no push when a session opens: the
  sender finds out on its next attempt, at most five minutes after the owner
  opens it. A message queued while the drainer is backed off for older messages
  waits for the same tick. Default links (`[peers] default_links`) join sessions
  of one daemon only, so they do not reach a session on another orchestrator.
- **Remote children** (phase 1) report their usage on the parent's stub and are
  not metered: the usage is not yet counted against a goal's token budget or shown
  in a status bar. A message to a remote child is refused, and a remote child's
  message upward reads that its parent is elsewhere. A parent session that holds a
  live stub is not yet refused by `sessions.move`, and a parent session's deletion
  leaves its children until their deadlines on the box. The box enforces those
  deadlines with a periodic tick on each delegate session's Agency (15 s), and a
  boot sweep deletes delegate sessions idle past the spawner's `retain_s`.
- **Moves** do not resume inside a file, carry running processes, the memory
  domain, memberships or claims. `sessions.list` records carry the `moving` and
  `moved` members; the terminal, the web home and the Admin drawer draw a moving session with its
  destination and leave a moved one out, and the receiver's row is listed only
  on the receiver until the elsewhere group lands.
- **Membership changes are eventual, and some are not checked.** `enroll`,
  `revoke` and `renew` change a running deployment without reprovisioning, and
  a member that is off learns an entry when it next connects to one that has it.
  A revoke does not check that the member owns no sessions, a revoked
  directory voter still counts toward Ra's majority until the leader's removal
  commits, and rotating the authority or the cookie means provisioning again. A node that was down across its own revoke
  and re-enrolment, and receives the revoke at the end of one pull batch and the
  re-enrolment in the next, self-revokes until `import` or a new bundle. The
  design is in [the membership ledger note](../design-notes/membership-ledger.md)
  and [protocol-change/086](../../protocol-change/086-membership-ledger.md).
- **The ledger is one SQLite file per executor.** Corruption affects every
  scope's history on that machine; full sync and a digest over each outcome are
  the mitigation. Writes serialize through one actor, two short transactions per
  call.

## Where the code lives

| Module | Role |
|---|---|
| `client/distribution`, `client/internal/ffi_distribution`, `client_distribution_ffi.erl` | Membership: boot checks, TLS verify, `epmd`, hidden connect |
| `client/ledger_boot`, `client/ledger_trust`, `client/ledger_service` | Ledger mode: the order at boot, the pin table, the allow list, disconnects, dialing |
| `client/distribution_plan`, `_provision`, `_bundle`, `_install`; `daemon/distribution_cli` | `loom distribution` |
| `client/authority_key`, `client/membership_provision` | The kept authority key and cookie, and the first ledger of a `provision` run |
| `daemon/ledger_cli`, `client/ledger_operator`, `client/ledger_sync` | `enroll`, `revoke`, `renew`, `log`, `import`: the entry from the fold, the copy kept in step with a daemon, the confirmations |
| `client/ledger_control`, `client/ledger_reference` | The `ledger.*` control commands, both halves; the ledger read for the start and for the tables that name a peer |
| `client/executors`, `client/workspaces`, `client/pools`, `client/orchestrators` | The `[executors]`, `[workspaces]`, `[pools]` and `[orchestrators]` tables |
| `client/tool_placement` | Which side runs each tool |
| `client/remote/protocol`, `client/remote/address`, `client/remote/codec` | The closed node vocabulary and its transport |
| `client/remote/host`, `client/executor_plane`; `daemon/main.start_executor` | The executor's host and its real plane factory |
| `client/remote/surface`, `client/remote/workspace`, `client/remote/scope` | The orchestrator's attach, run, recover and scope record |
| `client/remote/owner_port`, `client/remote/owner_link`, `client/owner_services` | Owner callbacks and the acknowledgement reconciler |
| `storage/exec_ledger`; `daemon/executor_cli` | The execution ledger and the operator's release |
| `client/session_directory`, `client/remote/orchestrator_port` | Two orchestrators: lookup and the answering port |
| `client/remote/remote_peer`, `client/peers`, `client/peer_outbox`, `client/peer_outbox_drain` | Peer mail across orchestrators |
| `client/session_move`, `client/session_mover`, `client/session_movers`, `client/session_importer` | Moving a session |
| `client/deployment`; `tui/deployment_view`, `tui.run_deployment` | Reading the deployment: `deployment.status` and `loom deployment` |
| `client/spawners`, `client/remote_spawn`; `daemon/main.spawn_host` | The `[spawners]` table, the subagent messages' vocabulary and the daemon's spawn host |
| `client/delegate_host`, `client/child_usage`; `agency.delegate_spawn`, `delegate_join`, `delegate_run_ended`; `manager.delegate_session`; `storage/catalogue.claim_delegate` | The delegate session of a (spawner, parent session) pair: finding or creating it, the Agency's side of a remote parent, a child's usage, and the catalogue record |
| `client/remote_child`, `client/remote_reach`, `client/remote/remote_spawner`, `client/remote_drain`; `agency.spawn_elsewhere`, `wait_across`; `runtime/lineage` | The parent's side: stubs, the Agency's reach, its sending end, the second drainer's pass, and the lineage cell's `orchestrator` |

`packages/client/CLAUDE.md` has one section per phase, from "Trusted
distribution membership" to "Moving a session between orchestrators", with the
invariants and tests of each. `packages/storage/CLAUDE.md` covers the ledger and
the catalogue's custody rows. Related decisions:
[ADR-017](../adr/017-executor-service-seam.md) for the executor service the
workspace plane runs on, [ADR-002](../adr/002-sqlite-binding.md) for the SQLite
binding the ledger uses, [ADR-006](../adr/006-macos-seatbelt-boundary.md) for
why a macOS executor enforces less than a Linux one, and
[ADR-015](../adr/015-language-servers-as-jailed-leases.md) for the language
servers that run beside the checkout. [The executor service](executor.md) and
[sessions in one daemon](sessions.md) describe the single-machine parts this
runtime splits.
