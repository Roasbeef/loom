# Scoped executor lifetime runtime review

The shared TLS BEAM endpoint now fences an exact registration before orderly
scope shutdown. Its six canonical credit records retain the original row and
request correlation; a lost assigned credit remains uncertain. The native
service independently retains its original physical-close disposition across
later durable-confirmation failures. These are component changes in PR #819;
production host assembly and separate-host acceptance remain required.

## Endpoint review and correspondence

Astra reviewed the five frozen endpoint files from base `a309c79ff`. The
production endpoint SHA-256 was
`1c8f734554d55e02c11e95d2f42a69e7556baf447f0f92d5b739ed123e715f73`.
The review found no actionable defect. It rebuilt the component and SQLite NIF
from source against Git Weft `368d01abcaaff3ef986317a89fe8b98e1e4a2ad6`;
no compiled artifact or dependency override supplied the result.

The independent baseline and restored-source replay both passed six tests with
no skips. Five mutations compiled and failed at their intended assertions:
admission after a row fence, busy credit death treated as drain, a late release
erasing lost-work uncertainty, a same-row stale correlation releasing newer
work, and normal idle death leaving dead capacity available. The independent
probe first needed missing pinned Git cache metadata; that setup failure is
retained alongside the successful runs.

The controls use actual TLS owner/executor processes, separate native pools and
journals, suspended real service asks, and withheld output acknowledgements.
They exercise both service-answer-before-producer-join and the reverse ordering.
The scoped endpoint fixture launches no native helper effect. It establishes
transport custody, not physical retirement.

| Model transition | Runtime evidence |
| --- | --- |
| Reserve | The serialized admission turn assigns an original registration and correlation to one canonical credit. |
| Fence | Explicit acknowledgement or observed lifetime-owner DOWN permanently closes only that row. |
| Release | The exact assignment matches, its real service answer arrived, and its managed transport joined. |
| Credit loss | Normal idle DOWN removes capacity; assigned DOWN keeps the unresolved original assignment. |
| Drain snapshot | Only a fenced row without assigned or lost work is Drained. |

The existing P gate passed 126 cases/probes and 56 mutation controls before this
runtime change. That bounded model assumes truthful answer and join events;
the real-peer tests supply a concrete correspondence for the paths above. They
do not prove every OTP ordering or an assembled host's cleanup.

Root imported the five frozen files after checking both base and source hashes,
then migrated the five original executor-role constructor calls. The extra
historical-refusal fixture also uses its original executor-role PID. The combined
`make check-executor` exited zero: 306 tests passed with no skips in 104.23 seconds.
The package includes the original native and Compile controls and both new
lifecycle/refusal suites. Executor lint exited zero with zero errors and 30
warnings. The root client replay exited zero with 2,847 passing tests and 15 explicit
optional skips: one Linux `/proc` control, thirteen shipped-server controls and
one rust-analyzer control. Separate actual TLS native and workspace E2E runs
both exited zero; the native run includes executor-generation replacement and
owner SQLite restart. These run separate roles on one host.

## Native-close and historical-refusal review

A separate Sol reader rebuilt the native-close and historical-refusal changes
from source. Five focused controls and the actual TLS E2E passed. Six mutations
compiled and failed their intended assertions. The review found no actionable
defect. Its focused replay did not independently repeat all original native
controls; those remain covered by the root's combined executor gate above.

The service keeps NativeOpen, NativeRetired or NativeUncertain independently
of the durable close-confirmation result. A successful physical close therefore
survives a later journal error. Retrying confirms the original disposition and
does not invoke a replacement close operation. Definite historical Missing or
Conflict refusals become Invalid only after the metadata operation has drained;
a failed rollback remains uncertain. Neither change grants authority to repeat
an effect or to bind an old request to a replacement executor generation.

## Evidence boundaries

The endpoint monitors a supplied local lifetime owner before admitting its row.
Trusted construction still has to supply the actual owner; PID locality cannot
prove that relationship. A crash racing ahead of the applied fence can consume
credits permanently. No capacity is recreated to conceal that uncertainty.

Drained covers transport and admitted service asks. The enclosing host must
still quiesce and join whole services, prove native retirement and physical
cleanup, then release journals. Endpoint DOWN cannot replace any of these
witnesses. The native-close fix retains one actual physical disposition; a
native success plus failed durable confirmation is still an outward failure
until those original confirmations succeed. Service death does not reconstruct
the lost in-memory disposition.
