# protocol-change/008 — a canonical `SessionId` in `core`

**Status**: ACCEPTED 2026-08-28 · **Affects**: Part 1.1 `core/ids` ·
**Raised by**: issue #15 (WP-K gap 4, WP-C-full gap 3) · **Implemented**:
core + session + storage + events + runtime + client + spec text

## Problem

Three symptoms in three packages are one missing concept: Loom has no
name for a session.

- **The bus keys sessions by a caller-supplied string.** `events/bus`
  groups are `#(session, topic)` where `session` is whatever the caller
  passed. The only production caller derives it from the file name —
  `serve.session_id_of("/data/review.db")` is `"review"` — so two repos
  each holding a `review.db` share one node-global `pg` group, and
  renaming a file renames the session. Nothing in the type system says
  that string names a session rather than a strand, a branch, or a
  typo.
- **`events/search` cannot scope a query to a session.** The index
  stores a `session_id` column and `Hit` carries it back, but the only
  query is repository-wide: there is no way to ask "what did *this*
  session say about auth". The column holds the same caller-supplied
  string, so scoping by it would inherit the collision above.
- **The SQLite schema's `parent_session_id` column stays unwritten.**
  `insert_catalog_row` writes a literal `NULL` because a fork has
  nothing to write there. spec-gaps records it as WP-C-full item 3:
  "Loom has no session-id concept yet, so the schema's parent-session
  column stays unwritten."

Issue #28 (memory M1) is blocked on the same absence: its session
scoping *is* this id.

## What was considered

**A bare `String` forever.** Free, and it is what ships. It fails on
identity rather than on ergonomics: a file-derived name is not stable
under `mv`, is not unique across repositories, and cannot be compared
for equality with any confidence, which is exactly what a bus group key
and a search scope need it for. It also has no minting site, so nothing
can say when two names denote the same session.

**Deriving the id from the session file path.** Stable while nobody
moves the file, and needs no durable write at all. Rejected for the same
reason: `mv` is not a rename of the conversation. It also has no answer
for the memory backend, which has no path, and it would make the id
undefined for the demo, the conformance simulation, and every test.

**Reusing an existing id kind — an `EntryId` for the root entry, or the
`OpId` of the first operation.** Tempting because it needs no new type,
and rejected because it is a lie about lifetime: a session exists before
its first entry (that is what `ensure_strand` seeds), a precise rewrite
may erase the entry the identity was borrowed from, and the whole point
of the three distinct opaque wrappers in `core/ids` is that an id of one
kind can never be passed where another belongs. Borrowing one would undo
that property at exactly the boundary — the bus, the search index —
where a mistyped key is silent rather than loud.

**A ULID/UUID-shaped opaque id minted in `core`.** Chosen. It is the
fourth wrapper around the same UUIDv7 shape the other three already use:
minted purely from an injected `Clock` plus a seeded generator, sortable
by mint time, parseable by a total decoder into a `CorruptionReport`
rather than a crash. Nothing new is invented; `SessionId` is `OpId`'s
sibling, and the same lint R6 purity holds — no `@external`, no
`gleam_erlang`, still compiles to the JavaScript target.

## Proposal

```gleam
// core/ids — added alongside EntryId, UsageId, OpId
pub opaque type SessionId              // UUIDv7, same shape as the other three
pub fn mint_session(Generator) -> #(SessionId, Generator)
pub fn session_id_to_string(SessionId) -> String
pub fn parse_session_id(String) -> Result(SessionId, CorruptionReport)
pub fn session_id_timestamp_ms(SessionId) -> Int
```

**Where it is minted.** Once, at session creation, by whoever first
brings a session up:

- `runtime/api.open` calls `session.ensure_id` before it seeds the
  primary strand — the same boot bookkeeping slot `ensure_strand`
  already occupies, committed through the session handle because no
  writer exists yet (spec-gaps WP-E item 2). Every session that boots a
  runtime therefore has an id, memory sessions included.
- `session/repo.fork` mints the destination's id inside the single
  destination transaction, so a forked session is born identified.

`session.ensure_id` is idempotent and race-safe in the shape
`ensure_strand` established: it reads the cell, returns the stored id if
one is there, and otherwise mints and commits under
`Expect(seq: None)`, treating a losing `StaleExpectation` as success and
re-reading. Reopening a session therefore always yields the same id.

**Where it lives durably.** In the session's own store, as a reserved
`fact.custom` cell under the key `session/id`, with the parent under
`session/parent` — the pinned-system-prompt pattern
(`client/system_prompt`'s `prompt/system`), and for the same three
reasons: it is one journaled write through the ordinary commit path, it
is readable off an open store before any writer exists, and the reserved
prefix keeps it out of `put_fact`'s reach. `session/` joins
`escalation/`, `operation-result/`, `lineage/` and `prompt/` in
`api.reserved_fact_key`, so no model-supplied key can forge or rewrite a
session's identity. The register is the **only** truth; both backends
carry it identically, which is what keeps memory sessions first-class.

**A corrupt cell refuses the open, permanently.** `session.id` decodes
through `parse_session_id`, so a `session/id` holding anything but a
canonical UUID is a `SessionCorrupt` report rather than a crash —
and `ensure_id` propagates it, which fails `api.open` and keeps failing
it. That is the chosen posture: a session whose name cannot be read must
not be quietly re-named, because the bus, the search index and any parent
edge already key by the old one. The way out is the rewrite tooling —
`repo.rewrite_sqlite`'s `ValueRewrite` reaches `fact.custom` payloads like
every other register cell — not a self-heal in the open path.

**A byte copy duplicates the identity.** The id lives in the file, so `cp
session.db copy.db` makes two files that are one session: both publish
into the same bus group, and their search cursors fight over one
`search_cursor` row, each dropping and re-indexing what the other just
wrote. Copy a session file for archival if you like, but open only one
copy. A copy that is meant to become a separate session is what
`session/repo.fork` is for, and a fork mints.

**How `parent_session_id` gets written.** The SQLite `session` catalog
row carries a *projection* of those two cells: `parent_session_id` in
the column the spec reserved for it, and the session's own id in the
`metadata` JSON blob beside `generation` (no column, therefore no
storage-version bump and no migration step). It is written by
`storage/sqlite.record_identity` whenever the cells are written, and
read back without acquiring the writer lease by
`storage/sqlite.identity(path:)` — the pairing `sqlite.generation(path:)`
already established. Nothing in the harness reads it for behaviour: it
exists so a repository lister, an operator with a `sqlite3` shell, or a
future cross-session index can build the parent→child graph without
opening and leasing every file. Both halves are needed for that graph,
which is why the row records its own id as well as its parent's. A
projection that fails to write is not a session failure — the register
stands and the next open repairs the row.

**What is TRUE about children.** Measured, not assumed: the client
protocol's `fork` (both scopes) forks **in place** — a new strand whose
leaf is the source strand's leaf, in the same session file — and the
Agency's spawned children are strands of the parent session, tracked by
the `lineage/` fact ledger, not sessions of their own. So
`parent_session_id` is written by exactly one path: `session/repo.fork`,
the admin surface that opens a genuinely separate destination. Every
other "child" in Loom is a strand, and strand lineage already has its
own ledger. A fork whose source has no id records no parent rather than
minting one into the source: fork never mutates the source.

**How the bus keys migrate.** The bus key becomes the canonical id
wherever a session exists. `events/bus` gains an opaque `SessionKey`
with two constructors — `bus.key(of: SessionId)` and
`bus.unidentified_key(name:)` — and every entry point (`publish`,
`subscribe`, `subscribe_all`, `unsubscribe`, `subscriber_count`,
`bridge`, `Published.session`, `projection.FromBus`) takes one instead of
a `String`. The caller-supplied string is **kept, not refused**, for one
honest reason: a publisher may have no session at all — the pre-id file
a running server already has open, a bridge standing up before boot
bookkeeping has run — and refusing it would mean the bus could not carry
a hint until the id existed, which trades a naming defect for a
correctness one. It is kept *marked*: the rendered group key is
`"id:" <> uuid` or `"name:" <> caller_string`, disjoint prefixes, so a
caller-supplied string can never collide with — or impersonate — a
canonical id, and the type makes every remaining unidentified caller
greppable. `client/gateway` is the one such caller today, and #28's
serve wiring is what flips it.

`events/search` is stricter: `sync`, `notify`, `remove` and the new
`query_in_session` take a `SessionId` outright, with no unidentified
form. Search is a *repository-wide* index — the one place where a
file-derived name collides across repositories with no way to notice —
and it has no production caller yet, so requiring the id costs nothing
and forecloses indexing two sessions under one name.

**A session that predates the id.** Mint on first open and persist:
`ensure_id` sees no cell, mints one, commits it, and every later open
reads it back. Its history keeps the keying it already has — nothing
re-keys, because nothing durable was ever keyed by the old string. The
bus key is process-lifetime state (a `pg` group), and the search index
is a rebuildable projection whose cursor is dropped and re-indexed on any
mismatch, so the old string's only trace disappears when the process
restarts and the index re-syncs under the id. The SQLite catalog row of
such a session is repaired at the same open.

**A pre-id session that already wrote under `session/`.** The reservation
is new, so an application could have put its own `fact.custom` keys there
first. Two sub-cases, stated honestly. A `session/id` cell whose value
parses as a canonical UUID is **adopted**: `ensure_id` cannot tell it from
one it minted and does not try, so that string becomes the session's name.
Anything else under that key **refuses the open** as corruption, per the
posture above, with the rewrite tooling as the way out. Other
`session/`-prefixed keys are left alone by `ensure_id` but stop being
reachable through the model-facing doors — `put_fact` refuses them and
`facts` hides them — so an application that kept state there loses its
access to it without losing the data. No session is known to do any of
this: the prefix has never been documented as writable, which is why the
reservation lands without a migration.

## Impact

- **core**: one opaque type and four functions, no change to any
  existing one. Purity unchanged; R6 census stays zero.
- **session**: `Session` gains a `record_identity` closure beside
  `renew_lease` (two constructors in the tree, both updated);
  `ensure_id`, `id`, `parent_id`, and two key constants are added;
  `repo.fork` gains a `generator` parameter, because minting the
  destination's id needs a seed and a clock alone cannot supply one.
- **storage**: one actor message and two functions on the SQLite
  backend. **No schema change, no `storage_version` bump, no migration
  step** — the column already exists and the id rides in the existing
  metadata blob. The memory backend has no catalog and needs none.
- **events**: `SessionKey` replaces `String` at every bus entry point
  and in `Published` and `FromBus`; `search`'s session parameters become
  `SessionId` and `query_in_session` is added, with one new named query
  (`SearchEntriesInSession`) in `src/events/sql/search.sql` and the
  matching function in the parrot-generated `events/sql` (ADR-004).
- **runtime**: `api.open` mints; `Runtime` carries the id and
  `api.session_id` reads it; `session/` joins the reserved fact
  prefixes.
- **client**: one line in `gateway.start` becomes
  `bus.unidentified_key(options.session_id)`.

No durable format is invalidated. The register cell is additive, the
catalog projection fills a column that has only ever held `NULL`, and a
session file written before this change opens, mints, and records
without a migration.

**One cost found by measurement, not predicted.** The mint is a commit,
and `api.open` makes it the *first* commit of a fresh session — which
shifts every commit ordinal the deterministic simulation's fault
schedules are keyed to by one, and turns a scheduled commit fault into a
refused `api.open`. The runner already had the pattern for this and the
sentence explaining it: it seeds the strand before arming the control,
"because seeding commits happen before the writer exists and have no
post-commit seam, so a schedule must not be able to name one". Minting
the id in the same place, for the same reason, leaves `api.open` with
nothing to commit and every ordinal where it was. Any future harness
that counts commits from a session's very first one inherits the same
obligation.

**Deliberately not in this change** (issue #28 owns them): the serve
wiring that keys the gateway's bus subscription by the canonical id, the
`history_search` tool, any cross-session query API beyond the
single-session filter, and the client wire protocol. The websocket
protocol is frozen separately and its `session` field remains the
caller-facing display name; if a snapshot should also carry the
canonical id, that is a follow-up protocol change against Part 1.6, not
a silent addition here.

## Decision

**Accepted.** A fourth opaque UUIDv7 in `core/ids`, minted once at
session creation through the same injected generator the other three
use, persisted as a reserved `fact.custom` cell that is the single
truth, and projected — for SQLite only, and for outside readers only —
into the catalog row's long-reserved `parent_session_id` column plus its
metadata blob. The adversarial case for the cheaper answer, keeping the
caller-supplied string and merely documenting its hazards, was
considered and dismissed: the three symptoms are not ergonomic
complaints but a missing equality. A bus group key, a search scope, and
a parent edge all need to answer "same session?", and a file-derived
name answers it wrongly across repositories and after any `mv`. The
cost is a frozen-surface addition to Part 1.1, one closure on `Session`,
one parameter on `repo.fork`, and a `SessionKey` type that keeps the old
string reachable but marked — which is the price of migrating a live bus
without a flag day, and which the compiler collects in full at every
remaining call site.
