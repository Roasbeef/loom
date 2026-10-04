# Workspace semantic codec review

The codec transports immutable semantic requests and complete typed results.
It does not authorize an effect, journal a result or enable the remote daemon.
Invocation and completion ceilings are nine and thirty-two MiB; the allocation
scanner admits at most depth 32, 8,192 elements per container and 65,536 nodes.
The decoder requires canonical bytes and the retained request projection.

## Review and corrections

An independent Astra review found three reachable producer mismatches. Native
anchored reads can return more than 2,000 short lines within their rendered byte
budget; only the separate structured line reader has that 2,000-line limit.
Hashline can report overlap coordinate zero, repeated stale references and
more than 4,096 fresh touched lines. Directory observations can contain Unix
filenames such as `a:b`, even though those names cannot become request paths.

The validators now preserve those producer contracts under the existing shared
allocation bounds. Ordered stale references keep their duplicates. Observed
names remain bounded data; request paths and prune components still use the
strict constructor. These changes do not relax request authority, extend the
byte ceilings or serialize runtime terms.

Five real-host regressions first require the expected filesystem result and
then roundtrip its exact content through the codec. They fail against the
previous validators and pass after correction. The maximal-edit fixture now
reads back the landed disk text, and the synthetic 4,096-entry listing requests
that capacity explicitly. The latter remains a synthetic inventory test.

## Validation and limits

The root independently ran the original 13 tests and then all 18 final tests;
both invocations exited 0, including warning-free compilation. The worker's
focused format and lint checks exited 0 with no gating lint errors. The five
new producer regressions were also run against the original code: each failed
on its intended `InvalidPayload` mismatch, not a setup or compiler error.

A real maximal edit retains an eight-MiB preimage, nearly sixteen-MiB postimage
and a 65,536-byte diagnostic block. Its canonical completion is 25,231,364
bytes, proving a 24-MiB result allowance insufficient. The final 32-MiB bound
covers it. A 4,096-symlink inventory encodes to 56,252 bytes and needs more than
the former 32,768-node allowance, so the final node limit is 65,536.

An existing nested `Abnormal(Dynamic)` error remains explicitly unrepresentable.
The service must retain uncertainty if a mutation's result cannot be encoded;
it cannot turn that failure into permission to repeat the effect. Oversized
observations also remain bounded refusals. Encode constructs a semantic
projection before checking final size; only decode has the pre-allocation
admission guarantee. These checks are component evidence, not the two-host
product acceptance gate for issue #697.
