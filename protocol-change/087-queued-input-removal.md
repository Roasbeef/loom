# protocol-change/087: Withdraw held client input

Status: ACCEPTED 2026-10-13. Extends Part 1.3's session protocol v2 and
protocol-change/024's queued-input editor. The operator requested both inline
editing and removal, including the protocol extension.

## Problem

A held prompt can be edited but cannot be withdrawn. Stopping the operation
halts the entire queue and keeps every prompt; replacing text with an empty
string would still submit its image blocks and create an unwanted turn.

## Decision

Add `remove_queued_input` with `strand`, opaque `id`, and nonnegative
`expected_revision`. The gateway applies the same live mutable-author check as
`edit_queued_input`. Session-owner authority gives no override over another
principal's message. A missing identity or stale revision returns `conflict`.
The gateway removes only that item in one actor turn and returns
`mutation_outcome` with `status: "removed"`. This acknowledges withdrawal from
the memory-only held queue; it commits no conversation record. The ordinary
`input_queue_changed` push invalidates every peer's capture.

Withdrawal preserves the remaining items' identities, revisions, priority,
content and order, and the strand's current drain intent. Removing its last
item retires the queue and its halt, as an ordinary drain already does. If
runtime admission wins first, removal conflicts. It never aborts admitted work
and never returns the withdrawn draft to the composer. Repeated requests are
independent conditional withdrawals, so only the first can succeed.

The web page offers Edit and Remove only on rows explicitly marked editable.
Edit fetches the existing complete document before mounting a multiline editor;
Save uses the existing replacement command and preserves image blocks and the
queue position. Browser submissions contain one bounded text field. The
browser owns unsaved keystrokes, and a refused or uncertain save retains the
editor. An uncertain save requires cancellation and a fresh read before retry.
Observers gain no handler. The page uses the existing operator click/submit
socket admission and the gateway rechecks authority on every command.

## Alternatives and cost

Reusing abort would affect unrelated input and the running operation. Editing
to empty text would not withdraw attachments or the turn. A new conditional
command adds one gateway transition, one command variant, and one mutation
outcome spelling to the total decoders. Older daemons refuse the new command;
the page makes no optimistic deletion and retains the queue row on refusal.

## Acceptance

Protocol tests round-trip the command and reject missing or negative revisions.
Gateway tests cover author and observer refusal, stale revisions, wrong strands,
duplicate-text identities, repeated removal, remaining FIFO drain, and removal
after runtime admission. Web tests cover the complete read, exact replacement
and withdrawal frames, malformed form refusal, read-only rows, and retained
drafts after refusal or uncertain delivery.
