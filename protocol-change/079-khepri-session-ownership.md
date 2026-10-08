# protocol-change/079: Khepri holds session ownership

**Status**: ACCEPTED 2026-10-08 on the owner's rulings, after an independent
review of the first draft; implemented. The spellings below are the
implemented ones.
**Affects**, for a deployment with a `[directory]` table only:
`client/session_directory.Directory` and its `Miss` type, a new write interface
beside it, the `loom_orchestrator` port (`Owns` is no longer asked, and the
`Activate` verdict gains `move_ended`), the control refusals of
`sessions.create` and `sessions.delete` (one new code, `no_quorum`), the
`sessions.move` command (one optional member, `abandon`, and the imported-session
hold removed), one new control command, `directory.status`, `loom.toml` (a
`[directory]` table), the distribution boot and connect path of member daemons,
one `loomd` subcommand, and the catalogue (version 13 adds one table). A
deployment without `[directory]` is unchanged in every respect.
**Raised by**: issue #697 and the owner's rulings of 2026-10-08: Khepri holds
move authority as well as the directory, with orchestrators and executors as
members; members use visible distribution; Khepri decides and the catalogue rows
stay as local memory.
**Design**: [docs/architecture/directory.md](../docs/architecture/directory.md),
[ADR-019](../docs/adr/019-khepri-for-session-ownership.md).
**Amends**: [protocol-change/078](078-distributed-runtime.md), the addenda on two
orchestrators, on session movement (catalogue storage) and on moving a session
between orchestrators, for member daemons.

## Problem

Two catalogues on two machines decide who owns a session today. A daemon asked
about a session it does not hold asks every configured orchestrator, under a
two-second deadline, and a move's authority is the source's `moving` and
`moved` row and the receiver's `imported` row, ordered by a write-ahead intent.
That design is correct for one move between two live machines, and the TLA+
model `protocol/models/session-move` checks it. It has four costs.

First, it cannot express failover. A takeover needs a record of ownership that
a third party can read and change when the owner is gone, and the two rows live
only on the two machines the move involved.

Second, a move can never be abandoned on silence. An unreachable receiver may
have taken the session and lost the reply, so the source keeps its `moving` row
until the receiver answers, for as long as that takes.

Third, an imported session cannot move onward or be deleted until its origin
has retired the move (`inbound_settled`), and an imported session whose origin
is decommissioned can never move again.

Fourth, every lookup of a session this daemon does not hold costs a connection
attempt to each orchestrator that is down, up to two seconds.

## What was considered

**Keep the two rows and add a third store only for failover.** Two authorities
for one fact must then be reconciled, and every rule of the phase 5 move stays.

**A designated authority daemon with an SQLite table.** One machine's loss stops
every creation and every move.

**Replace the rows with a register in Khepri.** The first draft of this proposal
did that. The review showed that deleting the rows reopens two races phase 5 had
closed: a client open could slip between stopping the slot and writing the
intent, and a receiver with no memory of what it imported could delete a session
it owned after a failed write.

**A register in Khepri that decides, with the rows kept as local memory.** Each
remote session has one record in a Khepri store replicated across the
orchestrators and the executors, and every change of ownership is one
compare-and-set on it. The catalogue rows stay, written in the registry turns
that already order them against admission, and no longer decide anything on
their own. This is the decision.

## Decision

### The record

The store is named `loom_directory`. Each remote session (created with an
executor or a pool) on a member daemon has one tree node at
`[loom, sessions, <<SessionId>>]`:

```erlang
{loom_owner, 1, Owner, serving}
{loom_owner, 1, Owner, {moving, Op, To}}
%% Owner, To :: binary()   distribution node names
%% Op        :: binary()   the move's identity, as in catalogue_session_moves
```

```gleam
pub type Record {
  Record(owner: String, state: OwnerState)
}

pub type OwnerState {
  Serving
  Moving(op: String, to: String)
}
```

The Gleam side reads the payload through one total decoder; a payload that does
not decode is an error, never an absent record. Owners are named by node,
because `[orchestrators.<name>]` keys are each daemon's own names for its peers.
A daemon translates a node to its own row when it answers a client and reports
the bare node name when no row names it.

`[loom, migrated, <<Node>>]` holds `{loom_migrated, 1}` once that orchestrator
has seeded the store from its catalogue.

Local sessions have no record.

### Writes

| Operation | Writer | Command | Expected | Written |
|---|---|---|---|---|
| Create a remote session | the creating daemon | create | absent | `{self, serving}` |
| Begin a move | the source | CAS | `{self, serving}` | `{self, {moving, Op, To}}` |
| Activate a move | the receiver | CAS | `{source, {moving, Op, self}}` | `{self, serving}` |
| Abandon a move | the source | CAS | `{self, {moving, Op, To}}` | `{self, serving}` |
| Delete a remote session | its owner | delete with a data condition | `{self, serving}` | absent |
| Mark migration done | each orchestrator | put | | `{loom_migrated, 1}` |

Every expected value is a literal term. Each write runs in a weft task under a
deadline (three seconds, five for an activation) and never inside a registry
turn.

### The rule between the record and the rows

A local transition that grants serving (`imported`; `moving -> resident` on an
abandon) follows a committed write. A local transition that revokes serving
(`moving`; the new `deleting` mark) precedes the write, in the registry turn that
stops the slot, and is reverted when the write fails because the record held
something else. Opening a session makes no store call: admission reads the
custody row in the turn that reserves the slot, as it does today.

### The directory interface

`Directory.lookup` keeps its signature. On a member daemon it reads the local
replica:

| Record | Answer |
|---|---|
| absent | `Error(Unknown)` |
| owner is this daemon's node | `Ok(Here)` |
| owner is another node | `Ok(Elsewhere(orchestrator))`, the configured row for that node or a row carrying only the node name |
| the store is not running or not joined | `Error(Unavailable)` |

`Miss` gains `Unavailable(reason)`; `Unreachable` remains for non-member
daemons, whose lookup is the phase 3 fan-out. `Directory.reach` and
`Directory.activate` are unchanged. `Directory` gains two fields that a
non-member leaves empty: `ownership`, the writes, and `standing`, which on a
member gives `directory.status` its answer. The writes are a record of
functions in `client/directory/ownership`, each bound to this daemon's node,
with a consistent read (`khepri:fence/2` then a local read):

```gleam
pub type Ownership {
  Ownership(
    node: String,
    read: fn(String) -> Result(Option(Record), Unavailable),
    read_consistent: fn(String) -> Result(Option(Record), Unavailable),
    create: fn(String) -> Result(Nil, WriteRefusal),
    begin_move: fn(String, String, String) -> Result(Nil, WriteRefusal),
    activate: fn(String, String, String) -> Result(Nil, WriteRefusal),
    abandon: fn(String, String, String) -> Result(Nil, WriteRefusal),
    release: fn(String) -> Result(Nil, WriteRefusal),
    migrated: fn(String) -> Result(Bool, Unavailable),
    mark_migrated: fn() -> Result(Nil, WriteRefusal),
    seed_moving: fn(String, String, String) -> Result(Nil, WriteRefusal),
  )
}

pub type WriteRefusal {
  NoQuorum(reason: String)
  Mismatch(found: Option(Record))
}
```

`create` and `begin_move` answer a record that already holds what they would
write as committed, so a retry after a lost reply succeeds. The executor role
builds no `Ownership`: a daemon with no `[executors]` and no `[pools]` has none.

### Creation

For a remote session, `sessions.create` asks the registry to reserve the
registration without opening it (`manager.reserve`), creates the record, then
calls `manager.create`, which finds the reservation by its request key and opens
it. A record that already names this daemon counts as created. `NoQuorum` is
refused `no_quorum` and the reservation stays; a record naming another daemon is
`conflict`.

### Moving a session

`sessions.move` writes the `moving` row and stops the slot in one registry turn,
as in phase 5, and replies. The mover then:

1. waits for `[loom, migrated, <self>]`;
2. writes the intent CAS; a record already `{self, {moving, Op, To}}` counts as
   written; an absent record reverts the row (`abort_move`) and abandons; a
   record naming another owner means the receiver's activation committed and
   its reply was lost, so the move goes on and the receiver is asked again;
3. closes, cuts and sends as in phase 5;
4. asks the receiver to activate;
5. retires when the receiver answered `Accepted` or `Refused(move_ended)`, or an
   abandon found the record changed, and a consistent read shows another
   owner: `finish_move`, then the file work. A consistent read naming this
   daemon as `serving` reverts the row instead, since its own abandon
   committed.

The receiver's activation: a custody row `imported(Op, From)` answers `Accepted`
at once; a row that holds the session in any other state, `moving` included, is
refused `conflict` before anything is written (the model's
`KhepriMutantImportOverMoving` shows this order is required); otherwise it
verifies the copy as in phase 5, writes the activation CAS,
and only after it commits runs `manager.import_session`. On `Mismatch(found)`,
an owner equal to the receiver runs the import (a catalogue conflict there means
the session has moved on, and is answered `Accepted`); any other owner or no
record is `Refused(move_ended)`, and only the incoming copy is removed. `NoQuorum`
is `Failed`.

The source abandons by the abandon CAS followed by `abort_move`. A `Mismatch`
whose owner is another node sends the mover to retirement instead. The source
abandons on the phase 5 causes, after thirty minutes of stalls during which the
store had a quorum and the receiver's migration marker existed, and on the
owner's request: `sessions.move` with `abandon: true` (owner-only, `epoch`
required) asks the movers to abandon now and replies `{session_id, op, state:
"abandoning"}`. A session with no `moving` row is refused `conflict`, and a
daemon that is not a member refuses `not_movable`, because without the record a
move cannot be abandoned on silence. The abandon itself runs in the mover, so
its outcome is read from `sessions.get` afterwards.

A move stalled for want of a quorum is reported as unquorate and does not count
toward the thirty minutes.

`inbound_settled` and its `not_movable` and `busy` refusals are not applied on a
member daemon.

### Deleting a remote session

`manager.begin_delete` checks the owner, the epoch and that no slot is open, and
writes a row in `catalogue_session_deletions` in the same turn; admission
refuses a session with that row (`SessionDeleting`, code `busy`). The daemon
then deletes the record with the condition `{self, serving}`:

| Outcome | Then |
|---|---|
| committed | `manager.delete_session`, which removes the registration, the mark and the file |
| `Mismatch(None)` | the same: this daemon's own delete committed before |
| `Mismatch(Some(_))` | the mark is removed and the delete refused (`not_owner` or `moving`) |
| `NoQuorum` | the mark stays, the delete is refused `no_quorum` |

The movers' tick retries the record delete for every marked session.

### Orchestrator port

`Owns` is not asked by a member daemon; the port still answers it, for a
non-member peer. `Activate`'s `Refused` gains `MoveEnded`. Nothing else changes.

### Control protocol

- **`no_quorum`**: a refusal of `sessions.create` and `sessions.delete` for
  remote sessions, and of `sessions.get` and `sessions.open` on a miss when the
  member's store is not running. Its message carries the store's reason.
- **`not_owner`** keeps its body, from the record.
- **`owner_unreachable`** is not sent by a member daemon.
- **`sessions.move`** gains `abandon` (boolean, optional).
- **`directory.status`** (owner-only, no arguments) answers:

  ```json
  {"members": ["alpha@10.0.0.1", "bravo@10.0.0.4", "exec@10.0.0.2"],
   "joined": true,
   "ra_members": [{"node": "alpha@10.0.0.1", "voter": true}, ...],
   "applied_index": 12,
   "leader": "bravo@10.0.0.4"}
  ```

  `members` is the configured list, `ra_members` the membership in force with
  each member's vote, and `leader` is absent when none is known. When the store
  cannot be asked, `ra_members` is empty and an `unavailable` member carries the
  reason. A non-member daemon refuses it `not_found`.

### Configuration

```toml
[directory]
members = ["alpha@10.0.0.1", "bravo@10.0.0.4", "exec@10.0.0.2"]
```

`members` requires `[distribution]`, contains the daemon's own node, names only
`[[distribution.peers]]` nodes otherwise, has distinct entries, and has three to
seven of them; an even count is accepted with a warning. On a member daemon,
every `[orchestrators.<name>]` node must be a member. The store lives at
`<state root>/directory`. `docs/configuration.md` documents the key.

### Distribution

A member daemon starts distribution with `hidden => false` and requires
`connect_all` to be `false` (`application:get_env(kernel, connect_all)`), which
the launcher passes as `-kernel connect_all false` with the TLS flags.
`distribution.start` refuses a member VM without it (`BootRefusal`
`ConnectAllEnabled`). `distribution.connect` uses `net_kernel:connect_node/1`
when both this node and the peer are members and `hidden_connect_node/1`
otherwise. A link keeper on each member connects every two seconds to the
members missing from `nodes()`. A non-member is started and connects exactly as
before.

### Forming the cluster

`loomd directory bootstrap` (daemon stopped) creates a one-member store and the
`joined` marker, and refuses when the data directory is not empty or when a
configured member answers that it holds a joined store. A booting member whose
store is not joined joins through the first member that answers, as a
`promotable` non-voter after removing its own stale identity, and marks itself
joined once Ra has promoted it. A joined member restarts its server.

### Catalogue (version 13)

The migration from version 12 adds
`catalogue_session_deletions(session_id PRIMARY KEY REFERENCES
catalogue_sessions(session_id))`. `catalogue_session_moves` is unchanged and
keeps its rows on both kinds of daemon.

### Migration

Once a member orchestrator's store is joined and has a quorum, and its marker is
absent, it seeds one record per remote registration:

| Custody row | Write |
|---|---|
| resident | create `{self, serving}` |
| `imported(Op, From)` | create `{self, serving}`; if the record is `{From's node, {moving, Op, self}}`, the activation CAS instead |
| `moving(Op, To)` | create `{self, {moving, Op, To's node}}`; if the record names `To`'s node as owner, nothing |
| `moved(Op, To)` | nothing |

A record that already names this daemon is a repeat. Any other existing record
is a conflict, logged as `directory.migration_conflict` and left standing: a
delete of the session is refused, and a move of it finds the record naming
another owner and retires it. Then the marker is written. The movers' periodic
pass runs the seeding, so a store without a quorum delays it and nothing else.

## What it costs

- A quorum for creating and deleting remote sessions and for each step of a move
  that changes the record.
- Visible distribution between members, and executors pinning one another when
  more than one is a member.
- Six Hex packages, about 2 MB of BEAM files, and a Ra log on every member.
- Two behaviours to maintain, with and without `[directory]`, until the phase 5
  path is retired.
- A second TLA+ model, `protocol/models/session-move/KhepriMove.tla`, beside
  `Move.tla`, which stays the model of a deployment without `[directory]`. Both
  are gated by `make model-check`.

Not built: automatic failover, a check of the record at open, ownership leases,
moving a session between executors, membership removal commands, and a merged
session list.
