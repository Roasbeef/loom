# protocol-change/072: a strand's history is read along its own parent links

**Status**: ACCEPTED 2026-10-06 · **Affects**: the client protocol (one new
command, `history_lineage`, and one new transfer window, `lineage`), the
snapshot reader in `storage/snapshot`, and the way the web view reads a strand ·
**Raised by**: the web UI critique of r6g and r6i (F162, F166, F167, F171) ·
**Implemented**: storage, client daemon, session view, web view

Amends [071](071-web-turn-summaries.md): its scan reads the strand's ancestry
through this command and no longer through intervals of the session's sequence.
Spec Part 1 is unchanged. The frozen `Storage` record gains nothing, and the
snapshot reader, which sits beside it, gains one read.

## Problem

The daemon's `history` read returns an interval of the session's sequence, at
most a hundred positions, and every strand's records in it. A page that wants one
strand's turns therefore walks the sequence downward, keeps the records of the
strand's own ancestry and drops the rest. How far that walk has to go depends on
how much the other strands wrote between the strand's records, which nothing
bounds, and each fix moved the place where it ran out.

A turn of 130 or more parallel calls (four messages of 33 calls, five of 31)
reloaded as a lane holding nothing but "Load older", because the walk stopped in
the results of its last message and did not complete the turn. A strand sparse
among the session's sequences (the main strand after the advisor wrote 2,400
records) needed 26 presses of "Load older", eight intervals each, and the 26th
ended on "Beginning of this conversation." over an empty lane. The advisor's
older reviews took 13 seconds of reads and drew nothing. A read budget, a barren
count that ended a walk after eight reads that found nothing, and a cursor that
resumed it, were each a patch on that walk, and each had a shape it did not
cover.

## Considered

**Raise the interval or the budget.** A larger interval makes the reads fewer and
each of them larger, and leaves the walk's length a function of the other
strands. The budget would only decide where it fails.

**A turn index computed by the daemon.** The request was for a compact index
beside the page: for each turn, its input record, its first and last sequence,
its steps, its duration and its ending, so that a page could draw dividers and
page by turns without reading every step. The daemon does not know what a turn
is. What opens one is `session_view/turns.entry_kind`: a person's message, an
advisor's advice or nudge, a feed, a goal feed, a continuation, a message from a
peer or a sibling, with the memory context the daemon attached ahead of a prompt
excluded, and what counts as a step, a file or a failure is decided beside it
(`turns.worked`). The records carry none of that in a column. A count needs every
payload of the turn decoded by an actor that serves every attachment (the
objection 071 made to counting steps in the daemon), and a second classifier in
the daemon would have to agree with the first for the figures on a divider to be
the same on a page that watched a turn and a page that opened after it, which 071
holds as a property. The cost this index would remove is not the cost that failed
here. A turn of 570 calls is a thousand records and the page reads them in a
dozen pages once, when it closes the turn into its summary
(`turn_ledger.Sealed`), and keeps the figures. What failed was the cost of
finding the strand's records among the others', and the lineage read removes
that. The page's summaries are the index, built once from the records a read
returns, and the daemon stays a reader of bytes.

**A daemon read keyed by the strand's name.** The daemon holds the strand's leaf
in the cut's metadata and could resolve it. It would then hold a second
definition of a strand's ancestry beside the page's, and the page would still
need the leaf to know where its own records end. The page already has the leaf
(`snapshot_view.View.leaves`) and the parent of any record it holds, so the read
names an entry. The strand is a path, and a path is named by where it starts.

**A recursive query.** One statement would walk the chain. `sqlc`, which
generates the module (ADR-004), cannot generate a recursive query over its own
name, so the walk is a loop in Gleam over a primary-key probe of `entries` by
identity (`SnapshotEntryHead`). It is up to a hundred probes inside one dispatch
of the storage actor, each an index lookup, and the plan is asserted.

**A branch-index read.** `branch_entries` lists the entries of a branch by
sequence and has no parent column, the objection [066](066-entry-heads-scan.md)
made to it, so a walk would still need `entries`, and the index is keyed by a
branch, which is not a strand.

## Decision

**Accepted.**

*The command.* `history_lineage` carries one field, `from`, the identity of an
entry. The reply is the credited transfer every bounded read uses: a
`snapshot_begin` with `window` `lineage`, the metadata, one record per
descriptor, and a `snapshot_end`. The records are the entries on the path from
`from` down their parent links, oldest first as a `history` page is, so the
client's reassembly sees ascending sequences whichever read produced them. The
newest record of the page is `from` itself. A client names a strand by its leaf
and pages by naming the parent of the oldest record it holds, so the transfer has
no cursor and `more_after` is always null. A `from` that is not an entry identity
is refused with `bad_request`; an entry the store does not hold, or one at or
above the high-water the transfer was captured at, has no records and the page is
empty.

*Bounds.* A page holds at most 100 records (`snapshot.page_limit`, the bound of
every descriptor page) and at most 2 MiB of payload past its first record
(`snapshot.lineage_bytes_limit`). The first record is always returned, so a
record larger than the byte bound still has a page, and a walk cannot stall on
it. A record over the 32 MiB record limit is refused as it is in a `history`
page. Each step asks for an entry below the sequence of the one before it, so a
corrupt parent link ends the walk and cannot loop it. The capture that opens the
transfer uses an empty plan, so it copies no registers and the metadata it sends
is the roster and the queue only.

*Where the walk lives.* `snapshot.lineage` owns the walk and these bounds, and a
backend supplies only the step. `snapshot_sqlite.lineage` probes `entries` by
primary key. `snapshot_memory.lineage` reads the entry map. The reader record
gains a `lineage` field beside `capture`, `page` and `fragment`. The two backends
construct it, and the one test that rebuilds it spreads the record. The
transfer gains a `Lineage` window, a `ReadLineage` step funded as `ReadPage` is,
and `accept_lineage`, which checks that the page ascends, stays below the
high-water and holds no more than a page.

*Authority.* The command is in the read-only set. An observer's attachment may
issue it, and the page's relay checks the attachment at every frame
(`ui_relay.while_open`) exactly as it does for `history`. Naming an entry
reveals nothing an interval of `history` over the same sequences does not: that
read already returns every strand's records to any attachment. The daemon does
not check that `from` is a strand's leaf, and no check could mean anything, since
a strand's leaf moves and a client pages by naming parents. No value of the
browser's event reaches the read: the page chooses `from` from its own summaries,
as it chose the interval before.

*What the client does with it.* `session_channel.lineage` sends the read on the
lane's one request slot, and the reply arrives as `LineagePage`, which the
channel checks (the window `lineage`, and a newest record that is `from`) before
the page sees it. The history window's scan (`history_view.scan`, 071) reads
through it. A scan that lacks a parent owes a read from that parent
(`Owed(from)`), the lane sends it when the window has no demand of its own, and
the reply joins what the scan holds. A reply to a read the scan did not ask for is
ignored. A scan ends at the strand's first record, at its bound (4,096 records and
32 MiB), at a record over the presentation limit, or when a read adds no record it
did not hold (`Bottomed`), which keeps a read of an entry the store lacks from
being asked for twice. The window's own interval read stays for the terminal,
which pages with it. A recorded session replays a lineage read as it replays any
other (`attempt.LineageFrom`).

*What the page no longer needs.* The scan's read budget (`scan_barren`,
`scan_floor` and the count of barren reads), the cursor that resumed it
(`View.resume`, `paused`, `lowered`), and the sequence the next interval started
below, are removed. The stopping rules a read applies to what it found are
unchanged: a turn is whole when its input is among the records, a press of "Load
older" reads until ten whole turns, and a fold reads until its newest hundred
rows. A turn of any length is complete when the reads reach its input.

*Words.* While a page has not received its first cut it says it is loading, and
says "Beginning of this conversation." only when a read of the strand found it.
A decision is drawn only beside a record, so a page that has read none of a
strand's records draws no decision alone.

## Costs

The daemon gains a command and a transfer window that older clients do not send.
A daemon that lacks the command answers `unsupported`, and the page offers "Load
older" again as it does for any refused read. A client that sends it to an older
daemon sees that refusal and nothing worse.

A walk is up to a hundred probes inside one dispatch of the storage actor, within
the reader's wait of five seconds, where an interval was one query. Each probe is
an index lookup, and the plan is asserted in `snapshot_test`.

A turn of 570 calls is still read in about twelve pages when the page closes it,
and a page of large results holds fewer than a hundred records, so the reads are
more. The page waits for them in sequence and keeps no more than its bounds.

A strand whose parent is a record over the presentation limit still ends the
walk there. The page cannot read that record's parent, and the descriptor does not
carry it. The descriptor would have to name its parent, which is a wire change
and is not made here.

The daemon computes no turn figures. A page that did not close a turn cannot say
its steps without reading them, as before.
