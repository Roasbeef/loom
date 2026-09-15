# Streamed response handoff

Status: accepted, September 14, 2026.

## Problem

Provider completion precedes the commit and delivery of its assistant entry.
The terminal previously removed its live fragments on the provider's `end`
observation. While the next capture was pending, the viewport displayed older
history. The saved answer then arrived as new rows and could repeat the scroll.

An operation ID cannot identify the replacement: one operation can make several
provider requests, including retries and tool rounds. Equal text cannot identify
it either. A late capture can describe the state before the current request.

## Decision

Carry the existing reserved `response_entry: EntryId` through the internal
`runtime/effects.RequestSpec` generation and poll variants. The runtime forwards
the ID from its already-committed effect intent; it mints no second identity.
The gateway appends that ID to its generation/poll identity array, which remains
inside the existing `generation` string of stream observations and previews.
Summary request identities remain unchanged because their provider response is
not an ordinary assistant entry.

The terminal recognizes the extended identity and retains its existing bounded
fragments after `end`. An empty identity marker prevents an older preview from
reappearing and prevents late fragments from reopening the completed request.
The exact durable response entry replaces those fragments in one projection.
The exact operation result remains the retirement fallback when that response
is outside the bounded retained history. A successor request also replaces its
predecessor. No second copy of the answer is retained for this handoff.

A capture with an unrelated entry or an older idle state cannot retire the
response. A preview whose response is already in the branch cannot duplicate
that entry. Old servers and summary observations carry no response identity;
the terminal preserves their existing completion behavior.

## Alternatives and cost

Keeping fragments until any new record arrives assigns ownership by timing and
can lose an answer on an unrelated commit. Delaying all end events until a
commit still leaves the client waiting for its credited capture. A separate
presentation timer makes correctness depend on capture latency. The reserved
entry ID is the existing authority for the handoff.

The internal request constructors gain one required field. Old terminals still
treat the extended generation string as an opaque identity. New terminals need
an updated server to avoid the completion gap. Memory remains under the existing
per-stream byte bound, but completed fragments can remain until a matching
capture, operation result, or successor arrives.

## Validation

A scripted terminal regression reproduced the missing answer on the unchanged
client. The new tests cover a response taller than one viewport, exact versus
unrelated record retirement, late fragments, stale idle captures, and legacy
request identities. A gateway test checks that deltas and completion carry the
runtime request's reserved response ID.
