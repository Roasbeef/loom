# Current handoff

Baselined October 11, 2026 against main
`4417fdb6a073865660bf029495a9ecf08bc9e315` and the tool-latency branch through
`4839fd7d8`, including the transcript-read changes recorded below. Work is on
`perf/tool-latency` in the isolated `5086/loom` worktree and draft PR #949.
The installed daemon has not been changed.

## What moved

Distributed runtime PR #923 merged at the main baseline above. Its boundary is
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

Full repository and exact-head hosted/Linux gates are separate. Current status
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
shipped system. This task did not re-audit its reattachment, session movement
or extension/MCP limitations; consult current code before treating historical
notes as a current issue list.
