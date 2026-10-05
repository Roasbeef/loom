# Complete saved-report reader review

`cap/report.load_result` reconstructs a complete retained program result through
fixed owner-served chunks. Its public types preserve the program value, manifest,
enforcement observations and original bounded call log without requiring an
import of the harness's internal modules.

## Contract and independent review

The helper validates the canonical reference before dispatch. It accepts only
an exact three-field response containing the original reference, expected offset
and expected byte count. Each iteration consumes a fixed slice of at most
65,536 bytes; the maximum bundle requires 261 calls. Short chunks fail immediately.
The helper concatenates the bounded list once and validates the complete canonical
bundle before returning a typed value.

Astra found no actionable findings in the frozen source. An independent source-only
build passed all seven original tests and four supplemental controls. Those
controls verified the 261-call maximum, refusal before dispatch for an oversized
reference, malformed chunk rejection and preservation of degraded enforcement.
Three compiled mutations removed reference, offset and exact-length guards;
each failed its intended assertion. The restored source passed all eleven controls.
The reviewed module SHA-256 is
`311618ea92d3b03ef506133ab8c2b6d04b8c71665d9b4f5fc5196f075608211e`;
the test SHA-256 is
`f69eb8b5492b18674b844349282ac2a8978d0f78da2c94099f33a836965f53fa`.

Root's full cap gate exited zero with 182 tests and no skips. The cap lint
reported zero errors and 87 warnings. After regenerating the capability prelude,
the tools gate passed all 700 tests with no skips under native-helper permissions.
The earlier sandboxed tools attempt failed two native-helper controls; it is not
counted as a passing gate.

## Integration obligations

These tests use a channel fixture. They do not establish authenticated owner
routing, SQLite retention or a complete satellite read. The owner must verify
session, reserved result entry, digest and length before returning any slice.
The helper relies on that trusted owner for digest agreement; a syntactically
valid reference alone grants no authority.

The per-program limit of 261 admissions across all references, encoded-response
budget and original invocation deadline belong to the owner/router. The helper's
per-read bound does not substitute for those checks. Production availability and
prompt guidance remain pending that wiring. See the
[retention design](../design-notes/distributed-final-results.md) for the complete
contract and [codec review](distributed-report-codec.md) for decoding limits.
