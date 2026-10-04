# Semantic filesystem consumer review

The candidate adds service-backed native filesystem tools and shares the local
tool's argument validation and result rendering. Owner assembly remains a later
slice: a callback alone does not establish shipped remote workspace behavior.

A fresh Astra source review found no actionable findings. It traced virtual
scheme dispatch, RelativePath validation before the callback, unchanged caller
context, closed requests, Never replay metadata, response-kind validation and
uncertain-effect wording. The review independently confirmed byte-exact source
restoration after the worker's fallback mutation.

The focused suite has 13 tests; the existing filesystem suite has 99. Both
passed, as did the production warning-as-errors build, format and tools lint.
The mutation replaced semantic read dispatch with local file resolution. It
compiled, then the no-fallback test failed on an owner `read_link` panic. The
candidate was restored and the focused suite passed again.

The fabricated oversized anchored-read case tests consumer rejection. The real
workspace-local producer can reject capacity earlier, so that test does not
establish identical overflow wording across the complete production path.
Neither component tests nor this source review prove separate-host operation.

Root independently ran the full tools gate: all 663 tests passed. Its first
run inside the outer sandbox failed two real-helper integration cases; the
explicitly authorized unsandboxed run passed without source changes. Tools
lint passed with zero errors and 110 advisory warnings.
