# Side queries

Protocol-change/087 records the accepted `/btw` contract. Operators can ask a
question while the main strand continues. The first ask captures its latest
effective dispatched model request; follow-ups append against that frozen base.
Main compaction and newly committed work do not silently change its context.
Refresh captures newer work and starts the side conversation again.

Side requests run through the provider gateway with no tool dispatcher, runtime
operation, Agency or context hooks. A model-generated tool call is refused and
never executed. Questions and answers stay in the requesting attachment's
bounded ephemeral state, outside the durable transcript. Auxiliary usage is
still recorded, with unknown evidence when a terminal is lost.

The terminal and operator web page share parsing, wire encoders, total board
decoding, correlation, refresh pacing and rendering text in `session_view/btw`.
The daemon owns inference, frozen snapshots, deadlines and cancellation in
`client/btw`. The terminal keeps main rows visible above the side panel; the
browser uses a scrollable aside. Escape or Close hides a panel; Cancel affects
only its side request. The main composer retains its ordinary recipient, so
follow-ups explicitly use `/btw <question>`.

## Context and cache policy

The snapshot includes the current compaction summary and retained tail rather
than reconstructing old context from UI history. It excludes partial responses
and unjoined tool exchanges. A final response can extend the latest candidate;
a settled fallback pins its actual model identity before replaying that response.
The side boundary follows the captured context. Tool definitions, system text,
model and thinking settings stay stable. Original output-token settings are
retained because lowering a ceiling below an inherited thinking budget is invalid.

Anthropic marks the frozen base's last user block before merging adjacent user
turns. It uses the other tail marker on the side suffix; tools and system keep
the two head markers. OpenAI-compatible and Responses requests keep their existing
message boundaries. Cache hits depend on provider lifetime, routing and matching
endpoints, so the feature works when every request is cold. Cache reuse does not
reduce context-window occupation or the host's retained-memory cost.

Bounds are explicit: four latest snapshots, eight attachment conversations, two
active requests, eight exchanges, 8 MiB per base, 128 KiB side text, 8 KiB question,
32 KiB answer, 60-second response deadline and 90-second managed backstop. Slots
stay booked until transitive drain. Clear and disconnect release snapshots;
gateway restart resets the prior connection-number namespace.

## Verification boundary

Scripted HTTP tests exercise real provider encoding and stream ownership without
paid calls. Adapter tests verify the frozen Anthropic endpoint and marker count.
Live Anthropic cache reads/writes and latency remain pending until the owner has
credits configured. Provider fixtures prove request shape, not cache economics.

Sources: [Claude side questions](https://code.claude.com/docs/en/interactive-mode#side-questions-with-btw),
[Codex side implementation](https://github.com/openai/codex/blob/main/codex-rs/tui/src/app/side.rs),
[Anthropic cache invalidation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching),
and [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).
