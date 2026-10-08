# Khepri session ownership: the model and the implementation plan

Status: **proposed, 2026-10-08, revised after review.** This note orders the
work that [protocol-change/079](../../protocol-change/079-khepri-session-ownership.md)
specifies and [docs/architecture/directory.md](../architecture/directory.md)
describes. It has three parts: what the TLA+ model of a move must become, the
implementation slices in order, and what is left open.
[ADR-019](../adr/019-khepri-for-session-ownership.md) has the spikes.

## 1. The model

`protocol/models/session-move/Move.tla` models the phase 5 move, where two
catalogue rows decide ownership. With a directory, the record decides and the
rows remember, so the model gains a register and keeps the rows. It is rewritten
as a new specification beside the old one, `KhepriMove.tla`, because a
deployment without `[directory]` still runs the phase 5 protocol and its model
stays gated.

### What the model holds

Two orchestrators A and B, one executor, and up to two moves (A to B, then B
back to A):

| Variable | Meaning |
|---|---|
| `reg` | The record: `[owner, state, op]`, `state` in `{serving, moving}`. Every write is atomic and commits only while `quorum` holds. |
| `rowA`, `rowB` | Each node's custody row: `resident`, `moving(op)`, `moved(op)`, `imported(op)` or `absent`. |
| `quorum` | Whether a majority is up. The environment toggles it. |
| `copy[op]` | `none`, `cut` or `sent`. |
| `file[n]` | Whether node `n` has the session file in place. |
| `exec` | The executor ledger row `[inc, holder]`, as in `Move.tla`. |
| `serving[n]`, `alive[n]`, `mover[n]`, `replied[n]` | As in `Move.tla`, per node. |

### Actions

| Action | Effect |
|---|---|
| `Open(n)` | `alive[n]`, the row allows serving (`resident` or `imported`), no mover on `n`, `n` holds the executor token: `serving[n]`. No read of `reg`. |
| `Intend(n, op)` | The row becomes `moving(op)` and `serving[n]` stops, in one step (the registry turn). |
| `IntentCAS(n, op)` | `quorum`, `reg = [n, serving]`: `reg := [n, moving, op]`. A separate step, so an `Open` can interleave between `Intend` and it. |
| `RevertIntent(n, op)` | `reg` is absent: the row goes back to `resident`. |
| `StopClose`, `Cut`, `Send` | As in `Move.tla`, for the moving node. |
| `ActivateCAS(m, op)` | `quorum`, `copy[op] = sent`, `reg = [source, moving, op]`: `reg := [m, serving]`. |
| `Import(m, op)` | After `ActivateCAS` committed (or `reg.owner = m`): `row[m] := imported(op)`, `file[m] := TRUE`. |
| `Refuse(m, op)` | `reg.owner # m`: the receiver drops only its copy. |
| `AbandonCAS(n, op)` | `quorum`, `reg = [n, moving, op]`: `reg := [n, serving]`. |
| `Unmark(n, op)` | After `AbandonCAS` committed: `row[n] := resident`. |
| `Retire(n, op)` | The receiver answered, and `reg.owner # n` read consistently: `row[n] := moved(op)`, `file[n] := FALSE`. |
| `Crash(n)`, `Restart(n)`, `QuorumLoss`, `QuorumBack` | Memory is lost; `reg`, rows, files and the ledger survive. A restart resumes a mover for a `moving` row. |

### Properties

- `OneOwner`: `~(serving[A] /\ serving[B])`.
- `ServeOnlyAsOwner`: `serving[n] => reg.owner = n`.
- `OwnerHasFile`: `reg.state = serving => file[reg.owner]`, once the owner's
  import has run; `reg.state = moving => file[reg.owner]`.
- `RowsFollowRecord`: a row that allows serving on `n` implies `reg.owner = n` or
  `n`'s own revert or import is the next step.
- `OneServingHolder`: unchanged from `Move.tla`.
- `MoveSettles`: `reg.state = moving ~> reg.state = serving`, under weak
  fairness of `QuorumBack`, `Restart`, the protocol steps and `AbandonCAS`.

### Mutants

| Mutant | Rule removed | Expected violation |
|---|---|---|
| `MutantIntendBeforeStop` | `IntentCAS` may run before `Intend` stops serving (the local revoke follows the write) | `OneOwner`: A serves after the record says `moving`, and B activates |
| `MutantBlindActivate` | `ActivateCAS` writes `[m, serving]` without expecting `[source, moving, op]` | `OneOwner`: A abandons, reopens, and B's late activation takes the session too |
| `MutantBlindAbandon` | `AbandonCAS` writes `[n, serving]` without expecting `moving` | `OneOwner`: B activated and serves; A takes it back |
| `MutantImportBeforeCAS` | `Import` runs without `ActivateCAS` having committed | `ServeOnlyAsOwner`: B serves a session A then takes back by abandoning |
| `MutantRefuseOwned` | `Refuse` runs whatever `reg.owner` is, and removes B's file | `OwnerHasFile`: B refuses a late repeat of a move it completed, then deletes its own file |
| `MutantRetireStale` | `Retire` reads a stale copy of `reg` | `OwnerHasFile`: during the return move, A's old mover sets aside the file the return just placed |

The review named its first mutant `MutantStopBeforeIntend`, for the design in
which the intent write came before any local change. With the rows kept, the
dangerous order is the reverse, the local revoke after the write, and the mutant
is named for it. The refusal edge is covered by `Refuse` and `MutantRefuseOwned`:
a receiver may refuse only when the record names someone else.

The model is gated by `make model-check` beside `Move.tla`, and the README of
`protocol/models/session-move` describes both.

## 2. The slices

Each slice is a run of atomic commits that ends green on the package gate and
`make doc-check`. The shipped fixtures need `make server-shipment`, `make
sandbox` and `bin/loom-exec`.

### Slice 0: the dependency and the FFI boundary

`khepri = "== 0.19.3"` in `packages/client/gleam.toml`; the regenerated
`packages/client/manifest.toml` and the hand-updated
`packages/conformance/manifest.toml` in their own commit.
`client/internal/ffi_khepri.gleam` and `client_khepri_ffi.erl`: start a Ra system
and a store, local and consistent reads, create, compare-and-swap, conditional
delete, the non-voter join, membership, all normalized. `client/directory/record`
with its total decoder.

Tests: a one-member store in the ordinary test VM, covering every call's success
and failure shapes. Exit: `make check-client` green; the release includes the six
applications and boots.

### Slice 1: visible member links

`distribution.start` takes whether this node is a member; members start visible
and are refused without `connect_all false`. `distribution.connect` takes the
membership and chooses `connect_node` between members. The launcher passes
`-kernel connect_all false`.

Tests: fixture scenarios for three visible members (no transitive connection),
the refusal, a non-member left hidden, and an attach-style connect between two
members after which both ends list each other in `nodes()`.

### Slice 2: configuration and provisioning

`client/directory/settings` for `[directory] members`, the cross-checks against
`[distribution]` and `[orchestrators]`, `docs/configuration.md`,
`scripts/config_keys.sh`, and `loom distribution` plans and bundles that carry
the members list and pin executors to each other.

### Slice 3: the store, the keeper, bootstrap, join, status

`client/directory/store` starts the store at boot, joins a fresh member as a
non-voter with retries, and refuses calls until joined. `client/directory/links`
is the keeper. `loomd directory bootstrap` and `directory.status`.

Tests: a three-emulator fixture that bootstraps, joins two members, writes past
a snapshot while one is stopped with its directory deleted, and checks that the
member rejoins as a non-voter, is promoted, and reads the writes; the keeper
reconnects after a cut; bootstrap refuses a second time.

### Slice 4: the record in the directory, creation and deletion

`Directory.lookup` over the local replica; `Ownership`; remote creation through
`manager.reserve` and the record; catalogue version 13 and the deletion mark;
delete through `begin_delete`, the record and `delete_session`; `no_quorum`.

Tests: `session_directory_test` with a one-member store; `daemon_directory_test`
for each refusal; `daemon_shipped_directory_test` with two orchestrators and one
executor as members.

### Slice 5: the move over the record

The mover's intent, abandon and retire through `Ownership`; the receiver's
activation write before its import; `move_ended`; the thirty-minute rule and
`abandon: true`; no `inbound_settled` on members.

Tests: `session_mover_test` and `session_importer_test` in the store mode;
`daemon_shipped_remote_move_test` with members, the source lost after each step,
and a move onward without waiting.

### Slice 6: migration

`client/directory/migrate` and the marker.

Tests: version 12 catalogues on two orchestrators with a resident, an imported, a
moving and a moved session, upgraded and checked; a conflict.

### Slice 7: quorum loss and rejoin, shipped

Three shipped daemons: stop two members and check the table in the architecture
page; restart one and check recovery. A member that loses its directory rejoins
as a non-voter and serves lookups.

### Slice 8: the model

`KhepriMove.tla` and its mutants, gated.

### Slice 9: documentation

The architecture page and 079 at the implemented spellings, the package
`CLAUDE.md` files through `/doc-gardening`, `docs/distributed-setup.md`,
`docs/configuration.md` and `docs/next.md`.

## 3. Left open

1. **Membership removal.** Adding a member works by configuration and the
   non-voter join; removing one needs `ra:remove_member/3`. A `loomd directory
   forget <node>` command is left for later.
2. **Ra and Khepri logging.** Both log through OTP's logger. Their domains are
   held at `warning` in the daemon; routing them through Loom's telemetry is left
   for later.
3. **Consistent reads that ignore their timeout.** Measured, wrapped in weft
   deadlines, and worth reporting upstream.
4. **Retiring the phase 5 path.** Once every deployment has a directory, the
   fan-out, `inbound_settled` and the rows-as-authority mover can go.
