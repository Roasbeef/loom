# protocol-change/001 — make `BranchSummaryEntry.from_id` optional

**Status**: ACCEPTED 2026-08-24 · **Affects**: Part 1.1 `Entry` ·
**Raised by**: WP-A · **Implemented**: core + machine + spec text

## Problem

pi's `BranchSummaryEntry` allows `fromId: null` for a summary whose source
branch starts at the root. Our frozen contract declares
`from_id: EntryId`, which makes that state unrepresentable and would force
the format-4 import to reject or fake such entries.

## Proposal

```gleam
BranchSummaryEntry(id: EntryId, parent: Option(EntryId), seq: Seq, ts: Int,
                   from_id: Option(EntryId), summary: String, from_hook: Bool,
                   usage: Option(Usage))
```

`None` means "summarized from the root". Codec: emit `null`, accept a
missing field as `None` for forward compatibility.

## Impact

Core codec change plus any Part 1.1 consumer that reads `from_id`
(none yet beyond WP-A). No storage schema impact — the field lives in the
payload BLOB.

## Decision

**Accepted.** The adversarial case for rejection — keep the field total
and represent a root-sourced summary with a sentinel or the first entry's
id — was considered and dismissed: a sentinel misstates provenance in a
write-once store, pi's data model genuinely produces null here, and the
format-4 import would otherwise reject real transcripts. Nothing in the
codebase dereferences `from_id` today, so no invariant weakens; machine's
acceptance continues to reject summarize-from-root until navigation work
needs it, which keeps `Some` the only value the harness currently writes
while the wire admits both.
