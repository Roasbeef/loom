# Physical compiler and LSP extraction review

Astra independently reviewed the whole-compiler and physical-runner extraction.
There were no actionable findings. Vetting and generated-import narrowing
precede the physical service. Phase identity, grants and pooled budgets retain
their existing authority. Local launch refuses executor artifact references
before physical resource creation. Late-clearance cancellation and original
enforcement reports remain intact.

That resource guarantee is specific to the local launcher. The owner satellite
can call its configured token writer before launch, so a later remote assembly
must replace all physical resource callbacks together. The extraction does not
claim remote execution or a second authority on the executor.

The coordinator independently reran all five compiler-service regressions and
all 25 launcher tests in an isolated checkout. The implementation worker also
ran the complete real code-mode E2E suite, client code-mode tests, extension
lifecycle/build-mask tests and the jailed monorepo LSP conformance fixture.
The known Darwin enforcement limitations remain visible in their reports.

The separate whole-LSP extraction moves document and dependency work with the
server. Its focused regression exposed an existing protected-file outline
read: ownership resolution alone did not apply protected-path admission. The
shared manager now applies the existing admission check before content reads;
a mutation removing that check fails the regression. Astra independently reviewed all eight moves against their pre-extraction
implementations and found no functional or security issue. The one stale
client-only rename comment was corrected to describe physical-host composition.

The coordinator independently passed the three shared physical-host tests in
an isolated checkout that also contained the separately tested finite output
quota. The worker passed all 347 code-mode tests and all six real Gleam/gopls
conformance cases. Its 130-test client LSP run includes a returning Rust analyzer
prerequisite skip: Rust integration remains unverified. These results do not
claim cross-host behavior or hosted signoff for this commit. The quota change
is a following slice and was excluded from the extraction review.
