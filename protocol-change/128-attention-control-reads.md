# protocol-change/128: answering an ask and reading saved counts over the control socket

**Status**: PROPOSED 2026-11-20. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is the control-socket
half of what the web view already does in process, so that a native client can
do it too.
**Affects**: two new control commands, `attention.answer` and
`sessions.saved_attention`; one new field of the daemon's `server.Config`
(`strand_send`); one new parameter of `main.listen_moving` (`gateway_of`); one
function split in `client/daemon/ui_socket` (`strand_sender`, which
`message_to_strand` now calls). No stored record, catalogue table, frame or
`loom.toml` key changes, and no existing command changes.
**Raised by**: the native desktop client (`roasbeef/loom-desktop`), which speaks
the control protocol and has no in-process path to the web view's functions.
**Builds on**: [120](120-attention-feed.md) (the feed, `attention.read`,
`attention.close_find`, and the answer's steps, which this document does not
change) and [122](122-attention-catalogue-summary.md) (the catalogue summary of
saved sessions' attention, whose only reader was the web home).

## Problem

A native client can list the feed (`sessions.attention`), read a record
(`attention.read`) and close a find (`attention.close_find`) on the control
socket. It cannot answer an ask, and it cannot read how much attention a saved
session needs.

[120](120-attention-feed.md) specified `attention.answer` as a control command.
Its "As built" section records why it was not built as one: delivering the
answer needs the session's gateway, and `server.Config` does not hold one, while
the home page reaches the gateway through `ui_socket`. The reader of the feed
sees an ask with `may_answer: true` and has nowhere to send the answer. The
note left the control command to "the slice that draws the answer"; this is that
slice.

[122](122-attention-catalogue-summary.md) keeps a summary row for each session so
that counts survive a restart, and says Home reads it. The only reader is
`server.home_saved_attention`, an in-process function the web home calls. After a
restart every session is saved, so a native client that can read only the live
feed sees nothing for sessions that still wait on a person.

## What was considered

### Answering through the in-process web view

A native client could open the daemon's web view and drive its page. Rejected. It
would put a browser engine and the page's session login between a native client
and a command the control protocol already has the shape for, and the page's
answer form is not an interface.

### Giving the control socket its own delivery code

The control socket could attach to the gateway itself and send the prompt.
Rejected. The page's send (`ui_socket.message_to_strand`) already resolves the
caller's authority from the registry, finds the resident incarnation, builds a
binding capped at Operator and maps the gateway's reply to a `thread_send.Answer`.
A second copy would drift from it, and the two doors would then deliver a prompt
under different bindings.

### Importing `ui_socket` from the control server

`daemon/server` cannot import `daemon/ui_socket`, which imports `server`. Moving
the send into a third module was considered and rejected as the larger diff: the
send is about 150 lines with its frame handling and its reply decoding, and
`gateway_test` calls its pieces by their `ui_socket` names. The send is instead
built where both are visible, in `main`, and handed to the server as a value.

### Letting the control command take the web view's owner-only rule

The page lets only the daemon's owner answer, because a member's home draws no
answer control. The in-process door that does the work
(`attention_door.answer`) authorises the owner and a member holding the session
as an Operator, as [120](120-attention-feed.md) specifies for the command. The
control command takes the door's rule. A member Operator can already answer
through a session's own page, and an observer cannot through either.

### Returning saved counts inside `sessions.attention`

The live feed's row could carry the saved summary for a session that is not
resident. Rejected. The two answers differ in kind: a live row is current and
bounded by the 2,400-byte row rule, and a summary is a cache that can lag its
record ([122](122-attention-catalogue-summary.md), "Consistency and
reconciliation"). A client must be able to tell which it holds, and a separate
command says so by its name.

## Decision

### `attention.answer`

```json
{"v":2,"id":3,"cmd":"attention.answer","body":{"session":"<canonical-id>","ask":"ask-3f9c01a2b4","revision":41,
 "answer":{"answers":{"q1":true,"q2":"Retry"}},"epoch":"<current-epoch>"}}
```

It is the request of [120](120-attention-feed.md), "The answer", and runs the
steps of that section in order, through `attention_door.answer`, the function the
home page calls. The control command differs from the page's call in one step
only, the standing check: the page checks that its own socket is still open and
at an Operator ceiling for the owner, and the control socket has no page, so the
registry's authority for the credential at the moment of the command is the whole
of it.

The decoder is total. `session` is a canonical session identity, `ask` a string
of at most 64 bytes, `revision` a nonnegative integer, `answer` a JSON object and
`epoch` a string of at most 256 bytes. A member of the wrong type, or a missing
one, is `bad_request` before any registry call. The members of `answer` are not
checked by the decoder: `core/attention_answer.check` validates them against the
stored ask, as for the page, and names the first failing key.

Authority is read from the registry with `manager.session_authority` at the
command. The owner and a member holding the session as an Operator are answered.
An observer is `forbidden`; a member that does not hold the session is told
`not_found`, as an unknown session is. The command is a mutation: it is refused
while the daemon drains (`control_use` is `ControlMutation`).

The reply is `{"ask":"<id>","delivery":"admitted"|"queued","revision":<new>}`.

Refusals, each leaving the ask as it was unless the text says the prompt may
have arrived:

| Code | Cause |
|---|---|
| `stale_epoch` | The epoch is not the daemon's current one. |
| `bad_request` | The envelope is malformed, the record is not an ask or is routed to a strand, or the answer fails validation (the message names the first failing key). |
| `forbidden` | The caller holds the session as an Observer. |
| `not_found` | The session is not held by the credential, the ask is absent, or the asking strand no longer exists. |
| `not_resident` | The session is saved, opening, stopping or has no gateway. |
| `conflict` | The ask is answered already, its revision is not the one given, the strand's queue is full, or the settling write lost a race after delivery (the message then reads "delivered; the record changed"). |
| `unavailable` | The gateway would not take the prompt, did not answer in time, or the settling write failed. |

The messages say whether the ask is still open. A client that receives a
`conflict` with "delivered; the record changed" reads the record again before
offering another answer, as the page does.

### `sessions.saved_attention`

```json
{"v":2,"id":4,"cmd":"sessions.saved_attention","body":{"sessions":["<id>", "..."],"epoch":"<current-epoch>"}}
```

`sessions` is one to 24 distinct canonical identities, validated exactly as
`sessions.attention`'s are (`activity_limit`). The reply is the catalogue summary
of [122](122-attention-catalogue-summary.md) for the sessions among them that
the credential holds, saved or resident, in the order asked:

```json
{"saved":[{"session_id":"<id>","pending_approvals":1,"open_asks":0,"open_finds":2,"oldest_open_at":1763400000000,"updated_at":1763400100000}]}
```

A session with no row, one the credential does not hold and an unknown identity
leave no entry, so a client cannot tell the last two from the first, which is
what [050](050-session-activity.md)'s addendum asks of every read. A row that
does not decode (a negative count or time, which the table's `CHECK` forbids) is
dropped as a session never read. `oldest_open_at` is absent when no ask or find
is open. A catalogue that cannot be read is `unavailable` and never an empty
`saved`, so a client does not draw "nothing open" over a failed read.

The command shares its read with the web home (`server.saved_rows`): one
function holds the membership check, the row decode and the drop rule, so the
two readers cannot disagree. The control command is a read and is answered
during a drain. The owner is answered for every identity and a member for the
identities it holds, at any role.

### Where the send comes from

`attention_door.answer` takes a send as an argument, and the page passes its own.
The control server passes one built by a new `server.Config` field:

```gleam
strand_send: fn(manager.Manager(instance), access.Digest, String) ->
  fn(String, String, String) -> thread_send.Answer
```

Given the registry, the caller's credential and the daemon epoch, it returns a
function from a session, a strand and the prompt's text to the gateway's answer.
`main.listen_moving` builds it from `ui_socket.strand_sender`, the body of the
page's `message_to_strand` with the three values the page took from its
attachment passed as arguments, and a `gateway_of` projection supplied by the
caller as `worktree` is. The prompt is always a `Prompt`. The page's
`message_to_strand` now calls `strand_sender`, so a prompt from a page and one
from a native client take one path, under one binding, capped at Operator.

## What it costs

One field in `server.Config` and one parameter of `main.listen_moving`. Every
test that builds a `server.Config` by hand names a send; the shared fixture's
default refuses every prompt as `NotResident`. `main.listen_serving`, which has
no gateway to offer, passes a projection that finds none. The page's behaviour
is unchanged and `ui_socket_test` and `ui_route_test` pin it.

A native client that holds an Operator credential can now answer an ask the page
would not offer it, because the page's answer control is owner-only. That is the
rule [120](120-attention-feed.md) already states for the command, and a member
Operator could already send the same prompt to the same strand from the session's
own page.

The rare case [120](120-attention-feed.md) and `attention_door` already record is
unchanged: a `queued` prompt is the gateway's custody and can be lost to a drain
while the ask reads answered.

## Verification

`client/test/client/daemon_protocol_test.gleam` pins both decoders: every
nonnegative revision round-trips and every negative one is refused on a fixed
named seed, an answer that is not an object is refused, and the batch of
`sessions.saved_attention` has `sessions.attention`'s bound.
`client/test/client/daemon_attention_test.gleam` runs the commands over a real
control socket against a real registry, catalogue and scripted gateway: an owner
answers and the prompt appears in the strand's transcript; a stale epoch, a stale
revision, an invalid answer, a find, an absent record, a saved session and an
unknown session are each refused with nothing sent and the ask unchanged; a
gateway refusal leaves the ask open; an observer is `forbidden`, a bystander
`not_found` and an Operator member answers, and the record names it; the page's
path through `strand_sender` still delivers and settles; and saved counts are
read for the sessions a credential holds, bounded, epoch-checked and absent for a
bystander.
