# 087: Attachment-scoped side queries

Status: Accepted for implementation by the owner on October 13, 2026.

## Problem

Operators need to ask about ongoing work without steering or interrupting it.
TUI and web must share the same isolation, context, and lifecycle semantics.

## Decision

Add operator-only `btw` with strand, action (`read`, `ask`, `refresh`, `clear`,
`cancel`), and text. It immediately returns a correlated `snapshot` with mode
`btw`. Reads never wait for inference. Clients poll while a side request runs.
The connection owns its side conversation. Detach cancels work and forgets it.
Observers cannot create, read, or mutate another attachment's conversation.

The first ask freezes the latest dispatched effective request for that strand,
including request-local context transformations, system text, tool definitions,
and resolved model settings. A settled text-only final answer extends that
snapshot. Incomplete assistant/tool exchanges and streaming fragments do not.
Before the first dispatch, the service reports that context is unavailable.
Follow-ups append to that frozen base. Refresh discards the side exchanges and
captures the latest base. Main compaction cannot change a frozen base.

Side inference is one provider request with no tool executor, Agency, hooks,
or main operation. Tool calls are never run. Keep tool definitions and settings
stable for cache reuse and append the side boundary after the base. Pin the
resolved route; do not fallback across services. Cache reuse is an optimization,
not a correctness premise. Anthropic live cache validation is deferred until
the PR because the owner currently has no configured credits.

Bounds: four latest strand snapshots, eight attachment conversations, two
concurrent requests, eight exchanges per conversation, 8192-byte questions,
32768-byte answers, 131072-byte side history, and an 8 MiB serialized base.
A request has a 60-second answer deadline and a 90-second managed-run backstop.
The service retains a cancellation slot until its managed subtree drains.
Usage is recorded as an auxiliary `btw` request, without a transcript entry.

## Considered

A normal strand/fork carries tool execution and main-operation lifecycle that
this feature does not need. The advisor intentionally receives a different
context. A new system prompt or stripped tool list loses prefix reuse. A
provider-only no-tools setting is not the execution boundary and, on Anthropic,
changing tool choice invalidates the message cache.

## Cost and verification

Retaining effective request snapshots copies bounded context into the service.
Side workers copy only their request, not tool executors or full wiring records.
Closing a panel hides it; clear or disconnect releases its snapshot. Bounded
follow-ups require an explicit refresh when exhausted. Both hosts retain main
transcript updates and approvals while the panel is open.

Tests must cover isolation, frozen follow-ups, refresh, rejection of generated
tool calls, bounds, cancellation/drain, disconnect, observer refusal, wire
round-trips, and both host submission/rendering paths. Provider request fixtures
prove prefix preservation; they do not prove a live provider cache hit.

Sources: [Anthropic tool caching](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching)
and [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).

Anthropic side requests spend the two tail breakpoints on the frozen base's
last user block and the side history's newest user block. Marking before user
turn merging preserves the original endpoint when a question is asked during
a main response. The request-scoped gateway hint leaves frozen ProviderRequest
and ResolvedModel records unchanged. Output token settings stay unchanged so
an inherited extended-thinking budget cannot exceed a newly lowered ceiling.
