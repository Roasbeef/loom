# Submit held input together after abort

Status: accepted for the requested Escape behavior, subject to the independent
review and regression gates below. This changes the held-input behavior of
`abort` without adding a command or changing its wire shape.

## Problem

An explicit Escape currently cancels the live operation, then starts only the
first held prompt. Remaining prompts wait through further model runs, so the
user's queued instructions do not all reach the immediate replacement request.

## Decision

When an authenticated `abort` addresses a live operation, mark that strand's
existing held queue to drain as one batch after the operation retires. Preserve
every held `UserMessage` as a separate message, including its full content,
images, and recorded author. Preserve the existing queue order:
steers first, then ordinary turns, FIFO within each priority.

The queue owns its drain mode. An empty queue has no pending batch intent;
new input submitted after an empty-queue abort retains ordinary behavior.
Input joining an existing marked queue before admission joins its batch.
Reads and compare-and-replace edits retain their existing IDs and revisions
until the whole batch is admitted. Admission removes all batch members
atomically; a busy refusal retains them. Another admission error is reported
to each affected submitter and retires the refused batch, as the existing
single-prompt drain retires a refused item.

Natural completion and steer-triggered cancellation keep their current drain
policy. Abort still addresses the captured operation and sweeps its live
effects. The queued batch cannot start before that operation retires. Queue
limits, admission authority, transient lifetime, and background-job ownership
remain unchanged.

## Cost and rejected alternatives

One domain-specific mode lives alongside the held items; an empty queue cannot
retain an orphaned flush flag. The runtime already accepts a list of messages,
so there is no new execution path or message concatenation. Concatenating text
would discard message boundaries and complicate image and author preservation.
Changing every natural drain to batching would expand the requested behavior.

## Acceptance

A parked provider must receive every queued message after abort and before the
replacement provider is released. Long multiline content must remain complete;
ordinary completion must retain its existing ordering, and queue editing must
continue to preserve authorship and images. Use isolated fixture sessions only.
The baseline regression failed because only the first held message committed.
With the fix, all 87 gateway tests and all 1,546 client tests passed. The
independent review found no actionable issues: the existing writer transaction
admits separate messages atomically, busy admission retains the batch, and
queue edits preserve the drain mode. Client lint and documentation gates passed.
