# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain measurements in their evidence documents.

Baselined October 19, 2026 against resource commits `35a0957cb` and
`a0c42df95` on `perf/swarm-resources`. This edition includes their
published integration `4f3c6f458` and the subsequent main updates through
`b65857090`. The profiling comparisons retain
their original `c444fca25` baseline.
The claims below were checked against this tree, the saved local gates and the
live observations identified in the report. This is a scoped resource handoff,
not a fresh audit of the repository's architecture or hosted CI.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Live profiling | Pickglass sampled installed daemon PID 50242, launch metadata commit `3cd330739`, OTP 29 / ERTS 17.0.5. The captures declared five sessions and ten strands. No live restart, forced GC or application-state walk occurred. |
| JSON CPU | `35a0957cb` adds an eight-byte ordinary-run scan while preserving the four-byte and byte tails. Three alternating fixture pairs reduce median reductions by 10.0% on plain text, 3.8% on escaped text and 2.7% on transcript-shaped input. Heap allocation is unchanged. |
| Page ownership | `a0c42df95` narrows component session-list and sign-in callbacks to registry and identity fields. The observer fixture's enlarged-hook component falls from 191,308 to 9,550 flattened words. This is a copy-size bound, not installed RSS. |
| Prior-head validation | On `96554f554`, all local package and static stages passed after selecting Homebrew's `rg` for the Seatbelt PATH fixture. Client passed 4,885 tests, TUI 1,544 and conformance 111. All hosted Linux jobs and the combined skip census passed. The 882-input complete-result JSON equivalence digest matches baseline. Independent adversarial and integration reviews found no blocking issue. These results precede the latest integration. |
| Upstream integration | Main `b65857090` includes remote-approval fixes from PRs #1036 and #1039, the sparse-renderer resource fix from PR #1023, and the private admin-read fixture adjustment from PR #1040. Their source changes and fixture repairs are retained. Incoming handoffs are preserved in the linked snapshots below. |
| Publication and installation | PR #1037 is authorized for merge once current-head hosted CI and independent review are green. The owner accepts hosted CI as the Linux evidence; remote Obelisk signoff is not a prerequisite. Installation and restart remain separate. |

The [resource report](review/swarm-resources-2026-10-19.md) records the probe
coverage, counter meanings, fixture methods, test results and remaining limits.
Its [numeric evidence](review/swarm-resources-2026-10-19.json) retains all 36
final JSON observations and twelve component measurements. Raw captures and logs
remain local under `/private/tmp/loom-swarm-20261019-*`.

The [previous handoff](next-2026-10-19-before-swarm-resources.md) described an
older idle-resource branch and Mermaid work. Its branch baseline does not
identify this tree, and its pending-publication statements do not establish
current GitHub state. They remain historical; their PRs and browser follow-ups
were not re-audited during this profiling task.

The [incoming renderer handoff](next-2026-10-19-before-swarm-integration.md)
preserves the upstream resource measurements, fixture failures and Mermaid
follow-ups. Its statement that PR #1023 is awaiting publication is now false:
that PR merged in `698a693de`. The renderer measurements remain in the
[frame-resource report](review/live-frame-resources-2026-10-19.md).

The [incoming admin-read handoff](next-2026-10-19-before-swarm-admin-integration.md)
preserves the renderer merge exception and fixture follow-up evidence. PR #1040
has since merged at `b65857090`; its private admin-read wait is five seconds,
while ordinary routing probes retain one second. The known-failure merge
exception described there applied to #1023 only.

## What to do next

1. Finish the authorized PR and full publication gates. **Exit:** full hosted
   coverage and independent review refer to the published source. Inspect raw
   advisory macOS results and the skip census before declaring CI green.
   Hosted Linux CI is the acceptance evidence; Obelisk is not a merge gate.
2. Measure remaining memory owners with an isolated fixture. **Exit:** identify
   the retaining callback and prove its bound while preserving authorization
   and lifecycle behavior. Owner-page capabilities in `ui_socket.upgrade`
   still capture attachments; the current observer fixture does not validate
   the owner-only sign-in callback's retained size.
3. Coordinate an authorized update and matched installed comparison. **Exit:**
   compare CPU, cumulative allocation, process/binary memory and OS RSS/footprint
   at the same concurrency and lifecycle cuts. Keep active swarm interruption
   outside an unannounced profiling step.
4. Attribute remaining storage and JSON work before another repair. **Exit:** a
   bounded workload identifies removable work. SQLite sample widths alone do
   not justify statement caching, new synchronization or allocator tuning.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Counter scope remains explicit.** The [BEAM memory review
skill](../skills/beam-memory-review/SKILL.md) distinguishes heap allocation,
flattened copied terms, process capacity, binary ownership and RSS. The report
keeps live observations separate from offline comparisons.

**Narrowing captures does not cache authorization.** The [client package
account](../packages/client/CLAUDE.md) records the callback ownership. Each
session-list read still authenticates its original credential; each sign-in
read still checks the page and registry. Admission remains bound to its
original gateway.

**The scanner preserves the durability boundary.** The [core package
account](../packages/core/CLAUDE.md) records checked byte boundaries and total
error behavior. The complete-result equivalence corpus matches unchanged
corruption reports, not just accepted values. The wider scan adds no FFI or
public API.

**Blank frames keep sparse cells.** The [terminal package
account](../packages/tui/CLAUDE.md) records the inherited sparse-canvas and
first-column repaint-marker invariants. The frame-resource report retains the
renderer comparison; the swarm report measures the parser and page callbacks.

## Deliberately open

None of these is unfinished work somebody forgot.

- Installed CPU and RSS savings are unmeasured. Three fixture pairs support
  parser-work reductions; active host load makes timing much noisier.
- Other owner-page callbacks retain attachments. The component measurement
  observes returned application state and excludes other actor-loop roots.
- A selected 96-byte JSON string still references its 1,048,679-byte input in
  the existing ownership probe. The scanner does not change binary ownership.
- The older idle-resource and Mermaid follow-ups remain in the linked previous
  handoffs. Their cross-browser state is unverified here.

## How to verify

From the repository root:

```sh
bash scripts/check.sh core
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match session_socket_test
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match ui_socket_test
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match ui_relay_test
bash scripts/lint.sh packages/core/src packages/client/src
make doc-check
```

Put `/opt/homebrew/bin` first on PATH for native gates. The Seatbelt PATH
fixture must select the installed Homebrew tool rather than a bundled `rg`
under `/Applications`, which is outside the jail's filesystem grants.

Use `scripts/json_decode_perf.sh` with separately built baseline/candidate
artifacts for performance comparisons, and its `equivalence` mode for complete
results. Run builds one at a time per checkout and measure timing without a
concurrent repository gate. The extended page regression intentionally fails
against the original callback capture. Its forced collection belongs only to
its owned fixture socket, never to a live daemon. See
[execution guidance](execution.md) for build, sandbox and exact-gate hazards.
