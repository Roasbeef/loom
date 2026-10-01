# Terminal state review

Baseline: 868dfedd8754e1b8a750add24227bd2b83fcd167. Scope: #399 and #524.

An idle captured strand with held input is halted under protocol 033.
The composer and queue derive that state after local interrupt retirement
and on another attachment. A currently submitting or running strand takes
precedence, and Enter still submits an ordinary prompt.

Protocol 056 adds a data-free goal_changed invalidation after a successful
reserved goal write or deletion. The gateway uses subscribed delivery and
binding revalidation. The shared lane retains one owed read, honors the
outstanding and queued command order, and preserves another read when a
notification arrives during an older read. The terminal adopts the returned
board. The web component drives the same lane; the operator page renders its goal
observation through the shared step.

## Independent review disposition

The adversarial pass reproduced an older background goal reply confirming a
queued pause before the mutation committed. The confirmation was armed at
admission, and quiet board adoption consumed it before the lane's Sent update.

ConfirmGoal now has no request owner while queued; Sent binds it to the actual
mutation ID. Older background and explicit reads update the observation without
settling that report. Their refusals preserve the queued report. Only the
mutation's own success or refusal settles it. The correction review found no
remaining finding and independently passed all 48 goal tests.

The added sequences cover older background and explicit reads, all five goal
mutations, successful and refused mutation replies, and an older-read refusal.
The pre-fix regression failed because an Active board printed the pause
confirmation. The restored correction passes.

## Validation boundary

Before the confirmation correction, every Gleam package suite passed,
including client 2286, TUI 947, session_view 47, web_view 42 and events 47.
After correction, the focused goal suite passed 48 tests. Formatting,
house-rule lint, documentation checks and package mirrors passed; existing
warnings remain.

Three mutation witnesses removed halted-state derivation, post-write
publication and in-flight read debt. Each failed at the intended assertion,
and source restoration was verified. A controlled reviewer holds completion
until the primary is idle and an Active board has been read; a later
notification then produces Complete without a primary wake. Another production
gateway fixture verifies two authorized subscribers receive goal changes.
These are production dispatch with in-process sinks, not two live terminals.

Full make check exited 2 at the unchanged Darwin sandbox test
TestSeatbeltJailedPathFindsHomebrewTools: jailed command -v rg returned exit 1.
The sandbox package gate repeated the failure while an isolated invocation
passed. That difference remains unresolved. This is not a green full gate.
Hosted CI and exact-head Linux/shipped-server signoff are separate PR gates.
Lost notifications retain the documented best-effort boundary; no periodic
goal read is added. The global wave handoff belongs to the docs-cleanup PR.

## September 30 integration

The branch is rebased onto `7b1c662cfd4e9f6fe8d4b63dc8a40e5a54e3a55d`.
Main moved session decisions into `session_view` and split the terminal model
into `Shared` and `View`. Held-queue derivation and confirmation ownership use
that shared owner. All 48 goal regressions, 23 queue regressions and six
production goal tests pass after adapting their fixtures.

The web invalidation fixture settles the four initial capture-triggered reads
before notifying, then answers the newly issued request. Its idle-lane
assertion prevents an existing read from falsely proving notification handling.
The focused web witness passes. Removing held-state derivation fails only the
held-queue test among 23; admitting confirmation before request issuance fails
the older-read witness; removing invalidation debt fails the late-write witness.
Every mutation restores the original source before further validation.

The full affected-package gate, independent final review, fresh hosted CI and
exact-head Linux signoff remain separate from this focused evidence.
