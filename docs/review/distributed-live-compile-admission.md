# Live Compile admission review

The original resource claim can now obtain one committed native launch permit.
The final resource transaction orders that association against cancellation,
while historical input and association APIs return data only. The
[architecture guide](../architecture/remote-compilation.md) describes the order
the native service must enforce.

## Independent findings

Astra found no actionable correctness or security defect in the frozen slice.
It found one documentation issue: five new API examples lacked the fenced,
module-qualified Gleam form required by the style guide. Those examples are
corrected. Root verified that production syntax, tests and all other reviewed
files remained byte-identical after the prose correction.

The review checked exact identity and endpoint binding, native readback outside
the writer transaction, final state revalidation, commit-before-permit, duplicate
refusal and unchanged historical behavior. Authority syntax permits negative
monotonic deadlines; freshness remains the original native continuation's duty.

## Verification and limits

Root independently ran the full executor gate: 218 tests passed, exit zero, in
98.895 seconds. Every reviewed source hash remained unchanged. The worker's
focused journal gate passed all 40 tests, preserving the earlier 28 and adding
12. Three mutations compiled and failed their intended assertions: permitting
association after a cancellation fence, comparing a historical key by address
alone, and comparing a live reference by address alone. Source was restored
before the final gates.

The controls use real resource and native SQLite journals, including a failed
deferred-constraint COMMIT. Cancellation orderings are exercised sequentially.
The lost-reply control discards a returned permit; it does not simulate network
loss or power failure. Native service integration and separate-host acceptance
remain outstanding.

Format, rendered documentation, package lint and SQL-generation parity passed.
SQL, schema and generated artifacts did not change. The documentation correction
passed format, rendering and lint without rerunning unchanged runtime tests.
The corrected journal source SHA-256 is
`7588315569ef29f40d3271f16357cc9e69e91c0be0bc698840c8e6c46688d499`.
