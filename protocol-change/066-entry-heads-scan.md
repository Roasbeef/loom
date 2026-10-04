# protocol-change/066 — `scan_entry_heads`: the entry inventory without payloads

**Status**: ACCEPTED 2026-10-04 · **Affects**: Part 1.2 `Storage` behaviour ·
**Raised by**: the startup and memory bench (`docs/design-notes/startup-and-memory.md`) ·
**Implemented**: storage (both backends), conformance, `client/gateway`

## Problem

When a session opens, the gateway primes itself: it pulls every entry above a
high-water of zero, so that its entry-to-strand attribution cache and its
high-water describe the history already in the store, and the first real pull
reports changes instead of history. The pull reads the entries with
`scan_entries` and decodes each one's full JSON payload. The prime then throws
the decoded entries away. What it keeps is, per entry, the id, the parent id
and the seq.

On the bench's long session (2,438 entries, 9.5 MB of payload) that decode is
about 250 ms of the roughly 650 ms between `sessions.open` and the session
being resident. The `entries` table already stores `id`, `parent_id` and
`seq` in columns, so SQLite could answer the three fields without reading a
payload, but the `Storage` behaviour has no read that returns less than a
whole `Entry`. The gateway cannot ask for less than it needs, and a caller
cannot work around that by calling `scan_branch`, which also returns whole
entries.

## What was considered

**Make the gateway's decode faster.** The decode is `gleam_json` over a
payload whose size is dominated by tool output and message text. Nothing in
the three fields depends on that text, so a faster decode still reads and
parses all of it.

**Cache the attribution on disk.** Persist the strand map beside the session
and read it at open. That adds a second durable fact that has to agree with
the entries after every commit, a crash, and an offline rewrite, to save work
the entries table can already do. It also moves a rebuildable index into the
durability plane.

**Add a branch-index read.** `branch_entries` holds `entry_id`, `entry_seq`
and `entry_type` per branch. It has no parent column, and the gateway's
fallback attribution walks parent links across entries no leaf covers, so it
would still need the entries table.

**Add `scan_entry_heads` to the behaviour.** One read, the same query as
`scan_entries`, projected to the three fields. This is the smallest read that
answers the question, and it can be defined entirely in terms of an existing
frozen read, which is what keeps the two from disagreeing.

## Decision

Add one function to Part 1.2:

```gleam
pub type EntryHead { EntryHead(id: EntryId, parent: Option(EntryId), seq: Seq) }
pub fn scan_entry_heads(h, q: EntryScan) -> Result(List(EntryHead), StorageError)
```

`scan_entry_heads(h, q)` answers exactly what `scan_entries(h, q)` would
answer, projected to those three fields and in the same order. That is a
single normative sentence, and it carries the whole contract:

- The same `EntryScan` filters apply: `kind`, `custom_type`, `from_seq`,
  `to_seq`, `order`, and `limit`, including the rule that a limit of zero or
  below returns no rows.
- The same entries come back, in the same order, with no row added or dropped.
- A row whose stored id text does not parse is `CorruptRow`. A column of the
  wrong type (a `seq` that is not an integer, an `id` that is not text) fails
  the row decoder and is a `BackendFault`, exactly as `scan_entries` answers
  for a payload that is not a blob. The projection is a view over the same
  rows, so it adds no new failure.
- Rule 5 applies: the SQLite query is served from an index with no
  `TEMP B-TREE FOR ORDER BY`. It orders by `seq` through `ix_entry_seq`, which
  also carries the primary key, and CI asserts the plan.

`EntryHead` is a new public type. It is not an `Entry` and cannot be
committed; it names an entry and its position and is not a second source of
truth. Part 1.1 is otherwise unchanged. The conformance suite asserts, for
every query shape its entry-scan checks use, that `scan_entry_heads` equals
`scan_entries` projected, on both backends. That agreement is the definition
of correct for this function.

The gateway uses it for the prime only. A later pull emits entries, so it
needs the payloads and keeps decoding. The two paths share one attribution
routine, so the claim rules (strand order, `BranchOwned`, `Shared`,
`Unverified`, and the parent-chain fallback) exist once.

## What it costs

- Every constructor of the `Storage` record gains one field: the two
  backends, `session.erase`, and the conformance simulation store. Wrappers
  that build on `Storage(..store, ...)` inherit it. The compiler finds the
  rest.
- One new SQL statement in `storage/sqlite`, and one new plan assertion beside
  the branch-query plan.
- The additive function does not change any durable format or wire frame.
  `storage_version` stays as it is, and a session written before this change
  opens unchanged, because the columns it reads have always been written.
- A third read that must keep agreeing with `scan_entries` is a standing
  obligation. The conformance property above is what discharges it; a new
  `EntryScan` field has to be added to that property when it is added to the
  scan.
