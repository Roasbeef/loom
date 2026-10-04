# Physical compile stages review

The local compiler now calls the same workspace preparation, seed preparation
and finalization functions that the remote physical service will use. The
preparation config contains seed and dependency facts, with no unused runner,
grant or phase identity. Source preparation still precedes seed verification
and cloning; admitted generated modules are installed after the clone.

Finalization checks cancellation, timeout, signal and exit code before touching
products. A cancelled command can report exit code zero, so exit code alone was
an insufficient success condition. Every result retains the original enforcement
report. The positive and negative controls use a genuine compiler-produced BEAM
entry and the real flattening/fingerprint path.

The compiling cancellation-guard mutation returned actual BuildProducts and
failed the intended cancellation assertion. The original source was restored
exactly. An earlier mutant failed compilation and is explicitly excluded from
this evidence. Root independently ran the seeded code-mode gate: exit zero,
381 tests, no reported skips, 49.863 seconds. All seven frozen source files
matched before and after. The worker's separate full gate and format, lint and
documentation checks also passed.

The independent review found no actionable defect. It checked local ordering,
report preservation, adjacent settlement paths and the new test-only entry.
The fixture has no production import and is excluded from seed vendoring.

The private seed initially had four stale transitive core source files. The
worker refreshed only its own fixture, retained the pinned resolved lock and
verified current cap/core/ext source parity before the accepted gate. Integration
has independently refreshed those same four files in its private seed.

These internal functions do not establish a remote service or admission proof.
The physical caller still owes the original preparation claim, actual native
association, original authority/deadline and remote artifact custody. Separate-host
acceptance and final Linux signoff remain outstanding.
