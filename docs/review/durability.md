# Adversarial review — durability plane

**Scope.** `packages/core` (ids, entry, register, tx, json, msgpack, codec,
corruption, clock, message), `packages/storage` (storage behaviour, memory,
sqlite, internal/branch), `packages/session` (session.gleam — which also holds
the projection; there is no separate `projection.gleam`), and
`packages/conformance/src/conformance/storage_suite.gleam`.

**Method.** Read the design (`docs/architecture/durability.md`), the frozen
contracts (spec Part 1.1–1.2), and `docs/spec-gaps.md` for intended semantics,
then read every source file line by line asking, for each: what input breaks
the total decoder, what interleaving breaks the single-writer/CAS assumptions,
what the two backends disagree on that the suite does not cover, and where a
doc comment promises more than the code delivers. Codecs were probed for
crash-on-adversarial-input; the SQLite commit path for CAS/lease/branch-index
ordering; both backends for behavioural divergence. Findings are ordered by
severity. Nothing rises to CRITICAL or HIGH: the CAS ordering, seq
monotonicity, write-once enforcement, branch-index segment maths, and lease
fencing arithmetic were all traced and found correct.

---

## DUR-01 — MEDIUM — CONFIRMED — backends disagree on a negative `limit`
`packages/storage/src/storage/memory.gleam:554` (`take_limit`) vs
`packages/storage/src/storage/sqlite.gleam:1996` (`limit_sql`).

**Defect.** `scan_entries` and `scan_usage` apply the row cap outside the
shared `branch` pipeline, and the two backends clamp a negative limit
differently. Memory calls `list.take(rows, n)`, which returns `[]` for any
`n <= 0` (stdlib `list.gleam:565`, `n <= 0 -> []`). SQLite emits
`" LIMIT " <> int.to_string(n)`; SQLite defines a **negative LIMIT as no
limit at all**, so the query returns *every* row. For the same query on the
same data, memory yields `[]` and SQLite yields the full result set — a silent,
backend-dependent wrong answer. (Limit `0` happens to agree: both yield `[]`.)
Branch scans are immune because they route the limit through
`branch.new`/`is_zero_limit` (`internal/branch.gleam:47`), which both backends
share; only the two seq-range scans bypass it.

**Trigger.** `storage.scan_entries(store, storage.entry_scan()
|> storage.entry_limit(-1))` — or any caller that computes a limit such as
`keep_recent - consumed` that can go negative. Memory: `[]`. SQLite: all rows.

**Fix direction.** Clamp negatives at the boundary (treat `Some(n)` with
`n < 0` as `Some(0)`, or as `None` — pick one and apply it in both backends),
or make the `EntryScan`/`UsageScan` constructors reject non-positive limits.
Add a negative-limit case to `entry_scan_checks`/`usage_scan_checks`; the
suite currently tests only `limit 0` and positive limits, so it misses this.

## DUR-02 — MEDIUM — CONFIRMED — lease *fencing* path is untested; doc claims otherwise
`packages/storage/src/storage/sqlite.gleam:701` (`check_and_renew_lease`),
`:335` (`acquire_lease` steal branch), test file
`packages/storage/test/storage/sqlite_test.gleam`.

**Defect.** `docs/architecture/durability.md` states "The conformance suite
duels two writers through exactly that sequence, down to checking that the
refused commit left no row behind," and the suite header lists "lease fencing
under simulated dueling writers." The actual SQLite tests are only
`lease_held_refuses_second_open_test` (an unexpired lease refuses a second
`open`) and the close-releases-lease tail. There is **no** test that: steals an
*expired* lease with a bumped fence (`acquire_lease`'s
`expires_at_ms <= now -> claim(fence + 1)` branch), then drives the fenced-out
original writer's commit and asserts it fails with `Faulted` and applies
nothing (`check_and_renew_lease`'s `[#(owner, _), ..] -> Error(FailLease)`
path → `fail_to_commit_error` → `Faulted`). This is the security-critical
zombie-writer refusal (design priority #1, security & isolation). The code is
correct by inspection — fence is bumped on steal, every commit re-reads
`(owner, fence)` inside its own `BEGIN IMMEDIATE` and rolls back on mismatch —
but the guarantee is unexercised, so a future regression in the fence
arithmetic would ship green.

**Trigger.** Open owner `w1` (short TTL); read lease; advance the injected
clock past expiry; open owner `w2` (steals, fence 2); from `w1`'s still-live
handle `storage.commit(...)`; assert `Error(Faulted(_))` and that the DB is
byte-unchanged.

**Fix direction.** Add the fenced-duel test above to the SQLite suite (it must
live in the SQLite test main, not the shared suite, since it is file-specific).

## DUR-03 — LOW — CONFIRMED — branch-index metadata invariants are unasserted
`packages/storage/src/storage/sqlite.gleam:530` (`segments`, `do_segments`).

**Defect.** `durability.md` lists, among the SQLite-only conformance checks,
"the branch-index metadata invariants (one segment per divergence, unique
tips, every base naming a live segment strictly below its own tip)." The
`sqlite.segments/1` accessor exists precisely for this, but no test in
`sqlite_test.gleam` (or elsewhere) calls it or asserts any of those three
invariants. Only the *root-path reproduction* torture (the shared suite's
`branch_index_checks`) is implemented, which validates scan output but not the
`branch_meta` shape (e.g. it would not catch a base whose `base_seq` sits at or
above its own tip, or a duplicated segment on one divergence, as long as scans
still happened to reproduce paths).

**Trigger.** N/A (missing assertions). Build a divergent tree, call
`sqlite.segments`, and check: tips unique, each `base = Some(#(id, seq))`
names an existing segment with `seq < tip_seq`, one segment per divergence.

**Fix direction.** Add a segments-invariant test over the
`branch_index_checks` tree.

## DUR-04 — LOW — SUSPECTED — decoders recurse without a depth bound
`packages/core/src/core/msgpack.gleam:349`/`:371` (`decode_array_loop` /
`decode_map_loop` via `decode_value`), `packages/core/src/core/json.gleam:219`
(`parse_value` → `parse_items`/`parse_members`).

**Defect.** Nesting is decoded by mutual recursion whose depth equals the
nesting depth of the input (`decode_value` → `decode_array` →
`decode_array_loop` → `decode_value`; likewise objects/arrays in JSON). There
is no depth cap. Both module docs assert decoding "never crashes" / is "total".
A deeply nested but otherwise well-formed input (`<<0x91>>` repeated N times,
or `[[[[…]]]]`) recurses to depth N and materialises an N-deep value; on the
BEAM this does not segfault but grows the process heap unboundedly, so a large
enough frame OOM-kills the decoding process (or trips `max_heap_size` if set) —
a total decoder that faults rather than returning a `CorruptionReport`. msgpack
is the effect-plane boundary from semi-trusted sandbox helpers/satellites
(§3.3), so this leans on the broker capping the `u32` frame length; JSON is our
own durability boundary, reachable only via a corrupt/hostile session file.

**Trigger.** `msgpack.decode(<< a few hundred thousand 0x91 bytes >>)` or the
JSON analogue. Confirm whether the broker bounds frame size before core sees it.

**Fix direction.** Thread a decreasing depth budget through `decode_value` /
`parse_value` and return a `CorruptionReport` past a fixed ceiling; document
the ceiling.

## DUR-05 — LOW — CONFIRMED — query-plan CI assertion is weaker than the doc claims
`packages/storage/src/storage/sqlite.gleam:1837` (`do_scan_branch_plan`),
test `sqlite_test.gleam:91` (`branch_plan_drives_from_branch_entries_test`).

**Defect.** `durability.md` says the plan assertion enforces "first step a
covering search on `ix_be_seq`, `entries` probed by key, and any
`TEMP B-TREE FOR ORDER BY` or scan of `entries` fails the build." The actual
test asserts only `string.contains(plan, "ix_be_seq")` and
`!string.contains(plan, "TEMP B-TREE")`. It does **not** assert the `entries`
access is a primary-key probe (a full `SCAN entries` could still slip through
as long as `ix_be_seq` appears anywhere in the plan text), and it never checks
`segment_sql_asc` — the `ORDER BY … ASC` variant used by every `OldestFirst`
branch scan — whose plan is never exposed or asserted at all.

**Trigger.** N/A (missing assertions).

**Fix direction.** Also assert absence of `SCAN e`/`SCAN entries` and presence
of a `SEARCH entries … USING PRIMARY KEY`; expose and assert the ASC plan too.

## DUR-06 — NIT — unbounded error-context strings from adversarial input
`packages/core/src/core/codec.gleam` (e.g. `:255`, `:1096`, and every
`context: json.to_string(other)`).

Decode-failure reports embed `json.to_string(other)` — the full re-serialised
offending value — as `context`, with no length cap (unlike `json.parse`'s own
`excerpt`, which trims to 24 codepoints). A decode error on a multi-megabyte
array therefore allocates a multi-megabyte report string in the error path.
Harmless functionally; consider truncating oversized contexts.

---

## Checked and sound (coverage of what was verified correct)

- **CAS ordering.** Both backends evaluate every `Tx.expected` against the
  pre-transaction register state before any write; SQLite does so inside
  `BEGIN IMMEDIATE` after the lease check but before `apply_write`, and any
  mismatch rolls the whole transaction back (`memory.gleam:121`,
  `sqlite.gleam:663/782`). `None`=must-not-exist and `Some(seq)`=exact-seq are
  both correct; the placement pattern round-trips.
- **Seq monotonicity / gaps / write order.** `next_seq` is consumed once per
  write in list order in both backends; register deletes consume a seq; failed
  commits consume none (memory by purity, SQLite by `ROLLBACK`).
  `first_seq = next_seq - len(writes)` in SQLite equals memory's captured
  initial `next_seq`, including the empty-tx case.
- **Write-once / shared id namespace.** `check_fresh_id` covers both `entries`
  and `usage_ledger` (SQLite via a summed `COUNT(*)`; memory via
  `entries`+`usage_ids`); a cross-namespace duplicate is corruption.
- **Lease fencing arithmetic (code).** Steal bumps the fence; every commit and
  `renew_lease` re-reads `(owner, fence)` inside its own IMMEDIATE tx and
  faults on mismatch applying nothing; `close` deletes only the writer's own
  `(owner, fence)` pair. Correct — only the *test* is missing (DUR-02).
- **Branch-index segment maths.** Divergence copies rows down to the newest
  compaction found by walking the base chain (`newest_compaction` recurses
  through `chain_windows`), links the base at that boundary, resolves the cover
  through a physical `branch_entries` row (mandatory rules 1 & 2), and reports a
  cyclic base chain as corruption rather than looping. Entry insert + index
  update share one SQL transaction, so no crash can desync the index from the
  tree. `clip_windows` boundary maths (`lo < hi`, `lo < seq <= hi`) was checked
  against stop/cursor in both directions and is off-by-one-free.
- **Total decoders (crash-freedom).** msgpack rejects `0xc1`, float32, ext /
  fixext, truncated payloads, invalid utf-8, NaN/Inf float64 (falls through to
  `tag_error`), ragged bit arrays, and trailing bytes as reports; length-prefixed
  str/bin/array/map do not pre-allocate (they fail on `slice`/on running out of
  bytes), so a huge declared length is not a DoS. JSON rejects leading zeros,
  bare `-`, empty exponents, unescaped control chars, lone surrogates, and
  out-of-range floats as reports. UUID parsing enforces 8-4-4-4-12, version 7,
  and RFC variant. Register-namespace and entry-kind vocabularies are closed and
  reject unknowns. No `let assert`/`panic`/partial match on any decode path
  (aside from the depth concern in DUR-04).
- **UUIDv7 identity.** Mint/parse round-trip; follower minting copies the 48-bit
  time prefix; `mint_uuid_at` masks ms/rand_a/rand_b to their field widths;
  canonical text is lowercase and time-sortable. Minting is pure and
  deterministic from clock+seed.
- **Stats projection.** message_count counts only `MessageEntry`; usage is the
  field-wise ledger sum in both backends; the suite's `commit_ok` re-derives and
  asserts equality after every successful commit, and `atomicity_checks`
  confirms a failed commit leaves stats at `empty_stats`.
- **`list_registers` ordering parity.** Memory `string.compare` resolves to
  Erlang binary (byte-wise) comparison; SQLite `ORDER BY key ASC` uses BINARY
  collation (byte-wise); UTF-8 byte order equals codepoint order, so the two
  agree on non-ASCII keys. LIKE metacharacters in prefixes are escaped
  (`like_prefix_pattern`) and the suite exercises `%`/`_` keys.
- **Close semantics.** Idempotent in both backends; reads on a closed handle
  return `HandleClosed`, commits return `Faulted`; the actor stays alive to
  answer in-band rather than crashing callers.
- **Context projection (session).** Stops inclusively at the first compaction,
  reverses to oldest-first, opens with summary+retained_tail, drops
  error/aborted/deferred assistant responses, skips custom entries — consistent
  with the shared branch pipeline; `None` leaf → empty context.
