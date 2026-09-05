# Design note: multiplayer — several operators on one session

Status: **brief, not built.** Written from a cited survey of the gateway
as it stands (2026-09-04), so the gaps below are measured rather than
assumed. Where this note and the code disagree once work lands, the code
is right and this note should say so at the top.

## What already holds

More of this exists than the word "multiplayer" suggests. The
ClientGateway is "one actor per served session that speaks the Part 1.6
protocol to any number of attached connections"
(`packages/client/src/client/gateway.gleam:1-2`), and the design doc
means it: the UI is always a thin client, a phone and a terminal are
peers, a fleet routes clients by session id (`docs/loom-design.md`
§8.5). Concretely, today:

- **Fan-out.** Every durable emit — `entry`, `usage`, `op_transition`,
  `strand_result`, `escalation` — and every ephemeral `stream_delta`
  is written to every subscribed connection (`client/gateway.gleam:593-627`,
  `1167`, `1880-1900`). The issuing connection's copy is suppressed and
  re-sent as its `reply_to` frame with the same seq, so each client
  sees each event exactly once (`client/gateway.gleam:1839-1878`).
- **One order.** The envelope `seq` is the storage seq of the write that
  produced the event, one strictly increasing space per session
  (`client/gateway.gleam:14-22`). N clients get one total order for free, and
  resync is `subscribe{from_seq}` or `catch_up` replaying
  `[from_seq, high_water]` from storage (`client/gateway.gleam:1382-1481`).
- **Serialised writes.** The hub is one actor and every write goes
  through the session's single writer, so two clients' commands queue in
  mailbox order and never race at the store. A second prompt on a live
  strand is refused as `StrandBusy` (`runtime/api.gleam:53`); two
  steers both admit, in writer order, and both reach the run at
  successive checkpoints.
- **Per-connection state is only `subscribed`.** Every command names
  its strand; there is no per-connection "active strand" to fall out of
  step (`client/protocol.gleam:101-170`).
- **Two clients on one server is already exercised**, as a benchmark
  setup (`docs/performance.md:355-366`) and as `tui_e2e_test`'s second
  raw subscribe (`client/tui_e2e_test.gleam:294-307`).

So the concurrency question is mostly answered by the architecture: the
transcript *is* the lock. What is missing is everything about *who*.

## What is missing

Numbered as the survey found them; **frozen** means spec Part 1 and a
`protocol-change/NNN.md`.

1. **No author on a user turn.** `UserMessage(content, timestamp)`
   (`core/message.gleam:45-47`) and `MessageEntry` carry no identity, so
   the transcript cannot say who said what. Frozen (§1.1, and the `entry`
   body in §1.6).
2. **No client identity on the wire.** The envelope has no client id; the
   hub's `connection: Int` never leaves the process. Frozen (§1.6).
3. **One bearer per server.** "One session is one gateway is one bearer
   token is one trust domain" (`docs/architecture/client.md:30-38`), and
   off loopback that token crosses the wire in the clear and is
   replayable (`client.md:488-500`). Not frozen (WP-L scope), but stated
   design.
4. **`set_config` is invisible to other clients.** It replies to the
   issuer only and `register_events` emits no config event
   (`client/gateway.gleam:2838-2863`, `824-838`); `queue_mode` and
   `tool_execution` are hub memory (issue #184). A `config` event is
   frozen (§1.6 event union).
5. **Presence is a count.** `gateway.attached()` answers "is a human
   there?" for the escalation seam (`docs/spec-gaps.md:812-845`); there is
   no roster and no join/leave event, so nothing can say whose keyboard a
   parked call waits on.
6. **Concurrent steers are silent about each other.** Both admit, both
   inject, neither operator learns of the other.
7. **`deny` is not CAS-guarded** where `approve` is: compare `deny` at
   `client/gateway.gleam:2294` with `approve` at `client/gateway.gleam:2209`.
   Two clients racing approve and deny have no ordering on the deny side.
   Not frozen.
8. **Approvals record grants, not granters** (`client/gateway.gleam:2199-2215`).
9. **The native TUI cannot yet be the second operator.** It does not
   send protocol-change/007's action-and-grant approval, and it has no
   automatic reconnect or sparse catch-up (`client.md:544-547`), though
   the gateway supports both. Client-side only.
10. **No two-connection test asserts fan-out.** `gateway_test` attaches
    a second connection only to count it (`client/gateway_test.gleam:268-272`).
11. **No concurrent-TUI harness.** `run_script` is synchronous and
    single-process, and a script is a fixed list, so two TUIs on one
    server and cross-client interleavings are not expressible yet.
12. **No per-connection rate or frame-size limit**, accepted while
    clients are mutually trusted (`client.md:53-61`).

## The design, in five decisions

### D1. Identity is a *principal* the server knows, not a name the client claims

A client that could type any name into a `who` field could impersonate
another operator in the transcript, and the transcript is the durable
record. So identity is minted server-side and bound to authentication:

- The server keeps a small **principal table** — `id`, display `name`,
  token hash, `role` — beside the session token it mints today. `loom
  invite <name> [--role operator|observer]` mints a token for a
  principal and prints it once; the existing startup token becomes the
  `owner` principal's. Presenting a token identifies a principal;
  presenting the owner's token is what it is today.
- `subscribe` acknowledges with the principal the server resolved,
  never the reverse (`snapshot{…, you: {id, name, role}}`), so a client
  learns who the server thinks it is and renders that.
- Roles are deliberately two: **operator** (prompt, steer, abort,
  approve, set_config) and **observer** (subscribe, catch_up only). Anything
  finer waits for a need. Refusals use the existing `code_forbidden`
  shape rather than a new one.

This closes gaps 2 and 3 together and makes 1 and 8 meaningful: an
author field is only worth writing if it cannot be forged. It touches
§1.6 (the `subscribe` reply body) and is otherwise WP-L auth work. TLS
off loopback is a prerequisite for *remote* multiplayer, not for
same-host, and is filed as its own item rather than folded in here.

### D2. The author travels *with the message*, as an optional origin

A `UserMessage` gains `origin: Option(Origin)`, where `Origin(principal:
String, name: String)`, on both the durable record (§1.1) and the wire
`entry` body (§1.6): **one protocol change, `protocol-change/014`**.
Optional because every record already on disk has none, and because the
memory-session and scheduled runs write user turns with no human behind
them. A steer and a queued follow-up carry the same origin, since they
become user turns.

The projection the model sees gets the author too, once, as a prefix on
the turn's first text block — `[alice] …` — under the same rule the
prompt package uses for other rendered metadata. That is a `prompt`
change, not a protocol one, and it is the whole reason to carry the
author: a model steered by two people should be able to tell them apart
and address them.

Approvals record the granter the same way (gap 8): the approval record
gains `origin`, surfaced in the `escalation` body's resolution. Same
protocol change.

### D3. Configuration is session state and is broadcast

`set_config` becomes a durable register write for *all* of its keys
(closing #184 as a side effect) and materialises a `config` event that
fans out like every other register event, with the issuer's `origin`.
Frozen: a new event in the §1.6 union, in the same protocol change.
Client B's footer then changes model when client A does, and the
recording of either client replays the change.

### D4. Presence is a roster, and the escalation seam asks the roster

`attached()` keeps its count for the "is anyone there?" question. Beside
it, the hub keeps a roster of `{principal, connection, subscribed_at}` and
emits `presence{joined|left, principal}` to every connection, with the
full roster in `snapshot`. Frozen (§1.6), same protocol change.

Escalations stay **broadcast to every operator, first responder wins** —
the existing CAS on `approve` already gives that, and picking "the" approver
would need a policy nobody has asked for. `deny` gets the same CAS guard as
`approve` (gap 7), which is a bug fix independent of the rest. The
`escalation` event names the operators it was shown to, so a client can
render "waiting on alice, bob".

### D5. Concurrency stays as it is: the writer is the arbiter

No new lock, no per-session command queue, no optimistic client-side
merge. The single writer already totally orders every command; the
things two operators can do at once are the things one operator can do
twice, and the existing answers stand: a second prompt on a live strand is
`StrandBusy`; two steers both admit and now both carry an author (gap 6
dissolves: the transcript shows both, the model sees both). The only
addition is a **`code_conflict` with the winning origin** in the refusal
body, so client B's footer can say "main is busy: alice is prompting"
instead of "conflict".

## What the client does

Two TUIs already render the same seq stream. With D1–D4 landed the
native client adds: its own principal in the header, an author prefix on
user turns not its own (its own stay `›` as today), a presence line in
the footer's status section, a `config` event handler that updates the
model label, the 007 approval frame and automatic reconnect with
`from_seq` (gap 9, both prerequisites regardless of multiplayer). Every
one of these is a `Model` change under the virtual backend and gets a
snapshot.

## Tests, in the order they become possible

1. **Gateway fan-out** (`gateway_test`, no new machinery): two attached
   connections with their own inboxes; A prompts, assert B receives the
   `entry` broadcast with A's `origin`, A receives only its `reply_to`
   copy, both see the same seq. Then: observer's prompt is refused; two
   approvals race and exactly one wins; approve/deny race has an order.
2. **Two TUIs, one server** (work package 5's harness, extended): the
   end-to-end run gains a **process-per-client driver** — each client is
   a spawned process owning its inbox, its `connection.connect` and its
   own `run_script` — and the script's operator actions gain a client
   index. Frames from both are collected and held to Part A's invariants
   plus the multiplayer ones: every durable event appears in both clients'
   transcripts in the same order; a user turn from A renders with A's
   name on B and without it on A; a config change on A moves B's footer
   within one settling tick; presence on both matches the roster after
   every join and leave.
3. **The simulator's schedule gains a second operator** (work package
   4): interleavings of two clients' keystrokes and the resulting server
   events, with the invariants above; the fault taxonomy adds "client B
   disconnects mid-stream and resubscribes with `from_seq`".
4. **Recordings from each client** of the same live session, replayed
   side by side, as the golden for the multiplayer PR: the `loom --record`
   flag already captures everything a client saw.

## Order of work

1. `protocol-change/014-operator-identity.md`: origin on user turns and
   approvals, `config` and `presence` events, `you` in the subscribe
   reply. One document, since the four are one idea.
2. Principals and roles on the server (D1), `deny` CAS (D4, standalone).
3. Origin through prompt admission, steers and the projection (D2), and
   config as durable broadcast state (D3, closes #184).
4. Roster and presence (D4).
5. Client: approval frame, reconnect, then the rendering above.
6. Tests 1 and 2; test 3 lands with work package 4.

## Deliberately not in scope

Per-strand principals or ACLs; a chat channel between operators that is
not the transcript; conflict-free editing of a shared draft; TLS in the
client plane, which is required for remote multiplayer and filed
separately; any change to the escalation policy beyond attribution.
