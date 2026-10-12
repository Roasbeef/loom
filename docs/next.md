# Current handoff

Baselined October 11, 2026 against main
`2ff7512ac` (PR #950), with measurements based on the earlier
`4417fdb6a073865660bf029495a9ecf08bc9e315` tree and the tool-latency branch through
`9b1654af5`, including the JSON decoding follow-up described below. Work is on
`perf/tool-latency` in the isolated `5086/loom` worktree and draft PR #949.
The installed daemon has not been changed.

## What moved

Distributed runtime PR #923 merged at the earlier measurement baseline.
PR #950 subsequently brought peer mail and remote code-mode/MCP support from
PRs #937 and #938 onto main. Integration conflicts only in this handoff; the
admission, indexed scan and completion-witness source changes have no overlaps.
The execution boundary remains
`runtime/effects.ToolSurface.run`: the orchestrator owns sessions, SQLite,
providers and approvals; the executor owns the workspace plane, including its
broker, jailed commands, jobs, LSP and code mode. The optimizations use those
shared boundaries rather than a per-command remote broker interface.

Three benchmark layers now separate the costs:

- `make bench-tool-latency` measures real broker/helper/jail execution.
  The [October 9 report](review/tool-latency-2026-10-09.md) records warm
  medians of 18 to 23 ms on macOS.
- `make bench-tool-roundtrip` measures the scripted-provider-to-provider
  interval through shipped local and TLS distributed daemons. The
  [completion report](review/tool-completion-latency-2026-10-11.md) records
  tiny-call medians of 95 to 51 ms locally and 99 to 52 ms distributed after
  replacing positive polling waits with a completion witness.
- `LOOM_BENCH_TOOLS_WORKLOAD=history make bench-tool-roundtrip` fixes a
  65,550-byte prompt. The [storage report](review/tool-storage-latency-2026-10-11.md)
  records additional median reductions from 62 to 47–51 ms locally and 70 to
  50–51 ms distributed. Its standalone SQLite scan falls from 8.166 to
  0.100 ms over exactly 128 messages containing 1 MiB of text.

The previous edition left repeated reads and transcript scans as an open lead
from the [bounded call trace](review/tool-completion-calls-2026-10-11.txt).
That lead now has two measured changes. Image-capable model admission checks
model capability before reading operation or transcript state. SQLite pushes
kind filtering into the existing covering index and caps fetches at the
remaining limit when custom-type filtering cannot reject rows. It still
resolves stops and cursor windows on the unfiltered branch first.

The latest live [Pickglass resource profile](review/loom-live-resource-profile-2026-10-11.md)
observed the installed main daemon during active sessions. It identified
repeated failed-tool refusal trimming in web rendering. A failed body now
uses one memo leaf over its words and rows; its rows are drawn directly.
The real Lustre cache fixture falls from four trim calls to zero on unchanged
patches. Empty bodies remain empty; independent words and row changes
invalidate the memo. The adjacent profile JSON records sanitized counters.

The JSON lead now has a controlled [decoder comparison](review/json-decoding-allocation-2026-10-11.md).
The parser dispatches empty runs before slicing and validates nonempty string
runs directly, avoiding an intermediate Result pair and cursor update. Three
alternating fresh-VM comparisons reduce measured heap allocation by 14.0% for
128 transcript-shaped objects, 15.3% for escaped text and 53.0% for dense
adjacent escapes. Full values and corruption reports match for 882 differential
inputs. Final concatenation, output ownership and numeric parsing are unchanged.

## Rulings

Production positive waits use `jobseam.production` and `jobs.await_completion`.
Each watched live job lazily owns one linked weft actor. Terminal processing
attempts the fact write before stopping that witness. Callers monitor it and
reread authoritative state on DOWN or timeout. There are no retained waiter
subjects. Local and distributed executors select the same constructor.
Injected-clock polling remains available to simulations.

A dead witness is never a successful result. The existing commit path updates
memory after a failed persistence attempt; the wake preserves write-attempt
ordering, not successful durability during owner failure. No tool schema,
frozen interface, distributed protocol, durable job format or jail enforcement
was changed.

Kind metadata is derived from the immutable entry at insertion. Matching
malformed payloads still fail total decoding; payloads excluded by kind are no
longer fetched or validated. Custom-type filtering stays in pure refinement.
The existing `ix_be_type` supplies both traversal orders without a new index,
migration or temporary sort.

## Verification and remaining work

The completion change passed 57 focused job tests, including a direct witness
monitor held across blocked terminal persistence. The test fails when witness
shutdown is moved before the write. Both real shipped placements passed.

The transcript changes passed focused storage, wiring and vision runs. Tests
check zero reads for image-capable admission, failure on selected malformed
payloads, stop-before-filter semantics, sparse pagination and exact traversal
around the 256-row boundary. Independent review found no remaining actionable
defect. A benchmark count observation was corrected, and both scan timings
were rerun on the exact 128-message fixture.

The full pre-integration `make check` passed with exit 0: client 3,749, TUI
1,331 and conformance 98, followed by Go sandbox tests, house lint and the
configuration-key self-test. The parallel Linux signoff on an older head found
two TUI fixtures sharing a credential path. Their three calls now own distinct
paths; the full 14-test module passed 100 parallel runs. The exact failing Linux
interleaving remains inferred, since twenty local baseline pair runs passed.

The full integrated `LOOM_TEST_PARALLEL=8 make check` also passed with exit 0:
storage 271, client 3,835, TUI 1,331 and conformance 98, plus all remaining
packages and static gates. Three subsequent shipped history runs passed, but
their full-round medians varied substantially (local 56 / 57 / 65 ms and TLS
55 / 59 / 74 ms, candidate / read-baseline / candidate). A following host
snapshot showed load around 19 with unrelated compilers and VMs consuming CPU.
The earlier 18–29% full-path reductions are observations; an isolated host is
needed to establish a repeatable integrated speedup. All samples are retained
in the storage report.

The live-profile follow-up passed all six preprocessing regressions and the
final `make check-web_view` (956 tests). Astra reviewed the actual drawing
callback, memo dependencies and empty-body shape. `make doc-check` passed
with 198 existing warnings and zero errors. The follow-up full
`LOOM_TEST_PARALLEL=8 make check` also passed with exit 0, including client
3,835, TUI 1,331, conformance 98, Go tests and zero house-lint errors. The
final web-only check includes the empty-body regression added during that
full run.

The JSON decoder follow-up passed the full local
`LOOM_TEST_PARALLEL=8 make check` with exit 0, including 163 core, 3,835 client,
1,331 TUI and 98 conformance tests, Go sandbox tests and zero house-lint errors.
Documentation checks passed with the same 198 warnings. Astra reviewed parser
correctness and the inline simplification; Sol 6.1 checked benchmark arithmetic
and evidence. Both found no remaining actionable issue. The optional JavaScript
comparison still has the same pre-existing non-finite-number corpus failure
and 25 build warnings on both sides; both new regressions pass.

Exact-head hosted/Linux gates are separate from the local results. Current status
is on PR #949 and under `build/signoff/`; do not infer green from an earlier
candidate or this handoff. The full `make check` runs outside the nested macOS
sandbox so jailed conformance cases can create their capability sockets.
After pushing, use the prescribed
`LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote` for the current SHA.

All latency results are from one Mac with loopback TLS, with first calls
separate from warm samples. They are not production SLOs. Repeat on Linux and
across physical hosts, then measure contention, growing transcripts, code-mode
compilation and provider inference separately. Attribute further costs on one
clock before adding storage or transport machinery. Keep profiling separate
from timing comparisons and capability sockets outside `/tmp`.

Read [distributed architecture](architecture/distributed.md),
[the setup guide](distributed-setup.md) and
[protocol-change/078](../protocol-change/078-distributed-runtime.md) for the
shipped system. PR #950 adds remote background code mode and executor-placed MCP servers. This
task did not re-audit the remaining reattachment and session movement limits;
consult current code before treating historical notes as a current issue list.

## Next measurements

The bounded live allocation probe counted 146.7 MB in 5.119 seconds over its
selected functions and processes. The decoder follow-up measures only synthetic
parser inputs; it cannot scale that live total or establish retained-memory
savings. A 96-byte output in both builds still references the same roughly
1 MiB input backing binary. Study actual selected-field lifetimes and a matched
copy-policy fixture before changing string ownership.

Repeat the integrated local/TLS latency comparison on an isolated host. Only
compare live resource profiles after an authorized deployment under a matched
workload. The installed daemon remains unchanged, and no live CPU or memory
reduction is claimed for this candidate.
