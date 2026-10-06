# Whole Launch owner and finite controls

The executor retains the original Launch Claim before creating its token or
listener. It verifies the token commitment and the retained Compile producer,
including the physical artifact fingerprint, before admission. The live owner
keeps that Claim, the original absolute deadline and the one local channel.
Historical queries recover coordinates and completion evidence without creating
another Claim or channel.

The channel transfers paused socket ownership only after both managed I/O tasks
have been adopted. The capability reader alone publishes frames and End; native
terminal observation cannot publish a competing End. Final consumption stops
the reader, while cleanup separately requires the original preparation task and
transport tasks to join.

## Cleanup evidence

The atomic before-native refusal closes the original admission while proving
that no native association exists. A successful cancellation fence followed by
exact Unassociated readback also excludes future native dispatch: associations
are immutable, and creating one is required to obtain a live native permit.
A missing fence or readback leaves custody unresolved. Neither path fabricates
a historical refusal when only cancellation was observed.

Directory removal and the resource-release COMMIT require this exclusion plus
actual preparation and transport joins. Associated native completion supplies
terminal evidence but no per-execution retirement witness. Such Launches retain
their active entries and resources until an approved retirement path supplies
that witness. This remains a product acceptance blocker.

## Independent review and corrections

The independent source review found two reachable lifecycle gaps. Successful
historical placement completed without a Claim or channel, but retained a live
slot forever after its managed task drained. The corrected Admitting branch
releases that entry only on actual AllDelivered. Its regression first releases
an original before-native refusal, replays that retained history, and then
admits a distinct parent and run phase with a one-entry active limit.

Partial preparation failure could enter Refused after acquiring a directory
and token. That phase armed the original deadline but ignored both its firing
and parent death. Both events now enter the existing close path. Real partial
allocation controls exercise each event and retain unresolved resource custody
when no cleanup witness exists. No new timer, retry or fallback is added.

The historical regression also waits for the exact original refusal operation
to lose its live Claim before replay. Directory absence alone precedes the
resource COMMIT and actor notification, so it could exercise the existing-active
metadata branch instead of the intended fresh historical task.

A real blocked-write transport control exposed a third lifecycle race. An
original Connection.close stores its reply door, then invokes cancellation.
The service's resulting fire-and-forget Stop(None) arrived during Closing and
erased that door. The handler now preserves the existing reply when Stop carries
none. A deterministic real-socket control holds Closing through the original preparation
join, witnesses both stop messages, and requires the caller to receive the
actual published close result. The clobber mutation fails that equality while
the ordering witnesses pass.

The finite-control review found no actionable defect in its pinned slice. It
checked exact registration attachment, producer matching, role-specific command
routing and the original answer-plus-AllDelivered credit rule. The
[finite-control record](launch-beam-finite-controls.md) describes the route and
its tested limits. Endpoint Drained remains evidence about finite requests;
it does not establish live-stream drain or resource retirement.

## Validation boundary

The integrated source commits are `fb1a5e5c` (whole owner) and `892baf87`
(finite controls). A separate verification worktree assembled their exact frozen
source bytes, including the review corrections, before import. Its final
executor gate passed all 357 tests with exit 0; executor lint and documentation
checks also exited 0. No executor skip was printed. The source import checked
every snapshot hash and every overwritten predecessor.

The owner worker's final gate passed 352 tests. Nine distinct compiling owner
mutations were caught, including the strengthened historical-capacity control
and the close-reply clobber. The finite-control worker's six compiling mutations
were caught. Those mutation runs belong to the workers. The independent reviewers
inspected the original receipts; the root checked the subsequent regression
evidence and replayed the assembled executor gate. These are different forms of evidence, with no claim that the reviewers
reran the mutations.

The gates cover these assembled components. Live duplex binding, associated
native retirement, registered daemon assembly, separate physical hosts and the
full distributed-runtime acceptance criteria remain separate obligations.
