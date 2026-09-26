# 050: Summaries of long reasoning blocks and advisor messages

Status: accepted for implementation (issue #487). Amends Part 1.6 with
one pushed event, `block_summary`, and one subscribed read,
`block_summaries`. No existing command, event or durable entry changes.

## Problem

A reasoning block renders in the terminal as one collapsed row whose text
is the block's first substantive line, clipped to 64 cells. For a long
block that line says little about what the block works through. The
operator either expands the block, which costs a screen of transcript, or
skips reasoning that may matter to steering. Long advice and nudges
messages from the advisor have the opposite problem: they render in full
in compact mode and push the conversation off screen.

A one- or two-sentence summary written by a model fits in the collapsed
row. The terminal has no provider access, so the daemon has to produce the
summary, and the terminal has to receive it. Nothing in the protocol
carries it today. The durable `Entry` is frozen and must not change, and
the capture plan cannot carry it: every capture copies the whole `client/`
register prefix, and a capture fails past 1024 cells or 1 MiB, so one cell
per long block under that prefix would eventually break the session's own
captures.

## Decision

### Which blocks are summarized

The daemon summarizes a block when its source text is at least 512 bytes,
eight times the terminal's 64-cell digest. Two kinds of block qualify:

- a reasoning block (`thinking`) of a committed assistant message that is
  not redacted; a redacted block carries no text;
- the body of a committed advice or queued-nudges message the advisor
  delivered to the primary, recognized by both of its frame tokens, as the
  terminal recognizes it. Feeds, goal feeds and goal continuations are not
  summarized.

A block below the floor produces no request, and the terminal renders it
exactly as before this change.

### Confidentiality

Reasoning text must not leave the service that produced it. The rule
compares services by endpoint: the lowercased scheme and host of a
catalogue entry's `base_url`, with any port, path or query dropped, or,
for an entry with no URL to read, its dialect. Two catalogue entries on
the same host are the same service; for example, three entries served
from `https://inference.baseten.co/v1` share one endpoint.

A committed reasoning block's assistant message names its catalogue entry
(`provider`). The daemon sends the block to the summarizer only when that
entry shares the endpoint of the `summarize` role's first routed entry. A
provider name the catalogue does not hold is skipped, since its endpoint
cannot be known. The summarize request is dispatched to that first entry
alone, with no fallback, so a retryable failure cannot move the text to
another service.

A stream still being written names no provider, and the strand's
configured identity is not always the one that answers it: a strand whose
identity heads a role's chain is dispatched to that role, and the gateway
walks the chain on a retryable failure, possibly to another service; a
text-only identity with an image in the turn is dispatched to the `vision`
chain. The daemon therefore summarizes a live stream only when every
target that could answer it shares the summarize entry's endpoint: the
strand's identity, every chain that identity heads, and, for a text-only
identity, the `vision` chain. A strand outside that set gets no live
summaries; its settled blocks are still checked one by one against the
entry the committed message names.

Both admitted sets are computed from the catalogue when the session is
assembled.

Advice and nudges are text the harness writes and already sends to every
provider in the session, so they carry no such restriction.

### The summarizer

The daemon uses the catalogue's `summarize` role, with thinking off and a
160-token output cap, and no fallback to any other role. A catalogue that
routes no `summarize` model gets no summaries. The request asks for one or
two sentences in the third person, beginning with "The agent" or "The
advisor", and instructs the model not to follow instructions in the text.
Source text beyond 32 KiB is clipped from the middle. The daemon collapses
whitespace in the answer, removes a leading `Summary:` label and enclosing
quotation marks, and cuts the result to 320 bytes at a word boundary. An
empty answer is discarded.

Every failure — no route, a refusal, an error, a timeout, an empty answer —
produces no summary, no push and no error frame.

### Storage

A summary of a committed block is stored in the reserved `fact.custom` cell

```text
summary/<entry_id>/<block_index>      {"text": string}
```

where `block_index` is the block's zero-based index in the message's
`content` list, and is `0` for an advice or nudges message, which has one
text block. `summary/` is a reserved prefix (`runtime/api.reserved_fact_key`):
`put_fact` refuses it and `facts` hides it. No capture plan selects it. A
summary is derived presentation: it may be absent, and a missing cell
claims nothing about the block.

A summary of a block still being written is never stored.

### Live summaries

While a generation request streams reasoning, the daemon summarizes the
accumulated text once it reaches 4 KiB or 40 lines, and again each time it
has grown by 4 KiB or 40 lines since the last request began. A stream has
at most one summary request outstanding, and at most two live requests
are outstanding across all streams; a stream refused a slot is considered
again on its next fragment. At most eight live streams are tracked; a new
one evicts the oldest with no request outstanding, so a stream whose end
the daemon never observed cannot hold its text indefinitely. Growth that arrives while one is
outstanding does not queue another request; when the outstanding request
ends, the daemon starts one more if the stream has grown past the
threshold since that request began, with the stream's newest text. The
text kept per stream is bounded to its newest 32 KiB (trimmed once it
reaches 64 KiB).

### Event `block_summary`

Pushed to every subscribed connection, with no `reply_to` and no `seq`.
Two body shapes, discriminated by `subject`:

```text
{subject: "block",  entry: string, block: integer, text: string}
{subject: "stream", strand: string, op: string, generation: string, text: string}
```

`subject: "block"` names a committed block by entry id and block index; its
summary is also stored. `subject: "stream"` names the provider request that
is writing a reasoning stream by the same `generation` identity its
`stream_delta` frames carry; nothing about it is stored, and a later
`block_summary` for the same stream replaces it. `text` is at most 320
bytes. The frame is display state, as `tool_output` is: a lost frame costs
a stored summary nothing, because the read below recovers it, and costs a
live summary nothing the next frame does not restate.

A client that does not know `block_summary` ignores it (§1.5). A client
that knows the event and receives an unknown `subject` ignores that frame.
This obligation binds clients. The daemon's own reference decoder in
`client/protocol`, which serves the golden fixtures and tests, refuses an
unknown `subject` as a malformed body.

### Command `block_summaries`

A subscribed, read-only command that observers may send:

```text
{blocks: [{entry: string, block: integer}]}
```

`blocks` is a nonempty array of at most 32 blocks; each `entry` is an entry
id in canonical form and each `block` is nonnegative. Duplicates collapse.
A body outside these bounds is refused with `bad_request`. The server reads
one exact `fact.custom` key per block, never a prefix, and answers with a
`snapshot` of mode `block_summaries`:

```text
{summaries: [{entry: string, block: integer, text: string}]}
```

in the order asked, holding only the blocks that have a stored summary. A
cell that does not decode is treated as absent. A storage read that fails
is refused with `unavailable`, as other bounded reads are. An older server
answers `unsupported`.

### What a client does with them

A client MUST present a summary as the summarizer's text and never as the
agent's or the advisor's own words. The reference terminal says so in the
row above it: `∴ Reasoning (summarized)`, or the advice heading followed by
`(summarized)`.

The reference terminal behaves as follows. In compact mode, a long
reasoning block with a summary renders as a header row, `∴ Reasoning
(summarized)` with the expand hint when settled, or with its line count
and the time the generation has run while it streams, and the summary
beneath it as dim secondary text wrapped to at most three rows, cut with an
ellipsis beyond that. A block without a summary keeps its single digest
row. A summarized block therefore takes more rows than the digest it
replaces, and a summary that arrives after its block is on screen adds
those rows once; a reader scrolled back into history keeps the rows on
screen in place. When a response commits before its own summary arrives,
its first long reasoning block shows the stream's live summary until the
stored one replaces it, so a block that showed a summary while streaming
settles into the same number of rows. A long advice or nudges message
collapses in compact mode to its heading and, beneath it in the same dim
form, its summary, or its first line while no summary exists. Detail mode
(Ctrl+G) shows every block's full text, unchanged.

The terminal reads stored summaries for long blocks of the records it
holds that it has not yet read, at most 32 per read, once per block per
attachment, on the ordinary read lane. It stops reading for the rest of
the attachment after a refusal and shows no error for it.

## Alternatives and cost

**A field on the entry.** Adding the summary to the durable entry payload
would make it travel with every capture, but the entry is frozen, is
written before the summary exists, and is write-once. Rewriting entries
for a derived label is the wrong trade.

**A cell under `client/`.** The capture plan copies the whole `client/`
prefix, so the terminal would receive every summary with no new command.
It would also put one cell per long block into every capture, and captures
fail at 1024 cells or 1 MiB. A long session would eventually be unable to
capture itself.

**On-demand summarization.** Summarizing a block only when an operator
looks at it avoids requests nobody reads, but the first look waits a model
round trip, and a terminal cannot tell the daemon what it is looking at
without a new command per row. Settlement-time summaries cost one request
per long block whether or not anyone reads it; routing a `summarize` model
is how an operator opts into that spend.

**Pulling live summaries.** A terminal could poll for the newest summary
of each stream it is drawing. A push from the daemon at the moment a
summary is ready costs one small frame per summary and no polling.

**What it costs.** One summarizer request per long reasoning block and per
long delivered advisor message, plus about one per summarizer round trip
while a long reasoning stream is live. One reserved cell of at most a few
hundred bytes per summarized block, never read by a capture. One pushed
frame per summary per subscribed connection. A daemon restart forgets live
state and the in-memory high-water, so blocks committed while no
summarizer machine was listening keep the first-line digest; a durable
cursor would close that gap at the cost of one more commit behind every
commit hint.

## Review

Primary review by the implementer against the gateway, the terminal's
three command-name tables, and the confidentiality rule in
`docs/architecture/advisor.md`. The golden fixtures `cmd_block_summaries`,
`event_snapshot_block_summaries`, `event_block_summary_block` and
`event_block_summary_stream` pin the wire shapes.
