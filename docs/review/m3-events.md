# Adversarial review — M3 `events` (WP-K)

Scope: `packages/events/src/events/{bus,projection,search}.gleam`,
`internal/ffi_pg.gleam`, `events_ffi.erl`, `sql/schema.sql`,
`src/events/sql/search.sql`, the generated `src/events/sql.gleam` (its
*use*, not its style), the package tests, `docs/spec-gaps.md` "From WP-K",
and `scripts/gen-sql.sh`.

Method: read the package against its own stated invariants, then attempt
to break each one in a scratch copy (`/tmp/scratch-loom-events`) that
builds and runs the real test suite, plus FTS5 experiments against
`sqlite3` 3.45.1. Every finding below is marked **CONFIRMED** (reproduced,
with the observation quoted) or **SUSPECTED** (argued from the code, not
reproduced). The package's own 29 tests pass unmodified; the
reproductions were added as a tenth test module and are not proposed for
merge.

Counts: **1 high, 6 medium, 12 low.**

---

## High

### H1. A projection has no rewrite guard, so a precise rewrite strands it forever — CONFIRMED

`search` treats rewrite invalidation as load-bearing: its cursor is stored
*with* the store generation (`search.gleam:188-194`), and a mismatch drops
the session's rows and re-indexes from zero. `projection` has no
equivalent. `Checkpoint(state)` persists `#(state, Seq)` and nothing else
(`projection.gleam:56-63`), and `catch_up` short-circuits on the frontier:

```gleam
Ok(frontier) if frontier <= high_water -> Ok(#(state, high_water))
```

`projection.gleam:109`

A precise rewrite is exactly the case this cannot see. `sqlite.rewrite_into`
preserves seq numbering and replaces entry *payloads* — that is what the
package's own `sqlite_rewrite_invalidates_index_test` demonstrates, erasing
"the doomed passphrase". After such a rewrite the frontier has not moved, so
a checkpointed projection folds nothing and keeps the pre-rewrite state
permanently. A rewrite that *shortens* the session is worse: the frontier
moves backwards and the branch is taken on every subsequent pull.

Reproduction (a projection that folds `search.entry_text`, three entries,
then the same store rewritten to `"[erased]"` payloads at the same seqs):

```
#("folded before rewrite", ["concurrentfact 1", "concurrentfact 2", "concurrentfact 3"], "hw", 3)
#("after rewrite, catch_up on the new store", ["concurrentfact 1", "concurrentfact 2", "concurrentfact 3"], "hw", 3)
#("shorter store, catch_up", ["concurrentfact 1", "concurrentfact 2", "concurrentfact 3"])
```

The erased text survives in the read model, and `rebuild` is the only escape
— but nothing tells a caller to run it, because nothing detects the rewrite.

Two aggravators in the driver, both CONFIRMED by reading:

- `DriverState` captures `store: Storage(handle)` at start
  (`projection.gleam:289-297`). A rewrite swaps the session's store; the
  driver keeps the old handle and reads a stale or closed one.
- `pull`'s error is discarded on the hint path — `Hinted -> let #(driver,
  _result) = pull(driver)` (`projection.gleam:372-375`). A driver reading a
  `HandleClosed` store therefore serves its last good state silently and
  forever; only an explicit `sync` ever surfaces the fault.

Why high: the whole point of the precise rewrite is erasure, and a read
model that keeps the erased content defeats it. It is also the cheapest
possible moment to fix — `grep` finds **no production consumer of
`projection.*` outside this package**, so the `Checkpoint` contract can still
grow a generation field (`load: fn() -> Option(#(state, Seq, Int))`, or a
`Options.generation` compared exactly as `search.sync` compares it) without
a `protocol-change/` proposal against a live dependant. The invariant list in
`packages/events/CLAUDE.md` should then say for projections what it already
says for search.

---

## Medium

### M1. `search.sync` reads its cursor outside the write transaction, so concurrent syncs duplicate every index row — CONFIRMED

`sync` establishes *what to write* before it takes the write lock:
`read_cursor` at `search.gleam:185`, the session scan at `195-205`, and only
then `in_transaction` at `219`. The docstring claims idempotence backed by
serialization — "index rows and the advanced cursor commit in one
transaction, so re-running after any failure converges on the same state",
and on the handle, "writers serialize". Serializing the *write* is not
enough when the read that decides the write happened before the lock.

Two syncs of the same session that both read cursor `H` both scan
`(H, ∞)` and both `INSERT` those rows — no `DELETE` intervenes, because
neither is `stale`. Reproduction (five entries in a second wave, indexed by a
slow reader racing a fast one against one index file, both returning `Ok`):

```
#("fast", Ok(Nil), "slow", Ok(Ok(Nil)))
#("secondwave hits", 10)
```

Ten hits for five entries. The damage is permanent: every subsequent query
returns each entry twice (consuming `LIMIT`, distorting `rank`), and nothing
repairs it short of a generation bump or `remove`. The window is not
artificial — it is open for as long as the session scan takes, which for a
first sync of a large session is the whole session.

The obvious fix is to move `read_cursor` inside `BEGIN IMMEDIATE` and
re-check it there (re-scanning if it moved), or to make the insert
idempotent. The plain `INSERT INTO entry_fts` (`sql.gleam:12-21`) has no
uniqueness to conflict against, so the cursor is the only guard there is.

Related, same family, SUSPECTED: `Search` is a freely copyable value
wrapping one `sqlight.Connection`. Two processes sharing one handle share
one transaction — B's `read_cursor` sees A's uncommitted rows, and B's
`BEGIN IMMEDIATE` fails outright. The docstring licenses sharing the *file*
between processes; it should say a handle belongs to one process.

### M2. `subscribe` is not idempotent: a second join duplicates delivery, and one `unsubscribe` does not undo it — CONFIRMED

`pg` counts multiplicity: a pid that joins a group twice appears twice in
`get_local_members/2`, and `pg_publish/3` sends to the list
(`events_ffi.erl:59-64`). Nothing in `bus.subscribe` (`bus.gleam:184-186`)
or `subscribe_all` (`198-210`) deduplicates, and `unsubscribe`
(`221-227`) is one `pg:leave/3` — it removes one membership.

Reproduction (`subscribe(Commits)` followed by `subscribe_all`, then one
publish, then one `unsubscribe`):

```
2                                             # subscriber_count
Ok(Published("adv-dup", Committed([1], 1)))   # first delivery
Ok(Published("adv-dup", Committed([1], 1)))   # second delivery of the same event
1                                             # count after one unsubscribe
```

This contradicts `subscribe_all`'s docstring directly — "Events still arrive
exactly once each — an event is published to its one topic group only" —
which is true of the *publish* side and false of the subscribe side. It also
makes `subscriber_count`'s "number of local subscribers" a count of
memberships, not processes.

Consequences are cheap but real: a subscriber that pulls per hint pulls
twice (`projection`'s driver would do a redundant storage round-trip per
event), and a partial unsubscribe leaves a live membership the caller
believes it dropped. `subscribe` should leave-then-join, or check
`member_count` for `self()`, and `unsubscribe` should loop until the pid is
gone. At minimum the docstrings must state that membership is counted.

### M3. The driver's first catch-up runs inside a 5 s initialiser budget — CONFIRMED

`projection.start` does the cold catch-up inside
`actor.new_with_initialiser(5000, …)` (`projection.gleam:316-347`). With
`ephemeral()` that is a full rebuild — every entry and usage row of the
session — and with a checkpoint it is still at least the two frontier scans.
A store slow enough to exceed the budget does not degrade; it fails to
start:

```
Error(InitTimeout)
```

(a `Storage` whose scans take 3 s each, so `frontier`'s two scans total 6 s).
Under `projection.supervised` this is a restart loop that can never
converge, because each restart repeats the same too-slow work. The
docstring's promise — "A storage fault during any catch-up leaves the last
good state in place; the next hint or `sync` retries" — holds for faults but
not for slowness, and the start-time pull is precisely where slowness is
worst.

Catching up *after* `actor.initialised` (send the actor a `Hinted` to
itself) keeps the same convergence guarantee without gambling the process's
existence on scan latency. Note `client/gateway.gleam:199-227` primes with
the identical pattern; that is the gateway reviewer's to weigh, but the
shape came from here.

### M4. `bus.bridge` is linked, unsupervised, and runs caller-supplied code — CONFIRMED

`bridge` is `actor.start` (`bus.gleam:289-300`), i.e. `start_link`, and the
package ships no `bridge_supervised` counterpart even though `bus` and
`projection` both ship child specs. The mapping closure is written by the
composition layer and runs inside the bridge actor; anything it does not
handle takes the actor down and the exit signal reaches whoever called
`bridge`.

Reproduction (a host process starts a bridge whose `map` fails on one input,
sends that input, then tries to report that it survived):

```
#("host alive?", False, Error(Nil))
```

The docstring anticipates death — "if it dies, events are missed until it is
restarted" — but there is no seam through which anything restarts it, and
the default outcome is that it takes its starter with it. Add
`bridge_supervised(bus, session:, map:) -> ChildSpecification(...)`, and say
in the docstring that `map` must be total.

(The typed `Subject(incoming)` does mean a *malformed* bridge input cannot
be delivered in the first place — the hunt-list's "malformed bridge input
crashes the bus actor" does not apply; there is no bus actor, and the input
is type-checked. The exposure is entirely the caller's closure.)

### M5. Search is repository-wide with no session scope, and `remove`'s promised reconciliation does not exist — CONFIRMED (by reading)

`search.query` (`search.gleam:304-323`) takes only `text` and `limit`. There
is no session filter, no allow-list, and every session's extracted message
text lives in one file (`entry_fts` is a normal, content-carrying FTS5
table, so the index holds a verbatim copy of everything indexed). The tests
assert this cross-session behaviour deliberately
(`sessions_are_distinguished_in_hits_test`), so it is a design choice — but
the consequences are not written down anywhere:

- A caller cannot scope a search. Filtering hits after the fact is wrong,
  because `LIMIT` and `rank` are applied before the caller sees them: a
  10-hit request scoped to one session can return zero rows while that
  session has matches.
- `remove`'s docstring says "call alongside deleting the session, or leave
  stale rows to the next sync reconciliation." **No reconciliation exists.**
  The module exposes `sync`, `notify`, `remove` and nothing else; nothing
  enumerates index sessions and compares them to live ones. A deleted
  session's text stays searchable indefinitely, including text a rewrite was
  run to erase (a rewrite only reaches the index if someone later calls
  `sync` for that session with the bumped generation).

Given the design's stated priority ordering (security and isolation first),
`query` should take an optional session scope — pushed into the SQL, not
applied by the caller — and either the reconciliation sweep should exist or
the docstring should stop promising it.

### M6. Both scan paths are unbounded and unbatched — SUSPECTED (mechanism confirmed by reading; no failure reproduced)

Neither `catch_up` (`projection.gleam:113-120`) nor `search.sync`
(`search.gleam:195-205`) sets a scan limit, and `storage`'s scan builders
default to none (`storage.gleam:509-516`, `595-596`). So:

- `rebuild` of a large session materializes every entry, every usage row,
  and the merged `List(Change)` simultaneously before folding.
- The first `search.sync` of a large session materializes every entry, then
  performs every `INSERT` in one `BEGIN IMMEDIATE` on the *repository-wide*
  database. Other sessions' syncs wait on that write lock against a 5 s
  `busy_timeout` (`search.gleam:124`) and return `IndexFault` when it
  expires.

Neither is a correctness bug — a failed sync retries, and `catch_up` is
correct at any size — but the docstrings speak of "one catch-up batch" and
"a crash mid-batch simply re-runs the batch" while no batching exists. Cap
each pull (`entry_limit`/`usage_limit` at the frontier, loop until drained)
so that the batch the comments describe is the batch the code runs. Note
`catch_up`'s frontier makes this safe to add: bounding the row count while
keeping the seq bound is sound, whereas today's all-or-nothing pull is what
makes the size unbounded.

---

## Low

**L1. `search.query` treats a non-positive limit as "no limit" — CONFIRMED.**
`storage` states a repo-wide convention three times over: "a limit of zero
or below returns no rows, never 'no limit'. Every backend must implement
that non-positive-limit rule identically" (`storage.gleam:154-158`,
`180-182`). `search_entries` passes the limit into SQL `LIMIT ?`
(`sql.gleam:41`), and SQL `LIMIT -1` is unlimited. Reproduced: three indexed
entries, `limit: -1` → 3 hits, `limit: 0` → 0 hits. Callers that compute a
limit by subtraction (which the storage docs explicitly warn about) get the
whole index instead of nothing.

**L2. CJK and emoji content is effectively unsearchable — CONFIRMED.**
The hunt-list question resolves cleanly in two halves. Indexed *content* is
unrestricted: the ASCII rule in `scripts/gen-sql.sh` is about parrot's
byte-offset slicing of query *files*, and non-ASCII text round-trips
(`café` matches `café`; diacritic folding is symmetric because
`remove_diacritics` applies to index and query alike). But the schema names
no tokenizer (`schema.sql:12-16`), so FTS5 uses `unicode61`, which splits on
non-alphanumerics only. A Japanese sentence becomes one token:

```
$ sqlite3 … "SELECT term FROM fts5vocab_of(entry_fts)"
…
日本語のテキストと検索          ← the entire sentence, one term
$ … MATCH '検索'    → no rows
$ … MATCH '日本語のテキストと検索' → 1 row
```

Emoji produce no term at all, so `MATCH '🚀'` never matches text containing
it. Fix is `tokenize='trigram'` (or an ICU tokenizer) — a schema change, so
it costs a reindex; the cheap alternative is to document the limitation
beside the "Search indexes message text" invariant.

**L3. `param_to_sqlight`'s NULL fallback fails silently, contrary to its own
comment — CONFIRMED (by reading + SQL semantics).** `search.gleam:389-401`
maps the temporal, list, and dynamic `dev.Param` variants to
`sqlight.null()`, justified as "a wrong-parameter bug surfaces as a failed
query, not a crash." For this package's statements that is not what would
happen: `DELETE FROM entry_fts WHERE session_id = NULL` deletes nothing and
returns success, and `INSERT … VALUES (NULL, …)` succeeds. A wrong parameter
would surface as a silently empty `remove`, not a failed query. The variants
are unreachable today (all generated params are `ParamString`/`ParamInt`),
so this is about the justification, not the behaviour: returning
`Error(IndexFault("unsupported parameter"))` would make the claim true.

**L4. No CI guard on the generated SQL — CONFIRMED.** The DDL has a pin
(`schema_matches_source_test`), but nothing pins `src/events/sql/search.sql`
to the committed `src/events/sql.gleam`, and `make check` never runs
`gen-sql`. `scripts/gen-sql.sh` documents a silent-corruption hazard in the
same breath — "A multi-byte character anywhere in a query file shifts
parrot's byte-offset slicing and silently corrupts every later query's
generated SQL text" — and nothing enforces it. `search.sql` is ASCII today;
`sql/schema.sql` is not (one U+2014 em dash on line 2), which is harmless
because parrot reads the schema through `sqlite3 .schema` rather than the
file, but it shows the rule is not being checked anywhere. Two cheap
guards: an ASCII assertion over `src/events/sql/*.sql` in the test suite,
and a CI step that regenerates and `git diff --exit-code`s.

**L5. `events_ffi` does let exceptions escape — CONFIRMED (by reading).**
The module header claims "no exceptions escape". `pg_start/1`
(`events_ffi.erl:25-29`) matches only `{ok,_}` and
`{error,{already_started,_}}`; any other `{error, Reason}` from `pg:start/1`
is a `case_clause`. `pg_join/2` (`41-43`) is `ok = pg:join(…)`, a badmatch
on anything else. Both are unlikely in practice — that is the argument for
making them explicit rather than for leaving them implicit.

**L6. `bus.start` and `bus.supervised` cannot coexist, and `start` is
ambient authority — CONFIRMED (by reading).** `start` is idempotent
(`bus.gleam:130-133`); `supervised` fails if the scope is already running
(`145-152`) and, as a `supervision.worker`, will retry into a permanent
restart. Any component calling `bus.start()` first therefore poisons the
supervised child. Separately, `Bus` is opaque but confers nothing:
`bus.start()` is public and hands any code on the node the ability to
subscribe to *every* session's topics and to publish forged events into
them. Payloads are thin by design, but `Escalation(description)` and
`OpTransition(phase)` are display strings, and forged `Committed` events
cost a spurious pull. Worth a sentence in the invariants: bus isolation is
by group key, not by capability, and the node is the trust boundary.

**L7. `read`/`sync` use `call_forever` — CONFIRMED (by reading).**
`projection.gleam:434-436` and `447-449`. `read` is documented as "the
local-speed lookup", but it is a call to an actor that may be mid-`pull`; a
wedged store (SQLite `busy_timeout`, a lost backend process) blocks every
reader permanently with no way to time out or shed load. A bounded
`process.call` with a documented timeout preserves the "may lag" contract
and removes the wedge.

**L8. `in_transaction` does not roll back a failed `COMMIT` — SUSPECTED.**
`search.gleam:453-462`: the `Ok` branch maps a `COMMIT` failure to an error
and returns, leaving the connection inside the transaction. Everything
subsequent on that handle either joins the stale transaction or fails at
`BEGIN`. `BEGIN IMMEDIATE` makes a busy `COMMIT` rare in WAL, not
impossible. A `ROLLBACK` in that branch costs nothing.

**L9. `search.open` leaks the connection on a partial failure — CONFIRMED
(by reading).** `search.gleam:116-144`: if any pragma or DDL step fails, the
already-open `db` is returned to no one and never closed.

**L10. `published_payload`'s coercion is spoofable — SUSPECTED (latent).**
`select_published` matches any local `{loom_event, _}` two-tuple
(`ffi_pg.gleam:105-112`) and coerces field 1 unchecked. The stated
invariant — "only `publish` ever sends the `{loom_event, _}` tuple" — is a
property of this package, not of the node: any process that knows a
subscriber's pid can send that tuple. Today's only real consumer discards
the payload (`gateway.gleam:409` is `BusHint(published: _)`), so nothing
dereferences a forged value yet; the first consumer that reads
`published.session` inherits a crash-or-confuse path. If that day comes, the
cheap fix is a shape check in `published_payload` rather than a coercion.

**L11. `pull` writes a checkpoint even when nothing changed — CONFIRMED.**
`projection.gleam:404-407` saves unconditionally on `Ok`, and `catch_up`
returns `Ok` on the no-op path. The package's own
`checkpoint_resumes_without_refolding_test` asserts this ("The start-time
convergence pull found nothing new but still saved"). On a hot session
subscribed via `subscribe_all`, every event on every topic is one frontier
read plus one checkpoint write. Skipping the save when `high_water` is
unchanged is a two-line guard.

**L12. An empty query string is a fault, not an empty result — CONFIRMED.**
`search.query(service, "", 10)` and `" "` both return `IndexFault`. Harmless
but worth knowing for a search-as-you-type caller, which will hit it on
every first keystroke's backspace; the docstring mentions malformed queries
but not empty ones.

---

## Checked and sound

Things the hunt list asked about that hold up, with what was checked.

- **The frontier rule is applied on every multi-scan path, rebuild
  included.** `rebuild` is literally `catch_up(store, projection,
  projection.initial, after: 0)` (`projection.gleam:183`), so there is no
  second implementation to drift. The scan order is also right in a way the
  comment does not claim credit for: `frontier` reads newest-entry then
  newest-usage (`140-167`), so a commit landing between the two reads can
  only make the frontier an *under*-estimate — the batch is short, never
  skipped, and the next pull collects the remainder.
- **No committed-seq gap can open under the frontier.** The concern would be
  a seq assigned but uncommitted below the frontier. Both backends allocate
  seqs inside the commit itself (`memory.gleam:110-116`, `sqlite.gleam:1326`
  under the write transaction), so a visible seq implies a committed row.
- **Checkpoint ordering is replay-safe for non-idempotent folds.**
  `save(state, high_water)` stores the pair (`projection.gleam:404-406`) and
  `load` returns the pair (`328-331`). A crash between applying and saving
  loses the in-memory state *and* the advanced high-water together, so the
  restart re-folds from the older pair onto the older state. There is no
  interleaving that applies a change twice — which is exactly what makes the
  pair, rather than the high-water alone, the right unit (spec-gaps WP-K §2).
- **`poke`/`sync` do not race.** The actor mailbox serializes; `Synchronize`
  pulls and replies with the state that pull produced
  (`projection.gleam:380-387`), so `sync`'s result is never a stale read.
- **`pg` reaps dead subscribers.** A spawned process subscribed and died;
  `subscriber_count` went `1` → `0` without any explicit leave. Membership
  cleanup is `pg`'s monitor, exactly as the FFI docstring argues.
- **No cross-session bus leakage.** The group key is `#(session, topic)`
  (`bus.gleam:165-186`), so a subscriber only ever joins its own session's
  groups; the package's `session_isolation_test` covers the direct case and
  nothing in the FFI widens it.
- **The atom-safety claim holds.** The generated Erlang confirms it: `-type
  scope() :: loom_events`, `-type tag() :: loom_event`, and
  `select_record(Selector, loom_event, 1, …)` — all compile-time literals.
  The group key is `{binary(), atom()}` where the atom is one of six
  compile-time topic constructors, so an unbounded number of session strings
  creates an unbounded number of *groups*, never an atom. `pg` drops a group
  when its last member leaves, so the table does not grow without bound
  either.
- **FTS5 injection: parameterized and safe, including the query syntax
  inside the parameter.** `text` is bound (`sql.gleam:42`,
  `search.gleam:309-315`), and 20 hostile probes through the real API — SQL
  injection attempts (`concurrentfact"); DROP TABLE entry_fts; --`, `';
  DELETE FROM search_cursor; --`), unbalanced quotes, bare operators
  (`AND`, `NOT`, `*`, `-`, `NEAR(`), trailing operators, empty strings, 2000
  nested parens, and a 5000-term disjunction — produced either ranked hits
  or `IndexFault`, never a crash, and both tables were intact afterwards.
  Deep nesting is caught by FTS5 itself (`fts5: parser stack overflow`)
  rather than by exhausting the C stack. No FTS5 auxiliary function is
  reachable from inside a MATCH expression — the argument is a query
  expression, not SQL — so there is no exfiltration path through
  `snippet`/`highlight`/`bm25`. Column filters naming the `UNINDEXED`
  columns (`session_id : s1`) are accepted and return nothing, because those
  columns are not in the index.
- **`snippet()` output does not re-enter anything unsafe.** Column index 2
  is `text` (0-based over `session_id, entry_id, text` — correct), and the
  generated decoder is three total `decode.string`/`decode.int` fields
  (`sql.gleam:45-50`, `64-68`) feeding a plain `Hit`. Nothing re-parses the
  snippet. One cosmetic caveat for renderers: the `[`/`]` markers are not
  escaped in the source text, so an entry containing literal brackets is
  indistinguishable from a match marker.
- **The sync transaction is real, not just claimed.** `in_transaction` is
  `BEGIN IMMEDIATE` … body … `COMMIT`, with a best-effort `ROLLBACK` on the
  body's error (`search.gleam:445-463`), and the `stale` delete, all row
  inserts, and `set_cursor` are all inside the body (`219-245`). Rows and
  cursor do land together. (M1 is about what is decided *before* `BEGIN`,
  and L8 about the `COMMIT` failure branch — the transaction itself is
  correctly formed.)
- **Generation drop-and-reindex leaves no partial rows, and a rewrite racing
  a sync self-heals.** The `DELETE` and the re-index share one transaction,
  so there is no window in which the session has half an index. The
  caller-supplied generation is read before `sync` scans, so the worst
  interleaving stores an *older* generation alongside newer data — which the
  next sync detects as a mismatch and repairs. The ordering that would be
  unsafe (scan, then read generation) is not expressible through this API.
- **Generated-SQL parameter order and types cannot drift silently.** Every
  call site uses labelled arguments (`sql.insert_entry_text(session_id:,
  entry_id:, text:)`, `sql.set_cursor(session_id:, generation:,
  high_water:)`, `sql.search_entries(text:, limit:)`), so a reordering in
  `search.sql` becomes a compile error, not a mis-bound query. `run_statement`
  takes `#(String, List(dev.Param))`, which structurally rejects a `:many`
  three-tuple — an `:exec` that grew a result set would fail to compile.
  `GetCursor` decodes `generation`/`high_water` as ints against `INTEGER NOT
  NULL` columns, and `read_cursor`'s `list.first |> option.from_result`
  handles the absent-cursor case totally.
- **The schema pin works.** `schema_matches_source_test` compares the
  embedded DDL to `sql/schema.sql` with comments and blank lines stripped —
  the right normalization, since it lets the prose move without loosening
  the contract.

---

## Reproductions

All reproductions live in the scratch copy only, as
`/tmp/scratch-loom-events/packages/events/test/events/adversarial_test.gleam`
(10 tests; run with `gleam test` from `packages/events`). Nothing in
`/home/user/loom` was modified except this file. The FTS5 tokenizer,
nesting, and `LIMIT` experiments were run directly against `sqlite3` 3.45.1
in `/tmp`.
