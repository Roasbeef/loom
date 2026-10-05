# Complete-report storage and owner custody review

Owner SQLite format 5 retains a checked complete program report before accepting
its bounded final reference. The profile and full future allowance are immutable
pre-effect admission data. Ordinary tools keep their previous allowance; a code-mode
report reservation accounts for the complete bundle, final and bookkeeping before
its runner starts.

## Ordering and recovery

Scalar version, identity, length and quota validation precede BLOB access.
Startup verifies WAL and synchronous FULL, then validates one canonical report
and its actual host SHA-256 digest at a time. A report COMMIT precedes the final
COMMIT. Report-only history remains AwaitingFinal and cannot authorize rerunning
the program. Original runner handles pin one custodian incarnation, so recovery
cannot commit an old renderer's report through a replacement owner.

Named SQL reads return aligned slices of at most 65,536 bytes after exact session,
result-entry, digest, length and profile checks. The ordinary tool-row projection
excludes report bytes. Collection requires the existing exact session readback
and live/physical custody proofs, and preserves the report and its actual charge.
Format 4 is refused unchanged before accessing new columns.

A model-to-runtime mismatch was corrected before integration: a report-profile
generic ToolFailed could previously discharge an otherwise unfenced run. It now
retains the bounded diagnostic with sticky Unresolved, including after restart.
Only an actual trusted vet/compile producer can supply the closed report-free
refusal; validation of its schema alone does not establish that provenance.

## Verification

The final twelve-file worker freeze has SHA-256
`5d663099e32303c828055ec371b595a0ff032d8875664875fc1303a40ae3d4dc`.
Root verified both original baseline hashes and frozen source hashes before
import. The earlier provisional freeze was superseded by the generic-failure
correction and was not imported.

The worker passed 202 storage tests, fourteen original owner tests, seven matched
command/TLS controls and eight report-custody controls. Seven compiled mutations
failed their intended assertions. SQL generation/parity, format and owned-source
lint passed. No original test was removed; three corruption assertions now
observe refusal earlier, during startup validation.

Astra found no actionable defect in the corrected component. Its independent
source-only build passed all 202 storage tests, eight report-custody tests and
fourteen original owner tests. Four independently compiled mutations removed
pre-effect allowance, prior-reference equality, reopen hash checking or sticky
generic-failure custody; each failed its intended witness. Restored-source
replays passed and all twelve hashes remained exact.

Root's complete integration checkout passed the storage gate with all 202 tests
and the client gate with all 2,855 tests. The client log contains fifteen explicit
optional SKIP notices: one Linux `/proc` control, thirteen shipped-server controls
and one rust-analyzer control. Those prerequisites remain outside this result.
The private worker's earlier full-client attempt remains a failed run; the root
complete-tree result is a separate command with its own zero exit. Its LSP
fact-bound control passed in the complete checkout.

## Limits

The concrete tests cover SQLite failure, report-only recovery after an actual
original-owner crash, unchanged original identity, exact final association and
bounded readback. WAL/FULL readback and ordinary reopen are not a power-loss
campaign. Logical byte accounting is not a resident-memory ceiling.

The trusted renderer, authenticated router, per-invocation retrieval ceiling,
companion lifecycle and real satellite/remote Launch acceptance are separate
integration obligations. Component correctness does not establish the complete
distributed runtime. The [architecture](../architecture/remote-custody.md) and
[report design](../design-notes/distributed-final-results.md) describe those
boundaries.
