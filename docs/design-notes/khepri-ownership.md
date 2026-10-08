# Khepri session ownership: the model and the implementation plan

Status: **proposed, 2026-10-08.** This note orders the work that
[protocol-change/079](../../protocol-change/079-khepri-session-ownership.md)
specifies and [docs/architecture/directory.md](../architecture/directory.md)
describes. It has three parts: what the TLA+ model of a move must become, the
implementation slices in order, and the questions the design could not settle on
its own. [ADR-019](../adr/019-khepri-for-session-ownership.md) has the spike.

## 1. The model

`protocol/models/session-move/Move.tla` models the phase 5 move, where ownership
is two catalogue rows. Once the record in Khepri decides ownership, three of the
model's four rules no longer exist in the code, and the model would check a
protocol nobody runs. It is replaced, not patched.

### What the new model holds

One move of one session from A to B, one executor, and the record as a single
register that every member reads and writes:

| Variable | Meaning |
|---|---|
| `reg` | The record: `[owner, state, op]` with `state` in `{serving, moving}`. Abstracts Ra: every write is atomic, linearizable, and commits only while `quorum` holds. |
| `view[n]` | Node `n`'s local replica: some earlier value of `reg`. A node's view can lag; a restart may set it to any earlier value. |
| `quorum` | Whether a majority is up. The environment toggles it. |
| `copy` | `none`, `cut` or `sent`, as today. |
| `placed` | Whether B has registered the session and placed the file. |
| `exec` | The executor ledger row `[inc, holder]`, unchanged from `Move.tla`. |
| `serving[n]`, `alive[n]`, `mover` | As today. |
| `fileA` | Whether A still has the session file in place (`FALSE` once retired). |

### Actions

| Action | Guard and effect |
|---|---|
| `Claim(n)` | `alive[n]`, `quorum`, `reg = [owner \|-> n, state \|-> serving, ..]`; then `serving[n]` may start (with the executor attach as today). |
| `Intend` | A, `quorum`, `reg.owner = A /\ reg.state = serving`: `reg := [A, moving, op]`, A stops serving. |
| `StopA`, `Cut`, `Send` | As today, guarded by `reg.state = moving` with A as owner. |
| `Place` | B registers and places the file (`placed := TRUE`). |
| `Activate` | B, `quorum`, `placed`, `copy = sent`, `reg = [A, moving, op]`: `reg := [B, serving, op]`. |
| `Abandon` | A, `quorum`, `reg = [A, moving, op]`: `reg := [A, serving, none]`. Allowed at any step, including after `Send`, and with B silent. |
| `Retire` | A, `view[A].owner # A` or a read of `reg` showing it: `fileA := FALSE`. |
| `Refuse` | B, `reg # [A, moving, op]`: B removes its registration and file. |
| `Catchup(n)`, `Lag(n)` | `view[n]` moves toward `reg`, or a restarted node's view is set back to an older value. |
| `Crash(n)`, `Restart(n)`, `QuorumLoss`, `QuorumBack` | Memory is lost; `reg`, the files and the ledger survive. |

### Properties

- `OneOwner`: `~(serving[A] /\ serving[B])`.
- `ServeOnlyAsOwner`: `serving[n] => reg.owner = n`. This is the property the
  claim exists for.
- `OwnerHasFile`: `reg.owner = B /\ reg.state = serving => placed`, and
  `reg.owner = A => fileA`. No state leaves the record naming a daemon that has no
  file.
- `NoResurrectionAtSource`: once A has retired, `reg.owner # A` until a later
  move brings it back (the model has one move, so: forever).
- `OneServingHolder`: unchanged from `Move.tla`.
- `MoveSettles`: `reg.state = moving ~> reg.state = serving`, under weak fairness
  of `QuorumBack`, `Restart`, the steps and `Abandon`.

### Mutants

Each `Mutant*.cfg` turns one rule off and names the invariant TLC must then
break, as the current gate does.

| Mutant | Rule removed | Expected violation |
|---|---|---|
| `MutantStaleOpen` | `Claim` reads `view[n]` instead of committing against `reg` | `ServeOnlyAsOwner`, then `OneOwner`: A begins a move, crashes, restarts with a lagging view, and serves after B activated |
| `MutantBlindActivate` | `Activate` writes `[B, serving]` without expecting `[A, moving, op]` | `OneOwner`: A abandons, reopens, and B's late activation takes the session too |
| `MutantBlindAbandon` | `Abandon` writes `[A, serving]` without expecting `moving` | `OneOwner`: B activated and serves; A's abandon takes the session back |
| `MutantActivateBeforePlace` | `Activate` does not require `placed` | `OwnerHasFile`: B crashes between the write and placing the file |
| `MutantEarlyRetire` | `Retire` runs after `Send` without reading an owner other than A | `OwnerHasFile`: A sets its file aside, then abandons |
| `MutantOwnerOnlyClaim` | `Claim` checks the owner and not the state, so it accepts `moving` | `OneOwner`: a client opens the session on A after the intent, and B activates and serves |

`MutantAbort`, `MutantIntend`, `MutantRefuse` and `MutantRetire` of the current
model are retired with it. `RefuseUncommitted` and `AbortGuardsSent` have no
counterpart, because the record makes their rules unnecessary: a refusal can only
come from a record that no longer says `moving` to B, and an abandon after the
send is safe.

The model is written in slice 8 and gated by `make model-check` like the current
one. The README in `protocol/models/session-move` is rewritten with it.

## 2. The slices

Each slice is one branch's worth of commits, ends green on `make check` and
`make doc-check`, and leaves `main` working. Slices 0 to 3 add machinery that
nothing depends on yet; slice 4 switches the directory; slice 5 switches the
move; slice 6 migrates. The shipped fixtures need `make server-shipment`, `make
sandbox` and `bin/loom-exec`, as in the existing brief.

### Slice 0: the dependency and the FFI boundary

Add `khepri = "== 0.19.3"` to `packages/client/gleam.toml`. Commit the
regenerated `packages/client/manifest.toml` and the hand-updated
`packages/conformance/manifest.toml` on their own. Add
`client/internal/ffi_khepri.gleam` and `client_khepri_ffi.erl` (start a store,
get, create, compare-and-swap, conditional delete, fence, join, members), with
every return normalized and no atom built from input.

Tests: a single-member store in the ordinary test VM (it works on
`nonode@nohost`), covering each call's success and failure shapes, including a
mismatch carrying the stored value. Exit: `make check-client` green; `make
release` and `make release-smoke` include `ra`, `khepri`, `horus`, `aten`,
`gen_batch_server` and `seshat` and boot; the release grows by about 2 MB.

### Slice 1: visible distribution for members

`client/distribution` takes whether the node is a member, starts it visible when
it is, and refuses a member VM without `connect_all false` and
`prevent_overlapping_partitions false` (`GlobalNotIsolated`).
`boot_arguments` and the launcher add the two flags. This slice edits
`client_distribution_ffi.erl`, so it rebases onto the epmd fix first.

Before relying on `prevent_overlapping_partitions false`, measure it: three
visible members with `connect_all false`, cut the connection between two, and
check that the third keeps both connections with the flag set and loses one
without it.

Tests: new scenarios in `client_distribution_fixture_ffi.erl` for three visible
members (no transitive connection, `nodes()` lists only the connected members),
for the refusal, and an unchanged hidden scenario for a non-member. Exit: the
distribution suite green on Mac and Linux.

### Slice 2: configuration

`[directory] members` with the rules in protocol-change/079, the requirement that
`[orchestrators]` implies `[directory]`, `docs/configuration.md`,
`scripts/config_keys.sh`, and `loom distribution` provisioning that writes the
table and the extra pins between executors.

Tests: the parser's acceptance and each refusal; a provisioning test that an
installed three-node bundle parses on every node. Exit: `make doc-check` green.

### Slice 3: the store, the link keeper and forming the cluster

`client/directory/store` (start, the joined marker, join with retry under weft,
the deadline-bounded calls), `client/directory/links` (the two-second link
keeper as a weft actor), `loomd directory bootstrap` and `loomd directory
status`.

Tests: a three-emulator fixture built on `client_distribution_fixture_ffi.erl`
that bootstraps one member, joins two, writes, stops a member, writes past a
forced snapshot, restarts it, and checks it caught up (the hidden-mode failure
from ADR-019 becomes a regression test); a member that lost its data directory
rejoins; the link keeper reconnects after a cut. Exit: the fixture green on Mac
and Linux, three runs each.

### Slice 4: the record, the directory and admission

`client/directory/record` with its total decoder and its encoder.
`Directory.lookup` reads the local replica; `Ownership` holds the writes.
Creation writes the record; admission claims a remote session; delete removes
the record first. The refusal `no_quorum` and the `Miss` variant `Unavailable`.
`Owns` and the fan-out are removed from the port and the directory.

Tests: `session_directory_test` rewritten against a one-member store;
`daemon_directory_test` for each refusal across the control socket;
`daemon_shipped_directory_test` with two orchestrators and one executor as the
three members. Exit: the shipped directory test green with 0 SKIP lines.

### Slice 5: the move over the record

The intent, activation and abandon become compare-and-sets; retirement reads the
record; the receiver removes an import whose activation found the move ended;
`inbound_settled` and its holds are removed; the move deadline for abandoning on
silence. The catalogue move transitions leave the registry.

Tests: `session_mover_test` and `session_importer_test` rewritten (an abandon
racing an activation, in both orders; a lost activation reply; a receiver down
for longer than the move deadline); `daemon_shipped_remote_move_test` extended
so the source is lost after each step and after the intent's write but before the
slot stopped, and so a session moves A to B and on to C without waiting. Exit:
the shipped move test green, three runs on each platform.

### Slice 6: migration

`client/directory/migrate`, run once per orchestrator when its store has a
quorum, with the table in protocol-change/079.

Tests: a migration test that builds version 12 catalogues on two orchestrators
holding a resident session, an imported one, one moving and one moved, boots the
new release on both and the executor, and checks the records and the emptied
tables; a conflict from the same session resident on both. Exit: green, and
`docs/distributed-setup.md` has an upgrade section.

### Slice 7: the quorum-loss test

A shipped test over three daemons (two orchestrators, one executor): stop the
second orchestrator and the executor's daemon; check that a lookup redirects
from the survivor's copy, that a running local session keeps running, that
opening a remote session and creating a session are refused `no_quorum`, and
that a move in progress stalls without changing owner; restart one member and
check that all of them recover. A second case stops only one member and checks
that everything keeps working.

Exit: green with 0 SKIP lines on Mac and Linux.

### Slice 8: the model

`Move.tla` replaced as in part 1, with its mutants and README. Exit: `make
model-check` green, every mutant breaking its named property.

### Slice 9: documentation

`docs/architecture/directory.md` and protocol-change/079 brought to the
implemented spellings; `packages/client/CLAUDE.md` and
`packages/storage/CLAUDE.md` through `/doc-gardening`;
`docs/distributed-setup.md` (members, bootstrap, status, upgrade);
`docs/next.md`. Exit: `make doc-check` green.

## 3. Open questions

Each has a recommendation; none blocks slice 0.

1. **Visible distribution for members.** The spike made it necessary, but it
   changes the posture `client/distribution` documents ("the node is hidden").
   Recommendation: accept it for members only, with `connect_all false` and
   `prevent_overlapping_partitions false`, and keep non-members hidden. The
   alternative is a patched Ra.
2. **Does opening a remote session need a quorum?** The claim makes it so. The
   alternative keeps a local write-ahead row on the owner ("I began moving this
   session") and opens without a quorum when no such row exists, which is safe
   until failover and has to be undone for it. Recommendation: the claim, because
   it is the rule failover needs and a remote session cannot run without its
   executor, which is itself a member.
3. **Does creating a local session need a quorum?** As proposed, yes, because the
   record must exist before the session is served. The alternative creates local
   sessions without a record and writes it later, which needs a reconciler.
   Recommendation: require it, and revisit if operators report it.
4. **When does a stalled move give up?** Abandoning on silence is now safe.
   Recommendation: abandon after thirty minutes of stalls during which the store
   had a quorum, so a receiver that stays down does not leave the session
   unopenable everywhere, and never while the store has no quorum.
5. **Bootstrap by command or by rule?** Recommendation: the command, because the
   rule creates a second cluster when the first member loses its disk.
6. **Member count.** Recommendation: three to seven, any count allowed, with the
   setup guide recommending an odd number.
7. **Ra and Khepri logging.** Both log through OTP's logger at debug and info.
   Recommendation: set their logger domains to `warning` in the daemon and route
   them through Loom's telemetry logger, decided in slice 3.
8. **Membership change.** Adding a member works by configuration and the
   automatic join. Removing one needs `ra:remove_member`. Recommendation: a
   `loomd directory forget <node>` command after slice 7, not in this change.
9. **Consistent reads that ignore their timeout.** Measured, and wrapped in weft
   deadlines here. Recommendation: report it to Khepri upstream with the spike's
   reproduction.
