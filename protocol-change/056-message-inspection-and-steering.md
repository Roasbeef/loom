# protocol-change/056: inspect delivery and interleave steering

**Status**: User-authorized implementation, pending independent review.
**Affects**: code-mode capability vocabulary and orchestration checkpoint policy.

## Problem

An accepted local message is stored in an operation's steer queue. The old
post-tool checkpoint skipped that queue before each generation. A model
continually issuing tools could therefore postpone messages until an abort
removed their pending payloads. The sender's successful admission response
remained truthful, but the recipient had never seen the body.

Code mode could send and enumerate addressable strands, but could not inspect
its own pending messages. `peer.roster` lists authorized cross-session links,
not incoming local messages. Blackboard notes are another store entirely.

## Decision

A complete tool batch leaves the checkpoint inbox eligible. Existing queued
steering materializes after all source-ordered tool results, before the next
provider request. Providers and tools already in flight are never preempted.
Projection drains retain their one-shot skip, preserving one-at-a-time queue
modes across recovery. Abort and custody retain their existing semantics.

The default host exposes these read-only calls in both program modes through
`cap/peer`. The host binds the calling session and strand; no recipient argument
can substitute another caller. Each execution retains the existing 128-call
peer admission ceiling. Responses are JSON text, bounded to 194560 bytes;
oversized selected pages or records fail explicitly without truncating bodies.

`inbox(after, limit)` inspects current caller-owned steer, follow-up, cancelled
but not yet deleted inputs, and next-run queues. `after` is an exclusive ID
cursor, empty initially; `limit` is 1..12. The result has `revision`, `items`,
`total`, and `next`. Ownership lists and selected payloads are copied together
in the final read cut. A consumed item can shorten or empty a page; continue
through `next` even when `items` is empty. Pages are independent observations,
not a frozen multi-call queue snapshot. Newly arriving input can require a new
scan from the beginning. Inspection neither drains nor acknowledges input.

`inbox_get(id)` returns a pending input owned by the caller or a materialized
user input on the caller's captured conversation branch. A consume racing the
lookup falls through to that same cut's leaf. Another strand's IDs and absent
inputs return null. `history(before, limit)` pages materialized user inputs,
with an exclusive sequence cursor, zero initially, and a scan limit of 1..64.
Assistant and tool entries advance this cursor without becoming input rows;
therefore an empty page can still have `next`.

`received(after, limit)` pages existing cross-session admission receipts,
filtering every selected receipt to the exact caller target. Its cursor advances
through bounded global receipt pages, including pages containing only other
recipients. `received_get(source_session, source_strand, message_id)` returns
the existing receipt only when its recorded target is the caller. Receipts prove
admission and retain remote bodies after abort; they do not prove consumption,
provider inclusion, comprehension, or application acknowledgement.

`sent_receipt(session, message_id)` reads an existing receipt from a linked,
resident recipient. The harness supplies the authenticated source session and
strand. The directory identity is checked and an outgoing link is required.
The call sends no message, wakes no saved session, and grants no join authority.

## What was considered

A consuming receive API would compete with automatic steering and would need
acknowledgement and cancellation rules. A new mailbox would duplicate the
existing durable queues and remote receipts. Neither is needed for these
inspection calls. The retained remote admission record remains unchanged.

## Cost and limits

Local queued bodies still disappear on operation abort. Materialized local
inputs remain in the conversation tree, and remote admitted bodies remain in
existing receipts. This proposal adds no local post-abort retention, delivery
acknowledgement, consuming receive, queue, transport, dependency, or database
schema. Supporting register page reads remain internal and do not alter the
frozen Storage behavior or data-plane frame format. Generated capability
signatures and the default host router must land together; a library-only
method would not provide a usable capability.

Receipt cursors order hashed register keys, rather than arrival times. Pollers
start a fresh traversal and reconcile message identities to discover admissions
whose keys sort before a previous cursor. No incremental arrival watermark is
introduced by this proposal.
