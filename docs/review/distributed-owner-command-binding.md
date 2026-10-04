# Owner command binding review

The owner binding connects one existing Broker/dispatcher to exact retained
Compile service inputs and command offers. The [custody guide](../architecture/remote-custody.md)
explains the callback order and the distinction between fresh reservation,
historical receipt and cancellation.

## Reviewed boundary

The independent Astra high pass reviewed nine frozen files against `7632e6e58`,
including the two new untracked client files. Manifest
`9d531b2853e713f959cbc6e9ac2ede83a3a9849f6f38adda53ec18d9e550489f`
and every owned source hash matched before and after. No actionable defect or
justified simplification was found. The reviewer read source and evidence without
running builds or tests.

The trace verified complete offer/input/enrollment identity before preparation,
unchanged actual Prepared, the returned original UUID, effective policy bounds
and exact receipt association. Missing command custody and unsupported Satellite
roles cannot select the generic native path. Receipt and cancellation use
historical data without minting, preparation, clearance or a new sendable request.

## Tests and mutations

Root independently reran the twelve focused client controls: exit zero in
1.407 seconds, with no skips or hidden peer failures. The full storage gate
exited zero with 177 tests in 21.811 seconds. All nine frozen file hashes remained
unchanged. The worker's full client gate reported 2767 passing tests with actual
exit zero in 260.023 seconds; its 47 optional skip lines are a separate limitation,
not executed coverage.

Root also ran the integrated full client gate: exit zero with 2767 reported
passes in 315.041 seconds. Its prepared test environment reduced the optional
skip census to 15; that does not turn the remaining skipped lanes into coverage.
The integrated documentation gate exited zero, and all nine owned source hashes
remained unchanged.

The broad client log also exposed two unrelated test-witness problems. The held
advisor check receives a subject owned by another process and crashes while its
test reports success. A schedule-reaping worker can call a writer after shutdown.
Those observations prevent treating the broad exit code as proof that every peer
completed correctly. They are outside this binding's nine-file diff. The new
focused controls contain neither failure.

Four final mutants compiled and failed their intended controls: replacing the
returned original UUID, permitting broader cleared policy, using generic command
fallback and skipping the pre-preparation physical-step guard. The step mutation
initially survived because a later Prepared check still refused it. The corrected
witness observes that refusal happens before preparation or minting; it then
fails the intended assertion. The initial survivor remains in the evidence.

## Assembly obligations

The actual Broker fixtures establish shared original clearance/custody and
outstanding-cap enforcement. They use empty grants and a finite base wall. They
do not independently prove nonempty-grant behavior, zero-wall pre-clear handling,
native ceiling-order acceptance, live routed receipt exchange or separate-host
execution. Root assembly must verify those concrete paths before product
acceptance. No second Broker, new grant source or renewed deadline is permitted.
