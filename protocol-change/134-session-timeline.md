# protocol-change/134: the session timeline, a bounded read of a session's cards

**Status**: PROPOSED 2026-11-24 for slice 1 of
[`docs/design-notes/session-timeline.md`](../docs/design-notes/session-timeline.md),
which the owner accepted as the design of record. Numbers 133 and catalogue
version 24 belong to the own-worktree work, so this takes 134 and no catalogue
change; whichever change lands second takes the next free number.
**Affects**: one new v2 control command (`sessions.timeline`); one new command on
the session's peer endpoint (`SessionTimeline`); one new in-process read for the
home page (`server.home_timeline`, `home.Attention.timeline`); one new typed
module shared by the page and a control client (`web_view/timeline_feed`); a pure
cut in `session_view/timeline`. No existing command, frame, event, record,
catalogue table or `loom.toml` key changes.
**Raised by**: the owner's review of the inbox's review thread, which showed the
diff, the last command and the last message and no account of what the agent did.
**Builds on**: [125](125-session-brief.md) (the door, the authority and the
allowance this read repeats) and [072](072-strand-history-read.md) (the strand
grant a later read of another strand applies).

## Problem

A finished session's review thread cannot say what the agent set out to do, what
it did or where it stopped. A turn is too coarse a unit, since one holds hundreds
of calls, and a record is too fine. The design note divides a strand's records
into spans, each a card, by a pure function of the records.

## What was decided

`sessions.timeline` takes `session`, an optional `before` (a `from_seq`, a
nonnegative integer), an optional `limit` (1 to 20, default 10, refused outside
that range) and `epoch`. It answers one page:

```json
{"timeline": {"cards": [...], "older": 41, "now": {...}}}
```

- `cards` are the newest `limit` cards older than `before`, oldest first, at most
  32,000 bytes encoded. When the page does not fit, the oldest cards are shed and
  `older` names the oldest card kept, so they stay reachable.
- `older` is the `from_seq` to ask `before` for the cards still older, and is
  absent when there are none.
- `now` is the span still open, as a card, on the newest page only.
- A card has `kind` (`prompt`, `work`, `command`, `result`, `ask`, `compaction`,
  `answer`), `turn_seq` (the seq of the prompt that began the turn, or 0), `from_seq`
  and `to_seq`, `last` (the id of the span's last record), `started_at` and
  `ended_at`, `steps`, `reads`, `failed`, up to six `files` with `added` and
  `removed` and a `files_total`, an optional `command` (`text`, reduced to its
  executable and subcommand, and `exit`), up to three `spawned` purposes, `peers`,
  an optional `tokens_before` and an optional `excerpt` of a prompt or an answer.
  Every string in a card is session text and the card says `"trust": "untrusted"`.
  A card holds no word a model wrote.

The resident cuts the newest 2,000 records of its main strand
(`client/timeline_read`), so a strand longer than that starts its cards inside a
turn. The cut is `session_view/timeline.cut`, which looks at no later record, so
the cards of a prefix are a prefix of the cards of the whole.

## Who may read, and what it costs

The owner and a member at any role, as `session.brief` is, afresh from the
registry at each read. An observer sees the same cards, because they say what the
session's own transcript shows. A saved session is refused as not running, since
the daemon never opens one for a read. A refusal is a fixed code and fixed words,
never a session's text.

The read spends the credential's brief allowance (six reads in four seconds,
`ui_sessions.brief_read_limit`) and does not take one of its own. A timeline read
costs the session a bounded walk of its records as a brief does, and one bound
for both keeps a page from multiplying the session's reads. A thread that is open
reads a brief and a timeline together, so it spends two of the six.

## What it does not do

It writes nothing and stores nothing. It runs no tool and no process, and the
command text it reads is never executed. It carries no model-written title: that
is a later slice, with its own protocol change, and the page does not wait for it.
It does not read a strand other than `main`.

## What it costs

A scan of at most 2,000 records of one strand, a cut, and a reply of at most
32,000 bytes, per read, in the session's own Agency actor. The first page of a
thread is read when the thread is opened and again when the page's refresh finds
it still open and the last read fifteen seconds old.
