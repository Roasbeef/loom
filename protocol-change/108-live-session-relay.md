# protocol-change/108: the full session page for a session on another orchestrator

**Status**: PROPOSED 2026-11-04, revised the same day after an independent
review. Nothing is built. The spellings below are provisional until a slice builds
them. The owner's calls are recorded under "Decided, and what stays open".
**Affects**: the stable peer exchange of [105](105-versioned-peer-exchange.md),
which gains four operation revisions (`108.attach.1`, `108.feed.1`, `108.send.1`,
`108.detach.1`) inside its existing `Exchange` constructor, and an amendment to 105
itself: `client/remote/peer_client` gains an entry point that dispatches against an
epoch the caller already observed, because `peer_client.call` always discovers
first (`client/remote/peer_client.gleam:62`). Also `client/remote_top`'s `Refusal`
(one variant, `FeedEnded`), `Cap` (`MaxFeeds`) and `Offered` (`OfferedPage`);
`loom.toml`, one key on `[spawners.<name>.top_level]`, `page`, and a
`[spawners.<name>]` table that may carry only `node` and `top_level`;
`client/gateway.Door` (one variant, `PeerDoor`, which carries whether its spawner
may decide) and what `gateway.attached` counts; and in `web_view`,
`component.Standing` (one field, `route`) and `ending.Ending` (one variant,
`PeerUnreachable`). No Part 1 interface changes: the page reads and writes the
session endpoint's own frames, byte for byte. No orchestrator port constructor, no
executor `HostMessage`, and no `protocol.version` change.
**Raised by**: issue #1135, under the remote-feels-local umbrella #1137.
**Builds on**: [051](051-web-view-route.md) and [052](052-web-view-remote-origin.md)
(the page and its relay), [089](089-remote-approvals.md) (the approval ceiling),
[090](090-remote-observation.md) (remote children), [094](094-cross-orchestrator-sessions.md)
(the relayed session and its `top_level` table), [097](097-reconnect-failed-pages.md)
(a failed lane reconnects through a fresh page), 105 (the negotiated exchange) and
the chunk path of [107](107-state-transport.md).
**Amends**: 094's list of what a laptop page may not do with a relayed session, for
the live page only (it may open every strand and draws images as a local page
does). 094's rule that only relayed sessions are reachable, and 085's rejection of
attaching to a foreign session, are unchanged; widening them to the owner's own
sessions is left to a follow-up proposal (see "The owner's own sessions").

## Problem

A session's page on the laptop is the `web_view` component running the shared
`session_view` step over a relay into the session's gateway
(`client/daemon/ui_relay.gleam:224`). Captures, stream fragments, summaries,
approvals and pending inputs arrive as they happen, and the page draws them as the
terminal does. A session the laptop created on the box gets a different page. Under
094 the laptop pages a plain-text transcript with `TopHistory`, lists state and
pending requests with `TopSessions`, and can send to the main strand, stop,
archive and resolve. That page is drawn by the home component with a `Visit`
(`client/daemon/server.gleam:569`), not by the session component, because there is
no stream for the session component to run from.

So the relayed page has no live streaming, no folds, no diffs, no strands, no
"allow for the session", no steer and no top bar figures. It also has two defects of
its own: the transcript is raw text, so Markdown and tool calls show unrendered, and
it draws the framing written for an agent reading another agent's transcript
(`session_view/strand_framing.gleam:91`, drawn at
`web_view/view/relayed_session.gleam:459`) to a person.

The goal of #1135 is one page for every cell of the matrix: the laptop's page for a
laptop session and for a box session, the box's page for a box session and, where
the laptop's owner opts in, for a laptop session.

## What was considered

### Teach the 094 page to approximate the full one (rejected)

Render `TopHistory` pages as turns, poll faster, add strands to `TopSessions`. Every
feature of the session page would be built a second time against a paged text
projection, and the two would drift. The session page's behaviour comes from the
session endpoint's frames (pushed deltas, credited transfers, escalation events),
and a paged projection cannot carry them.

### Run the component on the box and relay its patches (rejected)

The box would run `web_view` for the laptop and the laptop would forward Lustre
patches and browser events. The box would then be judging browser events under the
page rules of 051 for a browser it never sees, the laptop could check nothing it
forwards, and the markup on the laptop's origin would be authored by another
machine. It breaks the rule of 051 and 052 that the browser talks only to its own
daemon and that daemon draws the page.

### Push the gateway's frames to a process on the laptop (rejected)

The box's relay could send every frame to a laptop pid over distribution. It is the
shortest path for a frame, but nothing bounds it: a laptop that is slow or
partitioned becomes an unbounded mailbox on whichever side Erlang distribution
buffers it, which is the hazard 107's review recorded for the chunk path ("a flood
of requests to one owner queues in its mailbox"). It also needs a monitor and a
resume protocol across a link that may drop, and 094 already chose a box that sends
nothing it was not asked for.

### A new orchestrator port constructor or executor message (rejected)

The orchestrator port's closed type kills its actor on an unknown constructor, which
is why 105 exists, and `HostMessage` (`client/remote/protocol.gleam:623`) is the
executor vocabulary, which a session's page never crosses. 105 says future
operations extend the JSON body, not the outer constructor.

### Pull the session endpoint's frames through the stable exchange (accepted)

The box attaches to the relayed session's gateway exactly as a page socket does,
holds the frames in a bounded, numbered queue, and the laptop pulls them with a long
poll through `loom_peer_v1`. The laptop hands each frame to the component as if a
local relay had received it. The session endpoint protocol was written for a lossy
pushed channel (a lost notice is harmless, a lost reply is an unknown outcome, the
idle refresh is the recovery path, `docs/client-protocol.md` §6.2 to §6.5), so
carrying it over a link needs no new semantics, only a transport that delivers what
it delivers once and in order.

## Decision

**Proposed: a pull feed of the session endpoint's own frames, over 105.** The
laptop's daemon attaches to a relayed session on the box, polls a numbered queue of
the frames the box's gateway wrote to that attachment, and sends the lane's frames
back one at a time. On the laptop a new socket adapter, `client/daemon/ui_feed`, is
the component's `Transport`, so the page, the strip, the approvals dock and the top
bar are the existing code paths. On the box a new feed host,
`client/remote/feed_host`, owns one gateway attachment per feed and judges every
frame the page sends before the gateway sees it. Authority stays with the box: the
gateway judges what it always judges, and a decision goes through the hub's relayed
door with the spawner's ceiling, as `TopResolve` does. The box sends nothing on its
own. The browser talks only to the laptop.

### Configuration, on the box

```toml
[spawners.laptop.top_level]
# ... 094's keys ...
page = "live"          # "live" (default) or "paged"
```

| Key | Meaning |
|---|---|
| `page` | `live`: the four operations below are served for this spawner. `paged`: `108.attach.1` is refused with `NotOffered(OfferedPage, "live")` and the laptop draws the 094 page. |

The decoder refuses any other value. The key lives in the `TopLevel` record
(`client/spawners.gleam:202`), so a spawner without a `top_level` table has none
and every operation is refused with `TopLevelOff`, as in 094. A feed may attach only
to a session in `catalogue_relayed_sessions` for this spawner, as every 094 message
requires.

The default is `live`. An older laptop never asks for the revisions, so the default
costs nothing in compatibility, and `top_level` is already the box owner's opt-in.

A `[spawners.<name>]` table that exists only for the page may carry `node` and
`top_level` and nothing else. Today the decoder needs 084's keys for children, a
placement among them, even when no child is wanted. A table without them admits no
spawn: a `Spawn` from that node is refused with a reason that says the table has no
placement for children. The other direction below needs this.

### The four operations

Each is a 105 operation on the stable endpoint, with the serving epoch fenced at
dispatch (`client/remote/peer_service.gleam:104`) and every body judged by the box's
`TopHost` against the spawner its node resolves to (`client/top_host.gleam:238`). The
attach is one `peer_client.call` (`client/remote/peer_client.gleam:62`), discovery
and dispatch under one deadline. The other three dispatch against the epoch the
attach observed, through a new `peer_client` entry point that sends the operation
envelope with a given epoch and skips discovery; it shares `call`'s size checks,
deadline and failure meanings, and the fences below explain why it is safe. Bodies are JSON arrays of the arity
shown.

| Revision | Body | Answer |
|---|---|---|
| `108.attach.1` | `[session, principal, name]` | `{attach, epoch, incarnation, label}` |
| `108.feed.1` | `[attach, after, wait_ms]` | `{first, frames, ended}` |
| `108.send.1` | `[attach, n, offset, total, piece]` | `null` |
| `108.detach.1` | `[attach]` | `null` |

`108.attach.1` names the session and the laptop page's principal and display name,
which the box keeps as plain data for provenance, as 094's `TopResolve` keeps
`decided_by`; it authenticates nothing. The box checks the spawner, the table, `page`,
the relayed row and the feed cap, opens the session if it is saved within the budget 094's
`reached` uses (`client/top_host.gleam:895`), starts a feed host and answers
`attach`, a 128-bit token in hex; `epoch`, the box daemon's epoch (the same value
the peer service serves, `client/daemon/main.gleam:1532`); `incarnation`, the
session's resident incarnation; and `label`, the session's name and placement in the
bounds and total decoder of a `TopSessions` row.

`108.feed.1` is a long poll. `after` is the number of the last frame the laptop
received, or zero. The box drops every frame numbered `after` or less and answers
the frames it holds after it, waiting up to `wait_ms` (at most 5,000) for the first
one. A poll that arrives while another is held supersedes it: the box answers the
held one at once with no frames and holds the new one, so a laptop that gave up on a
poll the link delayed is never refused for asking again. `first` is the number of the first frame in `frames`, and frames are numbered
consecutively from one per feed. `ended` is `null` while the feed is live, and once
it is not, one of `lapsed`, `stopped` or `revoked`. The box answers an ended feed's
polls that way for one more lease and then forgets the token, after which a poll is
refused with `feed_ended`.

`108.send.1` carries one piece of one frame the lane transmitted. `n` numbers the
laptop's frames from one; `offset` and `total` place the piece in the frame, as a
`Chunk` of `client/session_move` places a piece in a file. The box admits the pieces
of `n` in order and hands the frame to its filter when the last one lands. A piece
the box has already admitted is answered `null` again and changes nothing, so the
laptop may resend a piece whose answer it lost and the frame still reaches the
gateway once. A piece out of order, or a frame of `n` other than the next, is
refused.

`108.detach.1` ends the feed. It is idempotent and also answers `null` for a token
the box no longer holds.

Refusals reuse 105's `[kind, value, number]` form. New ones: `feed_ended` with
`lapsed`, `stopped` or `revoked` for a token that is gone; `cap_reached` with
`feeds` and the limit; `not_offered` with `page:live`. A malformed body is 105's
`malformed`.

### The fences

A feed is fenced three ways, and each is judged before the request can touch the
session, as 107 judges `StateCapture`'s incarnation and attach token in the host
before the plane sees the request. The 105 envelope carries the serving epoch, so a
request to a box that restarted is answered `stale` before `TopHost` runs. Every
poll, send and detach carries the attach token, which the box minted. It is looked
up only among the feeds of the spawner `judged` resolved the sender's node to
(`client/top_host.gleam:238`), before anything else, so a request for a feed that
has ended learns that it has ended and touches nothing, and a token of another
spawner's feed is unknown to this one and answered `feed_ended`. And
the gateway attachment is bound to the session's incarnation, so a session that
stops ends the feed with `stopped`, and a later attach is at the new incarnation. On
the laptop, the page's `snapshot.Expected` is the attach answer's session, epoch and
incarnation (`web_view/component.gleam:525`), so a cut that names any other fails the
lane, as it does on a local page.

The feed reuses the epoch its attach observed for every later poll, send and detach,
rather than discovering again. This amends 105, whose `peer_client.call` always
discovers first and whose text says there is no discovery cache. That rule is about
deciding whether to dispatch at all; here a stale epoch is answered `stale` and ends
the feed, which is the outcome a fresh discovery would reach one call later, and the
receiver's epoch and revision checks run unchanged. Doing discovery on every poll
would double the round trips of a stream.

### The box's feed host

`client/remote/feed_host` is one weft managed task per feed, found by its token
through a directory `TopHost` holds, as `top_relay` holds a worker per orchestrator.
It plays the part `ui_relay` plays for a local page (`client/daemon/ui_relay.gleam:224`):
it attaches with `gateway.attach_authenticated_flushing`
(`client/gateway.gleam:1608`) giving its own pid as the socket, so the gateway
monitors it and drops the attachment and its presence when it exits. Each feed takes
one of the box's connection permits, as a page socket does
(`client/daemon/ui_socket.gleam:2000`), and a spawner holds at most eight feeds
(`MaxFeeds`, a constant and not a key); the ninth attach is refused with `cap_reached`.

The binding (`client/gateway.gleam:309`) is the box owner's principal at the
Operator authority, the standing the box owner's own operating page has, with
`signin` empty and `door: PeerDoor(spawner, deciding)`. `Door`
(`client/gateway.gleam:345`) gains that variant so that the gateway's readers of the
door (the surface an evolution act is recorded as, which is refused here anyway, and
the attachment count below) can tell a feed from a page and a terminal. `deciding` is
`Decides` when the spawner's table has an `approval_ceiling` and `Watches` when it
has none, fixed at attach from the table the daemon read at start. The binding's
`digest` is a constant derived from the spawner's name, so it matches no credential;
slice 2 checks every reader of `Binding.digest`. The `check` the gateway calls at
each request and push has `ui_relay.while_open`'s shape
(`client/daemon/ui_relay.gleam:201`): the spawner still has its table with
`page = "live"`, the session still has its relayed row, and it is not archived. An archive closes the attachment and the next poll answers `revoked`. The
table is read once at start, so a table the box's owner changed is met first by the
new epoch of the restart that read it.

The gateway writes replies and pushes to the feed host's sink from one process, so
the feed host's queue holds them in the order a local page receives them
(`docs/client-protocol.md` §6.1). The queue is numbered as above and bounded at
1,048,576 bytes and 512 frames that the laptop has not acknowledged, except that a
single frame larger than the byte bound is always admitted to an empty queue, so a
frame's size alone never ends a feed. Pushes are not all bounded the way replies
are: a reply is held to 65,536 encoded bytes (`client/gateway.gleam:4915`), a usage
push is checked against the same figure (`client/gateway.gleam:4012`), and a delta
is clipped to stay under it (`client/gateway.gleam:4960`), but the other pushes are
not checked against it, so a large tool result's `entry` can be bigger. Such a frame
goes in an answer by itself, as below, and does not end the feed.

When the queue passes its bound, or no poll has arrived for 15,000 ms, the feed
**lapses**: the feed host detaches from the gateway, drops the queue and any
partially received frame from `108.send.1`, answers `ended: lapsed` to the next poll,
and keeps the ended token for one more lease so a late poll learns why before the
feed host exits. A detach drops the same state. A partial frame can hold up to the
operator bound of 12,582,912 bytes, eight feeds per spawner, so the box never keeps
it past the feed it belongs to. A lapse drops the feed and
not single frames, because a `stream_delta` carries no offset (§5.13): dropping one
from the middle of an answer would draw a garbled preview until the entry lands. A
lapsed page reconnects through 097 and starts from a fresh subscribe, which is
always correct.

### What the box admits from the page

The feed host decodes the `cmd` of every frame with the gateway's own decoder
(`client/protocol.gleam:1368`) and forwards the original text, so the gateway sees
exactly what the lane wrote. A frame that does not decode is answered as the gateway
would answer it. What a command becomes is a closed table:

| Commands | What the box does |
|---|---|
| `subscribe`, `snapshot_next`, `catch_up`, `history`, `history_lineage`, `escalations_get`, `escalations_decided`, `child_history`, `context`, `live_jobs`, `notes`, `queued_input`, `goal_get`, `block_summaries`, `advisor_pending`, `skills`, `models`, `permissions` | Forwarded. |
| `prompt`, `prompt_content`, `steer`, `follow_up`, `abort`, `edit_queued_input`, `remove_queued_input` | Forwarded, to any strand of the session. |
| `approve`, `deny`, `permission_forget` | Not forwarded. Judged through the hub's relayed door, below. |
| Everything else (`fork`, `create_strand`, `navigate`, `compact`, `set_config`, `profile_get`, `profile_set`, `schedules`, `schedule_cancel`, the goal mutations, `btw`, `proposals_get`, `proposal_decide`, `memory_get`, `evolution`, `worktree_diff`) | Answered `forbidden` with the fixed words "not offered to a page on another orchestrator". |

The refused set is everything 094 refused (a profile or model change, a fork) plus
what belongs to the box's owner at their own machine (proposals, evolution, memory,
schedules) and what this proposal leaves for later (compact, goals, `btw`; each can
be added as a line here and a control the page stops hiding).
The page hides the controls it will be refused (`Standing.route`, below), and the
box's refusal is the authority.

### Approvals with scopes

A decision from the page never reaches the gateway's `approve` door, which would
judge it as the box owner's and so with no ceiling. The feed host turns `approve`
and `deny` into a `remote_escalation.Decision` (`Approve(grants, action, scope)` with
`Once` or `Session`, or `Deny`) and calls `gateway.decide_relayed`
(`client/gateway.gleam:1797`) with the spawner's name, its `approval_ceiling`, the
escalation id, the echoed seq and the decider from the attach. That is the door
`TopResolve` already uses (`client/top_host.gleam:211`), and the hub judges it in its
turn with `remote_decision.admit_relayed` (`client/remote_decision.gleam:145`): the
ceiling with its canonical-path test, the echoed action, the subset of the stored
`wanted` list and the seq compare-and-set. A remembered grant is written with the
spawner's provenance in the same transaction. So "allow for this session" from the
laptop grants exactly what 094's `TopResolve` with `"session"` grants and no more.
With no `approval_ceiling` every decision is refused.

**Whether a refused call waits.** Attaching changes what the session does with a
refused call, not only what the page sees. A session's escalation config asks
whether anyone is there to decide (`client/serve.gleam:4085`), and today the answer
is yes when the gateway counts an attachment (`gateway.attached`,
`client/gateway.gleam:1719`). A pending record then parks the call for its window
instead of settling it in band (`client/escalate.gleam:1150`). A relayed top-level
session with nobody on the box's own page settles in band today, so the model sees
the refusal at once. A feed attached as an ordinary Operator connection would make
every such call wait out its window, including where the page can decide nothing.

So `gateway.attached` counts a `PeerDoor` attachment only when its `deciding` is
`Decides`, which is the spawner having an `approval_ceiling`. With a ceiling, the
laptop's page behaves as a local page does: the call parks, the card shows, and a
decision inside the ceiling lets it run. Without one, the feed is not counted, the
call settles in band exactly as it does today, and the page draws the request as a
card with no buttons and the fixed sentence "This request can be decided only on the
page of the orchestrator that runs this session." The record stays pending there, as
in 094.

The feed host writes the answer as a reply frame in the gateway's own shape, encoded
by the box's `client/protocol`, with the lane's request id: `Decided` is a
`mutation_outcome` with status `committed`; `Stale` is `stale_approval` with the
record under `details.escalation`; `Refused` is `bad_request` with the reason,
which is what 4.9.6 already answers for a grant outside a spawner's ceiling. A hub
that did not answer is `internal`, whose outcome the page treats as unknown
(§6.5). The record's change then reaches the page as any escalation event does,
because the commit is in the session.

`permission_forget` of one grant becomes `Forget(grant)`, which withdraws only a
grant this spawner approved (`client/remote_decision.gleam:230`). Its reply is the
`permissions` board read after the forget, encoded as the gateway encodes it, so the
page redraws in one round trip as 073 does. A forget of an `action` consent or of
`all` is refused with `bad_request` and the words "forget it on the page of the
orchestrator that runs this session": `admit_relayed`'s `Forget` has no form for
either, and widening it is not needed for parity with what the spawner itself
approved. The board already carries a `spawner` member for a grant the spawner
approved (`client/permissions.gleam:574`), which `session_view/remembered` reads today
as unattributed (`session_view/remembered.gleam:207`). Slice 3 teaches it that member,
so the relayed page offers Forget only on the spawner's rows and words the rest as
approved on the other machine. That is a decoder change and no wire change.

### The laptop's socket adapter

The seam is `component.Transport` (`web_view/component.gleam:616`). The component
opens it with `connect(inbox, opened)` in `open` (`web_view/component.gleam:1552`) and
performs the step's `Transmit` and `Shut` through `transmit` and `shut` in `perform`
(`web_view/component.gleam:7196`). A local page's transport is built in
`ui_socket.admit` (`client/daemon/ui_socket.gleam:1974`) with `connect` starting
`ui_relay.start`, `transmit: ui_relay.transmit` and `shut: ui_relay.shut`. A live
relayed page is built the same way with `client/daemon/ui_feed` in their place, with
the same three signatures (`client/daemon/ui_relay.gleam:224`, `:335`, `:346`). No
`session_view` code on the frame path changes for it, and in `web_view` nothing
below the transport does. The one `session_view` edit is slice 3's change to the
`remembered` decoder above, which is about drawing provenance and not about frames.

`ui_feed` is a weft actor started from inside the component's start, as `ui_relay`
is. The socket has already attached (see "Choosing the page"), so `connect` starts
the actor with the attach answer and it answers `opened` at once, well inside
Lustre's one-second start budget. It holds the box epoch, the token, `after`, and
the lane's outbound frames in order. It keeps at most one poll and one send in flight
per feed: it polls again as soon as an answer is handed on, and it sends frame `n + 1`
only after every piece of `n` was admitted, stop-and-wait as 107's chunks are. Each
frame of an answer goes to the component's inbox as `connection_event.Incoming`, in
number order, and a number at or below `after` is dropped, so the lane sees each
frame once whatever the link did. It calls `top_relay`'s dial for the orchestrator
and the new `peer_client` entry point under 094's `call_ms`
(`client/remote/top_relay.gleam:95`); a poll waits at most 5,000 ms of that budget.
A poll answer that arrives after `ui_feed` stopped waiting for it (its call timed out,
or a later poll superseded it) is a stray: each exchange has its own reply subject,
and `ui_feed` drains and drops a reply on a subject it no longer waits on, so a late
answer can neither reorder frames nor fill its mailbox.

Resending at this layer is not the client resending a command. §6.5 forbids a client
from resending a command whose reply it lost, because the command may have run.
`ui_feed` resends only a piece whose admission answer it lost, and the box admits a
piece once, so the gateway receives the lane's frame at most once and the lane's own
rule is untouched: a reply that never comes still becomes `UnknownOutcome` at the
lane's deadline.

The page's other capabilities are the laptop's, not the box's. `sessions`,
`activity`, `open`, `resume` and `home` are the laptop page's own, so the sidebar,
switching and Home work as on any page. `invite`, `rename`, `shareable`, `worktree`,
`manage`, `peers` and `logins` are `None`, because each is a power of the daemon
that serves the session and the box offers none of them over the feed. The socket
admits events with `ExceptOwner` reach (`client/daemon/ui_socket.gleam:443`), which
already excludes the owner controls' paths. `ui_feed` checks on every poll that the
page is still open and still the owner's operating page, as the 094 page's
functions do (`client/daemon/ui_socket.gleam:1287`), and ends with `PageEnded` or
`AccessRevoked` otherwise.

`component.Standing` (`web_view/component.gleam:542`) gains `route`, `Local` or
`Relayed`, with `Local` in `unplaced` (`web_view/component.gleam:589`). A `Relayed`
page draws no control for a command the box refuses (the model chip, Compact, the
goal panel's mutations, `btw`, fork) and no decision buttons on a remote child's
request. `Standing.machine` is the `[orchestrators.<name>]` key, so the placement
strip reads "Agent on box".

### Choosing the page

The route is 094's (`/ui/p/<key>/orchestrators/<name>/sessions/<id>`), and the
document is unchanged: the session and home shells are the same document with a
different title and waiting paragraph (`web_view/page.gleam:246`, `:260`). The socket
chooses, before it starts any component. At upgrade, the relayed socket
(`client/daemon/server.gleam:569`) makes the attach call within `call_ms`, the wait the 094 page's first read already
has. If the features answer advertises `108.attach.1` and the attach succeeds, the
socket starts the session component with `ui_feed`. If the revision is absent or the
attach is refused with `not_offered`, it starts the home component with the `Visit`,
as today. If the box does not answer, it starts the session component with a
transport whose `connect` answers `PeerUnreachable`. No answer is cached, so each
reconnect chooses again, and a box upgraded or downgraded under an open page is
drawn in its new mode after the next reconnect.

### Bounds and backpressure

Nothing crosses the link unasked. The box answers only polls, sends and detaches,
and the laptop has at most one poll and one send in flight per feed, so the feed
host's mailbox holds at most two link messages per feed. A poll that supersedes a
held one releases it with an empty answer, so a confused or retrying laptop still
holds at most one poll at the box. The only mailbox the link cannot bound is the feed host's own sink, which receives
the gateway's pushes exactly as `ui_relay`'s does today
(`client/daemon/ui_relay.gleam:67`); the feed host does no work on a push but count
and enqueue it, and a queue over its bound becomes a lapse and a detach, which stops
the pushes. That is the lesson of the chunk path: the receiver's mailbox is
never the buffer.

An answer holds the frames that fit under 105's envelope bound
(`client/remote/peer_codec.gleam:21`, 1,048,576 bytes) after JSON escaping. A frame is
JSON with no raw control character, so carrying it as a JSON string at most doubles
it (only `"` and `\` gain a byte). A frame that does not fit beside others goes in an
answer of its own, so any frame of up to about 512 KiB of text crosses in one answer.
Whether a push can be larger than one envelope carries is not settled here, since the
gateway bounds only some pushes: slice 2 checks every push the gateway writes to an
attachment against that figure, and if one can exceed it, carries it in pieces the
way `108.send.1` carries the other direction rather than ending the feed. A piece of
a sent frame is at most 393,216 bytes of frame text for the same reason, and a whole
frame at most the page socket's operator bound
(`client/daemon/ui_socket.gleam:267`, 12,582,912 bytes), so a prompt with four
pasted images reaches the box in at most 32 pieces. 105 measures every envelope
before it parses one, so a hostile piece that escapes to more is refused as
`oversized`, not read. The box holds at most one partial frame per feed.

Fragment rate follows from the poll. A streaming answer's deltas accumulate on the
box while a poll is out and leave as one answer, and the component reduces an
arrival batch as one message and one render (`web_view/component.gleam:259`), so the
page renders about once per round trip, however fast the provider writes. The
history window is the page's own (`live_rows`, `held_rows`, the 600-record history
window and the scan's bounds), read through the lane as on a local page; the feed
adds only its 1 MiB queue.

A transfer costs about one round trip per 24 KiB chunk, because the session endpoint
is stop-and-wait (§4.2) and the lane sends `snapshot_next` only after it holds the
previous chunk. The send and the poll answer travel at once, so a chunk is one round
trip and not two. The box expires a transfer 30 seconds after its capture (§4.3), so
at a 50 ms round trip one transfer carries at most about 600 chunks, some 14 MiB. A
subscribe's metadata is at most 2 MiB and a lineage page 2 MiB past its first
record (§8), so ordinary transfers fit with room, and a command's reply has the
lane's 10 s deadline (`session_view/session_channel.gleam:2033`) against the
gateway's 6 s answer, which leaves the link 4 s. Slice 4 measures the page's open on
the exe.dev pair; a credit window for `snapshot_next` would be a client protocol
change of its own and is deferred (see the decisions below).

### When the link drops, and what the page shows

A drop shorter than the lease costs nothing. Polls fail, `ui_feed` polls again with
the same `after`, pausing 250 ms and doubling to 2 s (shorter than `top_relay`'s
500 ms to 4 s, because a poll changes nothing and the lease is 15 s), and the first
answer after the link heals carries every frame the box queued meanwhile. The lane's
own deadlines are the limit: a request in flight when the link drops fails the lane
after its 10 s, and an idle lane's 5 s refresh
(`session_view/session_channel.gleam:314`) puts one in flight. So a drop of more than
about 10 to 15 seconds ends the lane, `ui_feed` reports `ConnectionFailed`, which is
`Retry` (`web_view/ending.gleam:156`), and the browser reconnects through 097 into a
fresh component and a fresh attach.

While the box cannot be reached the fresh attach fails, and the page draws the new
ending `PeerUnreachable`: "The orchestrator that runs this session is not
answering. This page will reconnect." It is `Retry`, so the browser keeps trying
with 097's backoff and the page fills again on the first attach that succeeds. A
`lapsed` feed is `ConnectionFailed`; `stopped` is `SessionStopped` and `revoked` is
`AccessRevoked`, both `Final`, as on a local page. The session keeps running on the
box throughout, and nothing in it waits on the laptop.

### Strands, subagents, the advisor and remote children

Strands, local subagents and the advisor are strands of the box's session, so they
arrive in the same captures and pushes and the page draws them with its own code:
the strand panel, focus (`component.focus`, `web_view/component.gleam:6552`, a
lane-local switch plus history reads, which are admitted), the advisor's board and
nudges. Prompts and steers go to the strand on screen; the box admits them for any
strand of the session, which lifts 094's main-strand rule for the live page. A local subagent's request is a record in
the session's own register, so it is decided through `decide_relayed` like any other.

A remote child of the relayed session (a child the box session started on a third
orchestrator, or on the laptop itself) is a stub in the box's session, pushed to the
feed as the `remote_children` snapshot and peeked through `child_history`
(`web_view/component.gleam:6588`), which the box asks the child's orchestrator about
as it does for its own page. Its card and transcript peek are therefore what the
box's page draws. Its requests are shown and not decided: the record lives on the
third machine, `admit_relayed` cannot judge it, and the box's `top_level` ceiling
cannot be tested against paths on a machine the box cannot canonicalize. The box
refuses such a decision with `bad_request` and the page draws no buttons for it,
with the sentence a request draws when there is no ceiling. This is decided below.

### Identity on the page

The page shows what the box's own owner page at the Operator ceiling would show, and
no more, because the frames are exactly the ones the box's gateway writes to an
owner's Operator attachment. The heading is drawn from the attach's `label` (the
session's name, and its folder, executor workspace or pool, which 094's rows already
show), with `workspace_digest` the SHA-256 of the orchestrator's name and the
placement, so the layout the browser keeps never collides with a local workspace's.
The viewers in the Session pane are the box's presence rows; the feed is among them
as the box's owner, which is who it attaches as. The remembered permissions list is
the box's, with the box's sign-in fingerprints, as the box owner's own page shows
them. What the box's page draws from daemon capabilities and not from the gateway
(the worktree read, sign-ins, the admin page, invitations) is not relayed. Every
string from the box is drawn as a text node under 051's rules ("Nothing from the
session becomes markup"), and an image is drawn as on a local page, from the bytes
in the entry, through the laptop's own image route and its raster allowlist; which
machine wrote the bytes does not change what makes that safe.

### Version skew and the fallback page

A laptop that asks a box without the revisions finds `108.attach.1` absent in the
features answer and draws the 094 page. An older laptop never asks and draws the 094
page. A box with `page = "paged"` refuses the attach with `not_offered` and the laptop
draws the 094 page. The 094 page is therefore kept as the fallback, and it says which
mode it is in with one fixed sentence beneath its heading, with the orchestrator's
name drawn as a text node: "Showing the transcript only, because <box> runs a Loom
without the live session page." when the revision is absent, and "Showing the
transcript only, because <box> serves this session as a transcript." when the attach
was refused with `not_offered`. A live page needs no such sentence; it is the
session page, with "Agent on <box>" in its placement strip.

The fallback's two fixes that #1135 asks for regardless of the live page (the
transcript's text drawn through `markdown.parse` and `markdown_view` as text nodes,
and the head and foot written for an agent not drawn to a person) are in PR #1191
and are not part of this proposal's slices. The mode sentence above is slice 3's.

### The other direction

Both daemons run both halves, so the box's page views a laptop session by the same
path with the roles swapped: the box needs `[orchestrators.laptop]`, and the laptop's
owner opts in with `[spawners.box]` on the laptop carrying `node` and a `top_level`
table with `page`, and nothing else if children are not wanted. That covers the
sessions the box's page created on the laptop through 094. A box usually cannot dial
a laptop, so the box's page reaches the laptop while the laptop's link keeper holds
the connection and draws `PeerUnreachable` otherwise.

### The owner's own sessions

#1135's exit also asks for a session the owner created on the box to be driven from
the laptop's page. That reaches past `catalogue_relayed_sessions`, which amends 094's
reachability rule and 085's rejection of attaching to a foreign session, and it is
where most of this design's security cost would sit. It is split out of 108 into a
follow-up proposal, off by default, which would add a `reach` key to the same
`top_level` table and reuse this feed unchanged. Nothing in 108 depends on it.

### Security argument

- **051 and 052.** The browser holds a ticket and cookie for its own daemon only,
  and that daemon draws the page. Only the owner's operating page reaches the route,
  as in 094. No URL, class, attribute or key is built from box text.
- **The trust.** A pinned distribution peer is already fully trusted in both
  directions (094's argument). The spawner table bounds an honest peer's mistakes:
  `top_level`, `page` and `approval_ceiling` are the box owner's word, per peer.
- **Authority stays with the box.** The gateway judges every forwarded frame as an
  Operator attachment of the box's owner, and the feed host's table removes the
  commands this proposal does not offer. A decision never reaches the gateway's own
  door; it goes through `decide_relayed` and `admit_relayed`, the code that judges
  094's `TopResolve` and 089's `Resolve`, so the ceiling cannot be widened by the new
  path. A feed without a ceiling does not count as someone attached, so it cannot
  make a refused call wait for a decision nobody on it can make.
- **The widening, stated.** Under 094 a stolen laptop owner cookie could already
  read, send into, stop and approve within the ceiling every relayed session on the
  box. Now it can also steer and prompt any strand of them, read the box's presence
  and remembered permissions for them, and see their images. The set of sessions it
  reaches is unchanged. The owner accepted this with `page = "live"` as the default.

## What it costs

- Four revisions on the stable exchange and one `peer_client` entry point that
  amends 105, three refusal shapes, one `loom.toml` key and a looser `[spawners]`
  decoder, one gateway door variant and a change to what `gateway.attached` counts,
  one `Standing` field and one ending. No frozen interface.
- A feed host per open relayed page on the box: one gateway attachment, one
  connection permit and at most 1 MiB of queue each, at most eight per spawner.
- A long poll per open page: one round trip of latency on every frame, which makes
  the page render about once per round trip and makes a transfer cost a round trip
  per chunk. The tok/s figure is measured on the laptop's clock, so it carries up to
  one round trip of skew.
- A reconnect after a drop longer than the lane's deadline starts an empty
  component, so the transcript leaves the page until the box answers again. A local
  page behaves the same after a failed lane; on a laptop moving between networks it
  will be seen more often. Keeping the transcript across a reattach is deferred.
- The 094 page stays, as the fallback, with its own code and tests.
- The terminal gets none of this; a relayed terminal lane would be the same feed
  behind `tui/terminal_lane` and is not proposed here.

## Slices

1. **The fallback fixes.** Done in PR #1191: the 094 page's transcript as Markdown
   text nodes and no agent framing. Nothing else lands here; the mode sentence is
   slice 3's.
2. **The box half.** The four revisions in `peer_codec` and `peer_top`, the
   `TopHost` callbacks, `client/remote/feed_host` with its queue, lease, filter and
   decision routing, `gateway.Door.PeerDoor` and the change to `gateway.attached`,
   the `page` key with `docs/configuration.md`, and the P model. It also settles the
   push-size question under "Bounds and backpressure". Tested in one VM through a real
   gateway, a real `TopHost` and the real stable endpoint, with `node.self()` as the
   peer, as `peer_remote_test` does, including a refused call that settles in band
   under a feed with no ceiling and parks under one with a ceiling. Its first commit
   fixes the codec (the bodies and answers above), so slice 3 can start from it.
3. **The laptop half.** `client/daemon/ui_feed`, the `peer_client` entry point, the
   feed calls in `top_relay`, the socket's choice in `server` and `ui_socket`,
   `Standing.route`, `PeerUnreachable`, the fallback's mode sentence, and
   `session_view/remembered` reading the `spawner` member. Its files do not overlap
   slice 2's beyond reading the codec. Exit: the two-orchestrator fixture below drives
   a relayed session's page through every exit item of #1135 on one machine.
4. **Pieces, and the live drive.** Frames over one piece (image prompts), which
   touches `feed_host` and `ui_feed`, then the drive against the exe.dev pair: a
   session the laptop created on the box, driven from the laptop's page, and from
   the box's own page beside it.
5. **The other direction.** The `[spawners.<name>]` decoder accepting a table of
   `node` and `top_level` alone, and the box's page viewing a session it created on
   the laptop. It overlaps slice 4 on `feed_host`'s `check` closure, so the two run
   one after the other. Exit: both machines' pages for relayed sessions in both
   directions, with the relayed-only view reduced to the fallback.

The owner's own sessions, the rest of #1135's exit, are the follow-up proposal's.

## Test plan

**The P model.** `protocol/models/live-relay/`, beside `state-transfer` and
`remote-subagents`: a gateway that emits replies and pushes in one order, the box's
feed host with its queue, lease and bound, a link that loses answers and partitions
and heals, `ui_feed`, and a stop-and-wait lane. Its safety properties: every frame
the gateway wrote to the feed reaches the lane at most once and in the gateway's
order; every frame the lane transmitted reaches the gateway at most once; after a
feed ends no frame of it reaches any lane; a decision reaches the hub only through
the relayed door. Its liveness property: a partition shorter than the lease, during
which no lane deadline passes, loses no frame.

**Two orchestrators.** A shipped fixture in the shape of `daemon_shipped_top_test`:
two daemons under separate homes on the loopback address, provisioned with
`loom distribution provision --static`, a scripted model provider, and the procedure
of `docs/distributed-setup.md` Quick start D. The laptop creates a session on the
box, opens its page and drives it: a streamed answer, a folded turn with a diff, a
second strand, an approval allowed for the session and then forgotten, a steer, a
stop, and the top bar's figures; a tool result over 512 KiB arrives in an answer of
its own without ending the feed. Then the link between them is cut for less than the
lease (no visible change) and for longer than the lane's deadline (`PeerUnreachable`, then
a full page after the heal). Then the box restarts (`stale`, then a fresh attach at
the new epoch). Then a mixed pair: a box without the revisions and a box with
`page = "paged"` both draw the fallback with its sentence.

**Fixed-seed properties.** The feed's queue and the laptop's cursor are pure state
machines kept apart from their processes, tested with `statem` under fixed qcheck
seeds: pushes of random sizes, replies, polls with a correct, repeated or stale
`after`, lost answers, duplicated answers, ticks across the lease. The checks: the
frames delivered to the lane are a prefix of the frames queued, in order and without
repeats; the bytes held never pass the bound; a lapse happens exactly when the bound
or the lease is passed and nothing is delivered after it. The same for sent pieces:
any interleaving of lost admission answers and resends hands the gateway each frame
once and whole.

**Hostile frames, toward the laptop.** A box answer that is not JSON, that numbers
frames backwards or with a gap, that carries frames for another token, that answers
a poll `ui_feed` no longer waits on, or that names another session's or
incarnation's cut: each is dropped, ends the feed or fails the lane, and the page
draws none of it. A transcript and an
escalation holding markup and a `javascript:` URL are drawn as escaped text, through
the same checks as `web_view_parity_test`.

**Hostile frames, toward the box.** A command outside the table (`forbidden`), an
approval outside the ceiling (`bad_request`, record still pending), an approval of a
remote child's request (`bad_request`), a forget of `all` (`bad_request`), a piece out
of order or for a frame other than the next, a second concurrent poll (which
supersedes the first), a poll with an unknown token or another spawner's token
(`feed_ended`), an `after` ahead of what was sent, a lapse and a detach with a
partial frame held (dropped), and an attach beyond the feed cap. Each is answered as stated and leaves the session, the gateway
and the other feeds untouched.

## Decided, and what stays open

The owner settled these on 2026-11-04, after the first draft.

1. **DECIDED: `page` defaults to `live`.** Older laptops never ask for the
   revisions, so the default has no compatibility cost, and `top_level` is already
   the box owner's opt-in.
2. **DECIDED: the owner's own sessions are a follow-up.** `reach = "owner"` is split
   out of 108 into its own proposal and is off by default there, because it amends
   094 and 085 and carries most of the security cost. 108 has no `reach` key.
3. **DECIDED: the command table stays as drafted.** `compact`, the goal mutations,
   `btw`, a model or profile change, `fork` and `create_strand` are refused for now;
   each can be added later as a line in the box's table and a control the page stops
   hiding.
4. **DECIDED: a remote child's request is shown and its decision refused.** Deciding
   it through the box would need two ceilings and a path test on the third machine.
5. **DECIDED: a `[spawners.<name>]` table may carry only `node` and `top_level`**
   when it exists for the page alone. It admits no spawn.
6. **Deferred: keeping the transcript across a reattach.** Restarting a lane inside
   one component would keep the page drawn through a long drop, for local pages too.
   It is a `web_view` change of its own.
7. **Deferred: a credit window for transfers**, if slice 4's measurement shows the
   page's open is too slow over the tailnet. It is a client protocol change and would
   help a terminal on a slow link as well.

## Addendum: slice 2, the box half (2026-11-13)

Slice 2 built the four revisions, the feed host and its queue, the door and the
`page` key, and checked them with the P model `protocol/models/live-relay` and the
tests named in `packages/client/CLAUDE.md`. Building them settled the questions the
proposal left open, and corrected four places where the code is not as the text
above says.

**The push-size question is settled: slice 2 sends no piece answers, and an
oversized frame lapses the feed.** The proposal says some pushes are not checked
against the 65,536-byte reply figure, so "a large tool result's `entry` can be
bigger". Almost none can be. A daemon's gateway runs `Network` delivery
(`client/gateway.gleam:1417`), and under it a durable emit is pushed as a
`committed` notice that carries no record (`pull_and_broadcast`,
`client/gateway.gleam:3986`). The record travels the credited transfer path, in
chunks of 24 KiB, each a reply that `bounded_response` holds to 65,536 bytes
(`client/gateway.gleam:4947`). The entry push of `HostOnly` delivery
(`client/gateway.gleam:3979`) is a mode of the host fixtures, and no feed attaches
to a fixture. What a feed's sink receives is therefore this set:

| Push | Bound |
|---|---|
| `committed` notice, `presence`, `attachment`, `input_queue_changed`, `goal_changed`, `proposals_changed`, `evolution_changed` | a few hundred bytes each; presence is bounded by the daemon's connection ceiling |
| `usage_observation` | at most 65,536 bytes, or it is omitted (`bounded_usage_observation`, `client/gateway.gleam:4049`) |
| `stream_delta` | at most 24,576 bytes of text before encoding (`broadcast_delta`, `client/gateway.gleam:5009`); at most six times that after JSON escaping |
| `tool_output` | the collector's tail, a sixth of the 24 KiB figure (`broadcast_tool_output`, `client/gateway.gleam:5073`) |
| `remote_children` | at most 60,000 bytes (`remote_agent.list_bytes_limit`) |
| `block_summary` | a summarizer label, which the summarizer bounds, not the gateway |
| `held_input_returned` | the complete text of a queued prompt, with no bound (`held_return`, `client/gateway.gleam`, sent by `drain_held_queues` to the item's submitter only) |

Every push but the last crosses in one answer. `held_input_returned` can be larger
than one answer: a page whose prompt was held when the box drains is sent the
whole prompt, which can be many mebibytes. The queue then cannot carry the frame,
and it lapses the feed, as `feed_queue`'s module doc says. That is safe, and the
page reconnects, but it is reachable, and the first version of this addendum called
it unreachable. The exception for "a single frame larger than the byte bound" is
still never needed: one answer carries at most 1,044,480 bytes, which is below the
1,048,576-byte bound, so any frame an answer can carry is inside the bound. The test
plan's "tool result over 512 KiB arrives in an answer of its own" is true of the
credited transfer's chunks only in the sense that each is small, and it should be
read as the queue test that admits a frame of up to one answer alone
(`feed_queue_test`).

Two consequences are open for slice 4, where piece answers for polls belong, and
slice 2 builds neither.

- A frame larger than one answer, `held_input_returned` in practice, lapses the feed.
  A piece answer for `108.feed.1` would carry it.
- The gateway's flush marker, which `drain_held_queues` follows with the returns so
  that a transport can finish writing, is acknowledged by the feed host when the
  frames are queued on the box and not when the laptop holds them. A relayed page can
  therefore lose a held-input return at the box's shutdown. What is lost is the
  returned draft of a prompt that was never committed.

**Corrections.**

- The gateway does not write replies and pushes to a sink from one process. The
  remote-children pushes run in weft runs of their own (`broadcast_remote_children`,
  `client/gateway.gleam:5331`). Pushes from different processes carry no order
  between them, and the protocol never relied on one (`docs/client-protocol.md`
  §6.2). A reply and a push are ordered as `ui_relay` orders them: the feed host
  blocks in `gateway.connection_request`, queues the reply when the call returns,
  and then handles the pushes that arrived meanwhile.
- An archive is seen as `stopped` and not `revoked`. `archive` stops the session
  before the registry archives it (`client/top_host.gleam`), so the gateway goes
  down first. A feed is `revoked` when its check fails with the gateway still up: the
  relayed row is gone, or the session runs as another incarnation.
- A feed forgotten by the directory is answered `feed_ended` with `lapsed`, as is a
  token of another spawner, a token never minted and a detach race. The laptop's
  action for all of them is a fresh attach.
- An `after` that is ahead of what the queue numbered, or behind what a poll already
  acknowledged, is refused with `invalid_argument` and changes nothing. The proposal
  lists the case and gives no answer.

**Settled in the build.**

- `TopHost` gains one field, `feeds`, a `remote_feed.Host` of four closures, and the
  vocabulary lives in `client/remote_feed` as 094's lives in `client/remote_top`.
  `peer_codec.revisions` advertises the four and `peer_top.dispatch` decodes and routes
  them. The process is `client/remote/feed_host`; the pure queue, the pieces and the
  command table are `feed_queue`, `feed_pieces` and `feed_filter`; the token directory
  and the cap are `feed_directory`.
- The feed host owns the lease, as one weft named timeout that each poll's arrival
  re-arms. A fire means a whole lease passed without a poll. Releasing a held poll does
  not renew it, so the rule is that a poll's arrival renews the lease and nothing
  else. The queue reads no clock.
- A feed counts toward the cap of eight from its reservation until its process exits,
  ended or not. An ended feed keeps its process and its connection permit for one more
  lease so a late poll learns why, and counting it keeps the permits a spawner can hold
  at the cap. The cost is wire-visible: a laptop that attaches again at the cap is
  refused with `cap_reached` for up to one lease after its last feed ended. A feed
  whose attach was cancelled between its start and its registration exits with the
  attach, so it never runs uncounted.
- A feed takes a connection permit of its own class, `root.Feed`, charged what a feed
  can hold and not what a page can: the unacknowledged queue (1,048,576 bytes), one
  partial frame (12,582,912), one answer being built (1,048,576) and one piece being
  read (twice 393,216 as JSON), which is 15,466,496 bytes. Eight feeds take 123,731,968
  of the default 536,870,912, a little under a quarter, where eight page-operator
  charges of 64 MiB took all of it and refused every later connection, the box
  owner's control socket included. The process that answers the attach reserves the
  permit and the feed's own process transfers it, because the root releases a permit
  when the process that holds it exits.
- A piece that does not end its frame must carry at least `min_piece_bytes` (196,608,
  half of `piece_bytes`), so a frame arrives in at most 65 pieces. This is
  wire-visible: a sender sends full pieces and a last piece of any length, and the box
  answers `malformed` to any other. The proposal's "at most 32 pieces" is for
  full-size pieces, and a sender may send pieces from 196,608 to 393,216 bytes.
- The feed's gateway connection id is its own random id, and never the feed's token.
  The id is published in the presence roster and the attachment event to every
  subscribed connection, Observers included, and the token is what names the feed to
  the box.
- A feed blocks on a gateway call for at most the gateway's six seconds, as
  `ui_relay` does, so a laptop that sends faster than the gateway answers waits behind
  its own frame. The send's answer is written before the frame reaches the gateway.

### Follow-up to the slice 2 addendum (2026-11-13)

The re-check of the box half corrected three figures and one lookup, and this
section is the record of them. The text above stays as it was written.

- The feed's permit charge is 28,049,408 bytes, not 15,466,496. When the last
  piece of a frame arrives, `feed_pieces.extend` joins the pieces into the whole
  frame while the pieces are still referenced, and the command filter then parses
  that frame in the same process, so a second `frame_bytes` (12,582,912) is live at
  the peak. Eight feeds take 224,395,264 bytes of the default 536,870,912, about 42
  percent and not a little under a quarter, and still leave room for the owner's
  control socket, a page and a terminal.
- A frame arrives in at most 64 pieces, not 65. Every piece but the last carries at
  least `min_piece_bytes` (196,608), the last carries at least one byte, and
  `frame_bytes` is 64 times the floor, so the box holds at most 63 whole pieces
  below the frame bound and the last. `remote_feed.max_pieces` is 64 and a test
  drives `feed_pieces` with adversarial sequences of pieces that the codec accepts.
- The directory's lookup tells a token that is gone from a directory that did not
  answer. A poll or a send to a token that is gone is told `lapsed`, as before. When
  the directory does not answer, a poll, a send, a detach and an attach are told
  `not_yet_open`, as a feed that does not answer is, and the laptop asks again. A
  detach is no longer answered `null` when the directory was silent and the feed
  was never detached.
