# Real jailed retained-report review

Three genuine compiled code-mode invocations now exercise the retained-report
path. The first writes a 155,503-byte canonical report, including a 154,000-byte
string and distinct integer and floating-point values. Its complete result is
stored in three SQLite chunks before the bounded preview and reference return.
The second invocation has a distinct original identity and loads that reference
through `cap/report.load_result`. It checks the complete value, original compiler
fingerprint and call metadata.

The same reader attempts to read the owner's database and marker through the
real nested process capability. Both reads are refused with no output. This
checks the nested process jail's installed protection policy. It is not a claim
that every possible API is isolated or that a remote owner is already assembled.
No compiler outcome or pipeline result is injected into these controls.

## Exact cumulative limit

The third invocation reads 258 chunks from the first report and three chunks
from the second. Its next one-chunk read is denied. The test explicitly checks
that the final reference fits within one chunk, so denial proves the boundary
at chunk 262. Both references consume the same invocation-wide allowance.

Independent review caught a defect in the first version of this assertion. That
version attempted a three-chunk read at the end, which could fail after admitting
an extra chunk and still satisfy the expected error. A production mutation from
261 to 262 allowed chunks passed that original test. The corrected one-chunk
probe fails against the same compiling mutation. The production limit itself
was already correct.

## Executed evidence

The worker reproduced the original manifest mismatch with a real jailed run,
then passed after restoring the production fingerprint correction. Removing
the installed report route or the owner-file protection also produced intended
failing witnesses. Independent review verified those recorded artifacts and
separately replayed the corrected three-invocation test and limit mutation.

Root replayed the corrected test against the combined terminal preflight, owner
Launch binding and retained-report integration sources. The build and test each
exited 0 with zero skips. The corrected test source digest is
`be793a345cdedb3ce670c8fbae4ac43f6c86d5057556cb8e765f055b9bb10bd4`;
the independent review report digest is
`7625cf1e97a9b315ed1b87920630645c21eb21336bcc0cd6236e78a27af395bd`.

This proves a real local producer, owner retention and fresh jailed capability
reader. It does not enable the default registered remote host, whole remote
Launch, report-companion archive/restore/compaction, or separate-host acceptance.
Those remain required integration work.
