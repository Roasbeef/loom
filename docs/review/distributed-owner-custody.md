# Distributed owner custody review

This component follows the remote wire and physical-service interfaces for
issue #697. It makes the owner retain tool identity, exact final reports and
child receipts across callback loss and supervised restart. It does not yet
select a remote executor in daemon startup or establish product E2E behavior.

## Independent review and disposition

Astra reviewed immutable identity, atomic Fresh admission, runner custody,
exact collection, cancellation ordering and reservation limits. A retained
row whose byte reservation covered only its current contents could previously
accept a final result that subsequent validation rejected. The fix requires
the complete future terminal allowance before either final write. Regression
tests corrupt the reservation to that formerly accepted value and verify that
the outcome/terminal column remains SQL NULL.

The final owner review found no new functional defect. Its test-evidence
caveat identified a supervision test that only started an owner over retained
evidence. The test now kills the actual supervised actor, awaits a distinct
replacement PID, and uses the same opaque handle to verify the retained child
receipt and refusal to execute the admitted body again.

A separate review checked the runtime cancellation correction and the native
start-window checks. Runtime recovery now carries the durable abort state;
Pending cannot start another observer after cancellation. The strict native
dispatcher checks the unchanged cleared wall policy after helper checkout and
again when the helper consumes its queued Run. This does not claim hard
real-time scheduling after port delivery.

## Validation

| Gate | Result |
| --- | --- |
| Core package | 151 tests passed. |
| Storage package | 143 tests passed. |
| Runtime package | 187 tests passed. |
| Client owner binding | Nine real SQLite tests passed, including supervised restart. |
| Runtime counterexample | Both added abort regressions fail against the prior implementation. |
| Strict native start window | Three tests passed, including delayed checkout and queued Run. |
| Existing broker executor/helper | 25 executor and 59 helper tests passed. |
| Tool failure rendering | 17 tests passed. |

Commands were judged by their own exit status. These are component results,
not the final combined CI gate. Owner ingress still needs the production
bounded caller pool. Native receipt assembly must verify the original child,
request ID, scope and exact materialized command before acknowledging remote
custody. Session collection requires the exact persisted result; broker release
is never a receipt or proof that a mutation may be retried.
