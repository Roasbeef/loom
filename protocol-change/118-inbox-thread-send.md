# protocol-change/118: sending to a session from the inbox on Home

**Status**: ACCEPTED 2026-11-18. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. Built in the second slice
of phase 0 (the 16,384-byte limit and the typed refusals below are what was
built).
**Affects**: the web view's home page. One new capability on the owner's
home, one generalised function in `client/daemon/ui_socket.gleam`, and one
submit handler beneath `home.table_path`. The client control protocol, the
session wire (`prompt` and `steer`), `loom.toml` and every Part 1 interface
are unchanged. The admission rules of the home socket are unchanged
(addendum to [051](051-web-view-route.md), "the attention inbox on Home").
**Raised by**: phase 0 of the attention inbox
(`docs/design-notes/attention-inbox/README.md`, sections 2.2 and 4).
**Builds on**: [022](022-human-input-priority.md) (the gateway's input
queue and `steer`), [051](051-web-view-route.md) (the web view and its
threat model), [065](065-web-workspace-mode.md) (the home, and creating a
session from it).

## Problem

The inbox's reading pane ends each thread with a message field addressed to
that thread's session (README section 2.2). The owner types a message, picks
a delivery, and presses Send. Today the Home page can send to a session in
exactly one case: the first message of a session it has just created
(`first_message_for` (`client/daemon/ui_socket.gleam:7931`)). It cannot send
to a session that already exists. To message one, the owner must open that
session's page and use its composer.

This proposal lets the Home page send to a session the owner holds, by the
same path the first message already takes, and it states what a compromised
Home page could do with that ability.

## What was considered

### Peer mail (rejected)

The daemon already carries a message from one session to another: the
control command `peers.send` and the model-facing tool `peer_send`
(`client/peers.gleam:864`). Both deliver a peer-origin message. The agent
treats a peer-origin message as mail from another agent and treats a user
prompt as an instruction from a person. A message the owner types in the
inbox is a user prompt, so peer mail would mislabel its origin. Peer mail
also needs a source session and strand, and the Home page has neither.

### A new client protocol frame (rejected)

A frame such as `thread.send` on the home's socket would need a protocol
version, a decoder, and a new frame class in the admission rules. The
existing path needs none of them: the gateway already accepts `prompt` and
`steer` from an attachment bound to a principal. Reusing it keeps the
gateway the one place that admits, queues or refuses a human message.

### Sending through the session's own page (rejected)

The Home page could open the target session's page in a second element and
forward the text to its composer. That puts two pages in one view, and the
operator page's composer carries state (drafts, images, pending nudges) that
the inbox does not own.

## Decision

### Who may send

The Home page gets a thread-send capability only when the page's principal
is the daemon's owner and the page's ceiling is Operator. It is built like
`home_create_capability` (`client/daemon/ui_socket.gleam:1870`), which
returns `Some` for exactly that pair and `None` for a member at either
ceiling and for the owner at the Observer ceiling.

The capability MUST be re-derived when the submit is processed, with the
same checks `authorized_owner` makes for creating a session
(`client/daemon/ui_socket.gleam:4093`): the page is open, the ceiling is an
operator's, and the page's credential still authenticates as the owner. A
page whose standing has changed since it was minted therefore sends nothing.

A member's home and an observer's home MUST NOT be given the capability, and
the page MUST NOT draw the message field for them.

### What is sent

The Home page sends one message to one session. The message has:

| Field | Value |
|---|---|
| session | the identifier of a session the principal holds |
| strand | `main`. Other strands are not addressable in phase 0. |
| text | UTF-8 text. No images. |
| delivery | `Prompt` or `Steer` |

`Delivery` is the type the operator page's composer uses
(`session_view/operator.gleam:34`); `operator.frame`
(`session_view/operator.gleam:86`) maps it to the `prompt` or `steer`
command (`client/protocol.gleam:168` and `:174`). The wire also has
`follow_up` (`client/protocol.gleam:177`). The Home page MUST NOT send it,
as the operator page does not.

The two deliveries behave as they do from the operator page:

- `Prompt` to an idle session starts a turn. `Prompt` to a busy session is
  held by the gateway and runs after the current turn. The gateway orders
  it `AfterTurn` (`client/gateway.gleam:1406`), and the operator page labels
  the button "Queue".
- `Steer` stops the observed operation and runs first, ahead of queued
  turns. The gateway orders it `SteerNext` (`client/gateway.gleam:1409`),
  and [022](022-human-input-priority.md) specifies the behaviour.

The gateway bounds both queues: four normal inputs and four steers for each
strand ([022](022-human-input-priority.md)). A send over the bound is
refused by the gateway.

### Which buttons a thread offers

The buttons depend on the state the session's report gives the inbox:

| State | Buttons |
|---|---|
| idle, failed, or nothing said | Send (a `Prompt`) |
| working | Queue (a `Prompt`, held after the turn) and Steer (a `Steer`) |
| an approval is pending | Queue alone, with the words "held behind the approval" |

The page names the button it expects and does not enforce it: the gateway
decides from the strand's state whether a prompt starts a turn or waits. Every
message is the owner's own prompt, attributed as one typed on the session's
page.

### How it is sent

No new frame is added to the client protocol. The home's socket handles the
submit and, as the page's principal, runs the path the home composer's first
message uses. `message_to` resolves the session and `send_message`
(`client/daemon/ui_socket.gleam:8069`) sends the text. The steps are:

1. Resolve the principal and its authority on the session with
   `manager.session_authority` (`client/daemon/manager.gleam:1970`). A
   session the principal does not hold is refused.
2. Require the session to be resident. A saved session is refused.
3. Attach to the session's gateway with `gateway.attach_authenticated`. The
   binding's authority is the held authority capped at Operator
   (`ui_relay.capped`), and the binding's door is `PageDoor`, as for every
   page.
4. Subscribe, then send `Prompt` or `Steer` on strand `main`.
5. Report success only when the gateway answers `admitted` or `queued`. A
   `conflict` carrying the gateway's queue-full words is `QueueFull`, and any
   other refusal, or a reply that did not come, is `NotAccepted`.
6. Detach.

`first_prompt` sent `Prompt` only. It is generalised to `send_message`, which
takes the delivery, and the resolution in `first_message_for` becomes
`message_to`: from "the first message of a new session" to "a message to a
session the principal holds". The home composer keeps its first message
working through the same function, with `Prompt` (`first_message_for` is now a
thin wrapper that turns the typed answer into the `Result` the creation
expects). The text is a JSON string inside the frame, so it cannot name another
command.

The home component receives the generalised function through a `Start`
field, `thread_send`, as it receives `create` and the other owner-only
requests. The request runs in a task, so the page's runtime never waits for the
gateway. The task bounds the send with a 20-second deadline inside its own run
and delivers an answer whether the send finished or not, so the page's
"Sending…" is always settled; a send that misses the deadline is `NotAccepted`.

### Bounds

The message is text only. The Home page MUST refuse text that is empty after
trimming, and text longer than `composer.prompt_limit`
(`web_view/composer.gleam:68`, 16,384 bytes), the limit the home composer
already applies to its first message. The daemon checks both again at the press
and answers `NotAccepted` for a message that fails either.

An inbox message is a short note to a session that is already working, and
Home already accepts 16,384 bytes in its composer, so the same bound serves
both and no second number exists. The operator page's composer draft limit
(`component.prompt_limit`, 262,144 bytes) is larger and is not used here; a
long brief belongs on the session's own page.

### What the page shows

The result of a send is drawn in the outbox as fixed words. The words do not
include text from the session, from the gateway or from an error value. The
daemon answers with a closed type: `Delivered(Admitted | Queued)` or a refusal
`NotHeld`, `NotResident`, `NotAccepted(reason)` or `QueueFull`. The reason in
`NotAccepted` is kept for the daemon's log and is never drawn.

| Answer | Words |
|---|---|
| before any send | Not sent |
| the task is running | Sending… |
| `Delivered(Admitted)` | Delivered to (session) · admitted |
| `Delivered(Queued)` | Delivered to (session) · queued |
| `NotHeld`: the principal does not hold the session, or the capability fails at the press | Not sent: this home no longer holds that session |
| `NotResident`: the session is saved, or not running | Not sent: the session is not running |
| `NotAccepted(reason)`: the gateway refused the message, or did not answer | Not sent: the session refused it |
| `QueueFull`: the queue bound was reached | Not sent: its queue is full |

After `Delivered` the message field clears. After a refusal it keeps the draft.

"Delivered" means only that the gateway admitted or queued the message. It
does not mean that the session read it, or that a turn ran.

### No hold and no undo

Phase 0 does not hold a message on the daemon before sending, and it does
not retract one after sending. A message that the gateway has admitted or
queued is the gateway's, and it is handled as a message typed on the
session's own page. A daemon-side hold is a later decision (README section
5, "Holds").

An approval is never decided from Home. The approval stays on its own
session page's dock, as [051](051-web-view-route.md) specifies, and this
proposal adds no command that answers one.

## Threat model

Everything in [051](051-web-view-route.md)'s threat model stands. This
proposal adds one thing a page can do, for the owner's operating home.

**What a compromised Home page can do.** Send `Prompt` or `Steer` text, up
to the limit above, to any resident session the owner holds, on strand
`main`, as the owner. This is what the owner could type on that session's
own operator page. A steer interrupts the session's current operation, as it
does from that page.

**What it cannot do.** Decide an approval. Reach a session the principal does
not hold. Send as any principal other than the page's own. Send an image.
Send to a strand other than `main`. Send `follow_up`. Send peer mail. Send
from a member's home or an observer's home, which have no capability. Send
after the page's ceiling or the credential's standing has changed, because
both are checked again at the press.

**Session-derived text.** The inbox shows text that a session produced. It
stays text nodes, as [051](051-web-view-route.md) requires, and no
session-derived text is used as a path, an attribute or markup.

**Residual risk.** A compromised owner Home page can steer every resident
session the owner holds. The gateway's bound of four steers for each strand
limits how much a page can queue, and the owner's own operator pages carry
the same ability.

## What it costs

- One capability, built like `home_create_capability`, and its test.
- One generalised function: `send_message` (was `first_prompt`) takes a
  delivery, and `message_to` (was `first_message_for`) serves any session the
  principal holds.
- One submit handler beneath `home.table_path`. The home socket already
  admits a submit there for `Submitting` (`home_owner_accepts`
  (`client/daemon/ui_socket.gleam:2193`)), so no admission rule changes.
- `first_prompt` answered a refusal with one string ("the session did not
  accept the message"). The outbox words above need the refusals told apart,
  so `send_message` returns the closed `web_view/thread_send.Answer` in place
  of that string. The gateway's queue-full refusal is a `conflict` whose words
  are now a public constant (`gateway.queue_full_message`), so the daemon tells
  it from the other conflicts a prompt can meet without a copy of the sentence.

## Slices

1. Phase 0 of the inbox build: the capability, the generalised function, the
   submit handler and the outbox words land with the inbox's message field.
2. Phase 1 extends the same command to answers that name a record revision.
   That is the attention feed proposal, and it gets its own
   `protocol-change` file.

## Decisions for the owner

None are open. The owner accepted autonomous protocol changes for this
build on 2026-11-17, and the decisions above were made under that
acceptance.
