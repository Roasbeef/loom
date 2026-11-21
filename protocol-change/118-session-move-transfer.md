# protocol-change/118: how a session move carries the file

**Status**: DRAFT 2026-11-19. Not accepted, not built. Phase 1 is the
recommendation. Phase 2 is written down so that its cost is known, and it should
be built only if the evidence named in "Phase 2" shows that moves back and forth
are common.
**Affects**: the transfer step of the session move in
[078](078-distributed-runtime.md) (phase 5, "Send"). Phase 1 adds two operations
to the versioned peer service of [105](105-versioned-peer-exchange.md), changes
no existing orchestrator port constructor, and extends `Chunk`, `Stage` and
`Verdict` in `client/session_move` for the new operations only. Phase 2 adds a
second kind of transfer and changes what the receiver's activation verifies. No
Part 1 interface and no client control protocol command changes.
**Raised by**: the owner's question of whether a move could send less than the
whole file.
**Builds on**: 078 (the six steps, the importer, the retirement), 105 (the
versioned peer endpoint), 107 (`client/state_transfer`, which already resumes at
the offset a receiver reports).

## Problem

A move cuts a closed copy of the session's SQLite file and sends it to the
receiver in pieces of `chunk_bytes`, 262,144 bytes (`session_move.gleam:52`). It
refuses a file over `size_limit`, 256 MiB (`session_move.gleam:58`). Each piece
is a separate request that waits for its verdict before the next is sent
(`session_mover.gleam:999-1061`). The whole file is hashed once, at the cut, and
the receiver checks that digest at activation (`session_importer.gleam:530-533`).
Two properties of this send cost us something, and they are independent.

The first is that the send is stop-and-wait. With a round trip of `r` and a file
of `n` pieces, the source spends `n * r` waiting, however much bandwidth is free.
The limit makes this concrete without any measurement. The largest file is
`268,435,456 / 262,144 = 1,024` pieces, and the whole send runs under one deadline
of `send_ms = 600_000` (`session_mover.gleam:168`, applied at line 989). So at the
size limit each piece, including the receiver's write and the round trip, has to
average under `600,000 / 1,024`, about 586 ms, or the deadline passes. We do not
know whether any deployment is near that. We only note that the margin is set by
the per-piece time and not by the link's capacity.

The second is that a failure inside the send loses all progress. The deadline
expiring is a stall, not a verdict (`session_mover.gleam:62-63`), and the next
run sends from offset zero: a piece at offset zero makes the receiver write the
`.part` file afresh (`session_importer.gleam:191-193`). The receiver does tell the
source where it stands when a piece is out of order, `OutOfOrder(expected:)`
(`session_move.gleam:233`, `session_importer.gleam:203`), and the source ignores
the number and restarts at zero once (`session_mover.gleam:1038-1044`). A second
loss in one send is a stall. A stalled move leaves the source's row `moving`, and
admission refuses a `moving` session (078, "Who owns the session at each
moment"), so the session is not served while the move retries. A send that cannot
finish therefore costs availability, and a send that restarts from zero on every
stall can fail to finish indefinitely when it needs longer than the deadline.

The workspace side already solved the second problem. `client/state_transfer`
answers every piece with the number of bytes the receiver now holds
(`Accepted(held:)`, `state_transfer.gleam:120-124`), asks `Stage` for
`Partial(held:)` (`state_transfer.gleam:134-143`), and continues at that offset
(`state_transfer.gleam:604-675`). Its module doc names the difference from the
session move in so many words (`state_transfer.gleam:16-27`). We want the session
move to resume the same way, and to keep more than one piece in flight.

A third cost is separate and only sometimes present. A session that moves from A
to B and later back to A sends the whole file in both directions, although A held
all but the newest entries of it before the first move. We take that up in
phase 2, because it needs a different kind of argument.

## What was considered for phase 1

We considered leaving the send alone and raising `send_ms`. That removes the
deadline stall for a slow link, and it does nothing for the restart from zero. We
considered a larger `chunk_bytes`. The constant is shared in spirit with
`state_transfer.gleam:68`, whose comment says one lost piece costs the same in
both, and the link's other traffic (ownership lookups, mail, subagent calls) moves
between pieces. A larger piece makes that wait longer, and it does not reduce the
number of round trips below what a window does.

We considered reusing `state_transfer` for the session file. Its loop
(`transfer`, `step` and `judge`) is generic over a source and a sink, but its
`Piece` carries a `State` (`state_object.gleam:70-84`), which is a Git bundle's
description with a tip, a base and a dirtiness. A session file has none of those.
Extracting the loop so that both callers share it is attractive, and it is a
refactor of 107's code that this proposal should not make on its way past. We list
it as an open question.

We considered a cumulative acknowledgement with no per-piece reply, to cut the
reply traffic. It would make the receiver's verdict unobservable until the end of
a window and gives up the per-piece `Refused` that today lets the source stop at
the first bad piece. We kept one verdict per piece.

## Decision: phase 1, a windowed and resumable send

The source keeps up to `window` pieces in flight, and `window` is the constant 8.
At 262,144 bytes a piece this is 2 MiB sent ahead of the oldest unanswered piece.
We chose a small fixed number because of the reason stop-and-wait was chosen,
stated at `session_move.gleam:49-52`: the distribution link carries other traffic
and the actor that handles a piece does a disk append in its own turn
(`orchestrator_port.gleam:1342-1344` for the legacy port), so a lookup queued
behind the window waits for at most `window` appends. A window bounds that wait
and the receiver's mailbox backlog from one move. We did not measure either, and
8 is a first value. It is a named constant in `session_move`, and a measurement on
the two-box test setup may change it. We do not propose to adapt it at run time:
an adaptive window is machinery whose failure modes we would have to model, and a
constant is enough to remove the round trip from the critical path for the sizes a
move carries.

The pieces of one window are sent from the mover's single process in offset order.
Erlang orders signals between one pair of processes, so under normal operation
they arrive in order. The protocol does not depend on that. The receiver already
appends a piece only at exactly the offset it holds and refuses any other with the
offset it expects (`session_importer.gleam:195-205`), and the source treats a
refusal as a correction, as `state_transfer` does (`state_transfer.gleam:659-672`).

Four things change in the vocabulary of `client/session_move`, for the new
operations only.

`Chunk` gains `digest`, the SHA-256 of the whole copy, declared with every piece
as a `state_transfer.Piece` declares its state. Today the digest travels only in
`Activation` (`session_move.gleam:194-211`), so a receiver cannot tell whether a
`.part` file left by an earlier run is a prefix of the copy now being sent. The
cut is repeated after a restart (the next cut replaces the copy, 078, "The six
steps"), and we have not established that two cuts of the same file are
byte-identical: the cut writes to the original's lease table before copying
(`sqlite.gleam:1490-1494`). The receiver therefore names the part file by session,
operation and digest, and a piece at offset zero for a different digest discards
the old part. Resuming from a part that is not a prefix of the copy would be
caught by the whole-file digest at activation, and the cost would be a wasted
send, so the digest in the piece makes the common case cheap instead of making it
safe.

`Verdict` for a piece becomes `Held(bytes)`, the number of bytes the receiver
holds after the piece, and a repeated piece is answered with the same number, as
`state_transfer.placed` does (`state_transfer.gleam:358-368`). The existing
`Verdict` stays as it is for activation, where `Accepted` has no number to carry.

`Stage` gains `Partial(held)`, between `Absent` and `Received`, and the status
question names the digest. The receiver answers `Partial` with the size of the
part file for that digest, which `session_importer.size_of` already reads
(`session_importer.gleam:222-227`).

The source's loop changes from "send the next piece, restart at zero once on
`OutOfOrder`" to the loop in `state_transfer.transfer`: ask where the receiver
stands, send a window starting there, read the verdicts in order, and on the first
one that is not `Held` stop reading the rest of the window (each later piece will
be refused as out of order), ask again, and go on from the reported offset. The
number of corrections one send follows is bounded, as `state_transfer.max_resyncs`
bounds it at 8 (`state_transfer.gleam:72`), and exhausting the bound is a stall.
The `RestartedOnce` state of `session_mover.pieces` goes away. A restarted mover
asks `Stage` before it sends (`session_mover.gleam:970-979`) and now continues at
the held offset instead of at zero.

Everything after the send is unchanged. The receiver renames the part file to the
complete copy only when the last byte lands (`session_importer.gleam:209-216`),
and it still checks the whole-file SHA-256 against the activation's digest before
it reads the scope cell (`session_importer.gleam:530-533`). That check is what
makes it safe for the part file to be written without a flush: a restart that
leaves a shorter part is a different offset, and a restart that leaves wrong bytes
is a digest mismatch, which the source answers with one whole resend as it does
today (`session_mover.gleam:1128-1142`). The crash-safety argument of 078 rests on
that, and phase 1 does not touch it.

### The version, and an older peer

The orchestrator port has no version of its own and is served by peers of the same
build (`protocol.gleam:159-160`). An extra field on `Chunk` would be a different
tuple on the wire, and an older receiver would fail to match it. 105 describes the
outcome: the port's actor can crash, and its death neither identifies the release
nor shows that the earlier request had no effect. For a move the consequence is
worse than for a lookup, because the source reads silence as a stall and never
aborts (078, "When a move stops"), so the session stays `moving` and unserved until
the receiver is upgraded.

So phase 1 does not change the legacy constructors. `Import`, `ImportStatus` and
`Activate` stay as they are, and every build with an importer understands them. The
new send is two operations on `loom_peer_v1`, as revisions `118.chunk.1` and
`118.stage.1` in the style of 105 (`peer_service.gleam:101-108` is where the
service checks the epoch and the revision). The source asks `features`, and if the
receiver advertises both revisions it uses them, with the receiver's epoch in every
request. If the receiver does not (`unsupported`, or no endpoint), the source sends
as today, stop-and-wait with a restart from zero. Activation always uses the legacy
`Activate`, so the commit that hands the session over is the same message on both
paths. The version bump is the two entries added to the advertised revisions, and
nothing else is numbered.

This has a cost that we state here and do not hide. 105 carries JSON, and its bound
for one operation envelope is 1,048,576 bytes. A 262,144 byte piece is about 349,528
bytes in base64 plus the envelope, which fits, and the encoding adds a third to the
bytes sent and a decode at the receiver. The alternative is new constructors on the
legacy port with the same-build rule, which keeps the binary payload and puts the
mismatched-build stall back. We recommend the peer service because its failure with
an older peer is a clean fallback, and we ask the owner to confirm it.

### What the formal models say

`Move.tla` abstracts the send to one step: `copy` is `none`, `cut` or `sent`, and
the file "is cut and sent whole" (`protocol/models/session-move/README.md`, "What
is abstracted away"). Phase 1 changes nothing that `Move.tla` models, so it needs no
change. The model that does need work is the P model in
`protocol/models/state-transfer`. It checks `PartIsAlwaysAPrefix` for a sender with
one piece in flight, and its README states that with one sender and one piece in
flight a repeated piece and a gap are unreachable
(`protocol/models/state-transfer/README.md`, "What the model leaves out"). A window
makes both reachable: a receiver restart that shortens the part while later pieces
of the window are in flight produces a gap. Before phase 1 is built, `Sender.p`
should gain a windowed pass, and the existing specs (`PartIsAlwaysAPrefix`,
`OnlyTheDescribedBytesAreStored`, `EveryTransferEnds`) should hold over it, with a
probe that reaches a gap. Whether that model is extended to cover the session
importer's `take` as well as `state_transfer.take`, or the session move gets a
model of its own, is an open question.

## Phase 2: an incremental move

Build this only if moves back and forth are common. We do not know that they are.
The evidence to collect first is how often a session's move chain returns to a
daemon that held it before, and how large the session file is at the return. A
first move gains nothing, because the receiver holds nothing of the session. The
gain is on a move back, and it is the size of the part of the file that existed
before the first move.

### What the receiver can hold

The retirement renames the source's original to `<id>.db.moved`
(`session_mover.gleam:1250-1251`), after releasing the move's lease row
(`session_mover.gleam:1247`). That file is a complete, closed copy of the session
as it stood at the cut. We found no code that deletes it, and we did not look for
operator tooling that does, so the base can be gone and the protocol must not
assume it is there.

The conversation store has three parts (`docs/architecture/durability.md:20-22`).
Entries are written once and form a tree through `parent_id`. Usage rows are
appended. Registers are the one mutable part: a write replaces the cell, and a
deleted cell is indistinguishable from one that never existed
(`durability.md:164-166`). One counter, `seq`, increases strictly across all three
kinds of write (`durability.md:153-157`), and the schema stores it with every entry
and register (`storage/session_schema.gleam:6`).

Two facts about that store decide the shape of the transfer. First, a move gives
the session one writer at a time. The intent stops the slot before anything is cut
(078, "Who owns the session at each moment"), so the source's file is quiet from
the intent, the copy is cut from it, and nothing opens `<id>.db.moved` afterwards.
So a base held from an earlier hop contains exactly the entries and usage rows with
`seq` at or below its own highest `seq`, and the current file contains the same ones
with the same ids, parents and payloads, plus later ones. Second, "entries are never
modified" has one sanctioned exception. A precise rewrite, used for erasure, keeps
ids, parents and seqs and replaces payloads, and it increments a `generation`
counter in the session metadata (`durability.md:559-603`, `sqlite.generation`). An
entry id that matches therefore does not show that its payload matches.

### Have and want

You might expect the receiver to report the leaves of the tree it holds, with the
source sending every entry that is an ancestor of one of its own leaves and not of
the receiver's, as Git does. The workspace transfer is the model for that:
`choose_basis` takes the sender's candidate commits and the receiver's held ones
and thins the bundle against the newest shared one (`state_object.gleam:365-370`).
Git needs the negotiation because two clones can diverge. A session cannot
diverge, by the single-writer argument above, so the leaf frontier of the receiver
is always an ancestor-closed prefix of the source's file, and `seq` names that
prefix with one integer. We propose that the receiver reports a pair, its
`generation` and its highest `seq`, and the source sends everything above it.
The result is the same set that the leaf negotiation would compute, without the
walk. If divergence ever becomes possible, for example by a path that opens the set
aside file, the negotiation by leaves is the fallback, and we do not build it now.

The exchange is exact and involves no estimation:

1. The source asks which base the receiver holds for the session. The receiver
   answers `generation` and highest `seq`, or nothing.
2. The source compares. A different `generation` means a precise rewrite happened
   since, no base is usable, and the transfer is the whole file of phase 1. A
   highest `seq` above the source's own is also unusable.
3. Otherwise the source sends the entries and usage rows above that `seq`, every
   register, and the session metadata, together with the prefix digest below.
4. The receiver recomputes the prefix digest over its own base, and builds a new
   file beside the base. A mismatch is a `Refused`, and the source falls back to the
   whole file.

The prefix digest is a SHA-256 over the entries and usage rows with `seq` at or
below the base's highest, in `seq` order, where each row contributes its kind, id,
parent, `seq` and stored payload bytes unmodified. It is one flat hash, not a
Merkle tree. A Merkle structure is useful when two parties need to locate where
they differ, and we never do: a mismatch means no shared base, and we send the file
whole. The digest costs a local scan of the prefix on each side and no network.

Registers are not in the digest and are always sent in full. A register that was
deleted leaves nothing for a delta to name, so the receiver cannot be told to
remove it, and a register cell's `seq` records its last write, not its history
(`durability.md:175`). Sending the register table whole is correct and has the
size of that table, which we have not measured. The scope cell that activation
reads is a register-level fact in the file, so it arrives with them.

### Why the receiver rebuilds and does not patch

We considered two other mechanisms and rejected them.

Set reconciliation, such as an invertible Bloom filter, suits two sets that drift
without any order between them. It needs an estimate of the difference size to
size the filter, and a fallback for when decoding fails. Neither of our sets drifts:
the log only grows at one end, and the receiver's holding is a prefix, so a single
number states the difference exactly. The mechanism would buy generality we have no
case for, and it would add the decode failure that the protocol has to survive.

An rsync of the SQLite file matches blocks. The receiver's pages and the source's
pages need not line up between machines: the cut is a `VACUUM INTO`
(`session_mover.gleam:909-917`), which rewrites the layout, and the receiver's copy
was written by a different vacuum history. We expect poor block matching, and we
have not measured it. More important, a block transfer moves bytes of a database
file that neither side can interpret during the transfer, and it makes the receiver
trust a patched file instead of rows it can verify.

So the receiver reconciles at the entry level and builds its own file: it copies
its base to a part path, inserts the new rows with the source's `seq` values
unchanged (a fork assigns new seqs, `durability.md:540`, and a move must not,
because register `seq` expectations compare against them), replaces the registers,
rebuilds the branch index projection, and renames the result into place at
activation. The base is never modified in place.

### What it costs: a new proof

The move's argument today is one closed file and one digest. The source hashes the
copy it cut, the receiver hashes the bytes it received, and equality means the
receiver holds the bytes the source closed. An incremental transfer breaks that in
two places.

The receiver's rebuilt file is not byte-identical to the source's, because page
layout differs. The end-to-end check therefore has to be a logical digest: the same
canonical hash over every entry, usage row and register of the whole content,
computed by the source over its cut and by the receiver over its rebuilt file, and
carried in the `Activation` in place of the byte digest on this path
(`session_move.gleam:194-211`, checked at `session_importer.gleam:530-533`).

The second is that the receiver's base is now an input to what the receiver
activates, so the receiver must show that the base is a prefix of the source's file
before it appends. That is the prefix digest above. Together, the two checks say
that the rebuilt file holds the source's rows, and that it started from rows the
source also holds.

The formal model that must change is `protocol/models/session-move`. `Move.tla`
has no second move (its README says so under "What is modelled"), and the
incremental transfer only exists on a move back, so the model needs the return move
first. `KhepriMove.tla` already models op 1 from A to B and op 2 from B back to A
for directory members. The new content is a variable for the base that the receiver
holds after a retirement, which a retention sweep may drop at any step, and a
`copy` that is `sent` as a delta over a base. The invariant that must hold is that
a base is only appended to if it is a prefix of the source's cut, so `b = active`
still implies a complete copy, and the complete copy is the source's content and
not a stale one. The mutations that show the rule is needed are a receiver that
appends without checking the prefix digest, and a source that ignores a changed
`generation`. Both should be caught by the invariant and not by the whole-content
digest alone, because the whole-content digest would catch them only at activation,
after the work is done.

Blobs need no part in this transfer. The overflow of a large tool result is stored
content-addressed under `<state>/blobs/<session>` on the executor, outside the
session file, and a close leaves it in place (`docs/architecture/distributed.md:87-93`).
The move already carries only the file: `session_move`, `session_mover` and
`session_importer` have no blob handling, and the receiver attaches to the same
executor. That holds for a session that lives on an executor. We have not checked
where the blobs of a session that began as a local checkout live after the
checkout step, and the question applies to the move today and not to this change.

## Impact

Phase 1 adds `window` and the new fields to `client/session_move`, a windowed loop
in `client/session_mover`, a digest-keyed part file and a `Partial` answer in
`client/session_importer`, and two revisions in `client/remote/peer_service`
beside the callbacks that serve them. It adds no `loom.toml` key and no client
control command. The legacy `Import`, `ImportStatus` and `Activate` and their
module docs stay, since they are the fallback. The P model of `state-transfer`
gains a windowed sender. `docs/architecture/distributed.md` and the 078 addendum
get a pointer to this document.

Phase 2 adds a base lookup on the receiver, the prefix and whole-content digests,
the row-level rebuild, and the model work above. It changes what activation
verifies on the incremental path, which is the most security-relevant step of a
move, so it should not ride along with phase 1.

## Open questions

Is the peer service the right carrier for a 256 KiB binary piece, with the base64
cost, or should the legacy port take new constructors and keep the same-build rule?
This changes the older-peer behavior from a clean fallback to a stall.

Is 8 the right window? We did not measure the receiver's append time, the link's
round trip, or the port's other traffic, and the value is a placeholder until the
two-box setup has numbers.

Should the loop of `state_transfer.transfer` be extracted so that the session move
and the state transfer share it, and `state_transfer` gains the window too? It is
also one piece in flight (`state_transfer.gleam:619-635`).

Should the P model of `state-transfer` be extended to the session importer, or
should the move have a model of its own?

Does the second cut of one file produce the same bytes as the first? If it does,
the digest in each piece is less needed, and if it cannot be made to, the digest
stays.

Is `<id>.db.moved` ever deleted, and by what? Also, `set_aside` removes the
original's `-wal` and `-shm` files (`session_mover.gleam:1295-1296`); we have not
checked that a clean close always leaves the main file complete, and a base that
lost frames would fail the prefix digest and cost a full send, not a wrong file.

How large is the register table of a long session, since phase 2 sends it whole?

Do moves back and forth happen often enough to build phase 2 at all? We have no
count. Phase 1 alone removes the restart from zero and the per-piece round trip for
every move, and phase 2 benefits only the returning ones.
