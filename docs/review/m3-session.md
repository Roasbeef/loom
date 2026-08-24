# Adversarial review — M3 session layer

**Scope.** `packages/session/src/session/repo.gleam` (forks, the precise
rewrite, `erase_text`), `packages/session/src/session/session.gleam` (versioned
open, the migration chain seam, the full projection and orphan healing), and
the WP-C-full additions beneath them in
`packages/storage/src/storage/sqlite.gleam` (`open_with_migrations`,
`ensure_schema`/`migrate`, `rewrite_into`, `copy_source`, `rewrite_copy`,
`read_generation`/`bump_generation`, `generation`). Their tests
(`fork_test`, `projection_test`, `rewrite_test`, `migrate_test`) were read for
what they do *not* pin down. Fidelity was checked against pi's
`packages/agent/docs/harness.md` §2.5, §2.7, §2.8, §2.9 and Part 7, and against
`docs/spec-gaps.md` "From WP-C-full".

**Method.** Read each file line by line asking, for each operation: what
interleaving of a second writer breaks it, what the crash window between two
non-atomic steps leaves on disk, what the doc comment promises that the code
does not deliver, and which pi sentence the code silently reinterprets. Every
finding below marked CONFIRMED was reproduced in a scratch copy of the tree
(`/tmp/scratch-loom`, throwaway tests, never committed); the reproduction is
described under **Trigger** in each case. Findings are ordered by severity.

**Counts.** 2 CRITICAL, 4 HIGH, 4 MEDIUM, 2 LOW.

The headline: the precise rewrite's two file-level swaps are both unsound.
A crash — or a failed `unlink` — in the window between the rename and the
`-wal` deletion silently restores the erased content, and nothing stops a
writer from taking the lease and committing into the file the rewrite is about
to replace.

---

## M3-01 — CRITICAL — CONFIRMED — the replaced file's WAL resurrects erased content
`packages/storage/src/storage/sqlite.gleam:706-713` (`rewrite_into`, the
rename/unlink sequence), `:781` (`copy_source`), `:1145` (`Close` — no
checkpoint).

**Defect.** `rewrite_into` renames the erased copy over the original and only
*then* unlinks the original's `-wal`/`-shm` siblings:

```gleam
case simplifile.rename(at: temp, to: path) {
  Ok(Nil) -> {
    let _ = simplifile.delete(path <> "-wal")
    let _ = simplifile.delete(path <> "-shm")
```

Between those two statements, `path` is the new, erased database and
`path-wal` is a fully valid write-ahead log belonging to the *old* one. SQLite
does not record which database a WAL belongs to; on the next open it recovers
any WAL whose header checksums validate and whose page size matches the
database — and here the page size matches by construction, because the copy was
made from that very file with `VACUUM INTO`. Recovery therefore replays the
pre-erasure pages into the rewritten file. The erased string is back, the
generation bump is rolled back with it, and the file reports itself as never
having been rewritten.

Two things make this far more than a theoretical crash window:

1. **The old `-wal` reliably exists.** The actor's `Close` (`:1145`) deletes
   the lease row and calls `sqlight.close`; it never checkpoints. The `-wal`
   sibling survives a clean `session.close`. `rewrite_test` already knows
   this — its "before" assertion is `contains_bytes(before, needle) ||
   contains_bytes(before_wal, needle)` (`rewrite_test.gleam:240`) — but the
   unlink is still placed after the rename.
2. **No crash is required.** Both deletes are `let _ =`; their results are
   discarded. If either unlink fails (a reader still holds the file, a
   read-only directory, a network filesystem), `rewrite_into` returns
   `Ok(Rewrite(generation: 1, ...))` and the operator is told the erasure
   succeeded, while the next open restores the secret.

This breaks the invariant the storage `CLAUDE.md` states outright — "the audit
contract is that the erased string appears nowhere in the new file's raw
bytes" — in the one direction that matters for compliance-grade erasure: the
content comes back *after* the operator was told it was gone.

**Trigger.** Reproduced: build a session file whose only entry carries
`XYZZY_SECRET_7`, close it (the `-wal` survives and holds the secret), then
perform `rewrite_into`'s exact steps by hand and stop at the crash window —
`VACUUM INTO temp`, erase in the copy, `VACUUM`, `rename(temp → path)` — with
the two deletes skipped. The copy is verifiably clean before the rename;
reopening `path` afterwards reads back
`{"...","text":"please handle XYZZY_SECRET_7"}` and the raw bytes of `path`
contain the needle again.

**Fix direction.** Retire the source's WAL *before* the copy is taken, on the
connection `copy_source` already holds: `PRAGMA wal_checkpoint(TRUNCATE)`
followed by `PRAGMA journal_mode = DELETE` (which checkpoints and removes both
siblings) after the `VACUUM INTO` and before `sqlight.close`. Then no sibling
exists at rename time and the post-rename deletes become belt-and-braces. Stop
discarding their results regardless: a failed unlink must be `RewriteFailed`,
not `Ok`. A regression test should assert `is_file(path <> "-wal") == Ok(False)`
*before* the rename, not only after the whole operation.

## M3-02 — CRITICAL — CONFIRMED — the rewrite samples the lease once and never holds it
`packages/storage/src/storage/sqlite.gleam:840-848` (`copy_source`'s lease
check), `:693` (`rewrite_into`), `packages/session/src/session/repo.gleam:16-22`
(the quiescence doc comment).

**Defect.** `copy_source` reads `writer_lease`, refuses if
`expires_at_ms > now`, and then does `VACUUM INTO`. That is the entire
enforcement. The rewrite never *takes* the lease, so from the moment the copy
is made — through the whole transform pass over every entry, the commit, the
`VACUUM`, and the rename — the session file is unleased and any writer may
`open` it, acquire the lease, and commit. Those commits land in the file the
rename is about to unlink. They are lost, silently, with no error to either
party: the writer's commits returned `Ok`, and the rewrite returns
`Ok(Rewrite(...))`.

The module docs claim the opposite. `repo.gleam:20-22`: "Fork and rewrite are
defined over a *quiescent* source... **The SQLite rewrite enforces this with
the writer lease**; the in-process operations trust their caller." The storage
`CLAUDE.md` repeats it. The lease is *sampled*, not enforced; there is a
check-to-use gap the length of the entire rewrite.

Worse, the loser is also the live writer whose `-wal` M3-01 unlinks: after the
rename, `rewrite_into` deletes `path-wal` and `path-shm` out from under a
process that still has them open and is still committing through them.

**Trigger.** Reproduced deterministically by using the transform callback as
the elapsed time the rewrite would otherwise take. Seed a one-entry session and
close it (lease free). Call `repo.rewrite_sqlite` with a transform that, on its
first entry, opens the same path under a *different* owner (the lease is free —
it is granted), commits a second entry, closes, and returns `Ok(None)`. The
rewrite completes and reports `Ok`. Reopening the file afterwards shows **one**
entry: the concurrent writer's committed entry is gone.

**Fix direction.** Make the rewrite a lease holder rather than a lease reader:
in `copy_source`, inside one `BEGIN IMMEDIATE`, read the lease, refuse if
unexpired, and otherwise claim it under a reserved owner (e.g.
`"rewrite"`) with a bumped fence and a TTL covering the operation, renewing it
as the transform pass proceeds. Release it after the swap. That reuses the
existing fencing machinery (`acquire_lease` at `:438`, `check_and_renew_lease`
at `:1214`) and turns a lost-commit race into the `LeaseHeld` refusal both
`OpenError` and `RewriteError` already model. Re-check the lease immediately
before the rename in any case.

## M3-03 — HIGH — CONFIRMED — the audit contract does not hold for registers or usage details
`packages/storage/src/storage/sqlite.gleam:668-681` (`rewrite_into` doc),
`:861` (`rewrite_copy` — `SELECT id, payload FROM entries` only),
`packages/session/src/session/repo.gleam:348-359` (`erase_text` doc),
`packages/session/test/session/rewrite_test.gleam:250-257`.

**Defect.** `rewrite_copy` rewrites exactly one table: `entries`. The
`registers` and `usage_ledger` tables are copied by `VACUUM INTO` and never
touched. `docs/spec-gaps.md` WP-C-full item 6 records the scope decision
("Rewrite scope is entry payloads only; registers and usage details are not
rewritten"), but the doc comment on `rewrite_into` states an *absolute* audit
claim that the scope decision falsifies: "The audit contract is that after
erasing a string, that string appears nowhere in the new file's raw bytes."

This is not a harmless mismatch of register. The registers that survive
untouched carry exactly the content a compliance erasure targets:

- `pending.entry` — queued user messages, i.e. steer and follow-up text
  verbatim, awaiting placement;
- `op.tool_args` — the model's tool-call arguments, write-once per step;
- `op.preparation` — compaction preparation, which by construction contains
  copies of the messages being summarized.

`usage_ledger.details` is an opaque JSON blob written straight through
(`insert_usage`, `:1451`) and is equally exposed.

The existing audit test passes only because `seed_secrets`
(`rewrite_test.gleam:58`) plants the needle exclusively in entries.

**Trigger.** Reproduced: seed a session with the needle in a message entry
*and* in a `pending.entry` register, an `op.tool_args` register, and a usage
row's `details`. Close, run `repo.rewrite_sqlite(erase_text(...))` — it returns
`Ok(Rewrite(generation: 1, ...))` — then read the raw bytes of the new file.
The needle is still present.

**Fix direction.** Either extend `rewrite_copy` to run the transform over
`registers.value` and `usage_ledger.details` as well (they are `RegisterValue`
and `JsonValue` blobs; the same decode/rewrite/re-encode shape applies, with
the same total-decode abort on collision), or — if the scope stays as it is —
delete the absolute audit sentence from `rewrite_into` and the storage
`CLAUDE.md` and replace it with the true, narrower claim ("appears nowhere in
any entry payload, retained tails included"), and say plainly in the doc that
queued pending payloads and tool arguments are out of scope. Leaving a false
compliance claim in place is the worse of the two.

## M3-04 — HIGH — CONFIRMED — migrations and schema DDL run *before* the lease
`packages/storage/src/storage/sqlite.gleam:300-312` (`initialize`), `:336`
(`ensure_schema`), `:395` (`migrate`), `:438` (`acquire_lease`),
`packages/session/src/session/session.gleam:98-102` (the migrate-on-open doc).

**Defect.** `initialize` runs, in order: `pragmas` (which includes
`PRAGMA journal_mode = WAL`, a write to the file header), `ensure_schema`
(which executes this build's full `schema_sql` DDL, then reads
`storage_version`, then runs the migration chain — each step's statements and
its version bump committing together), and only *then* `acquire_lease`. Every
write above happens on a file this process has not been granted, and may not be
granted at all.

Two consequences, both reproduced:

1. **A file another writer holds gets migrated anyway.** A live writer holds an
   unexpired lease and is committing. A second process opens with a migration
   chain: it applies the new DDL, runs the chain, bumps `storage_version`, and
   *then* returns `LeaseHeld`. The refused open has permanently upgraded a file
   underneath a live writer of the older build — the exact scenario the lease
   exists to prevent, and the one the storage `CLAUDE.md` describes as "the
   single-writer rule".
2. **`UnsupportedVersion` is not a clean refusal.** A file from a newer build is
   written to before it is refused: this build's `CREATE TABLE IF NOT
   EXISTS`/`CREATE INDEX IF NOT EXISTS` batch runs first, so v1 tables are
   recreated inside a v99 file. The doc promises the opposite — "a file from a
   newer build is refused with `UnsupportedVersion` **rather than misread**"
   (`session.gleam:101`) — and a newer schema that dropped or renamed a table
   would have it resurrected empty by an older binary.

This is also a direct pi deviation, and one `docs/spec-gaps.md` does not
record. pi §2.8: "older runs chained migrations **under the writer lease**
before returning (Part 7)." pi §7.4 leans on it as the reason migrations are
tractable at all: "migration runs at open under the writer lease, so it sees
**quiescent** state — no operation task is running, no effect is in flight."
Loom's ordering removes exactly that guarantee.

**Trigger.** Reproduced twice.
(a) Open a session under `live-writer` with a 600 s TTL; stamp the catalog down
to version 0 out of band; call
`sqlite.open_with_migrations(config(owner: "intruder"), clock,
[Migration(from_version: 0, statements: "CREATE TABLE migration_canary(x)")])`.
The call returns `Error(LeaseHeld("live-writer", ...))` — and afterwards the
file contains `migration_canary` and `storage_version = 1`, while the original
writer goes on committing.
(b) Hand-build a file containing only a `session` catalog at version 99; open
it. The result is `Error(UnsupportedVersion(found: 99, supported: 1))` — and
the file's bytes have changed, with all four of `entries`, `registers`,
`branch_meta`, `writer_lease` now created inside it.

**Fix direction.** Reorder `initialize` to acquire the lease first, then run
`ensure_schema`/`migrate` under it. The version read has to move with it: read
`storage_version` before the DDL so a newer file is refused with the file
untouched, and only apply the current build's DDL once the version is known to
be current or has been migrated up to current. `pragmas` sets `busy_timeout`,
which is needed for the lease transaction, so only the `journal_mode` write
needs to move. Add the two cases above to `migrate_test.gleam`, which today
covers only the happy chain and two refusals on unleased files.

## M3-05 — HIGH — CONFIRMED — concurrent creates write multiple catalog rows and permanently brick the file
`packages/storage/src/storage/sqlite.gleam:354-371` (`ensure_schema`'s fresh
-file branch), `:378` (the multi-row corruption arm), `:1269` (`read_session`),
`:323` (`pragmas`).

**Defect.** For a fresh file, `ensure_schema` does `SELECT storage_version FROM
session`, sees `[]`, and `INSERT`s the catalog row — as a bare statement, in no
transaction, and (per M3-04) before any lease exists. The `session` table has no
uniqueness constraint. Two processes creating the same session file both see an
empty catalog and both insert. The file then has two rows, and every code path
that reads the catalog matches on exactly one: `ensure_schema` (`:378`) returns
`CorruptSession("exactly one session row")`, `read_session` (`:1269`) fails
every commit with `Corruption`, and `read_generation` (`:1012`) fails too.

The file is unopenable forever and there is no repair operation. Even the
process that "won" the lease is dead on arrival: its very first commit fails,
because `do_commit` reads the catalog inside the transaction.

A second defect surfaced in the same reproduction: one of the racing openers
did not return an error at all — it exited with an unhandled `$busy` case
clause raised inside `PRAGMA journal_mode = WAL`
(`sqlite.gleam:332` → `run` → `sqlight.query` → `esqlite3:fetchall`). A
contended open crashes the caller rather than returning `OpenError`, which is a
totality break at exactly the boundary the style policy makes total.

**Trigger.** Reproduced: spawn eight processes that each call
`session.open_sqlite` on the same fresh path with the same clock. Outcomes were
one `ok`, three `LeaseHeld`, one `OpenFailed("5 database is locked")`, three
`CorruptSession("exactly one session row")` — and one run instead died with
`CaseClause('$busy')` from the journal-mode pragma. Afterwards
`SELECT COUNT(*) FROM session` returns **4**, and every subsequent open of that
path fails.

**Fix direction.** Wrap the create in the same `BEGIN IMMEDIATE` the rest of
the file uses: begin, re-`SELECT` the catalog, insert only if still empty,
commit — which serializes creators through SQLite's write lock. Belt and
braces, give `session` a fixed single-row identity
(`id INTEGER PRIMARY KEY CHECK (id = 1)`), so a second insert is a constraint
error rather than silent corruption. Separately, treat a `$busy` from the
pragmas as a retryable `OpenFailed` rather than letting it escape as an exit;
`PRAGMA busy_timeout` does not reliably cover the journal-mode switch.

## M3-06 — HIGH — CONFIRMED — healing covers orphaned calls but never orphaned results
`packages/session/src/session/session.gleam:719-724` (the compaction arm),
`:746-795` (`heal_orphan_calls`, `has_result`),
`packages/runtime/src/runtime/hooks.gleam:256-289` (`prepare`, the retained-tail
cut).

**Defect.** Rule 4 heals an assistant tool call with no matching result. There
is no symmetric rule for a tool *result* with no matching call, and the
projection has a producer for exactly that: the compaction arm splices
`retained_tail` into the context verbatim, immediately after the summary.

The retained tail is not batch-aligned. `hooks.prepare` builds it by folding
the projected messages from the newest end and keeping whatever fits inside
`keep_recent_tokens`; it stops at the first message that does not fit and
never backs up to a turn boundary (`is_split_turn` is hard-coded `False` and
`turn_prefix_messages` to `[]`). When the budget line falls between an
assistant message carrying a tool call and that call's result, the retained
tail begins with the `ToolResultMessage` and the `AssistantToolCall` is inside
the summarized prefix. The projected context then opens with a summary followed
by a tool result whose `tool_use` block does not exist anywhere — which every
mainstream provider rejects outright, and which no rule in `project_entries`
notices.

Rule 2 is a second producer of the same shape: dropping an assistant response
with stop reason `error`/`aborted`/`deferred` drops its tool-call blocks while
leaving any committed results for those calls on the branch.

**Trigger.** Reproduced purely: a chain of user → assistant(tool_use call-1) →
tool_result(call-1) → compaction whose `retained_tail` is `[tool_result(call-1)]`
→ user. `session.project_context` returns

```
[UserMessage("summary"), ToolResultMessage("call-1", ...), UserMessage("user-4")]
```

— a tool result with no preceding tool use, and no synthetic anything.

**Fix direction.** Add the symmetric heal to `heal_orphan_calls`: a
`ToolResultMessage` whose `tool_call_id` is not carried by any *earlier*
retained assistant message is dropped (or paired with a synthetic assistant
tool-call block, if the provider mapping prefers that). A single reverse pass
collecting live call ids before the forward pass costs nothing. Independently,
`hooks.prepare` should snap the tail cut to a turn boundary — that is what
pi's `turnPrefixMessages`/`isSplitTurn` fields, which the type already carries,
exist for. Add a projection test that compacts with a mid-batch tail.

## M3-07 — MEDIUM — CONFIRMED — healing at a moving frontier breaks the append-only invariant
`packages/session/src/session/session.gleam:664-672` (the rule-4 doc comment),
`packages/session/CLAUDE.md` ("On a settled history this is a no-op, which is
what keeps successive projections append-only"),
`packages/session/test/session/projection_test.gleam:196-201`.

**Defect.** The append-only claim is stated unconditionally in two places, and
it is only true under a precondition that is nowhere enforced: that every
projection happens at a settled frontier. When a projection heals a call and
the *real* result is committed afterwards, the earlier projection is not a
prefix of the later one — the healed synthetic occupied the position the real
result now occupies, and its content differs. pi §2.5 makes this a hard rule
("Across the requests of one lane, provider context must only grow at the
tail"), so a violation is a KV-cache invalidation on every subsequent request,
not just an aesthetic mismatch.

The property test (`append_only_context_invariant_property_test`) cannot catch
it: `step_turn` only ever appends *complete settled units* — the tool-call case
commits the assistant message and its result in the same step — and the comment
at `:196` writes the precondition into the generator as a justification.
The precondition is a real assumption about the runtime, and it deserves to be
stated as one at the projection boundary rather than assumed inside a test's
generator.

**Trigger.** Reproduced: user → assistant(tool_use call-1); project (yields the
synthetic "no result on this branch" error result); commit the real
`tool_result(call-1)`; project again. First projection's third message is the
synthetic; the second's is the real result. Neither is a prefix of the other.

**Fix direction.** No code change is obviously right — healing genuinely must
happen for forks and navigation. What is wrong is the unqualified claim.
Restate it at both sites as conditional ("a projection taken at a settled
frontier heals nothing, which is what keeps successive projections
append-only"), record the precondition in `docs/spec-gaps.md` under WP-C-full
item 5 alongside the placement decision, and — if the runtime can be made to
guarantee it — assert it there rather than assuming it here.

## M3-08 — MEDIUM — CONFIRMED — the memory rewrite re-stamps seq and ts; the SQLite one does not
`packages/session/src/session/repo.gleam:471-476` (the doc), `:502-508`
(the deliberate re-stamp that the destination then discards),
`packages/storage/src/storage/sqlite.gleam:929-931` (the SQLite path, which
preserves both).

**Defect.** `rewrite_memory` is documented as retaining everything but content:
"*everything else* is retained: every register namespace is copied verbatim and
the usage ledger is re-appended row for row, since a rewrite erases content,
not history." It even takes care to re-stamp the transform's output from the
stored row (`storage.stamp(new, seq: entry.seq, ts: entry.ts)`). That care is
wasted: the rebuild goes through `storage.commit` on a fresh store, and
`insert_entry` stamps every entry again with the destination's freshly
allocated seq and the destination clock's `now`. Entry timestamps are
destroyed and seqs are renumbered.

The SQLite rewrite does the opposite — it `UPDATE`s payloads in place and
re-stamps from the stored row, preserving both. So the two backends produce
materially different results from the same transform, which the conformance
posture ("both pass the same suite; that suite is the definition of correct")
does not admit. Entry `ts` is not cosmetic: the compaction and branch-summary
arms of the projection use it as the synthesized user message's timestamp
(`session.gleam:719-731`).

**Trigger.** Reproduced: a memory session with two message entries and one
register write has entries at `(seq, ts) = [(1, 1000), (3, 1000)]`. After
`rewrite_memory` with `clock.fixed(at: 777_000)` the rebuilt session reads
`[(1, 777000), (2, 777000)]`. `rewrite_test` never inspects seq or ts, so this
ships green.

**Fix direction.** Either give the memory backend a way to rebuild with
placement preserved (a store-level "restore" that writes rows as given, used
only by the rewrite), or narrow the doc: say plainly that the memory rewrite
re-stamps placement like a fork does and retains only *values*, and record it
in `docs/spec-gaps.md` next to WP-C-full item 6, which today mentions only the
absent generation counter.

## M3-09 — MEDIUM — CONFIRMED — the rewrite's temp path is fixed, unlocked, and blindly deleted
`packages/storage/src/storage/sqlite.gleam:698-700` (`let temp = path <>
".rewrite"` followed by an unconditional `simplifile.delete(temp)`).

**Defect.** Every rewrite of a given session uses the same derived path and
begins by deleting whatever is there — "a leftover copy from a crashed rewrite
is dead weight; remove it." Nothing distinguishes a leftover from a live one.
Two rewrites of the same session (or a rewrite plus a retry after a perceived
hang) collide destructively: the second deletes the first's in-flight copy out
from under its open connection.

The dangerous ordering is narrow but decisive. `rewrite_into` closes the copy's
connection at the end of `rewrite_copy` and *then* renames. A second rewrite
that recreates `temp` with a fresh `VACUUM INTO` inside that window has its
**pristine, unrewritten** copy renamed over the original by the first
rewrite — which reports `Ok(Rewrite(generation: n, entries_rewritten: k))`. The
operator is told the erasure succeeded and the file still contains the secret.
The generation bump is likewise lost, so an external index will not re-index
either.

**Trigger.** Reproduced (the collision, and its non-silent ordering): run
`rewrite_into` with a transform that, on its first entry, does what a second
rewrite does on entry — `delete(temp)` and `VACUUM INTO temp` from the source.
The outer rewrite's subsequent writes hit the unlinked inode and it fails with
`RewriteFailed("sqlite: 1 attempt to write a readonly database")` — a
misleading error for what actually happened. The silent-success ordering above
(the collision landing between `rewrite_copy` returning and the rename) is
SUSPECTED rather than reproduced, since it needs a genuine interleaving; the
code path is plain to read.

**Fix direction.** Fold this into M3-02's lease: a rewrite that holds the
writer lease cannot race another rewrite, because the second one refuses with
`RewriteLeaseHeld`. Independently, make the temp path unique per attempt
(mint a suffix) so a leftover is never confused with a live copy, and reap
leftovers by pattern only when the lease is held.

## M3-10 — MEDIUM — CONFIRMED — a tree fork copies strand leaves without checking they name copied entries
`packages/session/src/session/repo.gleam:119-131` (the read sequence),
`:208-227` (`ForkTree`'s register collection).

**Defect.** `fork` reads the source through four or more separate storage
calls: `collect_entries`, then `get_register`/`list_registers` for
configurations, leaves, names and labels. Each is its own actor round trip.
The module doc acknowledges that this can straddle two half-states and declares
fork "defined over a *quiescent* source... the in-process operations trust their
caller." Fine as a contract — but the destination transaction is atomic and
could cheaply refuse an incoherent copy instead of committing one.

Under tree scope the entries are read *first* and the leaves *second*, so a
commit landing between them yields a destination whose `strand.leaf` names an
entry that was never copied. That is not caught anywhere: leaves are copied
verbatim ("a fork moves cells, it does not interpret them", `:173-174`), the
destination transaction only enforces parent-must-exist for `InsertEntry`
writes, and `require_empty` checks the destination, not coherence. The result
is a fork that succeeds and produces a strand that cannot be projected at all.

**Trigger.** Reproduced with the end state a straddled read produces: a
one-entry memory session whose `strand.leaf` for `main` names an entry id that
is not in the tree. `repo.fork(scope: ForkTree)` returns `Ok`; the forked
session's `strand_leaf` is that id, and `session.project_context` on it returns
`Error(StoreFailure(UnknownEntry(...)))`.

**Fix direction.** Validate before committing: `collect_registers` already has
`copied_ids(entries)` for the label filter under branch scope — reuse it under
tree scope to check every copied `strand.leaf` names a copied entry, and add a
`ForkIncoherentSnapshot` variant to `ForkError` for the case where it does not.
That converts a silently broken destination into a refusal the caller can
retry, without weakening the quiescence contract.

## M3-11 — LOW — CONFIRMED — pi's `position` fork option is missing and unrecorded; fork type names have drifted in the docs
`packages/session/src/session/repo.gleam:48-61` (`ForkScope`),
`packages/session/CLAUDE.md` (Key Types), `docs/spec-gaps.md` WP-C-full.

**Defect.** pi §2.7's `ForkOptions` for branch scope is
`{ scope?: "branch"; entryId?: string; position?: "before" | "at"; id?: string }`.
`ForkBranch(strand, at)` implements only `position: "at"`; there is no way to
fork at the point *before* an entry, which is the natural spelling for "branch
off just before this message". `docs/spec-gaps.md` WP-C-full records four
other fork deviations (configuration source, re-stamping, the absent
parent-session record, fact semantics) but not this one, so it reads as
complete when it is not. `id` (the destination session id) is covered by
item 3.

Separately, `packages/session/CLAUDE.md` lists the constructors as
"`ForkStrand` / `ForkBranch`"; the code has `ForkBranch` / `ForkTree`. The
doc-gardening pass has drifted from the type.

**Trigger.** N/A (missing feature and stale doc).

**Fix direction.** Add a WP-C-full spec-gap entry stating that `position` is
unimplemented and that branch scope always means `"at"`, or add the variant.
Fix the constructor names in the package doc and its `AGENTS.md` mirror.

## M3-12 — LOW — CONFIRMED — the current build's DDL runs before the chain, constraining what a migration step can be
`packages/storage/src/storage/sqlite.gleam:341-346` (`ensure_schema` executes
`schema_sql` first), `:391-394` and `:146-154` (the `Migration` docs).

**Defect.** Migration steps run after this build's complete
`CREATE ... IF NOT EXISTS` batch has already been applied to the old file. The
type doc acknowledges the consequence ("Steps run after the current schema's
`CREATE ... IF NOT EXISTS` DDL has been applied, so they mostly alter or
backfill"), but two sharper corollaries are unstated and will bite the first
real schema bump:

1. A step that creates an object the current `schema_sql` also creates must
   itself be `IF NOT EXISTS`, or the step fails and the file becomes
   permanently unopenable — the failure is not recoverable by retry, because
   the DDL runs again on the next open.
2. No step can ever run *before* the current DDL, so a migration that must
   rename or restructure an existing table (rather than add to it) has no
   place to stand.

Also worth stating at the type: a step's `statements` run inside
`BEGIN IMMEDIATE`, so `VACUUM` and `PRAGMA journal_mode` cannot appear in
one — both are the natural instinct after a data-shape migration, and pi §7.3
explicitly pairs a migration with a compaction for the JSONL backend.

**Trigger.** N/A (design constraint, not a live defect at version 1).

**Fix direction.** State both corollaries on `Migration`, and consider giving
the chain a pre-DDL hook slot for the restructuring case before the first
version bump makes the ordering load-bearing.

---

## Checked and sound (coverage of what was verified correct)

- **Fork parent ordering — no dangling parents in either scope.** Branch scope
  scans `branch_scan(from: at) |> branch_order(OldestFirst)` with no stop or
  limit, which is the complete ancestor chain to the root, so the chain's
  oldest entry has `parent: None` and every other entry's parent precedes it.
  Tree scope uses `entry_scan()`, whose constructor defaults are
  `order: OldestFirst, limit: None` (`storage.gleam:509`), and a child's seq is
  always above its parent's because parent-must-exist is enforced at commit and
  seqs strictly increase. Writes apply in list order, so the destination's
  parent check passes in both cases.
- **Fork seq/ts re-stamping.** The destination assigns its own seqs in write
  order and its own `ts`, ids are preserved, and the entry-to-entry order of
  the copy matches the source — which is exactly what `docs/spec-gaps.md`
  WP-C-full item 2 records as the deviation from pi's silence on placement.
- **Ledger zeroing does not double-count.** `stats.usage` is derived only from
  `InsertUsage` writes (`insert_usage` at `:1455`); the fork issues none, so
  the destination ledger and stats are empty even though the copied entries'
  messages carry their own display usage. `message_count` counts copied
  `MessageEntry` rows, matching the source. Both are asserted in
  `fork_test.gleam`.
- **`fact.label` filtering.** The label register's key *is* the entry id
  (`machine/internal/build.gleam:147` writes
  `set(FactLabel, ids.entry_id_to_string(entry), ...)`), so `copy_labels`'s
  `set.contains(copied, cell.0)` filter is keyed correctly; a label whose
  target is not copied stays behind, and tree scope copies all of them because
  it copies all targets. This matches pi §2.7 exactly.
- **Fork never touches the source, and every failure path closes the
  destination.** `require_empty` runs before the single copy transaction; every
  error arm after `open_destination` runs `session.close(destination)`, which
  releases the SQLite lease scoped to that writer's own `(owner, fence)` pair.
- **Operation and terminal state stay behind.** `op.*`, `pending.entry`,
  `strand.last_result` and `fact.custom` are absent from both scopes' register
  collection, and every destination strand gets a freshly encoded
  `StrandState(current_operation: None, pending_next_run: [])`. A fork taken
  mid-operation therefore cannot resurrect half-settled operation state; the
  entries it copies mid-batch are handled by rule 4 at projection.
- **`erase_text` over JSON escapes.** The transform runs over the decoded
  `JsonValue` tree, not over serialized text, so a needle containing quotes,
  backslashes or newlines matches the Gleam string it lives in and never
  straddles an escape sequence. Verified with the needle `a"b\c\n d`: it is
  replaced cleanly and the entry re-decodes. Object keys are left alone by
  construction and an unchanged entry correctly reports `Ok(None)`.
- **`erase_text` totality at the boundary.** The rewritten payload is decoded
  back through `core_codec.decode_entry`, so a needle colliding with structural
  vocabulary aborts with a `CorruptionReport` rather than producing an
  unreadable store. A needle inside an entry id or parent additionally trips
  `check_placement`, and a matching needle inside a tool-call id is replaced
  identically in the call and its result, so pairing survives.
- **A migration step and its version bump are one transaction.** `migrate`
  opens `BEGIN IMMEDIATE`, execs the batch, updates `storage_version`, and
  commits; any failure rolls back. Verified with a two-statement step whose
  second statement fails: neither the first statement's table nor the version
  bump survives, and the file resumes the chain on the next open.
- **A version-refused open leaves no lease behind.** `ensure_schema` returns
  before `acquire_lease` is reached, so `UnsupportedVersion` (in either
  direction) leaves `writer_lease` empty and `open_with_migrations` closes the
  connection on the error path. Confirmed by counting lease rows after both
  refusals. (The file *content* is a separate matter — see M3-04.)
- **Generation read/modify/write is inside the copy's transaction.**
  `bump_generation` runs between the entry updates and `commit_sql` inside
  `rewrite_copy`'s `BEGIN IMMEDIATE`, so within one rewrite the read-modify-write
  cannot interleave; the `VACUUM` runs only after that commit, so no replaced
  bytes survive in free pages of the copy. `read_generation` treats a missing
  metadata blob or missing field as 0 and a non-integer as corruption, and
  `generation(path)` refuses to conjure a database for a missing file
  (`require_session_file`).
- **Healing insertion order.** For an assistant message with several orphaned
  calls, the accumulator arithmetic
  (`list.append(list.reverse(synthetics), [message, ..healed])` followed by the
  final reverse) yields the synthetics in original content order directly after
  their assistant message — verified by hand and pinned by
  `fork_at_assistant_with_calls_heals_at_projection_test`.
- **`has_result` scope.** Healing consults only the messages *after* the
  assistant message in the projected list, which is the right scope: a result
  that exists on another branch is correctly *not* consulted, because it is not
  in this branch's context. A healed synthetic can therefore never collide with
  a real result that is actually reachable in the same request.
- **Projection rule order.** Reverse to oldest-first, compaction opens with
  summary-then-retained-tail, `error`/`aborted`/`deferred` assistant responses
  dropped while `length` is retained, unregistered custom entries excluded,
  healing, then the transform hook last — matching pi §2.5 rules 1-5 with
  healing placed per `docs/spec-gaps.md` WP-C-full item 5. A `None` leaf short
  -circuits before the hook, which is the documented behaviour.
- **New actor messages are closed-handle-safe.** `RenewLease`, `ScanBranchPlan`
  and `Segments` all answer `HandleClosed` in `handle_closed`, and `Close`
  deletes only the writer's own `(owner, fence)` pair, so a stale owner cannot
  release its replacement's lease.
