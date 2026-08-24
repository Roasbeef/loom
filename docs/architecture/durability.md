# The durability plane

A Loom session is a conversation that survives having its process killed at
any instant. The durability plane is what makes that true: three stores,
one atomic commit primitive, and two interchangeable backends behind a
single interface. It knows nothing about models, tools, or sandboxes — it
stores rows and answers queries, and everything above it is built out of
those two operations. What follows is the plane as built, in the `core` and
`storage` packages, plus the conformance suite that decides whether a
backend is correct.

## The three stores

Every durable payload in a session lives in exactly one of three stores.

```
  entries    the conversation tree     write-once, never modified
  registers  current mutable state     namespaced cells, replaced in place
  usage      the cost ledger           append-only rows
```

**Entries** are the conversation itself. An entry is a complete stored row
— its placement (`id`, `parent`, `seq`, `ts`) and its payload together — so
a read returns exactly what was committed, with no materialization step and
no join. There are four kinds — message, compaction, branch summary, and
custom — of which the plain message is by far the most common:

```gleam
MessageEntry(id:, parent:, seq:, ts:, message: AgentMessage, terminate: Bool)
```

A `CompactionEntry` is a self-contained checkpoint: it carries the complete
retained suffix of the conversation rather than a pointer back into
history, because context assembly never reads past a compaction. A
`BranchSummaryEntry` records what an abandoned branch contained. A
`CustomEntry` carries an application payload under a named type, and that
name is structural — branch queries filter on it without touching the
payload.

**Registers** are the only mutable store: cells addressed by a namespace
and a key, where a write replaces the previous value and keeps no history.
The namespace set is closed, and each namespace fixes the shape of its keys
and the type of its values — `strand.leaf` is keyed by strand name and
holds an entry id, `op.state` is keyed by operation id and holds that
operation's complete current state, `pending.entry` is keyed by a reserved
entry id, `fact.*` is the shared blackboard. Ownership is baked into the
key structure, so almost no cell has two writers. The rich value types
those namespaces imply belong to the orchestration plane, so a register
value is stored as a tagged JSON payload and decoded by its owning package;
storage never needs to understand an operation state to write one.

**Usage** is an append-only ledger of cost rows, each optionally naming the
entry it belongs to. It is the billing source of truth.

Everything else that looks like state is a *projection*: derived,
rebuildable, carrying no authority. The session statistics and the SQLite
branch index are both projections, and where a projection disagrees with
the store it derives from, the store is right — which is why the
conformance suite checks statistics against the ledger sum after every
single commit.

## The tree, branches, and strands

Entries form a tree, not a list. Each entry names its parent or is a root,
and a parent that does not exist is corruption rather than a dangling
reference. Two entries may share a parent; that is what branching is, and
nothing is rewritten to make room for it.

A **branch** is not a stored object but the path from an entry back to the
root, computed on demand. The `BranchScan` query walks that path in a fixed
pipeline: order it (newest-first by default), stop *inclusively* at the
first entry matching a stop condition, filter by kind or custom type, apply
an exclusive seq cursor for paging, then apply a row limit. The stop
truncates the path before the filter and the cursor see it, so a scan never
runs past its stop to fill a page — the compaction that ends a context
window ends the scan even when a filter would have dropped that compaction
from the results.

A **strand** is a named line of work: the main conversation, a subagent, a
parallel attempt. Strands are processes in the orchestration plane, but
their durable footprint lives entirely in registers — a cursor into the
tree in `strand.leaf`, plus configuration and machine state. Spawning a
subagent at an arbitrary point in history is therefore a new strand name
whose leaf register points there: the tree is shared, the cursors are not.

## Identity

Every durable id — entry, usage row, operation — is a UUIDv7: 48 bits of
Unix-millisecond mint time, then version and variant bits, then 74 bits of
randomness. The mint time therefore reads back out of an id without
consulting storage; the canonical lowercase text form sorts
lexicographically in mint order, making an id a stable tiebreaker wherever
rows are ordered by text; and an id can be minted *before* the row it names
exists, which lets a transaction reserve an id for output not yet produced.

Minting is pure. A `Generator` threads two injected inputs — a `Clock` and
a seeded SplitMix64 state — through every mint and returns a successor
generator the caller must thread onward. Two generators built from the same
clock and seed produce identical id sequences, so a test wanting
reproducible ids passes a constant while the runtime seeds from real
entropy. Nothing in `core` reads a system clock or a random source itself.

Tool results are the one special case, minted with `mint_follower`, which
copies the leader's 48-bit time prefix and draws a fresh random tail:

```gleam
pub fn mint_follower(generator: Generator, of leader: EntryId) -> #(EntryId, Generator)
```

An assistant message and the results of its tool calls therefore stay
contiguous under id order even when a slow tool pushes a result into the
next second, or the next day.

Ids are minted; `seq` is not. A **seq** is a sequence number assigned by
storage at commit, strictly increasing within a session. Ids say when
something was created; seqs say in what order it became durable, and that
is storage's word alone.

## Transactions

A transaction — an ordered list of writes plus a list of expectations — is
the unit of durability. There are four kinds of write:

```gleam
pub type Write {
  InsertEntry(entry: Entry)
  InsertUsage(row: UsageRow)
  SetRegister(ns: RegisterNs, key: String, value: RegisterValue)
  DeleteRegister(ns: RegisterNs, key: String)
}
```

Five rules govern every commit, and both backends enforce all five.

**All or none.** No reader ever observes a state in which some of a
transaction's writes exist and others do not. A transaction whose third
write names a duplicate id leaves the first two undone.

**Writes apply in order; seqs increase strictly.** Each write consumes the
next seq, in write order — so an entry may name a parent inserted earlier
in the same transaction. Gaps are legal and normal: a transaction that sets
a register between two entry inserts leaves those entries with non-adjacent
seqs. Rely on monotonicity, never on adjacency.

**Write-once means write-once.** Entries and usage rows share one
session-wide id namespace, and writing either kind under an existing id is
corruption, not an update. The `seq` and `ts` fields inside an
`InsertEntry` are placeholders that storage overwrites at commit.

**Registers replace.** A set overwrites, a delete removes, deleting an
absent cell is a no-op, and a deleted cell is indistinguishable from one
that never existed.

**Expectations are checked first** — the subtle rule, which gets the next
section to itself. And whatever the reason for refusal, a failed commit
consumes nothing, not even seqs: a session that rejected a hundred
transactions is byte-for-byte the session that never saw them.

## Expectations: optimistic concurrency, made concrete

Every register cell remembers the seq of the write that last set it, and a
transaction may name the seqs it computed against:

```gleam
pub type SeqExpectation { Expect(ns: RegisterNs, key: String, seq: Option(Seq)) }
```

`Some(n)` means *this cell must still be at seq n*; `None` means *this cell
must not exist*. Storage evaluates every expectation against the
pre-transaction state before applying any write, and a failure returns
`StaleExpectation` naming the first one that did not hold, with nothing
applied. This is compare-and-swap — read a value, do some work, commit only
if nobody changed it meanwhile — over a set of cells, fused into the same
atomic step as the writes.

The pattern it protects is worth seeing whole. Queued input is staged into
a `pending.entry` register keyed by an entry id reserved in advance, and
later *placed*: turned into a real entry, removed from the queue, and made
the strand's new leaf — all in one transaction.

```gleam
Tx(
  writes: [
    InsertEntry(queued),
    DeleteRegister(register.PendingEntry, queued_key),
    SetRegister(register.StrandLeaf, "main", register.leaf_value(Some(queued.id))),
  ],
  expected: [
    Expect(register.PendingEntry, queued_key, Some(staged.first_seq)),
  ],
)
```

The expectation says: place this only if it is still the item I staged,
unchanged since seq `staged.first_seq`. Suppose a strand staged the item,
crashed, restarted, and the queue moved on while the old attempt was still
in flight. Without the expectation, that stale attempt would insert an
entry whose content no longer matches the queue and delete a pending value
it never wrote — two rows that quietly disagree, discovered much later if
ever. With it, the stale commit is refused; the strand reloads, sees the
world as it now is, and replans.

The invariant preserved is one the orchestration plane leans on: at every
commit boundary a queued id has a register *or* an entry *or* neither,
never both. Because the insert, the delete, and the leaf move are one
transaction guarded by one expectation, there is no instant at which both
exist, and none at which the leaf points at an entry never placed. A
transaction with no writes and only expectations is legal too, making a
bare assertion about the world a commit like any other.

## One writer

Concurrency here is handled by not having any, enforced twice over. Inside
the node, both backends are actors: every commit and every read is a
message to one process, and ordering is mailbox order. "Transactions on one
session are serialized" is therefore structural rather than a rule someone
must remember. The intended owner is the runtime's single storage-writer
process; even under accidental sharing, two callers cannot interleave
inside a transaction, and expectations catch the interleaving they *can*
have.

Across OS processes the actor guarantees nothing, and write-ahead logging
happily lets two processes alternate writes to one file. So the SQLite
backend adds a **fenced lease**: a row naming the current owner, a
monotonic fence number, and an expiry. Opening a session file acquires the
lease, and while a live lease is held `open` refuses with `LeaseHeld`,
naming the holder. Once it expires the newcomer steals it and *bumps the
fence*, which is what makes the old holder harmless: every commit re-reads
the lease inside its own transaction and proceeds only if the stored
`(owner, fence)` pair still matches its own, so a fenced-out writer that
wakes up and commits gets `Faulted` and applies nothing. Symmetrically,
`close` deletes only the writer's own pair, so a stale owner shutting down
cannot release its replacement's lease; an idle writer keeps ownership by
renewing on a timer. The conformance suite duels two writers through
exactly that sequence, down to checking that the refused commit left no row
behind.

## The two backends

Both backends implement one interface — a record of functions over an
opaque handle — so callers are written once: `commit`, `get_entries`,
`get_register`, `list_registers`, `scan_branch`, `scan_entries`,
`scan_usage`, `stats`, `close`. Commits fail with `CommitError`
(`StaleExpectation`, `Corruption`, `Faulted`); reads fail with
`StorageError` (`CorruptRow`, `UnknownEntry`, `BackendFault`,
`HandleClosed`). Closing is idempotent, and a closed handle answers in-band
rather than crashing the caller.

### Memory

The memory backend is the storage model written as pure data
structures: a `MemoryState` of entries, a children index, registers, the
ledger, the statistics projection, and the next seq. Every mutation is a
pure function returning either a fully applied successor state or an error
and no state at all, which is what makes all-or-none trivially true here. A
thin actor wraps that state to provide the handle and thread the injected
clock; branch scans walk parent pointers and hand the path to the same
refinement pipeline SQLite feeds from its index.

### SQLite

The SQLite backend keeps one database file per session. The file *is* the
session: corruption is confined to it, deleting a session is unlinking a
file, and moving a session between machines is copying one.

```sql
entries(id PK, parent_id, seq, type, custom_type, ts, payload) WITHOUT ROWID
registers(ns, key, seq, value, PRIMARY KEY(ns, key))
usage_ledger(id PK, seq, entry_id, adjustment, usage, details) WITHOUT ROWID
branch_entries(branch_id, entry_id, entry_seq, entry_type,
               PRIMARY KEY(branch_id, entry_id)) WITHOUT ROWID
branch_meta(branch_id PK, tip_entry_id, tip_seq, base_branch_id, base_seq)
session(created_at, storage_version, message_count, usage_payload, next_seq, ...)
writer_lease(owner_id, fence, expires_at_ms)
```

Payloads are JSON blobs; the columns beside them are exactly the fields
queries filter and order on, so no plan decodes a payload to decide whether
it wants the row, and indexes cover those columns — parent and seq on
entries, seq on the ledger, three on the branch index, and a unique index
giving a tip entry at most one segment. The single `session` row carries
both the seq allocator and the statistics projection.

Two operational settings are not negotiable. The journal mode is WAL, so
readers never block the writer. And every transaction opens with `BEGIN
IMMEDIATE`, because allocating a seq range reads `session.next_seq` before
writing it: a deferred `BEGIN` would take a read snapshot it might be
unable to upgrade, and a busy timeout cannot rescue that.

### The segmented branch index

Walking parent pointers is fine in memory and unacceptable in SQL, where it
costs one query per ancestor. The SQLite backend therefore maintains a
private index of **segments**. A segment is a run of the tree: rows in
`branch_entries` tagged with a segment id, plus a `branch_meta` row naming
its tip and, optionally, a **base** — another segment and a seq through
which that segment's contents count as this one's. A segment logically
contains its own rows above the base seq plus everything the base covers
below it.

Appending at a tip is one insert and a tip update. Diverging is the
interesting case: the new segment copies rows from the parent back down to
the newest compaction on that path, links its base to the segment it
diverged from at that compaction's seq, and leaves everything older
reachable through the link. Bounding the copy at a compaction keeps the
index from growing quadratically with branching, and is safe precisely
because a context scan stops at the first compaction anyway.

```
  entries:   e1 ─── e2 ─── c3 ─── e4 ─── e5        (c3 is a compaction)
                                    └──── f6

  segment b1   rows: e1 e2 c3 e4 e5     tip e5   base: none
  segment b6   rows: e4 f6              tip f6   base: b1 through c3
```

A scan from `f6` reads b6's rows down to c3's seq, then continues in b1
from c3 toward the root. Two rules make that correct, and both are easy to
get wrong:

1. **A base must cover the anchor within its own logical range.** Finding
   the anchor in a base's *ancestor* is not enough; the chain would then
   claim a range it does not hold. The code satisfies this by construction,
   resolving the covering segment through a *physical* `branch_entries` row
   for the parent, which always lies inside that segment's own range.
2. **The search for the newest compaction must traverse the base chain.**
   Checking only the newest physical segment can miss a compaction living
   in a base, and the new segment would then copy too much or link at the
   wrong boundary. The search walks segment by segment with a shrinking seq
   cap until it finds a compaction or reaches the root.

A cyclic base chain is reported as corruption rather than looped over.
Scans page through segment windows, decode only rows the pipeline can still
emit, and stop once the limit is met — so reading the newest fifty entries
touches roughly fifty rows however long the session is.

### Query plans as an enforced contract

An index the planner declines to use is not an optimization; it is a table
scan with extra bookkeeping. So the plan is part of the contract. The
segment page query reads `FROM branch_entries b CROSS JOIN entries e ON
e.id = b.entry_id`, and the `CROSS JOIN` is load-bearing: it forces
`branch_entries` to be the outer loop, making the plan a covering index
search plus a primary-key probe into `entries`. The backend exposes the
`EXPLAIN QUERY PLAN` output and the conformance suite asserts on it —
first step a covering search on `ix_be_seq`, `entries` probed by key, and
any `TEMP B-TREE FOR ORDER BY` or scan of `entries` fails the build. A
schema change that quietly loses an index is then caught by CI, not by a
slow session months later.

## Parse fully, or report

Every durability boundary decodes with a **total decoder**: a function
returning either a fully constructed value or a structured
`CorruptionReport`, never crashing and never half-succeeding. A report says
where the bad data was met, which key or offset it concerned, what a
well-formed value would have looked like, and an excerpt of what was there
instead. Reports are plain data, so they can be logged, stored, and passed
across process boundaries.

The rule holds at the four boundaries the plane owns: the JSON parser and
codecs for entries, registers, and ledger rows; the msgpack codec for the
effect-plane framing protocol; id text parsing, which rejects anything that
is not a well-formed UUIDv7 with the right variant bits; and the closed
namespace and entry-kind vocabularies, where an unknown name is corruption
rather than a value to ignore. It holds for *our* boundaries only.
Third-party wire formats are read leniently, because strict decoding of a
foreign vocabulary breaks against real proxies and gains nothing. The line
is ownership: data we wrote must decode exactly as written, or it is
damaged and we say so.

## After a crash

A transaction is atomic in both backends, so a crash lands before or after
a commit, never inside one: there is no torn write to detect, no journal to
replay by hand, no inference from absence. And nothing in this plane runs
an effect — it stores the record that an effect is about to happen and,
later, the record of how it settled, so a crash between the two leaves the
first record for recovery to find.

Recovery then reconstructs nothing. It reads a handful of registers by key
— the strand's state, leaf, and configuration, and the current operation's
metadata and state — validates the entries and registers they name, and
resumes. Register reads are the cheapest thing the store does, which is why
the durable program counter is a register and not a log.

A file-backed session adds two steps at restart. WAL recovery restores the
file to its last committed state, and the lease decides who writes next:
the crashed process's lease expires, the new process steals it with a
bumped fence, and any zombie writer from before the crash is refused at its
first commit.

## The conformance suite is the definition of correct

"Correct" here is not prose; it is `conformance/storage_suite`, one suite
parameterized over a backend constructor and run against both. A backend
that passes it is a backend, and adding a third means writing an `open`
function and running the suite.

What it proves: all-or-none atomicity, including that a failed transaction
leaves no trace and consumes no seqs; strictly increasing seqs with legal
gaps, and write order within a transaction; the shared id namespace, where
any duplicate is corruption; register set, replace, delete, delete-absent,
recreate, and prefix listing; the full expectation matrix, from
expect-absent on a present cell to several expectations guarding one
commit; the placement pattern end to end; branch scans across ordering,
stops by kind and by id, filters, cursor paging, limits, and the
interaction of stop with cursor; entry and ledger scans with catch-up reads
from a persisted high-water seq; statistics equal to the ledger sum after
every commit; and close semantics.

The hardest clause is a branching torture script: after every commit,
*every* entry ever written must scan to exactly its root path, which the
suite tracks independently by parent pointers. Stale branches therefore
stay valid, and chained segments yield the exact ancestor chain with no
gaps and no duplicates. Three further checks are SQLite-only, being about
the file rather than the model: the writer-lease duel, the query-plan
assertions, and the branch-index metadata invariants (one segment per
divergence, unique tips, every base naming a live segment strictly below
its own tip).

A perf smoke test rounds it off: build a 10,000-entry single-strand
session, scan the newest 50 entries twenty times, report the median. In the
development container that is **p50 ≈ 2.1 ms, worst case ≈ 2.5 ms**,
against the milestone target of p50 under 5 ms. It prints rather than
fails, since a shared container gives no stable millisecond guarantees
worth hard-failing on, but it is the signal that the segmented index works:
the number barely moves as the session grows, because a scan reads a window
rather than a history.

## Where the code lives

| Path | What it holds |
|---|---|
| `core/ids.gleam` | Opaque `EntryId`/`UsageId`/`OpId`, the injected UUIDv7 `Generator`, follower minting, `Seq`. |
| `core/clock.gleam` | The injected time capability: real, fixed, and stepping clocks. |
| `core/entry.gleam` | The four `Entry` variants and `UsageRow`, with their invariants. |
| `core/register.gleam` | The closed `RegisterNs` set, `RegisterValue`, and the leaf codec. |
| `core/message.gleam` | The `AgentMessage` family and the `Usage` cost shape. |
| `core/tx.gleam` | `Write`, `Tx`, `SeqExpectation`, `CommitResult`, `CommitError`. |
| `core/json.gleam` | A pattern-matchable JSON value with a total parser and serializer. |
| `core/codec.gleam` | Total JSON codecs for every durable type. |
| `core/msgpack.gleam` | The canonical msgpack subset the framing protocol uses. |
| `core/corruption.gleam` | `CorruptionReport` and its constructor. |
| `storage/storage.gleam` | The backend-agnostic handle, the scan query types, the commit rules. |
| `storage/memory.gleam` | The pure `MemoryState` model plus its actor wrapper. |
| `storage/sqlite.gleam` | Schema, lease, commit path, segmented index, plan introspection. |
| `storage/internal/branch.gleam` | The shared stop/filter/cursor/limit pipeline. |
| `conformance/storage_suite.gleam` | The suite that defines correctness. |

Each path is relative to its package's source root — `core/ids.gleam` is
`packages/core/src/core/ids.gleam`. For intent and contracts,
`docs/loom-design.md` §3 covers this plane's place among the three planes,
`docs/loom-implementation-spec.md` Part 1.1–1.2 holds the frozen
interfaces, and `docs/spec-gaps.md` records where implementation refined
the spec.
