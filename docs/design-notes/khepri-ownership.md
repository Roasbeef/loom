# Khepri session ownership: the model and the implementation plan

Status: **implemented, 2026-10-08.** This note ordered the work that [protocol-change/079](../../protocol-change/079-khepri-session-ownership.md)
specifies and [docs/architecture/directory.md](../architecture/directory.md)
describes. It has three parts: the TLA+ model of a move under the record, the
implementation slices in order with what each became, and what is left open.
[ADR-019](../adr/019-khepri-for-session-ownership.md) has the spikes.

## 1. The model

`protocol/models/session-move/Move.tla` models the phase 5 move, where two
catalogue rows decide ownership. With a directory, the record decides and the
rows remember, so the model gains a register and keeps the rows. It is a new
specification beside the old one, `KhepriMove.tla`, because a deployment
without `[directory]` still runs the phase 5 protocol and its model stays
gated. [The model's README](../../protocol/models/session-move/README.md)
describes both in full; this section says what the review asked for and where
the model has it.

- **The intent split from the stop.** `Intend` is the registry turn (row
  `moving`, serving stopped) and `IntentCAS` is a separate step, so every
  interleaving between them is explored. The review's `MutantStopBeforeIntend`
  was for a design whose intent write came first; with the rows kept, the
  dangerous order is the reverse, and `KhepriMutantIntendBeforeStop` lets the
  CAS run before the row that remembers it. It violates `MovingIsRemembered`.
- **A second move and a return.** Op 1 moves the session from A to B and op 2
  from B back to A, and an activation may arrive at any time once a copy is
  sent. The session has a content version, so serving an old copy is a
  violation (`OwnerHasNewest`), not a quiet success.
- **The refusal edge.** `RefuseConflict` (the receiver's own row holds the
  session in another state) and `RefuseEnded` (the record names someone else)
  are separate. `KhepriMutantRefuseOwned` refuses although the record names the
  receiver, and `KhepriMutantImportOverMoving` writes the record before the row
  check; both violate `OwnerHasNewest`.
- **The compare-and-sets.** `KhepriMutantBlindActivate` and
  `KhepriMutantBlindAbandon` drop the expected value and violate `OneOwner`;
  `KhepriMutantImportBeforeCAS` imports before the record names the receiver
  and violates `ServeOnlyAsOwner`; `KhepriMutantRetireStale` retires on a value
  the record held before and violates `OwnerHasNewest`.
- **Liveness.** `MoveSettles` and `MoverEnds` hold under weak fairness of the
  protocol steps, the restarts and the return of the majority, and fail when
  any one of those is dropped.

The plan named `RowsFollowRecord`; the model states the same thing as
`MovingIsRemembered` for the moving case and `ServeOnlyAsOwner` for serving.

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
non-voter with retries, and refuses calls until joined. The keeper became
`client/directory/member`, which also runs the join and reports the member's
status. `loomd directory bootstrap` (`client/daemon/directory_cli`) and
`directory.status`.

Tests: a three-emulator fixture that bootstraps, joins two members, writes past
a snapshot while one is stopped with its directory deleted, and checks that the
member rejoins as a non-voter, is promoted, and reads the writes; the keeper
reconnects after a cut; bootstrap refuses a second time.

### Slice 4: the record in the directory, creation and deletion

`Directory.lookup` over the local replica; `Ownership`; remote creation through
`manager.reserve` and the record; catalogue version 13 and the deletion mark;
delete through `begin_delete`, the record and `delete_session`; `no_quorum`.

Tests: `session_directory_test` with a one-member store;
`directory/daemon_record_test` for each refusal; `daemon_shipped_directory_test`
with two orchestrators and one executor as members.

### Slice 5: the move over the record

The mover's intent, abandon and retire through `Ownership`; the receiver's
activation write before its import; `move_ended`; the thirty-minute rule and
`abandon: true`; no `inbound_settled` on members.

Tests: `session_mover_test` and `session_importer_test` in the store mode;
`daemon_shipped_remote_move_test` with members and the source lost after each
step. A move onward of a just-imported session is not exercised by a shipped
test.

### Slice 6: migration

`client/directory/migrate` and the marker.

Tests: `directory/migrate_test`, one catalogue in the test VM holding a
resident, an imported, a moving and a moved session and a conflict, seeded and
seeded again; and a seed without a quorum, which writes no marker. The seed
runs in the movers' periodic pass.

### Slice 7: quorum loss and rejoin, shipped

`daemon_shipped_directory_quorum_test`: three shipped daemons; two members are
killed and the table in the architecture page is checked from the one left, then
the members return and the refused creation and the stalled move finish. A
member that loses its directory is refused a second bootstrap, rejoins as a
non-voter and serves lookups. The peer-mail and directory shipped tests gained
member variants.

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
5. **Local sessions across members** (closed). The first implementation
   recorded only remote sessions, so another member answered `not_found` for a
   local session and peer mail to it was not routed. The owner ruled that every
   session is recorded: a local session gets `{self, local}`, written by the
   movers' upkeep after the session exists and never waited on, so the gap is
   closed without making local creation depend on a quorum.

## 4. After the implementation review

The review found two problems around a move that the model did not cover, and
three smaller ones; ADR-019's addendum records the changes. The give-up now
waits for this daemon's seed, and a given-up move whose receiver already owns
the session retires only on the receiver's answer, because a receiver that
crashed between its compare-and-set and its import finishes the import only
when the source asks again. `KhepriMove.tla` now makes the receiver's steps fair
only while the source asks, adds `OwnerCanServe`, and catches the old rule with
`KhepriMutantRetireOnSilence`; the clean model needed three steps closer to the
code to stay live (a sender that finds the receiver owning the session carries
on, a resumed sender cuts and sends again, a refused close is an answer), and
`MoverEnds` still holds. Bootstrap no longer counts the Ra system's own files
as a store, the join's retries moved from the shim to `weft/poll`, and an
unrecognised Khepri answer is named instead of reported as a lost quorum.
