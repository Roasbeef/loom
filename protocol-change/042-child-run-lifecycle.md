# 042: Lifecycle metadata for resumed child runs

Status: accepted for implementation. The operator selected a ten-minute default
and explicit budgets for resumed runs.

## Problem

A child strand can receive more work after its spawn operation finishes.
The Agency used the immutable spawn handle for its roster, deadline and parent
cleanup. Resuming a stopped reviewer therefore left the roster on the old
aborted result and gave the new run no fresh budget or current parent owner.

## Decision

Lineage continues to identify the conversation, its parent and its original
spawn call. Each accepted child run has a reserved `child-run/{operation}` fact
with `strand`, nullable `owner`, nullable absolute session-clock `deadline`,
and `stop`. Stop values are `none`, `budget_expired`, `parent_finished` and
`legacy_reaped`. Missing or malformed fields are corruption. Model-facing
fact writes and listings cannot access this namespace.

Continued admission writes the lifecycle fact in the same transaction as the
operation. The transaction checks the observed lineage and parent strand and
operation state. An explicit sending parent must still own its current run.
A parent at `Checkpoint(MayFinish)` cannot accept new cleanup custody: its
run-end hook may already have scanned the children before the final commit.
Direct operator admission at that boundary gets no parent owner. Detached
children also have no owner, but still receive their own deadline.

`agent_send` accepts optional positive `within_ms` for an idle child. Supplying
a budget for an active child is refused; omitting it retains steer behavior.
A newly accepted run uses the stored default budget when no override is given.
Production defaults remain 600,000 milliseconds. Host configurations may keep
an explicit unbounded default. This adds one optional argument to `Agency.send`
and a runtime `send_to_child` entry point; the capability wire keeps its existing
send shape and uses the default when it starts a new run.

Spawn and started-send receipts expose nullable `deadline_ms`. A started-send
receipt includes a directly waitable `handle` as well as its existing operation
ID. Roster selects the current operation, or the latest completed operation
when idle. Old handles continue to select their original results. Ready wait
results and roster outcomes keep wire outcome `aborted` and add nullable
`abort_reason`: `budget_expired` or `parent_finished` when recorded, otherwise
null. Internal outcome variants preserve that distinction; existing capability
consumers still receive their established aborted outcome.

Reaping records its cause before aborting that exact operation. Later
observations repeat a recorded cancellation if necessary. A delayed cleanup
for an old owner cannot cancel a successor, and a later run cannot overwrite
an older handle's cause. Original spawn reconciliation seeds its run fact
before publishing lineage and reuses that fact after an interrupted publish.

## Compatibility and cost

Existing lineage payloads without `defaultWithinMs` decode to ten minutes;
explicit null remains unbounded. Original runs without a lifecycle fact use
their legacy deadline, owner and reaped marker. Older continued runs that have
no record remain observable without inventing a historical budget or cause.
A corrupt lineage record continues to refuse agent addressing, while direct
host prompts retain their existing recovery behavior. Those prompts cannot
synthesize trusted lifecycle metadata from the corrupt record; the admission
checks its observed sequence and leaves it intact. Storage read errors still
refuse admission.
There is one small retained fact per accepted child run and extra reads and
CAS expectations at admission. No additional timer or process is introduced.

The existing observation-driven enforcement remains: agent activity and waits
observe deadlines. A deadline is not a promise of cancellation at that exact
millisecond in an otherwise unobserved session. Schedule and held-rule lifetime
policies remain separate. New cancellation facts leave rule holds retryable,
and schedule cancellation is observed at terminal settlement rather than the
legacy stop-intent mark. Original-brief and legacy-reaped assumptions are
recorded as follow-up findings in the review note.

## Validation

Regressions cover continued roster handles, historical results, fresh default
and explicit budgets, explicit budget expiry, parent ownership and detachment,
refused late admission, direct operator admission, legacy decoding, reserved
fact protection, and the new tool metadata. A parked real run-end hook makes
the parent-finalization race deterministic.
