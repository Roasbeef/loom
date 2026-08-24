# protocol-change/001 — make `BranchSummaryEntry.from_id` optional

**Status**: proposed · **Affects**: Part 1.1 `Entry` · **Raised by**: WP-A

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

Pending maintainer sign-off. Until accepted, core implements the frozen
non-optional form.
