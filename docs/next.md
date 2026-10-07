# Current handoff

This edition is baselined on source
`cc9ec305da544c45609c959ed933d797930cac16`, the render implementation
`669a8274e`, the separately approved CI repair `1f0c7c6e5`, and snapshot
sizing implementation `8d37bf994`, measured on October 6, 2026
(America/Los_Angeles). Work is isolated on
`codex/perf-live-render-20261006`. The source, running process identities,
local validation and GitHub state below were checked during this pass.
Earlier gate results are explicitly dated to the source they tested.

Read [the CPU investigation](review/beam-transfer-cpu-2026-10-06.md) for the
new workloads and counters, and [the render investigation](review/beam-render-2026-10-06.md)
for the preceding live allocation pass and full-branch gate limits. The
[October 5 investigation](review/beam-cpu-2026-10-05.md) describes the earlier
merged optimization. Rewrite this handoff after the next body of work.

## Where the tree is

| Body of work | Verified state |
| --- | --- |
| Previous optimization | [PR #873](https://github.com/Roasbeef/loom/pull/873) remains merged at `bf4334140911296e3f393482f8d5c5c7c454e764`. |
| Running applications | Daemon PID 53549 and active terminal PID 67235 remain on installed revision `11454cba77ca96acc6b3be85f1da72ba469dd976`, before #873. Neither application has been restarted or updated. |
| Render candidate | Done/Pending step bodies avoid unused refusal preprocessing; settled preview blankness checks use the existing text-keyed memo. All 811 web-view tests passed sequentially and at parallelism eight before the snapshot CPU pass. |
| Snapshot CPU candidate | Private quoting counts UTF-8 bytes directly, advancing ordinary bytes four at a time. The conservative metadata budget, JSON serializer, admission, interfaces and custody remain unchanged. |
| CPU evidence | A five-second selected live allocation cut observed 2,374 quoting calls and 484,592 allocated words. Alternating full transfer-start fixtures remove about 71% of reductions for many small strings, 91% for ASCII and 78% for Unicode. Control-heavy metadata removes about 8%; serializer work remains. These are fixture reductions, not installed CPU savings. |
| Snapshot regressions | All 13 transfer tests pass; 40 concurrent executions of the new regressions pass. Trace sessions are unchanged after callback failure and concurrent execution. The work regression fails against the saved original module with 81,931 Unicode decoder calls. |
| Current local gate | The prepared CPU affected check against `52ebb1a4f` returns its own zero status in 557 seconds: static checks, fresh server preparation, all 2,947 client tests, all 97 conformance tests and skip census pass. This narrower run does not certify the entire branch's CI repair scope. |
| Static validation | The CPU pass returns zero lint errors and 2,176 warnings, zero doc-check errors and 196 warnings. Whole-tree formatting, generated-client and prelude checks pass with Gleam 1.19.0. |
| CI repair | Quiet grep closed an existing successful declaration match early under `pipefail`. Commit `1f0c7c6e5` consumes the stream, preserving existing declarations; all 18 selector/runner tests passed and both new regressions fail against the original runner. No skip declaration changed. |
| Full branch gate | The earlier full local affected wrapper remained red on two undeclared Linux `/proc` broker skips on Darwin. All local package gates had a passing result before the CPU source changed. Linux signoff remains required and unperformed. |
| Review | The new CPU diff has one independent source-only review with no actionable finding. The preceding render and CI diffs were independently reviewed; the render review also exercised 70 concurrent regressions and failure cleanup. |
| Hosted validation | No candidate branch has been pushed or tested remotely. Baseline [run 37538889208](https://github.com/Roasbeef/loom/actions/runs/37538889208) failed in macOS Skip census. A newer main [run 37548474023](https://github.com/Roasbeef/loom/actions/runs/37548474023) at `92df4a41347e6a1e203e6f71f027ba81b479ede4` was in progress when checked; it is not candidate validation. |
| Publication and installation | The implementations are committed locally. No candidate PR, shipment or installed comparison has run. The original checkout's 13 unrelated untracked entries remain untouched. |

The previous edition's local package passing results describe the render and
CI source before `8d37bf994`; they cannot be carried forward as validation
of the new CPU source. The latest stack probe collected only 15 running
samples out of 8,000. The native helper sample mostly waited. Those quiet
cuts cannot establish another broad CPU hotspot or a helper busy loop.
The allocation probe instead supplied a concrete, reachable metadata-sizing
cost, and the source fixture isolated its improvement.

The earlier two prepared client runs each failed the same gateway lifecycle
regression while a later full repository run passed all 2,945 client tests.
The focused regressions and predecessor-module sequence passed. Its cause
remains unresolved; passing later is not an explanation for failing earlier.
The same gateway regression passes in the CPU pass's full client run.
No assertion or timeout was weakened. See the render report for exact logs.

The earlier formatter blocker came from selecting Gleam 1.18.1 rather than
CI's 1.19.0; no formatter repair was applied. The Go sandbox gate similarly
selected an app-private `rg` outside its intended Seatbelt grants. It passed
with Homebrew first; no sandbox grant was widened. These are validation-shell
hazards, not reasons to weaken formatting or isolation.

## What to do next

1. Obtain the required exact-head Linux signoff and resolve the full-branch
   Darwin skip census.
   Exit: the selected gates return their own zero statuses, and platform
   omissions have explicit scope approval. The separate CI repair does not
   authorize new skip declarations. Preserve the intermittent gateway evidence.
2. Publish only when directed. Exit: exact-head hosted checks and the required
   review/signoff lanes pass, with fixture limits and inherited gate failures
   visible in the description. A local optimization is not a release signoff.
3. Follow [updating](updating.md) for an approved shipment and graceful daemon
   transition. Exit: verify installed revisions, then measure the same active,
   idle and released workloads before and after. The merged previous fixes
   and these candidates are absent from the current installed applications.
4. Profile a client started with its profiling option and obtain a matched
   active workload for the next CPU pass. Exit: bounded caller and allocation
   evidence identifies a reachable cost. The current quiet sample does not
   justify a broad serializer, SQLite or native-helper rewrite.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Snapshot admission.** Count UTF-8 bytes without constructing Unicode lists,
but retain the old conservative budget. Every C0 control costs six even if
JSON uses a shorter escape. The serializer and full-string traversal remain
unchanged. The boundary oracle and work counter in `transfer_test.gleam`
make both claims executable; the [CPU investigation](review/beam-transfer-cpu-2026-10-06.md)
records their controls and fixture limits.

**Render ownership.** Keep memos at leaves and project closure inputs before
construction. Every memo input participates in its references. Lustre 5.7.1
discards nested entries when an outer memo hits. The earlier and current
render investigations record editor-refusal invalidation, preview transitions
and the blank preview's invisible 20-byte memo placeholder.

**Dispatch before preparation.** A Done or Pending tool step does not need a
refusal sentence. Dispatch before assembling it. Failed steps retain their
whitespace, escaping, ordering and fallback. `render_work_test` measures the
removed work boundary without elapsed-time thresholds.

**Capacity and ownership.** Flat size, allocated process capacity, cumulative
allocation, RSS and physical footprint are distinct metrics. Cuts of the
same old build under different activity establish neither leaks nor savings.
Follow [daemon memory evidence](design-notes/daemon-memory.md) and
[BEAM memory review](../skills/beam-memory-review/SKILL.md) for attribution.

**Verification.** [Execution](execution.md) owns gates and signoff. Verify
every command by its own status, and distinguish an earlier package pass,
a current source check and an exact-head hosted result. A successful log tail
cannot certify the command that produced it.

## Deliberately open

- Installed CPU, resident-memory savings and the ownership census in
  [#454](https://github.com/Roasbeef/loom/issues/454) remain unmeasured; the
  issue was checked open during this pass.
- SQLite bursts and control-heavy JSON serialization remain workload-dependent
  costs outside the private snapshot sizing fix.
- Direct client attribution needs a named profiling node and a matched workload.
- The intermittent gateway-test cause, full-branch Darwin census, Linux
  signoff, publication and installation remain pending.

None of these is unfinished work somebody forgot. The measurement gaps need
matched installed workloads; fixture reductions do not close them.

## How to verify

Use a non-login shell with
`PATH=/Users/roasbeef/.local/lib/loom/server/bin:/opt/homebrew/bin:$PATH`.
Verify Gleam 1.19.0 and Homebrew `rg`. `make affected BASE=52ebb1a4f` selects
the CPU diff's static, client and conformance checks; `make check-affected
BASE=52ebb1a4f` prepares a fresh server and runs those lanes. The entire
branch's `make affected BASE=cc9ec305d` selects the full repository check
because it includes the CI repair. Both scopes require Linux signoff.
The remote signoff needs a published exact head and an explicitly selected
`LOOM_SIGNOFF_HOST`; neither has been supplied.

The CPU runner, saved original module and alternating logs are private files
under `/private/tmp/loom-live-20261006/`. Keep timing untraced, use identical
compiled dependencies and compare full result fingerprints. The live CLI,
focused tests, negative control and affected logs share the
`/private/tmp/loom-live-20261006-` prefix. Earlier full affected lane logs are
preserved under `affected-before-transfer/` before reusing `build/affected/`.

**Application-private tools are not Homebrew tools.** Intentional Seatbelt
grants cannot read Codex's app-private `rg`; use the supported tool path.

**Samples are not elapsed CPU shares.** Pickglass samples at reduction safe
points and allocation probes cover selected processes and module patterns.
Neither predicts whole-application savings. The latest stack cut was quiet.

**Natural capacity is not reachable size.** Do not force collection or walk
state between matched cuts. Keep VM allocation, binary payload, allocator
capacity and OS residency separate. Read [execution](execution.md) for the
remaining validation hazards.
