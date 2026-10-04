# Admission proof and production bridge review

The Lean model covers one admitted request's phase, gate, request-digest
comparison and event. It proves at most one launch over arbitrary finite
traces, preservation of refusal provenance, and the evidence required for
compaction. The differential bridge enumerates the 684 representative cases
against the actual Gleam admission functions.

The independent review found no actionable issue. It checked that the same
Lean step function supplies both the proofs and the computed comparison output,
and that the Gleam fixture constructs states through production APIs rather
than injecting a replacement reducer. Exhaustive projections cover the public
phase, event, custody, receipt, effect and error vocabularies.

The root checked the completed files in an isolated checkout of the journal
commit. All twelve theorem audits passed, with only the reported foundational
propext and Quot.sound axioms. All 684 computed cases matched; the runner
returned zero. The labelled model-output mutation returned one for exactly the
intended reauthorization mismatch. It modifies comparator output, not production
source, and is not presented as a production mutation experiment.

An earlier shared-tree run completed the Lean checks but failed to compile an
unfinished workspace-contract module from a concurrent worker. The isolated
run excludes that unrelated work; it is the acceptance evidence for this slice.

The proof concerns its abstract transition function. Representative digest
comparisons do not prove equivalence for arbitrary 256-bit values. Scope
validation, multi-key interactions, SQLite durability, TLS, native cleanup and
the full distributed runtime remain outside the proof. The model README names
those limits and supplies the reproducible local runner. The root model-check
target does not currently discover Lean; this runner must be invoked explicitly.
