# protocol-change/134: the session timeline, a bounded read of a session's cards

**Status**: PROPOSED 2026-11-24 for slice 1 of
[`docs/design-notes/session-timeline.md`](../docs/design-notes/session-timeline.md),
which the owner accepted as the design of record. Numbers 133 and catalogue
version 24 belong to the own-worktree work, so this takes 134 and no catalogue
change; whichever change lands second takes the next free number.
**Affects**: two new v2 control commands (`sessions.timeline` and `sessions.span`);
two new commands on the session's peer endpoint (`SessionTimeline`,
`SessionSpan`); two new in-process reads for the home page
(`server.home_timeline` and `server.home_span`, `home.Attention.timeline` and
`.span`); two new typed modules shared by the page and a control client
(`web_view/timeline_feed`, `web_view/span_feed`); a pure cut in
`session_view/timeline` and pure span lines in `session_view/span_lines`. No existing command, frame, event, record,
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
  No summarizer's words are in a card. A command, a path, a sub-agent's purpose
  and the first words of a prompt or an answer are text an agent, a tool or a person
  wrote, which is why every string is marked.

The resident cuts the newest 2,000 records of its main strand
(`client/timeline_read`). The cut is `session_view/timeline.cut`, which looks at no
later record, so the cards of a prefix are a prefix of the cards of the whole. A
strand longer than the scan is cut from a window that slides with each new record,
so a card's `from_seq` is stable only from the window's first hard boundary: a
prompt, an answer, an ask or a compaction closes a span whatever came before it, but
a command or result card needs three steps and the cap counts from the window's
start. The read therefore offers no card before that boundary and a `before` cursor
never points into the part it leaves out. A truncated window with no hard
boundary at all, one very long turn, offers no card. A strand that fits the window is cut
whole and every card is offered. The cap on cards closed by commands, results and
the step limit counts only those cards, so prompts and answers do not use it up.

## The span read

`sessions.span` takes `session`, `last` (the id of a span's last record, as a card
carries it), `from_seq` and `to_seq` (the card's sequences, `to_seq` not less than
`from_seq` and fewer than 5,000 records past it) and `epoch`, and answers one span:

```json
{"span": {"lines": [{"seq": 14, "at": 1790000000000, "kind": "step",
                     "words": "Ran make check", "trust": "untrusted",
                     "outcome": "failed"}], "omitted": 0}}
```

The resident scans down the strand's parent links from `last` for at most the
span's length, keeps the records from `from_seq` on, and makes at most 100 lines
(`session_view/span_lines`), the newest if there are more, with `omitted` counting
the rest. A line is a person's words, the agent's words, one tool call worded as
the session's own page words it with the outcome its result reported (`none`,
`no_result`, `succeeded`, `failed`; `no_result` says only that the span holds no
result for the call, not that it is running), or a compaction; each `words` is clipped to 200
bytes and marked untrusted. A record id that is not the session's is refused. It
has the timeline read's authority and spends the brief allowance too.

## Who may read, and what it costs

The owner and a member at any role, as `session.brief` is, afresh from the
registry at each read. An observer sees the same cards, because they say what the
session's own transcript shows. A saved session is refused as not running, since
the daemon never opens one for a read. A refusal is a fixed code and fixed words,
never a session's text.

The read spends the credential's brief allowance (six reads in four seconds,
`ui_sessions.brief_read_limit`) and does not take one of its own. A timeline read
is heavier than a brief: it scans up to 2,000 records where a brief scans 80, so
the allowance bounds how many scans a credential starts and not how heavy each is.
Measured over 23 copies of recorded sessions, one read took a median of 51 ms, a
90th percentile of 306 ms and a maximum of 361 ms, and a reply was about 3.3 KB
(`docs/design-notes/session-timeline.md`, section 11). A thread that is open reads
a brief and a timeline together, and a card opened reads its span, so a person
opening cards can spend the six reads quickly and is told to try again shortly.

## What it does not do

It writes nothing and stores nothing. It runs no tool and no process, and the
command text it reads is never executed. It carries no model-written title: that
is a later slice, with its own protocol change, and the page does not wait for it.
It does not read a strand other than `main`: neither request names a strand, so
the strand grant of [072](072-strand-history-read.md) is not engaged by the
timeline read. The span read names a record by its id and walks that record's own
parent links inside the session, so it cannot read a record that is not the
session's; a read of another strand's cards will apply the strand grant to both.

## What it costs

A scan of at most 2,000 records of one strand, a cut, and a reply of at most
32,000 bytes, per read, in the session's own Agency actor. The first page of a
thread is read when the thread is opened and again when the page's refresh finds
it still open and the last read fifteen seconds old.
