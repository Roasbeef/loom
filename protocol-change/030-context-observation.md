# Context usage observation

Status: accepted for the requested context inspector and persistent percentage.
Extends the optional read surface in Part 1.6, following protocols 025 and 026.

## Problem

The terminal shows cumulative usage, which cannot describe one strand's current
context. Its retained transcript may omit messages. The server knows the pinned
system prompt, active tools, model window, and complete compaction projection.

## Decision

Add read-only `context` with body `{strand}`. The response is a `snapshot` with
mode `context` and a board. The asynchronous pending/ready/failed exchange uses
protocol 025's request identity, shared worker slots, deadline, and cancellation.
The pending acknowledgement consumes `reply_to`; completion is a push carrying
`request_id`. Context reads require ordinary session-read authority; the existing
worktree observer continues to require the owner. Revalidate before delivery.

A ready board carries `strand`, `as_of`, `model`, `context_window`, `used_tokens`,
`basis`, `compaction_used_tokens`, nullable `checkpoint_at`, `reserve_tokens`,
`categories`, `items`, `items_total`, and `items_omitted`. Category and item rows
carry `name` and `tokens`; items also carry `category`. All counts are
nonnegative. Window sizes are positive; an unavailable model window refuses the
observation rather than manufacturing a denominator. The board fits below
48 KiB, including JSON escaping. Item omission is explicit and never changes
category totals or the usage estimate.

Capture the configuration and leaf together, then project the immutable branch
through its latest compaction. Refuse incomplete or unreadable projections.
The scan admits at most 4096 entries and eight MiB of encoded entries; these
limits bound accepted analysis, not allocations already made by the backend.

`reported_plus_estimate` means the latest usable post-compaction provider total
plus estimates for subsequent projected messages, reusing runtime accounting.
`estimated` means system, active tool definitions, and projected messages are
estimated without a valid provider baseline. Do not add static components to a
provider total, which already includes them. The provider total includes output:
the headline is a current context estimate, not an exact next-request input count.
`compaction_used_tokens` preserves the existing threshold's arithmetic when its
message-only fallback differs from the inspector's full estimate. Inspection
changes no compaction policy.

Component counts are independent character-based estimates, not scaled shares
of the provider total. The pinned prompt includes embedded instructions; projected
messages include loaded skills, memory injections, and tool results. Do not reread
instruction files, infer provenance from headings or tool names, or count every
available skill as loaded context. Transient hook transformations and unsent
input are not reconstructed by this read. No model calls or hooks run.

The TUI adds `/context`, `/context all` (also `/contextall`), and a `ctx ~N%`
footer label. It refreshes
after coherent conversation changes and explicit requests, coalesces outstanding
reads, and keeps observations scoped to attachment and strand. Unknown or failed
observations remain unavailable. Details scroll independently of the composer;
Escape returns without discarding input. Older servers can refuse the optional
command while the rest of the terminal remains usable.

## Cost and alternatives

One optional server observer and one bounded terminal projection reuse the
existing read lifecycle. Per-request audit history, tokenizer dependencies, and
prompt-hook replay would add state or effects without making this observation
necessary. Guessing from the terminal's visible history would undercount; using
cumulative billed usage would grow across requests and strands.
