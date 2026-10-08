# protocol-change/079: Khepri holds session ownership

**Status**: PROPOSED 2026-10-08. Spellings are provisional until the first
implementation slice lands; this document is updated to the implemented
spellings before the change merges.
**Affects**: `client/session_directory.Directory` and its `Miss` type, a new
write interface beside it, the `loom_orchestrator` port's message vocabulary
(`Owns` and `Ownership` removed, `Stage` and `Verdict` narrowed), the control
refusals of `sessions.create`, `sessions.open`, `sessions.move` and
`sessions.delete` (one new code, `no_quorum`, and two holds removed), the
members `moving` and `moved` of `sessions.get` (same shape, new source),
`loom.toml` (a `[directory]` table), the boot arguments and boot checks of
trusted distribution, two `loomd` subcommands, and the meaning of the catalogue
table `catalogue_session_moves`, whose schema does not change.
**Raised by**: issue #697 and the owner's ruling of 2026-10-08 that Khepri holds
move authority as well as the directory, with orchestrators and executors as
members.
**Design**: [docs/architecture/directory.md](../docs/architecture/directory.md),
[ADR-019](../docs/adr/019-khepri-for-session-ownership.md).
**Amends**: [protocol-change/078](078-distributed-runtime.md), the addenda on two
orchestrators, on session movement (catalogue storage) and on moving a session
between orchestrators.

## Problem

Two catalogues on two machines decide who owns a session today. A daemon asked
about a session it does not hold asks every configured orchestrator, under a
two-second deadline, and a move's authority is the source's `moving` and
`moved` row and the receiver's `imported` row, ordered by a write-ahead intent.
That design is correct for one move between two live machines, and the TLA+
model `protocol/models/session-move` checks it. It has four costs that the next
phase cannot carry.

First, it cannot express failover. A takeover needs a record of ownership that
a third party can read and change when the owner is gone, and the two rows live
only on the two machines the move involved.

Second, a move can never be abandoned on silence. An unreachable receiver may
have taken the session and lost the reply, so the source keeps its `moving` row
until the receiver answers, for as long as that takes.

Third, the receiver's row is the record the source's retry depends on, so an
imported session cannot move onward or be deleted until its origin has retired
the move (`inbound_settled`), and an imported session whose origin is
decommissioned can never move again.

Fourth, every lookup of a session this daemon does not hold costs a connection
attempt to each orchestrator that is down, up to two seconds.

## What was considered

**Keep the two rows and add a third store only for failover.** Two authorities
for one fact must then be reconciled, and every rule of the phase 5 move
(write-ahead intent, abandon only on an answer, refuse nothing after the
commit, hold an imported session until its origin retires) stays.

**A designated authority daemon with an SQLite table.** One machine's loss stops
every creation and every move, which is the dependency phase 5 avoided.

**A replicated register in Khepri, as the owner directed.** Each session has
one record in a Khepri store replicated by Ra across the orchestrators and the
executors. Every change of ownership is a compare-and-set on that record, which
Ra serializes, so two writers racing for one session cannot both succeed.
[ADR-019](../docs/adr/019-khepri-for-session-ownership.md) records why Khepri,
the versions, and the measurements, including the one that forces visible
distribution connections between members.

## Decision

### The record

The store is named `loom_directory`. Each session has one tree node at the path
`[loom, sessions, <<SessionId>>]` whose payload is a versioned term:

```erlang
{loom_owner, 1, Owner, Placement, State}
%% Owner     :: binary()                        the owner's distribution node name
%% Placement :: local | remote                  remote: the session has an executor or a pool
%% State     :: {serving, LastOp :: binary()}   LastOp is <<>> before any move
%%            | {moving, Op :: binary(), To :: binary()}   To is a node name
```

The Gleam side reads it through one total decoder into:

```gleam
pub type Record {
  Record(owner: String, placement: Placement, state: OwnerState)
}

pub type Placement {
  Local
  Remote
}

pub type OwnerState {
  Serving(last_op: String)
  Moving(op: String, to: String)
}
```

The owner is named by its node name, because `[orchestrators.<name>]` keys are
chosen by each daemon for its peers and are not shared: two daemons may call the
same orchestrator by different names. A daemon translates a node name to its own
`[orchestrators]` row when it answers a client, and reports the bare node name
when no row names it. A payload that does not decode is an error, never an
absent record.

A second path, `[loom, migrated, <<Node>>]`, records that a node has seeded the
store from its catalogue (see Migration).

### Who writes what

Every write is one Khepri command. "CAS" is `khepri:compare_and_swap/4` with the
exact expected payload; "create" fails when the path exists.

| Operation | Writer | Command | Expected | Written |
|---|---|---|---|---|
| Create a session | the daemon creating it | create | absent | `Serving(<<>>)`, owner self |
| Open a remote session | its owner | CAS to the same value | `Serving(_)`, owner self, `remote` | unchanged |
| Begin a move | the source | CAS | `Serving(_)`, owner self, `remote` | `Moving(op, to)`, owner self |
| Activate a move | the receiver | CAS | `Moving(op, self)`, owner the sender | `Serving(op)`, owner self |
| Abandon a move | the source | CAS | `Moving(op, to)`, owner self | `Serving(<<>>)`, owner self |
| Delete a session | its owner | delete with a data condition | owner self, `Serving(_)` | absent |

The open is a compare-and-set that writes the value it read. It changes nothing,
and that is its purpose: a command that commits only if the record still names
this daemon proves, at that point in Ra's log, that no move began since. A local
read cannot prove it, because a member's replica can lag, most dangerously after
the member restarts. If the CAS fails because the read was stale, the daemon
fences (`khepri:fence/2`), reads again and retries once.

A local session (`Local` placement) can never move, so its owner never changes,
and its open reads the local replica without a quorum. Only creation and delete
of a local session need one.

Archive and restore change visibility, not ownership, and write nothing to the
store.

### The directory interface

`Directory.lookup` keeps its signature and reads the local replica:

| Record | Answer |
|---|---|
| absent | `Error(Unknown)` |
| owner is this daemon's node | `Ok(Here)` |
| owner is another node | `Ok(Elsewhere(orchestrator))`, the configured row for that node or a row carrying only the node name |
| the store is not running or not joined | `Error(Unavailable)` |

`Miss` loses `Unreachable(orchestrators)` and gains `Unavailable`, because no
peer is asked any more. A lookup never waits on a quorum, so a daemon cut off
from the majority still redirects, from what its replica last applied. A
redirect is a statement of where the session was at that point, and the client
that follows it is refused by the owner if it moved since.

`Directory.reach` and `Directory.activate` are unchanged. A new record of
functions, `Ownership`, holds the writes in the table above and the read used by
admission:

```gleam
pub type Ownership {
  Ownership(
    read: fn(String) -> Result(Option(Record), Unavailable),
    create: fn(String, Placement) -> Result(Nil, WriteRefusal),
    claim: fn(String) -> Result(Record, WriteRefusal),
    begin_move: fn(String, String, String) -> Result(Nil, WriteRefusal),
    activate: fn(String, String, String) -> Result(Record, WriteRefusal),
    abandon: fn(String, String) -> Result(Nil, WriteRefusal),
    release: fn(String) -> Result(Nil, WriteRefusal),
  )
}

pub type WriteRefusal {
  /// The command did not commit within its deadline, or the store is not
  /// running. Its outcome may be unknown; the caller reads before it acts.
  NoQuorum
  /// The record did not match. Carries what the store holds now.
  Mismatch(found: Option(Record))
}
```

Every function runs its Khepri call in a weft task under a deadline (three
seconds for a write, five for an activation), because a consistent read does not
honour Khepri's own timeout when the majority is gone (ADR-019). No call runs
inside a registry turn.

### Creation

`sessions.create` reserves the registration in the catalogue as it does today,
then creates the record, then confirms the registration. A reserved registration
without a record is never served. A retried creation under the same request key
repeats the create and accepts an existing record whose owner is this daemon.
Without a quorum the create is refused `no_quorum` and the reservation stays,
so the same request key completes it later.

### Opening

Admission runs the claim outside the registry turn, between reserving the slot
and building it. A claim that finds the record `Moving(op, to)` with this daemon
as owner refuses `moving` with `op` and the orchestrator for `to`. A claim that
finds another owner refuses `not_owner` with that orchestrator. A claim that
finds no record refuses `not_found`. A claim that cannot commit refuses
`no_quorum`. In every refusal the reserved slot is released.

### Moving a session

The six steps of the phase 5 move keep their order and their file handling
(close, cut, send in pieces, verify on the receiver). Three things change.

1. **The intent is a CAS.** The source stops the slot in a registry turn, then
   commits `Moving(op, to)` outside it. A client open that races the intent is
   ordered by Ra: if the claim commits first, the intent's expected value no
   longer matches and `sessions.move` is refused `conflict`; if the intent
   commits first, the claim fails and the open is refused `moving`. Nothing is
   written to `catalogue_session_moves`.
2. **The hand-over is the receiver's CAS.** The receiver verifies the copy (the
   sender's node against `[orchestrators]`, the digest, the scope cell, the
   executor row), registers the session and places the file in one registry
   turn, then commits `Moving(op, self) -> Serving(op)`. The registration is not
   served before that commit, because admission's claim needs the record to name
   this daemon. If the CAS finds the move ended without it, the receiver removes
   the registration and file that this import created and refuses
   `move_ended`.
3. **The source abandons by CAS, and may do so on silence.** `Moving(op, to) ->
   Serving(<<>>)` competes with the receiver's activation for the same record,
   so exactly one commits. A source that abandons can never leave the session
   owned by two daemons, whatever the receiver did or will do. The rule "only an
   answer abandons a move" is retired. The source abandons on an unproven
   cleanup, a corrupt or oversized file, a receiver's refusal, or when the move
   has stalled for longer than the move deadline while the store had a quorum
   (thirty minutes, an open question in the design note).

The source retires when it reads a record whose owner is not itself: from the
activation's `Accepted`, from its own read when a reply was lost, or at boot.
Retiring is file work only (the file is set aside, the lease and the cut copy
are released). The source keeps its registration, so a later move back
registers nothing new.

The rule that the receiver answers `Accepted` to every repeat of an activation it
committed now follows from the record: a repeat finds `Serving(op)` with itself
as owner and answers `Accepted` without looking at the copy. The hold on an
imported session (`inbound_settled`, `not_movable` for `sessions.move` and
`busy` for `sessions.delete`) is removed, because the source's progress no longer
depends on the receiver's catalogue.

### The orchestrator port

| Message | Change |
|---|---|
| `Owns(session, reply)` and `Ownership` | Removed. Lookups read the local replica. |
| `Import(chunk, reply)` | Unchanged. |
| `ImportStatus(session, op, reply)` | `Stage` is `Absent` or `Received`. `Activated` is removed; the source reads the record. |
| `Activate(activation, reply)` | `Accepted` means the record names the receiver with `last_op = op`. `Refused` gains `MoveEnded`, sent when the record shows the move ended without the receiver. `Failed` now also covers a CAS that did not commit. |
| `PeerCommand(...)` | Unchanged. |

Both ends ship together, as for every message on this port.

### Control protocol

- **`no_quorum`**, a new refusal code of `sessions.create`, `sessions.open`
  (remote sessions only), `sessions.move` and `sessions.delete`. It means the
  session directory could not commit or could not be read within its deadline.
  The body carries the `code` and `message` every refusal has. A client retries
  later; nothing about the session changed unless the message says otherwise.
  `sessions.get` and `sessions.open` also answer it on a miss when the
  directory is `Unavailable`.
- **`owner_unreachable`** is no longer sent by a daemon that is a directory
  member. It stays in the vocabulary for a client talking to an older daemon.
- **`not_owner`** keeps its body. `orchestrator` is the daemon's own name for the
  owner's node, or the node name when no row names it, and `address` is present
  only when a row configures one.
- **`moving`** and **`moved`** members of `sessions.get` keep their shape. They
  are derived from the record: `moving` while the record is `Moving` with this
  daemon as owner, `moved` when this catalogue holds the registration and the
  record names another owner.
- **`sessions.move`** loses the `not_movable` refusal for an imported session
  whose origin has not retired. **`sessions.delete`** loses the matching `busy`.

### Configuration

```toml
[directory]
members = ["alpha@10.0.0.1", "bravo@10.0.0.4", "exec@10.0.0.2"]
```

`members` lists the cluster's voting members by node name, in the same order on
every member. It must contain the daemon's own `[distribution] node`, every
other entry must be a `[[distribution.peers]]` node, entries are distinct, and
there are between three and seven. The table requires `[distribution]`. A daemon
with `[orchestrators.<name>]` rows requires `[directory]`, so a two-orchestrator
deployment always has a store. An executor that is a member has `[directory]`
and no `[orchestrators]`.

The store's data lives at `<state root>/directory`, beside the executor ledger
on an executor and beside the catalogue on an orchestrator. It is not
configurable in this change.

`docs/configuration.md` documents the key and `make doc-check` gates it.

### Distribution

A daemon with `[directory]` starts distribution with `hidden => false`, and the
launcher adds `-kernel connect_all false -kernel prevent_overlapping_partitions
false` to the boot arguments. `start` refuses a member VM booted without both,
with a new `BootRefusal`, `GlobalNotIsolated`. `dist_auto_connect` stays
`never`, and the pins and the allow list are unchanged. A daemon without
`[directory]` is booted and started exactly as before.

Each member runs a link keeper: every two seconds it connects to each configured
member that is not in `nodes()`. Ra also connects to its peers when its server
starts. These are the only connections made without a client's request, and they
reach only configured members.

### Forming the cluster

`loomd directory bootstrap`, run once on one member with its daemon stopped,
creates a one-member store and marks it joined. Every other member, on a boot
that finds no joined store, joins the first configured member that answers, and
marks its store joined once `khepri_cluster:join/3` returns `ok`. A member whose
store is joined starts it and lets Ra resume its membership. A member that
lost its data directory has no joined store and joins again, which is what
`join` is for. A store that is not joined answers every call with
`Unavailable` or `NoQuorum`.

`loomd directory status` prints the configured members, Ra's members, the
leader, this member's applied index and whether its store is joined.

### Catalogue

No schema change. `catalogue_session_moves` stops being written. Migration reads
it once and deletes the rows it has seeded, and a later catalogue version drops
the table. `begin_move`, `finish_move`, `abort_move` and the custody arm of
`import_session` are removed from the registry's vocabulary.

### Migration

Once a member orchestrator's store is joined and has a quorum, and
`[loom, migrated, <<Node>>]` is absent, the daemon seeds one record per
registration in its catalogue:

| Catalogue custody | Record created |
|---|---|
| `Resident` | `Serving(<<>>)`, owner self |
| `Imported(op, from)` | `Serving(op)`, owner self; if a record exists and is `Moving(op, self)` from `from`'s node, the activation CAS instead |
| `Moving(op, to)` | `Moving(op, to's node)`, owner self; the mover resumes it under the new rules |
| `Moved(op, to)` | nothing; the receiver seeds its own |

Placement is `remote` when the registration names an executor or a pool, and
`local` otherwise. A create that finds an existing record whose owner is this
daemon is a repeat and succeeds. One whose owner is another daemon is a conflict:
the existing record stands, the daemon logs `directory.migration_conflict` with
the session, and the session stays unservable here until an operator resolves it
(a restored backup is the known cause). Then the daemon writes the marker and
deletes the migrated catalogue rows. Until the marker is written, a remote
session on that daemon cannot open, because its claim finds no record.

## What it costs

- A quorum for creation, for opening a remote session, and for beginning,
  activating, abandoning and deleting. ADR-019 lists the operations that keep
  working without one.
- Visible distribution between members, with the `global` and `pg`
  consequences ADR-019 lists, and executors pinning one another when more than
  one is a member.
- Six Hex packages, about 2 MB of BEAM files, and a Ra log on every member.
- `Move.tla` no longer models the protocol. It is replaced by a model of one
  register (plan in [the design note](../docs/design-notes/khepri-ownership.md));
  until that lands, the move has no gated model.
- Operators run one bootstrap command per deployment and keep `[directory]
  members` identical on every member.

Not built: automatic failover, ownership leases, moving a session between
executors, membership change commands beyond join, and a merged session list.
