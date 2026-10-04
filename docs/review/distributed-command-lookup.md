# Indexed historical command lookup

The owner custodian can resolve a managed native origin to its exact retained
command offer. The read uses the existing unique index, validates complete parent
and service identity, and preserves cancellation history without granting live
reservation. The [custody guide](../architecture/remote-custody.md) explains the
ownership boundary.

## Independent review and correction

Astra reviewed the frozen eleven-file candidate and found one actionable issue.
The indexed header returned `reserved_bytes` without checking its SQLite type.
A corrupted one-MiB BLOB passes the non-strict nonnegative constraint and counts
as zero in the aggregate budget. The integer decoder would reject it only after
the database transferred the body. Review found no peer-input writer for this
state; the defect concerns the promised persisted-data boundary.

Root independently reproduced that SQLite behavior. Both the new indexed query
and the existing address query now project invalid types as integer `-1`.
The generated bindings were regenerated from named SQL. A regression checks the
real generated headers and independent raw-cell projections before exercising
both public refusal paths. Removing the guard from the copied indexed query
compiles and fails the intended assertion with a one-MiB BLOB instead of `-1`.
The exact test source was restored before the corrected gates.

Review found no other actionable identity, simplification or literate-code issue.
An earlier compiling mutation that removes full retained-service comparison
also fails its intended identity control. Neither mutation is part of the tree.

## Verification boundary

Root independently ran the corrected full storage gate: 176 tests passed in
22.822 seconds. The focused client custodian gate passed six tests in 1.499
seconds. Both processes exited zero and all reviewed source hashes remained
unchanged. Worker checks also passed format, package lint, documentation mirrors
and reproducible SQL generation. No prerequisite test was skipped.

The corrected eleven-file source digest is
`fbecb87e227aa56af4542781c2e091d47c152186d4d734c94f874a0d55447d0c`.
These checks establish historical lookup behavior. Production command routing,
live service admission and separate-host product acceptance remain separate work.
