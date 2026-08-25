# Events, projections, and search

A session's durable log answers every question about that session
eventually, and none of them quickly. "What just happened" means finding
what is new since you last looked. "What is this session costing" means
summing the whole ledger. "Which conversation mentioned the auth migration"
means decoding every entry of every session on disk. Each answer is a fold
over rows the store already holds, and recomputing it on every ask is what
the `events` package exists to avoid.

The answer is the **projection**, which `docs/architecture/durability.md`
already names: state derived from the log, rebuildable, carrying no
authority, and losing to the log wherever the two disagree. What follows is
how that is made true in a running system — how a read model learns that
something changed, how it catches up without skipping a row, what becomes
of it when the history underneath it is rewritten, and what a full-text
index over a whole repository of sessions can and cannot find. Three things
live in the package — an event bus, a projection driver, and a search
service — and one rule governs all three.

## Events are hints; pulls are truth

An event on the bus never carries the thing that changed. It carries an id,
a seq, and sometimes a display label, and it means only *go look*. Every
read model converges by scanning the store from a cursor it persisted
itself, so an event that never arrives costs a subscriber some latency and
nothing else. Drop every event and each read model still converges on its
next hint, its next explicit sync, or its next restart; the package's
lost-event tests publish a hint for one commit in three and assert that the
projection ends equal to a rebuild from zero.

That rule is what lets the bus be as cheap as it is: process-group
membership plus plain sends, with no acknowledgements, no retries, no
buffering, and no ordering promise beyond what a single Erlang send pair
gives. Nothing in the delivery path can fail in a way that costs data,
because the delivery path never carries data.

The doorbell in `docs/architecture/messaging.md` is the same idea aimed
differently. A **nudge** is point-to-point: a sender that has just
committed a payload for one named strand asks *that strand's* driver to
re-plan now. A bus event is a broadcast on a session topic to whoever
happens to be listening, and the publisher does not know or care who that
is. Both are lossy on purpose, and both are safe for the same reason —
the durable write happened first, and the recipient's own scheduled pull
would have found it anyway.

## The bus

The bus is an OTP `pg` scope named `loom_events`, and that is the whole of
it: no actor, no mailbox of its own, no state beyond `pg`'s membership
table. A `Bus` handle is a compile-time atom in a wrapper. Publishing is an
ETS lookup of one group followed by a plain send to each local member.

Groups are keyed `#(session, topic)`, inside the one node-global scope, so
per-session isolation costs no per-session process and a lookup runs at
local ETS speed. The session key is a caller-supplied string — `core`
defines no session-id type, and the gateway's canonical identifier is still
an open question recorded in `docs/spec-gaps.md`.

There are six topics and six event shapes, one shape per topic:

| Topic | Event | Carries |
|---|---|---|
| `Entries` | `EntryAdded(id, seq)` | an entry id and its seq |
| `Operations` | `OpTransition(op, phase)` | an operation id and a display label |
| `Usage` | `UsageAdded(id, seq)` | a ledger row id and its seq |
| `Strands` | `StrandResult(strand)` | the strand's name |
| `Escalations` | `Escalation(op, description)` | an operation id and display text |
| `Commits` | `Committed(seqs, ts)` | the seqs one transaction consumed |

Three of these shadow a register, and in each case the register is the
truth. `phase` is a word to put in a progress line, not a machine state —
`op.state` holds that, and keeping the event to a string is also what keeps
the `events` package off a dependency on `machine`. `description` is text
to show a human; the durable escalation record under the reserved
`escalation/` prefix is what an approval actually attaches to.
`StrandResult` names the strand that settled and never its result. A
subscriber that reads any of these as data has already lost.

Because each event belongs to exactly one topic, a process subscribed to
all six receives each event once. Subscribing joins the *calling* process,
and `pg` cleans the membership up through its own monitor when that process
dies. `subscriber_count` is an ETS lookup, good for a test or a diagnostic
and never for a decision, since membership moves underneath it.

Subscription is idempotent per `{session, topic, pid}`, and that takes a
guard. `pg` counts multiplicity: a process that joins the same group twice
appears twice in `get_local_members/2`, receives every event twice, and one
`leave` removes only one of the two memberships. So `bus.subscribe` asks
whether the caller is already a member before joining, from the same
single-threaded process that would do the joining, which leaves no window
for the check to race the join it guards. Without it, a driver subscribed
twice does a redundant storage round trip per event and an
`unsubscribe` the caller believes worked leaves a live membership behind.

### The bridge

Nothing in `events` imports the runtime, and the runtime's StorageWriter
publishes its own minimal post-commit notification — an ordinal, the seqs,
a timestamp. `bus.bridge` is the seam between them: it starts an actor
holding a caller-supplied mapping closure, and everything sent to that
actor is mapped to an `Event` and published. The composition layer writes
the closure, because it is the only layer that knows both types.

The closure runs inside the bridge actor and comes from outside the
package, so a closure that crashes crashes the bridge. `actor.start` links
the new process to whoever started it, which would have propagated that
crash to the starter; `bridge` therefore unlinks immediately after a
successful start, keeping the failure local. That matches the promise the
bus already makes everywhere else — if the bridge dies, events are missed
until something restarts it, and missed events are legal. The package ships
no supervised bridge child specification today, so "something restarts it"
is the composition layer's problem, not a solved one.

### Who is on the bus today

The client gateway subscribes to every topic of its session, discards each
payload, and uses the arrival to pull from storage above its own high-water
seq. A projection driver configured with `FromBus` does the same. Those are
the only subscribers.

There is no production publisher. `client/serve` wires the gateway's hints
straight from the runtime writer through `gateway.commit_forwarder`, and
`gateway.default_options` sets `bus: None`. The bridge exists, and it is
tested, but no composition has yet run the writer's publication through it.
The bus as built is a working mechanism with one live consumer path and
no live producer.

The bus inherits `pg`'s ambience. `bus.start` is public and idempotent, and
any process on the node can join any session's groups or publish forged
events into them. Isolation here is by group key, not by capability, and
the node is the trust boundary — which Rule Zero already requires, since
model-influenced code never runs in this virtual machine at all. A second
trap for anyone wiring the bus up: `bus.start` and `bus.supervised` do not
compose. `start` treats an
already-running scope as success, `supervised` treats it as a failure to
start, and a component that calls `start` first turns the supervised child
into a permanent restart loop.

## Projections

A projection is a pure fold and nothing more:

```gleam
pub type Projection(state) {
  Projection(initial: state, apply: fn(state, Change) -> state)
}

pub type Change {
  EntryAppended(entry: Entry)
  UsageAppended(row: UsageRow)
}
```

`apply` performs no I/O and never crashes — a shape it does not recognize
folds as a no-op. Folding the same changes in the same order from `initial`
therefore always yields the same state, and that determinism is exactly
what makes an incremental catch-up and a rebuild from zero provably the
same thing. The package's exit criterion tests both directions: folding
after every commit ends equal to one rebuild at the end, and a rebuilt
`SessionStats` equals the statistics the storage backends maintain
natively.

Entries and usage rows share the session's seq namespace, so the two
`scan_*` reads merge into one totally ordered stream of changes by seq.
`stats_projection()` is the shipped example — it counts message entries and
sums the usage ledger field-wise, which is deliberately the same pair of
figures storage maintains for itself, so the two can be checked against
each other.

### The frontier

`catch_up(store, projection, state, after: high_water)` reads everything
past the high-water and folds it in. The subtlety is that it issues more
than one scan, and the writer may commit between them.

The fix is a **frontier**: before either scan, read the newest committed
seq across both streams, then bound both scans by `(high_water, frontier]`.
Seqs are strictly increasing and rows are write-once, so that window is
immutable by the time either scan runs, and the batch is consistent no
matter what lands mid-pull. Anything past the frontier is the next pull's
work.

Without the bound the loss is silent and permanent. Suppose the entry scan
runs, a commit appends an entry at seq 40 and a usage row at seq 41, and
then the usage scan runs and returns the row at 41. The high-water advances
to 41, and nothing will ever scan the entry at 40 again. The lost-event
test caught precisely that, and `docs/spec-gaps.md` records the rule as
load-bearing and marks it for promotion to a repo-wide convention: **a
catch-up that issues more than one scan bounds every scan by a frontier seq
read before the first one.** The scan order inside `frontier` matters too,
and is right: newest entry first, then newest usage row, so a commit
landing between those two reads can only make the frontier an
underestimate. A short batch is harmless; a skipped row is not.

`rebuild` is `catch_up` from seq zero on `projection.initial`. There is no
second implementation to drift.

### Checkpoints

A driver persists its progress through a `Checkpoint`, which loads and
saves a **triple** — the state, the high-water seq it was folded to, and
the store generation it was folded under. Any one of the three without the
others is meaningless. `ephemeral()` persists nothing and rebuilds every
restart, which is the honest default for a cheap projection.

Saving the state *with* its high-water, rather than the high-water alone,
is what makes a crash safe for a fold that is not idempotent. A crash
between applying a change and saving loses the in-memory state and the
advanced high-water together, so the restart folds those changes again onto
the older state, from the older high-water. No interleaving applies a
change twice.

Persistence itself is best-effort. A checkpoint that loses a write costs a
longer catch-up, never a wrong answer.

### The driver, and what a rewrite does to it

The driver is an actor. It loads the checkpoint or starts from zero,
catches up once, and thereafter pulls whenever it is hinted. `read` returns
the current state without pulling — a local-speed lookup that may lag until
the next hint. `sync` forces a pull and returns the converged state along
with any storage fault. `poke` is the fire-and-forget nudge an external
hint source calls.

Its configuration takes the store and the generation as *functions*, not
values:

```gleam
pub type Options(state, handle) {
  Options(
    store: fn() -> Storage(handle),
    generation: fn() -> Int,
    projection: Projection(state),
    checkpoint: Checkpoint(state),
    hints: Hints,
  )
}
```

Both are called fresh on every pull, and the reason is the precise rewrite
— the administrative operation that erases a leaked secret from a session's
history by rewriting payloads into a copy and swapping it over the
original. Three things follow from that, and the driver handles each one.

**The handle goes stale.** A rewrite swaps the session's store. A driver
that captured a `Storage(handle)` at start would keep reading a stale or
closed one forever, so it asks for the current store on every pull.

**The frontier cannot see the rewrite.** A precise rewrite preserves seq
numbering and replaces payloads. The frontier does not move, so a
checkpointed projection has nothing owed, folds nothing, and serves the
erased text forever — defeating the entire point of the operation. A
rewrite that *shortens* a session is worse: the frontier moves backwards
and every later pull short-circuits on it. So the store carries a
**rewrite generation** counter that the rewrite bumps
(`storage/sqlite.generation`; the memory backend has no persisted
generation, and callers pass `0`). Every pull compares the current
generation against the one the checkpointed state was folded under, and a
mismatch restarts the fold from `initial` at seq zero against the current
store. A fault during that pull leaves the driver's recorded generation
untouched, so a rewrite detected but not yet folded is retried whole rather
than half-adopted.

**A fault on the hint path has nowhere to go.** A `Hinted` cast carries no
reply channel, so a pull failure there would vanish, and a driver reading a
closed handle would serve its last good state indefinitely with nothing
ever saying why. The driver logs the fault instead; an explicit `sync`
still returns it to a caller that is watching.

```mermaid
flowchart TB
    W["StorageWriter"]

    subgraph store["session store — the only authority"]
        E["entries + usage rows<br/>write-once, strictly increasing seq"]
        G["rewrite generation"]
    end

    B(["pg group keyed (session, topic)"])
    K{"generation still the one<br/>this state was folded under?"}
    F["fold seqs above high_water,<br/>up to the frontier, onto the kept state"]
    Z["fold from initial, at seq 0"]
    C["checkpoint:<br/>state + high_water + generation"]

    W -- commit --> E
    W -. "bridge, then publish" .-> B
    B -. "hint: go pull" .-> K
    G --> K
    K -- yes --> F
    K -- "no — a rewrite landed" --> Z
    E --> F
    E --> Z
    F --> C
    Z --> C

    classDef durable fill:#1f5,stroke:#093,color:#000;
    class E,G durable;
```

Solid edges are commits and reads against the store; drop the dashed hint
and the next `sync`, the next hint, or a restart still converges. The
generation edge is the one that makes erasure stick.

The standing rule from `durability.md` holds throughout: where a projection
disagrees with the store, the store is right. Everything above is machinery
for noticing the disagreement.

## Search

Search is a standalone service with its own store. Sessions know nothing
about it. It reads them through the ordinary `Storage` scans and keeps its
index, plus a durable per-session cursor, in one SQLite file per repository
— never inside a session file. The index carries no authority: an indexing
failure cannot affect a commit, and deleting the database costs a re-sync
and nothing more.

The schema is two tables:

```sql
entry_fts(session_id UNINDEXED, entry_id UNINDEXED, text)   -- FTS5 virtual
search_cursor(session_id PK, generation, high_water) WITHOUT ROWID
```

`entry_fts` is a content-carrying FTS5 table, so the index holds a verbatim
copy of the text it indexes. The session and entry ids are stored but not
tokenized — they are there so a hit can name where it came from, and a
caller joins back through the repository it already holds.

### What gets indexed

`entry_text` extracts, per entry kind: the text blocks of a user, assistant,
or tool-result message, joined by newlines; a compaction entry's summary; a
branch summary's summary. Thinking blocks and tool-call arguments are
deliberately excluded, as are images and custom entries. An entry whose
extracted text is empty is skipped — but its seq still advances the cursor,
so a re-sync finds nothing to redo.

### Sync

`sync` pulls a session's entries past the stored cursor and indexes them.
`notify` is the same function under the name the wiring wants: a hint that
one session changed triggers a pull of that session, and a lost hint is
caught by the next sweep. Debouncing for search-as-you-type freshness
belongs in the caller.

The cursor read happens **inside** the same `BEGIN IMMEDIATE` transaction
that writes the rows, and that ordering is load-bearing, not tidiness.
The cursor decides what the call writes — how far back to scan,
and whether to drop and re-index — so reading it before taking the write
lock lets two concurrent syncs of the same session both read the same
un-advanced cursor, both scan the same range, and both insert the same
rows. There is no uniqueness constraint on `entry_fts` to conflict against
and no delete on the incremental path to heal it, so the duplication is
permanent: every later query returns each entry twice, consuming `LIMIT`
and distorting `rank`. Before the fix, five entries indexed as ten.
With the read under the lock, the second sync simply waits its turn and
then reads the advanced cursor. The package's test races a deliberately
slow scan against a fast one, through two real connections to one index
file.

Rows and the advanced cursor commit together, so a crash mid-batch re-runs
the batch into the same state.

### Rewrite invalidation

The cursor is stored with the session store's generation, and `sync` takes
the current generation from its caller. A mismatch drops that session's
index rows and re-indexes from seq zero, in the same transaction — because
a rewrite may renumber seqs, so nothing about the old cursor means anything
any more. A missing cursor takes the identical path. The end-to-end test
runs the real thing: a SQLite session file, `sqlite.rewrite_into` erasing
one entry's payload, `sqlite.generation` supplying the bumped counter, and
the erased text no longer matching afterwards while the retained text
still does.

The ordering that would be unsafe — scan first, read the generation
afterwards — is not expressible through this API. The worst interleaving
available stores an *older* generation beside newer data, which the next
sync detects as a mismatch and repairs.

### Querying

`query(text, limit)` runs an FTS5 `MATCH` and returns hits ranked
best-first, each with the session id, the entry id, and a `snippet()`
excerpt in which `[` and `]` mark the matched terms. The query text is
bound as a parameter, so FTS5 query syntax — bare words, quoted phrases,
`AND`/`OR`/`NOT` — is available to the caller without an injection path. A
malformed query is an `IndexFault`, not a crash. Twenty hostile probes
through the real API — injection attempts, unbalanced quotes, bare
operators, two thousand nested parentheses, a five-thousand-term
disjunction — returned either ranked hits or an `IndexFault`, never a
crash, and left both tables intact.

A hit may be stale. It names an entry as it was when indexed, and a rewrite
since then reaches the index only when someone later syncs that session
under the bumped generation.

`remove` drops a session's rows and its cursor. Call it alongside deleting
a session.

### What search does not do

These are limitations of the code as it stands, not of the design.

**CJK and emoji content is effectively unsearchable.** The schema names no
tokenizer, so FTS5 uses `unicode61`, which splits on non-alphanumeric
characters only. A Japanese sentence becomes one token — matchable only by
typing the entire sentence — and emoji produce no token at all. Indexed
*content* is otherwise unrestricted, and accented Latin text round-trips
correctly, because diacritic folding applies to the index and the query
alike. The fix is a tokenizer change (`trigram`, or ICU), which costs a
full reindex; the M3 triage deferred it to a search-quality pass as
`EV-unicode-tokenizer`. Until then, treat the index as covering
whitespace-delimited scripts.

**A query cannot be scoped to a session.** `query` takes only the text and
a limit, and the index spans every session in the repository — which the
tests assert deliberately. Filtering hits afterwards does not recover
scoping, because `rank` and `LIMIT` are applied inside SQL: a ten-hit
request narrowed to one session can come back empty while that session has
matches. A scope belongs in the SQL, and is not there yet.

**Nothing reconciles the index against live sessions.** The module exposes
`open`, `close`, `sync`, `notify`, `query`, and `remove`. Nothing
enumerates indexed sessions and compares them to sessions that still exist,
so a deleted session's text stays searchable until someone calls `remove`
for it.

**A non-positive limit means no limit.** The limit is passed into SQL
`LIMIT ?`, and SQL reads `LIMIT -1` as unbounded. Storage's own convention
is the opposite — a limit of zero or below returns no rows — so a caller
computing a limit by subtraction gets the whole index instead of nothing.
An empty query string is an `IndexFault` rather than an empty result, which
a search-as-you-type caller meets on the first backspace.

**Nothing wires search into a running harness.** No package outside
`events` calls `search.open`. It is a complete, tested service waiting for
a consumer.

## The parrot pilot

The named static SQL statements behind search are generated, not written.
`src/events/sql/search.sql` holds six named queries, `scripts/gen-sql.sh`
compiles them with parrot into `src/events/sql.gleam`, and the generated
module is committed. It carries the banner `Code generated by parrot. DO
NOT EDIT` and means it — edit the `.sql` and regenerate.

This is a deliberate pilot rather than a conversion. ADR-004 adopts parrot
for typed SQL but gates it: prove the workflow on the next *new* SQL
surface, then retrofit `storage/sqlite`'s straightforward statements in a
mechanical commit series, moving the plan-asserted branch-index queries
last. The storage backend is the most thoroughly proven code in the
repository — a conformance suite over two backends, `EXPLAIN QUERY PLAN`
assertions, a fenced-lease duel — and converting it wholesale would risk
that evidence to buy type safety it already has by other means. The search
database has no regression risk, so it went first.

Three things the pilot bought, all visible in the code:

- **The SQL text comes back verbatim.** A generated function returns
  `#(text, params)` or `#(text, params, decoder)`, so the statement is a
  value, not something hidden inside a driver. That is what makes the
  eventual retrofit safe for the plan-asserted queries: identical text
  means identical plans by construction, and `"EXPLAIN QUERY PLAN " <> sql`
  still composes.
- **Column order cannot drift silently.** Every call site uses labelled
  arguments — `sql.set_cursor(session_id:, generation:, high_water:)` — so
  reordering columns in the `.sql` becomes a compile error rather than a
  mis-bound query. Likewise `run_statement` takes a two-tuple, which
  structurally rejects a `:many` three-tuple: an `:exec` statement that
  grew a result set would fail to compile.
- **Decoders arrive with their queries.** `GetCursor` and `SearchEntries`
  and their total decoders are generated from the column list.

What stays hand-written is as much of the decision as what does not.
Schema DDL and pragmas are out of codegen, so the two `CREATE` statements
live as constants in `events/search` — and `sql/schema.sql`, which the
generation script loads into a throwaway database, holds the same text. A
test pins them together, comparing with comments and blank lines stripped
so the prose can move without loosening the contract. Parrot is
driver-agnostic and hands back its own `dev.Param` values, so a ten-line
function bridges them to sqlight's `Value`; ADR-002 is untouched and
sqlight remains the binding.

If you are about to touch this code, three constraints matter:

1. **Query files must be ASCII.** Parrot slices queries by byte offset
   while counting characters, so a single multi-byte character anywhere in
   a `.sql` file silently corrupts the generated SQL of every later query
   in that file. `scripts/gen-sql.sh` carries the rule in its header. The
   bug deserves an upstream report.
2. **Use the column-qualified match form.** The generator rejects the
   table-valued `tbl MATCH ?` spelling; `entry_fts.text MATCH ?` works, and
   is arguably the better spelling anyway.
3. **Nothing in CI checks any of this.** `make check` does not run
   `gen-sql`, and nothing pins `search.sql` to the committed `sql.gleam`.
   The ASCII rule and the source-to-generated correspondence are
   conventions today, not enforcement. The DDL pin is the one exception,
   and it is a test in this package.

The recorded verdict is positive with those findings: FTS5 virtual tables,
snippet functions, rank ordering, and upsert cursors all generate clean
typed modules, regeneration is byte-reproducible, and no hand-written
fallback was needed. The retrofit of storage's plain statements may proceed
on that evidence; the plan-asserted queries still move last.

## What is not built yet

Beyond the search limitations above, four gaps are worth knowing before
building on this package.

**No production consumer drives a projection.** Nothing outside `events`
imports `events/projection`. The driver, the checkpoint contract, and the
generation guard are all exercised by tests only — which is precisely why
the `Checkpoint` contract could still grow its generation field without a
`protocol-change/` proposal.

**Neither pull path is batched.** Neither `catch_up` nor `search.sync` caps
its scan, so a rebuild of a large session materializes every entry, every
usage row, and the merged change list at once, and a first search sync of a
large session performs every insert in one immediate transaction against
the repository-wide database, where other sessions' syncs wait on the write
lock against a five-second busy timeout. Neither is a correctness problem —
a failed sync retries, and `catch_up` is correct at any size — but the
"batch" the comments describe is not yet a batch the code enforces. The
frontier is what makes adding a row cap safe: bounding the row count while
keeping the seq bound is sound.

**A driver's first catch-up runs inside the actor initializer's
five-second budget.** With `ephemeral()` that first pull is a full rebuild.
A store slow enough to exceed the budget does not degrade the driver; it
fails to start, and under supervision that is a restart loop that repeats
the same too-slow work. Catching up after initialization — by the actor
sending itself a hint — would keep the same convergence guarantee without
staking the process's existence on scan latency.

**Cross-node fan-out does not exist.** The bus publishes to the local
members of a group. Clustering the `pg` scope is follow-up work and changes
nothing here but the member list.

## Where the code lives

| Path | What it holds |
|---|---|
| `events/bus.gleam` | The six topics and events, `publish`, idempotent `subscribe`, `select_published`, and the unlinked writer `bridge`. |
| `events/projection.gleam` | `Projection`, `Change`, `Checkpoint`, `catch_up` and its frontier, `rebuild`, `stats_projection`, and the driver actor with its generation guard. |
| `events/search.gleam` | `open`/`close`, the transactional `sync`/`notify`, `query`, `remove`, `entry_text`, the hand-written DDL, and the parrot parameter bridge. |
| `events/sql.gleam` | The six generated statement functions and their decoders. Produced by parrot from `events/sql/search.sql`; regenerate, never edit. |
| `events/sql/search.sql` | The six named static queries — the source of truth for the generated module. |
| `sql/schema.sql` | The search database DDL, pinned to the copy in `events/search` by a test. |
| `events/internal/ffi_pg.gleam` | The confined `pg` binding, and the publish/unwrap pairing that makes the typed boundary sound. |
| `events_ffi.erl` | The Erlang shim those externals bind to. |

Each path is relative to its package's source root — `events/bus.gleam` is
`packages/events/src/events/bus.gleam`, and `sql/schema.sql` sits beside
`src` rather than inside it. For the store these read models sit on,
`docs/architecture/durability.md` covers seqs, write-once rows, and the
single writer. For the bus's place among the four inter-strand patterns,
`docs/architecture/messaging.md` covers durable payloads and ephemeral
doorbells. `docs/loom-design.md` §3.6 states the hints-and-pulls rule,
`docs/loom-implementation-spec.md` WP-K holds the scope and exit criteria,
`docs/adr/004-parrot-sql-codegen.md` records the codegen decision and its
pilot verdict, and `docs/spec-gaps.md` "From WP-K" records where the
implementation refined the spec.
