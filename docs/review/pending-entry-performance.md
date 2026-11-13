# Pending entry reads

Current follow-up: [November 13 bounded bulk reads](bulk-register-reads-2026-11-13.md).
Protocol 114 replaces individual pending reads with exact-key batches while
retaining unrelated-corruption isolation. The historical point-read results below
remain the [November 4 full run](session-hotpaths-2026-11-04.md), not measurements
of the current bulk implementation. Neither candidate uniformly beats scans.

Issue: #1150. Source baseline: `ccb795759`.

`pending.entry` is keyed by entry ID, not by strand. Run admission and each
run-driver reload previously listed and decoded the entire namespace. An
unrelated pending payload therefore added work to every run and an unrelated
corrupt payload could prevent a run from starting or continuing.

Run admission now reads the IDs in the captured `pending_next_run` list. A
run driver reads the IDs in its steer, follow-up, and write queues, together
with the result IDs of `CallOutcomeReady` tool calls. Structural operations
still read none of these payloads. The planner and acceptance machine report
missing referenced IDs; an undecodable referenced payload remains an error.
Abort-drained IDs remain owned by the terminal cleanup transaction and are
not decoded for placement.

The initial point reads used separate writer calls, not a snapshot transaction. Queue
payloads are installed with a fresh ID and the corresponding state update;
placement and terminal transactions compare the state sequence they read.
A state change therefore prevents a successful stale placement. A concurrent
acceptance can already remove a captured next-run payload between another
acceptance's state read and its payload read. The latter can report missing
queue corruption before reaching the state expectation, even with the earlier
namespace listing. This work does not add a retry for that pre-existing race.

## Measurement

At the original measured revision, `packages/runtime/dev/pending_read_bench.gleam`
compared the writer namespace listing and decode with a point-read simulation.
It varied unrelated payload count and owned width on memory and SQLite `:memory:`.
The current module also includes the bulk method; its pinned source and complete
three-way reruns are recorded in the November 13 follow-up.
Each sample checks the selected payloads. All keys carry the same encoded
1 KiB payload, so these results do not model a backlog of distinct payloads.
The `pending_read_bench_test.benchmark_smoke_test` calls the same setup, reads,
and teardown with one sample and one loader iteration per mode on both backends. It is a
correctness check, not a timing measurement.

This is a writer-path microbenchmark,
not an end-to-end runtime benchmark or a measurement of a live daemon.

The initial baseline run completed with seven samples of 50 loader iterations for each
case and is retained at `.codemode/tmp/pending-entry-performance/baseline-benchmark.log`.
A later run with owned widths 0, 1, 32, and 128 did not finish: its writer
was still shutting down when the store closed. The host was also under heavy
load. Its raw output is retained at
`.codemode/tmp/pending-entry-performance/wide-benchmark.log`, but is invalid
for ranking either method. The benchmark now waits for the writer to stop
before closing the store. The November 4 corrected full run completed all
cases: it confirms that individual actor calls can cost more than one listing
for wide owned queues, while a large unrelated backlog favors scoped points.
The dated record retains all samples and the ordering/quantization caveats.

The production-path test `owned_inbox_and_staged_result_survive_unrelated_corruption_test`
wraps the actual storage boundary and asserts that a completed run performs
no pending namespace listings and no point read for the unrelated corrupt key.
It also asserts that owned point reads occur and that the steer, follow-up,
deferred write, and staged tool result are placed. The unrelated corrupt cell
survives until the test removes it. This proves the read shape for that fixture;
it does not quantify latency or memory savings.

## Verification

The baseline `make check-runtime` passed before these edits. The first
candidate `gleam test` passed 218 tests. The focused `pending_read` suite
passed three tests, including the benchmark smoke. The focused admission test
passed with an unrelated corrupt payload, then placed a valid captured
next-run message once and checked both corrupt and missing captured payloads.
The recovered-run test checks a missing referenced steer, and the existing
recovery test now corrupts an actually referenced steer.

Negative controls removed staged-result, steer, follow-up, and deferred-write
IDs in turn. Each caused the combined production-path test to fail. Restoring
the previous global decode before run admission caused the unrelated-corrupt
payload assertion to fail. All controls were restored before the final gates.
The existing runtime `interleave_test` covers steer placement across restart,
abort during a tool, and retry after failure. Machine `queue_test`,
`acceptance_test`, and `failure_test` separately cover abort drainage, next-run
acceptance, and failure-drain transitions; those machine tests are not a
substitute for a runtime placement test.

Raw logs and control output are retained under
`.codemode/tmp/pending-entry-performance/` for this session. `make
check-runtime` passed after the candidate, fixtures, and comment fixes were
installed (exit 0, `final-check-runtime-2.log`). The first `make lint-runtime`
found three missing case-stanza comments; after those comments were added, it
passed with 65 non-gating warnings (exit 0, `final-lint-runtime-2.log`). The
earlier `gleam test` count preceded the final smoke and admission fixture.

The runtime `failure_drain_places_queued_inputs_once_test` records a committed
`FailureDrain`, then verifies that the queued steer, follow-up, and deferred
write each reach the tree once and the pending registers are gone. The
`abort_places_write_and_discards_drained_inputs_once_test` verifies that abort
places the deferred write, discards the drained steer and follow-up without
placing them, and leaves no pending registers. The final focused `pending_read`
run passed all five tests after these fixtures were added (exit 0,
`pending-focused-boundaries.log`). The worker gates above preceded these two
test-only additions.

## Independent final verification

The primary rerun passed all 221 runtime tests and the package's additional
checks (`make check-runtime`, exit 0), runtime lint (exit 0, 65 non-gating
warnings), whole-tree formatting, documentation checks (zero errors, 228
warnings) and the generated prelude gate. Commands and output are retained in
`.codemode/tmp/session-hotpath-primary/`, with direct exit codes in
`results-rerun.tsv`. An independent source review found no actionable
correctness findings; its final delta check covered the counted read witness,
next-run and boundary fixtures, and corrected benchmark lifetimes.

The first primary full runtime run failed two existing cases:
`idle_poll_test.recording_a_timer_does_not_delay_its_wake_test` and
`restart_reap_test.provider_surface_crash_faults_the_effect_and_recovers_test`.
Both passed unchanged in separate focused reruns, then the complete runtime
gate passed unchanged. The failures were timeout observations; host load alone
does not establish their cause. No assertion or timeout was weakened. The
initial failure is retained in `runtime.log`, and the clean rerun in
`runtime-rerun.log`.

The primary also ran `register_read_bench_smoke` and
`commit_cost_bench_smoke` successfully through `gleam run -m`. The pending
benchmark's shared two-backend smoke ran in the runtime gate. These are
correctness receipts, not full performance measurements. The November 4 full
measurements now cover all three workloads under lower observed host load;
actual runtime prevalence and the scoped bulk-read design decision remain
open in #1150, #1151 and #1152. No live process was updated.
