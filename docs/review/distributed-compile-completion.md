# Compile completion review

A compile result now retains the complete original service identity, its native
command association and the exact native terminal response. The closed codec
distinguishes failure before native submission, failure after submission and a
successful executor-owned artifact. Success derives the artifact from the
original Compile identity and verified build products; cancellation, timeout,
signal or a nonzero exit cannot produce that artifact.

The enforcement report comes from the native response. A failure before native
submission carries an unreported result. Canonical decoding preserves the exact
error variant and rejects changed identity, evidence, unknown fields and oversized
nested values. The complete body is bounded to 256 KiB; its surrounding transport
still needs bounded chunking because an envelope adds bytes.

Independent review found no actionable implementation defect or evidence gap.
It checked identity pinning, artifact derivation, canonical decoding, cancellation
and report preservation. All six candidate files matched the recorded hashes
before and after review. The directed cancellation mutation compiled, returned an
actual artifact for the forbidden result and failed the intended assertion. The
original source was restored exactly.

Root independently ran the component executor gate: exit zero, 175 tests,
no reported skips, 100.527 seconds. Integration then passed 395 code-mode tests
and 191 executor tests without reported skips, in 51.258 and 97.084 seconds.
The documentation gate also passed. The earlier restricted run failed and is
excluded from this acceptance evidence.

The codec proves the shape and consistency of retained data. Production assembly
must still read the authenticated native journal, match the admitted Prepared
step, verify physical build products and commit the result before advertising it.
The resource journal will own this durable completion, with the original owner's
receipt separate from cleanup and native retirement. These obligations and
separate-host acceptance remain unfinished.
