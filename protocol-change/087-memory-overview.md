# protocol-change/087: a read-only overview of what the daemon remembers

**Status**: PROPOSED 2026-10-11, for the memory-as-recall work
(`docs/design-notes/memory-recall.md`, slice F). **Affects**: the session wire
(one command and one snapshot mode), one new public read in
`storage/sqlite` (`scan_entries_at`), a Session-pane section on the owner's web
page and an overlay in the terminal. No existing command, event or field
changes, and no event is added. **Raised by**: the observation that the
settings and files that decide what a run is told (`[memory] inject`, the
notes index, `loom-rules.md`) were each visible only by opening a file.
**Builds on**: [086](086-memory-proposals.md) (an owner-only snapshot command
over harness-owned text, and the `loom-rules.md` file this reads) and
[073](073-web-session-grants.md) (the owner-only listing precedent).
**Implemented**: `client/memory_overview`, `client/protocol`, `client/gateway`,
`client/serve`, `storage/sqlite`, `session_view/memory_overview`, `tui/memory_panel`,
`web_view/view/memory`.

## Problem

Memory reaches a run through three doors that each have their own file and
their own switch. `[memory] inject` selects the notes index or
nothing. The agent's typed notes live in a SQLite store nobody opens by hand.
The rules a person approved are appended to `loom-rules.md`, which every new
session carries whole. An owner who wants to know what the next run will be told
has to read a configuration file, a sidecar, a rules file and a database, and
has no way to see whether the notes the agent wrote are the ones it is being
handed.

The memory-recall design note names this as the gap it leaves after the notes
index and the proposal queue: a write-only store the owner cannot inspect is
harder to trust than one they can. Showing it needs one read that gathers the
four facts, and two panes that draw it.

## What was considered

### Reading the store with the writer's lease

`client/memory.open` is the open that exists, and it takes the writer lease.
That would make the overview wait on a `remember` call, or worse, take the
lease away from one: an overview that held it for a read would block the next
note for as long as it took. Rejected.

### Reading only the notes index sidecar

`loom-memory.notes` is derivable, small and needs no database, so the overview
could list notes from it. It would lose what the sidecar was designed to lose:
it is capped at 1 KiB, so it holds a few dozen titles and ends with
`+N more notes`, it carries no kind except in a parenthesis the reader would
have to parse back out, and it is stale by one write whenever the index rebuild
failed. The overview exists to show the store, not the projection a run sees of
it. Rejected as the source, kept as one of the files whose size is shown.

### A lease-free scan in `storage/sqlite`

Chosen. `read_entry` and `read_entries_around` already open a session file
read-only, check that it is the session the caller named, and never touch a
lease, but both start from an entry id. `scan_entries_at(path, session, query)`
runs the existing entry scan through the same identified read-only connection.
The memory store's own identity is read the way the history source reads it
(`sqlite.identity`), so a file that is not the memory store is refused before
a row is read. The query carries the limit, and the overview asks for at most
256, the store's lifetime note ceiling.

### A push when memory changes

The proposal queue pushes `proposals_changed` because a decision is an event a
person is waiting for. A note is written by the agent mid-run, often several
within a turn, and an overview that redrew on each would flicker for no one's
benefit. A `memory_changed` event would also be a new bus variant for a feature
with no action attached to it. Rejected. A client re-reads when the overview
opens and at most once a minute while it is open.

### An editing door

Deleting a note, pinning one, expiring old ones, a read counter beside each, a
switch for `inject`, a search box and a history of decided proposals were all
asked for or suggested. Each is a different feature with its own failure modes,
and the memory-recall note's cut list already excludes counters and expiry
until the first usage numbers say they are needed. The overview is read-only,
the setting is named by its key (`[memory] inject`) so a reader knows where to
change it, and the proposals have their own review.

## Decision

### The command and the snapshot

`memory_get` has an empty body and is answered by a snapshot
`{"mode":"memory","board":{...}}`. It is the daemon owner's alone, as
`proposals_get` is: an observer attachment or an authenticated member is refused
with `forbidden`, and a host that has no overview answers `unsupported`. It is
not a read an observer may make, because the rows are model-authored text and
the rules are the instructions a person approved for every later session.

### The board

```
{
  "inject":   "off" | "notes",
  "receives": [ {"file", "state", "bytes", "reason"?}, ... ],
  "notes":    { "state":"ok", "total", "omitted", "rows":[ {"kind","date","title","description","legacy"} ] }
            | { "state":"unavailable", "reason" },
  "rules":    { "state":"ok", "total", "omitted", "rows":[ {"id","approved","session","line"} ] }
            | { "state":"unavailable", "reason" },
  "proposals":{ "state":"ok", "pending" } | { "state":"unavailable", "reason" }
}
```

`receives` names the two files a run may read, always in this order:
`loom-rules.md`, `loom-memory.notes`. `state` is
`injected`, `off`, `missing` or `unavailable`. The rules file is injected into
every new session whatever `inject` says; the notes index is `injected` when
`inject` names it and, when it exists and `inject` is `off`, is `off`. `bytes` is the size on disk, which is what a run reads, less
the fence and attribution it adds. A file over the size its reader refuses above
(4 KiB for the index, 16 KiB for the rules) is
`unavailable` with a `reason` and is not read.

Files are named, never located. No path appears anywhere in the board.

### Bounds

At most 50 notes and 50 rules. A title is cut to 80 characters, a description to
160 and a rule's first line to 200, each folded to one line, with an ellipsis
where it was cut. The encoded board is at most 48,000 bytes. When the bounds cut
rows, `total` still counts what the store holds and `omitted` is `total` less the
rows listed, on every section, always present. A board over the byte bound loses
rows from the end of the longer list until it fits, and the loss shows in
`omitted`, so a cut is never silent. A reason for a fault is cut to 200
characters, so a library's error cannot exceed the bound on its own.

The notes are counted up to 256, the store's lifetime ceiling and the most the
scan reads. A store that held more would report 256 as its total.

### Faults

A section the daemon could not read is `{"state":"unavailable","reason"}` and
never an empty list, so a damaged store does not read as "no notes". A store file
that does not exist yet, or that has no identity yet, holds no notes, because
the first `remember` call mints the identity before it writes: that is an
ordinary empty section. The pending count is `unavailable` when the queue cannot
be read, not zero.

### Legacy notes

A note written before notes were typed carries only its text. The decoder that
builds the notes index already treats it as a `fact` titled with its first sixty
characters. The overview reuses that decoder and marks the row `legacy: true`,
which it sets by asking the entry whether it had a `title` field.

### Rules

The rules are read from `loom-rules.md` through the proposal queue's own reader,
and listed from the `### Rule <id> (approved <date>, from session <sid>)`
headers it writes. The rule's line is the first non-blank line beneath the
header. A header that does not carry the date or the session still names its
rule. Text outside any header can only come from a hand edit; it is counted in
the file's `bytes` and listed nowhere.

### Rendering

The terminal opens an overlay with `Alt+m`, which is free and sits beside
`Alt+p`, the proposals review. Sections are stacked and scroll with the arrow,
page and Home and End keys, and Escape closes it. The web page draws a "Memory"
section as the Session pane's ninth and last child, after the proposals
review, on the owner's page only. Neither host draws a control: there is
nothing to press, so the web section has no handler and the socket admits no
path beneath it. Both show the empty states "No notes yet. The agent writes one
when it learns something worth keeping." and "No approved rules.", and both say
that a note's body is read with `history_search kind=note`.

## What it costs

The read is synchronous on the session's gateway process. It takes a few
`stat`s, one read of a file of at most 16 KiB, and one scan of at most 256 rows
of at most 2,000 characters each, which is the same order as the index rebuild
a `remember` call already does. A client that reads it once a minute while the
overview is open costs one such scan a minute. A store on a very slow disk would
delay the gateway for that long, and the cost of fixing that is a worker
process, which a read this small does not yet justify.

The read is lease-free, so it can see a note a moment before or after a
concurrent `remember` commits. The board is a snapshot and says so.

The wire gains one command and one snapshot mode and no existing one moves, so
the protocol version stays 2 and an older client that never sends `memory_get`
never sees the snapshot. An older daemon answers `memory_get` as an unknown
command, which both panes show as a refusal.

`storage/sqlite` gains one public function. It is the third lease-free read in
that module and follows the other two exactly, so it adds no new way to open a
file.

## Verification

The board's content, its bounds, the legacy mark, the faults and the injection
states are tests over a real SQLite memory store and real files
(`client/memory_overview_test`), including a read taken while a writer holds the
lease and a board of the widest text that must still fit the byte bound. The
scan is tested for lease-freedom and identity (`storage/sqlite_test`). The wire
is checked by round-trip and malformed-body tests (`client/protocol_test`) and by
the gateway's authority and `unsupported` tests across owner, member and
observer (`client/gateway_test`). The decoder is total and tested against
malformed boards (`session_view/memory_overview_test`), and both panes are tested
with no rows, one and many, with a refusal, and with a hostile string
(`tui/memory_panel_test`, `web_view/memory_page_test`).
