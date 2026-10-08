# The session directory and session ownership

A deployment with two orchestrators has to answer one question correctly at
all times: which orchestrator owns this session? The owner is the only daemon
that may run the session's runtime, write its conversation store, and attach to
its executor scope. If two daemons ever both believe they own a session, both
can run it against the same checkout, and the conversation forks.

This page describes how Loom answers that question once Khepri holds the
answer. It is written for an engineer who has not worked on the distributed
runtime. Read [the distributed runtime design note](../design-notes/distributed-runtime.md)
first for the two roles (an orchestrator holds a session's conversation, an
executor holds its checkout) and for how a tool call crosses between them.
[ADR-019](../adr/019-khepri-for-session-ownership.md) records why Khepri was
chosen and what the spike measured, and
[protocol-change/079](../../protocol-change/079-khepri-session-ownership.md)
specifies the interfaces. [The plan](../design-notes/khepri-ownership.md)
orders the implementation and the formal model.

**Status: proposed.** Nothing on this page is built yet. Where it describes the
code as it stands, it says so.

## Where the answer lives today

Before this change, each orchestrator's catalogue (its SQLite registry of
sessions) is the source of truth for the sessions it holds. A daemon asked about
a session it does not hold sends the question `Owns` to every orchestrator in
its `[orchestrators.<name>]` table and waits up to two seconds for the answers
(`client/session_directory`, the `peers` backing). A move from one orchestrator
to another is decided by two catalogue rows: the source writes `moving` and then
`moved`, and the receiver writes `imported`. A write-ahead intent orders them,
and the executor's incarnation fence stops a stale source from running tool
calls.

That design stops working once failover is wanted, because a takeover needs a
record that a third daemon can read and change after the owner has gone, and the
two rows exist only on the two machines a move involved.

## What the store holds

Khepri is a replicated tree store built on Ra, an implementation of the Raft
consensus protocol. Every member of the cluster holds a full copy of the tree.
A write goes to the cluster's leader, which commits it once a majority of
members have it on disk, and every member then applies it to its copy.

The store is named `loom_directory`, and it holds one record per session at the
path `[loom, sessions, <session id>]`:

```erlang
{loom_owner, 1, Owner, Placement, State}
```

- `Owner` is the owning orchestrator's distribution node name, such as
  `alpha@10.0.0.1`. It is not an `[orchestrators.<name>]` key, because each
  daemon picks its own names for its peers: alpha may call its peer `bravo`
  while a third daemon calls the same node `laptop`. A daemon translates the node
  name into its own row only when it answers a client.
- `Placement` is `remote` when the session has an executor or a pool, and
  `local` when its checkout is a directory on the orchestrator. A local session
  can never move, so its owner never changes.
- `State` is `{serving, LastOp}` or `{moving, Op, To}`. `LastOp` is the
  identity of the move that made this daemon the owner, or empty. `{moving, Op,
  To}` means the owner has begun handing the session to the node `To` under the
  move `Op`, and stopped serving it.

The store holds nothing else about a session: no conversation, no workspace
path, no credential, no executor name. A second path, `[loom, migrated,
<node>]`, records which orchestrators have copied their catalogue rows into the
store (see "Migrating an existing deployment").

Every session created on a member daemon gets a record, local sessions
included. That makes a lookup one read for every session, so the two-second
question to every orchestrator goes away.

## Members, and who connects to whom

The cluster's voting members are listed in `[directory] members` on every
member, in the same order:

```toml
[directory]
members = ["alpha@10.0.0.1", "bravo@10.0.0.4", "exec@10.0.0.2"]
```

The members are the orchestrators and the executors. Raft needs a majority of
members to commit a write, so two orchestrators alone would stop committing
when either is down. With an executor as a third member, any one of the three
can be down.

```text
             alpha (orchestrator)  <------->  bravo (orchestrator)
                       ^                          ^
                       |                          |
                       +-------> exec <-----------+
                              (executor)

   every arrow: pinned TLS distribution, visible, connected by the link
   keeper on both ends; any member may be the Raft leader
```

Raft's leader sends every write to every follower, and any member can become
the leader. So every member must be able to connect to every other member, and
each must pin the other's leaf certificate in `[[distribution.peers]]`. Today an
executor pins only orchestrators. A deployment with two executors as members has
each executor pin the other as well.

**Members use visible distribution connections.** `client/distribution` starts
every node hidden today. A hidden connection does not appear in `nodes()`, and
Ra relies on `nodes()` in three places: the leader sends a snapshot only to a
node listed there, its node monitor reports only visible nodes, and its failure
detector sends heartbeats only to visible nodes. The spike in ADR-019 showed the
consequence. Over hidden connections, a member that fell behind a snapshot never
caught up, and a member restarted after a quorum loss never reconnected. So a
daemon with `[directory]` starts distribution visible. Two kernel settings keep
visible connections from spreading:

- `-kernel connect_all false` stops `global` from connecting this node to nodes
  that a peer happens to be connected to. Connections are still made only on
  purpose.
- `-kernel prevent_overlapping_partitions false` stops `global` from
  disconnecting one member from another because a third member lost its
  connection to one of them.

`dist_auto_connect` stays `never`, so sending a message to an unconnected node
still drops it instead of dialing. The `net_kernel:allow/1` list still admits
only pinned nodes. A daemon without `[directory]` (a single orchestrator with
its executors) is started hidden, exactly as before.

**Who connects, and when.** Three things open connections between members:

1. **The link keeper.** Each member runs one process that, every two seconds,
   connects to each configured member missing from `nodes()`. It is the reason a
   partition heals without an operator: once the network returns, both ends
   reconnect within two seconds.
2. **Ra itself.** When a Ra server starts, it connects to the members it does
   not see. The spike measured a restarted member reconnecting this way and
   committing a write 11 ms later.
3. **The existing callers.** An orchestrator still connects to its executor when
   a session attaches, and to a peer orchestrator for peer mail and for the
   pieces of a move.

Visible connections have side effects worth knowing. `nodes()` now lists the
other members. `pg` scopes of the same name on two members exchange their
membership lists; Loom's event bus publishes only to local members, so delivery
is unchanged. `global`'s locks span the members, which Khepri uses while a
member joins.

## Forming the cluster

A cluster is created once. An operator runs `loomd directory bootstrap` on one
member, with its daemon stopped. The command creates a store with that member
as its only member and marks the store as joined.

Every other member joins on its own. When a member daemon boots and finds no
joined store in its data directory, it calls `khepri_cluster:join/3` against the
first configured member that answers, and marks its store joined once the join
returns `ok`. A join resets the joining member's store, which is safe because it
had nothing. A member whose store is already joined starts it, and Ra resumes the
membership recorded in its log.

The same rule covers a member that lost its disk. It finds no joined store, joins
again, and Ra brings its copy up to date from the leader's log or snapshot.

Bootstrap is a command, not a boot-time rule, because a rule such as "the first
configured member creates the cluster when its data directory is empty" would
make a first member that lost its disk create a second, empty cluster beside the
real one.

`loomd directory status` prints the configured members, Ra's members, the
current leader, the member's applied index and whether its store is joined.

## Reading an owner

There are two kinds of read, and they give different guarantees.

**A lookup reads the local copy.** `Directory.lookup(session)` reads the
member's own replica with Khepri's `favor => low_latency`, which takes about
2 µs and never waits for other members. The answer is `Here` when the record
names this daemon, `Elsewhere` with the owner's orchestrator when it names
another node, `Unknown` when there is no record, and `Unavailable` when the
store is not running. A lookup serves the misdirected request: a client asks
bravo for a session alpha owns, bravo's `sessions.get` misses in its catalogue,
the lookup answers `Elsewhere(alpha)`, and bravo refuses `not_owner` naming
alpha and, if bravo's row for alpha configures one, alpha's address. A lookup
also serves peer mail, which needs to know which orchestrator to deliver to.

A local copy can lag the leader, so a lookup can name an owner that has just
handed the session on. That is acceptable for a redirect: the client that
follows it to the old owner is refused there with the new owner's name.

**Opening a remote session claims it.** Before a session on an executor
starts, its owner runs a compare-and-set on the record that expects the record
it just read (owner itself, `serving`) and writes the same value back. The write
changes nothing. What it proves is that the record still named this daemon at a
point in Ra's log, so no move began in between. A local read cannot prove that,
because a member's replica can lag, and it lags most after the member restarts:
a daemon that began a move, crashed, and restarted before its replica caught up
would read `serving` and open a session it had already handed over. When the
claim fails because the read was stale, the daemon waits for its replica to
catch up (`khepri:fence/2`), reads again and retries once.

A local session's record never changes owner, so opening a local session reads
the local copy and needs no claim.

## Writing an owner

Every change of ownership is one Khepri command against one record, and Ra
applies commands to a record in one order. When two daemons race to change the
same record, the second finds the record different from what it expected, and
its write fails. That one property replaces the write-ahead intent, the
"abandon only on an answer" rule and the "refuse nothing after the commit" rule
of the phase 5 move.

| Operation | Who | Expects | Writes |
|---|---|---|---|
| create | the daemon creating the session | no record | owner self, `serving` |
| open a remote session | the owner | owner self, `serving` | the same value |
| begin a move | the source | owner self, `serving`, `remote` | owner self, `moving(op, to)` |
| activate | the receiver | owner the sender, `moving(op, self)` | owner self, `serving(op)` |
| abandon | the source | owner self, `moving(op, to)` | owner self, `serving` |
| delete | the owner | owner self, `serving` | no record |

No Khepri call runs inside a registry turn, which is bounded at five seconds.
Each runs in a weft task under its own deadline (three seconds for most writes,
five for an activation). The deadline matters because, without a quorum,
Khepri's consistent reads ignore the timeout they are given (ADR-019).

### Creation

`sessions.create` reserves the registration in the catalogue, creates the
record, then confirms the registration. A reserved registration with no record
is never served, and a creation retried under the same request key repeats the
create and accepts a record that already names this daemon.

### A move

A move keeps the six steps of phase 5: intend and stop, close the executor
scope, cut a copy of the conversation file, send it in pieces, activate, retire.
The file handling is unchanged. What decides ownership is now the record.

1. **Intend.** The source stops the session's slot in a registry turn, then
   writes `moving(op, to)`. If a client's open claims the session first, the
   intent's expected value no longer matches, and `sessions.move` is refused
   `conflict`. If the intent commits first, the open's claim fails and the open
   is refused `moving`.
2. **Close, cut and send** run as before, while the record says `moving`.
3. **Activate.** The receiver checks the copy (the sender's node, the digest,
   the scope cell's clean close, the executor row), registers the session and
   places the file in one registry turn, then writes `serving(op)` with itself as
   owner. That write is the hand-over. The receiver does not serve the session
   before it commits, because its own open would claim the record and find the
   sender still named.
4. **Retire.** The source reads a record naming another owner (from the
   activation's reply, or from its own read after a lost reply or a restart), sets
   its file aside, and releases its lease and its cut copy. It keeps its
   registration, so the session can come back later.

**Abandoning a move.** The source abandons by writing `serving` back with itself
as owner, expecting `moving(op, to)`. Because the receiver's activation expects
the same `moving(op, to)`, exactly one of the two commits. That is why the source
may now give up on a receiver that does not answer: if the receiver had
activated, the abandon fails and the source retires instead; if it had not, its
later activation fails, and it removes the copy and refuses with `move_ended`.

An imported session can move onward at once. The phase 5 hold, which made a
session wait until its origin retired the move that brought it, existed because
the origin's retry read the receiver's catalogue row. The origin now reads the
record.

### Delete, archive and restore

Delete removes the record with a condition that it names this daemon and is
`serving`, then deletes the registration and the file. A registration left
without a record by a crash between the two is finished off on the next delete
or at boot. Archive and restore change only whether a session is listed, so
they write nothing to the store.

## Without a quorum

When a majority of members cannot reach one another, Ra cannot commit, and
Khepri writes return `{error, timeout}` at their deadline. Local reads keep
returning whatever the member last applied.

| Operation | With no quorum | Why |
|---|---|---|
| Lookups (`sessions.get` and `sessions.open` on a miss, peer mail routing) | Work, from the local copy | A redirect may be stale; the owner corrects it |
| A running session, its tool calls, its executor | Work | Nothing on the tool path reads the store |
| Opening a local session | Works | Its owner never changes |
| Opening a remote session | Refused `no_quorum` | The claim must commit |
| Creating a session | Refused `no_quorum` | The record must exist before the session is served |
| Beginning a move | Refused `no_quorum` | The intent must commit |
| A move already under way | Stalls at its next write and retries | Neither activation nor abandon can commit, so neither side changes ownership |
| Deleting a session | Refused `no_quorum` | The record must go first |
| Archive and restore | Work | They do not change ownership |

A `no_quorum` refusal leaves the session as it was, except that a creation's
reservation stays and the same request key completes it later. The executor
ledger and its incarnation fence are unaffected.

## What an executor member can and cannot do

An executor that is a member votes in elections, can become the leader, and
holds a full copy of the tree: session identities, owner node names, placements
and move identities. It holds no conversation content and no credential. Its
loss counts against the quorum exactly as an orchestrator's does, and when it
returns it catches up from the leader.

The executor's daemon code never writes to the store. The executor role builds
no `Ownership` value, so no code path on an executor can create, claim, move or
delete a record. That is a property of the code and not a security boundary: an
executor is a trusted Erlang peer, and any member could submit a Khepri command,
exactly as any pinned peer could already send any message to an orchestrator.
Ra has no voting member that is barred from becoming leader, so an executor can
lead the cluster; a leader only orders and replicates commands, and does not
decide which ones are valid beyond the conditions each command carries.

## Where the data lives

Each member keeps its store under `<state root>/directory`: Ra's write-ahead
log, its log segments and its snapshots. On an executor that directory sits
beside the execution ledger (`exec-ledger.db`); on an orchestrator, beside the
catalogue. Khepri keeps the whole tree in memory as well. A record is a few
hundred bytes, so ten thousand sessions take a few megabytes. Khepri writes a
snapshot and truncates the log after 20 MiB of commands by default.

Deleting the directory loses only that member's copy. The member rejoins on
its next boot and is brought up to date by the others.

## Migrating an existing deployment

An existing two-orchestrator deployment has ownership in its catalogues. The
first time a member orchestrator's store is joined and has a quorum, the daemon
copies its catalogue into the store, one record per registration:

| Catalogue state | Record |
|---|---|
| resident | owner self, `serving` |
| `imported(op, from)` | owner self, `serving(op)`; if the sender already wrote `moving(op, self)`, the activation write instead |
| `moving(op, to)` | owner self, `moving(op, to)`; the mover resumes under the new rules |
| `moved(op, to)` | nothing; the receiver writes its own |

A record that already names this daemon means the copy is being repeated, and it
succeeds. A record that names another daemon is a conflict; the existing record
stands, the daemon logs `directory.migration_conflict`, and that session cannot
open here until an operator resolves it. A restored backup is the case that
produces one. When every registration is copied, the daemon writes `[loom,
migrated, <node>]` and deletes the catalogue's move rows. The table itself is
dropped by a later catalogue version.

## What failover would add

This change makes the record authoritative and every change of owner a
compare-and-set, which is what failover needs to build on. Failover itself
needs four more pieces:

- **Knowing the owner is gone.** A lease in the record that the owner renews, or
  Ra's own view of which members are connected, with a rule for when another
  orchestrator may act.
- **A takeover write**: a compare-and-set from `serving` with the old owner to
  `serving` with the new one, guarded by the lease.
- **Fencing the old owner at the executor.** The executor's attach token and
  incarnation already refuse a stale source after a clean close. A takeover
  happens without a clean close, so attach would carry an ownership epoch from
  the record, and the executor would refuse a lower one.
- **The conversation itself.** The session's SQLite file lives only on the
  owner's disk. A new owner cannot run a session whose conversation it does not
  have, so failover needs the file replicated to, or readable by, the
  orchestrator that takes over. Of the four pieces, this one is the largest.

## Where the code goes

The modules below are planned (see [the plan](../design-notes/khepri-ownership.md)).

| Module | Holds |
|---|---|
| `client/internal/ffi_khepri.gleam` and `client_khepri_ffi.erl` | The only calls into Khepri, with every return normalized to a `Result` |
| `client/directory/record` | `Record`, its total decoder and its encoder |
| `client/directory/store` | Starting, joining and bootstrapping the store; the deadline-bounded reads and writes |
| `client/directory/links` | The link keeper |
| `client/session_directory` | `Directory`, now a local read; `Ownership`, the writes |
| `client/session_mover`, `client/session_importer` | The move, with the record in place of the catalogue rows |
| `client/directory/migrate` | Copying catalogue rows into the store once |
