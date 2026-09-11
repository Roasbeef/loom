# protocol-change/030 — running tool output as a pushed `tool_output` frame

**Status**: ACCEPTED 2026-09-11 · **Affects**: Part 1.3 session protocol
v2 (event envelope: one new pushed event), the `events/bus` topic set ·
**Raised by**: issue #186 (broker+client: forward CallOutput to the event
bus so tool output streams) · **Implemented**: `tools/tool`,
`tools/tail`, `events/bus`, `client/wiring`, `client/gateway`,
`client/protocol`, `client/serve`, `tui/protocol`, `tui/session_channel`,
`tui`

## Problem

The sandbox helper streams a jailed command's output in 32 KiB `exec_out`
chunks and the broker relays each one to the caller as `CallOutput`. Every
caller then folded the chunks into a list and said nothing until
`CallSettled` (`tools/tool.collect_events`). Nothing reached the event bus
or a terminal until the call settled; the only thing a terminal streamed
was provider tokens. A two-minute build was a blank screen for two minutes,
with `bash · awaiting result` above it.

The wire already did the hard part. What was missing was a bounded shape
for the stream to take past the collector, a topic for it, and a pushed
frame a client could draw.

## Decision

**1. The collector shows an observer each stream's rolling tail.**
`tools/tool.Ctx` gains `observe_output: fn(OutputTail) -> Nil`, and
`collect_observed` calls it after every chunk it folds with the *whole
retained window* of that stream — at most `tool.tail_bytes` (4 KiB),
beginning and ending on a UTF-8 character boundary, empty when the window
holds bytes that are not text — plus the stream's total byte count. The
window is `tools/tail`, the rolling-tail primitive background jobs already
used, moved down from `client/jobtail` so both owners share it.
`collect_events` keeps its signature and observes nothing.

Every observation is a snapshot rather than a fragment. That is the
property everything downstream leans on: a subscriber replaces what it
shows, so a dropped observation costs nothing the next one does not
restate, and the production observer may be a lossy publish.

**2. The bus gains an `Outputs` topic carrying `ToolOutput`.**
`ToolOutput(op, step, stream, tail, total_bytes)` is the first bus event
carrying text rather than an id, and the bus rule — events are hints,
pulls are truth — survives it because the payload is display state of the
same standing as `OpTransition`'s phase label: something to put on a
screen, never something to act on. The truth is the durable tool result
committed at settlement. Pull-driven subscribers must not be woken once
per chunk to find nothing new in the store, so `hint_topics` and
`subscribe_hints` name the six durable topics and the projection driver
joins those; `subscribe_all` still means all seven.

**3. `client/serve` is the bus's first production publisher.** The effect
wiring resolves an observer per tool run from `Config.observe_output`;
`serve` supplies `gateway.tool_output_observer`, which reads the session's
canonical id once per run and publishes every tail under `bus.key(of:)`.
The scope is entered with the idempotent `bus.start`, because one daemon
assembles many sessions and the second must find it running.

**4. The hub relays each event as a pushed `tool_output` frame.** Under
network delivery the hub joins the `Outputs` topic alone — its commit
hints already arrive through `commit_forwarder`, and joining the hint
topics too would make the same pull happen twice per commit — and turns
each `ToolOutput` into:

```json
{"v":2,"event":"tool_output","body":{"strand":"main","op":"op-1","step":"step-3","ephemeral":true,"stream":"stdout","tail":"compiling core","total_bytes":14}}
```

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `strand` | string | required | Strand whose call is printing. |
| `op` | string | required | Operation the call belongs to. |
| `step` | string | required | Step within the operation; one call batch. |
| `ephemeral` | boolean | required | Always `true`. |
| `stream` | string | required | `stdout` or `stderr`. |
| `tail` | string | required | The whole retained window of that stream after its latest chunk. |
| `total_bytes` | integer | required | How many bytes the stream has carried in all. |

No `reply_to`, no `seq`, never persisted, never replayed; pushed
unsolicited to every subscribed connection while the call runs, through
the same per-delivery authority re-check every pushed frame passes
(`protocol-change/018`). Wholly superseded by the settled tool-result
`entry` for the same `op`. The tail needs no clipping at the hub: the
collector's 4 KiB bound is a sixth of the 24 KiB preview bound a pushed
frame is held to.

**5. The terminal replaces, never appends.** `tui` keeps one `ToolTail`
per `{strand, operation, step, stream}`, replaced whole on every frame, so
the region stays the size of the last frame however long a command runs.
Tails clear with the strand's streams — on an entry landing and on the
operation reaching `done` — and a capture drops one once the durable
result for its operation is in view. The transcript draws each tail as one
result line under the live region: the stream's name and byte count so
far, then the last eight lines of the window.

## Alternatives and cost

**Send the chunk, not the window.** A fragment protocol like `stream_delta`
would make every client reassemble, and a lost frame would leave a hole
the client cannot see. The window costs at most 4 KiB per chunk on the
wire — bounded, and a helper chunk is 32 KiB — and makes every frame
self-sufficient. Taken.

**Route through the gateway's named subject, as provider deltas do.**
`tap_provider` sends `ProviderDelta` to the hub's registered address and
never touches the bus. The same shape would have worked here and avoided
the topic. The issue asked for the bus, the bus had a working consumer
path and no producer, and a remote client or a second node's hub can join
a topic where it cannot reach a named subject. The cost is the seventh
topic and the `subscribe_hints` distinction. Taken as asked.

**A `truncated` flag on the event.** The helper's cap is reported on the
settled result already, and `total_bytes` beside a 4 KiB window says the
window is a tail without a flag. A `Bool` field would also have met the
no-naked-`Bool` rule. Omitted.

**Show `grep` and the code-mode build too.** `grep` clears through the
same seam and hands its observer over for consistency; a long search
shows its tail like a long build. The hermetic `gleam build` behind
`code_mode` is the longest jailed stage a terminal waits on with nothing
else to draw, so `tools/codemode.Request` carries the tool's observer and
`codemode/build.BuildConfig.observe` hands it to the build's collector;
the compiler's own lines stream under the `code_mode` call. The launch
and satellite round-trips stay collapsed: they have no user-facing
output. No separate cost beyond one more field on each record.

**What it costs.** One more pushed frame kind every client must tolerate
(unknown names already decode to data). One `pg` lookup and a send per
32 KiB chunk of every foreground call on a daemon with a hub attached. A
fifth `Ctx` construction site to keep in step. `docs/architecture/events.md`
loses the sentence "there is no production publisher".
