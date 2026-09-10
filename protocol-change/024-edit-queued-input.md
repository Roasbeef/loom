# Edit input before runtime admission

Status: implementation of the requested queued-message editing semantics.

## Problem

The terminal can display pending input but cannot correct it before execution.
Those rows carry a 512-byte excerpt, so using their text as an editor document
would silently discard the undisplayed suffix. Removing and resubmitting a
prompt would also change its position and identity, and could run it twice
when the original drains while the human is editing.

## Decision

The gateway owns editing for messages still in its protocol-022 held queue.
`queued_input` takes `strand` and `id` and returns a `snapshot` with mode
`queued_input`. Its `board` contains `id`, `strand`, `revision`, `kind`, complete
`text`, and `attachment_count`. Revision starts at zero. The text consists of
all original text blocks joined by a newline; image data stays in the queue.
The encoded board must fit within 48,000 bytes. Larger documents return
`queued_input_too_large`; the server never supplies an excerpt as editable text.

`edit_queued_input` takes `strand`, `id`, `expected_revision`, and `text`.
The gateway compares identity and revision and replaces the text in one actor
turn. The item keeps its queue position, priority, ID, original timestamp, and
original author. Replacement consolidates text into one unsigned text block,
followed by every original image block in its original order. Image bytes and
MIME types remain unchanged. The resulting complete board must fit the same
48,000-byte bound before the gateway publishes the update. A successful edit
increments revision, replies with `mutation_outcome` status `queued`, and pushes
`input_queue_changed` through the existing per-frame delivery authority check.

The submitting principal's stable ID and principal kind are captured from its
authenticated binding at admission. Only that principal, currently authorized
to mutate the session, may fetch complete editing text or replace it. A later
connection by the same principal is allowed; another principal, including the
daemon owner, has no override. An observer is refused. Trusted host fixtures
have no authenticated principal, so their submitting connection is their editing
identity. Display names and durable origin snapshots never serve as credentials.
Admission and delivery retain their existing authority revalidation.

Ordinary `pending_inputs` rows gain `revision` and `editable`. Editability is
computed for the connection receiving that snapshot. Existing excerpts and
queue identities are opaque server-minted monotonic IDs, stable for each held
item. Client request IDs are retained only for reply correlation. A missing or
already drained item returns
`conflict`, as does a stale revision. No edit path admits a new prompt. A client
must retain uncertain edit state and reconcile by reading the item, rather than
resubmitting an edit whose reply was lost. If the item has drained, the client
reports that outcome and does not convert its draft into a new submission.

## Alternatives and cost

Local-only editing would hide the authoritative queue and race other peers.
Deleting and resubmitting would need separate cancellation and admission
semantics while losing FIFO position. The existing held queue provides the
atomic comparison and replacement without another actor, timer, or retry loop.
Its lifetime remains transient: a gateway restart can lose unadmitted input.
