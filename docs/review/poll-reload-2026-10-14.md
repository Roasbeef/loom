# Checkpoint reload optimization, October 14, 2026

Runtime commit `c4c6d1414` optimizes repeated full loads while a strand
waits for a live effect. Its baseline is `23532b5f9`, which already includes preparation-value
reuse at `6435d874b`. This comparison therefore measures the polling change
separately from that earlier fix. The [live profiling report](loom-live-resource-profile-2026-10-14.md)
identified repeated preparation loads in the installed daemon; that daemon
remains unchanged and is not used as a benchmark fixture.

## Preserved recovery boundary

The 200 ms occupied poll and the two-minute idle poll keep their existing timer
chain and generation stamps. A pass parked on a live effect records only an
operation identity, strand/op/configuration sequences and the leaf. Each
accepted tick still reads and totally decodes the small current control
registers. If that frontier matches, an effect is still live and no observation
is queued, the driver can continue waiting without rebuilding the preparation,
pending queue and tool payloads.

Quiet queue admissions commit `op.state` with their payloads, so a lost doorbell
still causes the next control check to take the full load. Independent leaf and
configuration changes also invalidate the frontier. The optimization relies on
the existing transactional sequence contract, not on notifications. Doorbells,
provider/tool completions, retries and recovery always take the full drive and
clear the frontier. Retry and deferred-permit waits do not establish a live-effect
frontier. Restart begins without one. No public interface, dependency, poll
period or payload cache was added.

## Matched experiment

`scripts/poll_reload_perf.sh` uses the committed `support/held_operation`
fixture with a real SQLite session and a summary containing 1,360,000 bytes of
synthetic message text. Two seed turns establish a navigation target. The
scripted summary provider then holds its request until observation finishes,
so no model/network variation or transcript changes occur in the measured wait.
The fixture releases the provider, asserts successful completion and closes the
runtime after measurement.

Each run starts a fresh single-scheduler OTP 29 / ERTS 17.0.5 VM, built with
Gleam 1.19.0 and identical dependency manifests. The poll setting is 200 ms.
Three additional operation-control reads warm up the held request, then the
window lasts approximately three seconds. Five CPU runs alternate baseline and
candidate. Two separate allocation runs per version trace only
`storage@internal@register_cache:decode_blob/1` and
`runtime@strand_runtime:load_operation/4` across this isolated VM. Their untraced
callees are charged to those roots. No garbage collection is forced.

| Measure during the held window | Baseline | Candidate |
| --- | ---: | ---: |
| Median VM CPU time | 880 ms | 8 ms |
| CPU range over five runs | 876–894 ms | 7–9 ms |
| Median VM reductions | 55,785,005 | 58,576 |
| Operation-control reads | 9 in each run | 14–15 |
| Preparation listings | 9 in each run | 0 |
| Selected-root allocation, both runs | 151,084,426 words | 0 words |

Median CPU time fell by 99.09% and reductions by 99.895% for this fixed waiting
workload. At eight bytes per word, the traced baseline roots allocated
1,208,675,408 bytes during each allocation run. Candidate calls never entered
those two roots during the window. This means their allocation was eliminated;
the candidate still allocates for small control reads and runtime housekeeping.
CPU time and reductions are VM-wide, so they include that remaining work.

The candidate also services more control checks in the same interval because
the expensive handler no longer delays the fixed-delay timer's next arming.
These are fixture measurements, not daemon-wide CPU improvements under an
arbitrary live workload.

## Memory observations and limits

| Median snapshot, five untraced CPU runs | Baseline | Candidate |
| --- | ---: | ---: |
| VM allocation before window | 51.05 MiB | 69.07 MiB |
| VM allocation after window | 69.08 MiB | 69.09 MiB |
| Driver allocation after window | 55,272 bytes | 68,256 bytes |
| OS RSS before window | 101.22 MiB | 138.25 MiB |
| OS RSS after window | 162.11 MiB | 122.59 MiB |

Heap capacity, garbage collection and allocator residency have different
histories after baseline's repeated decoding and candidate's small reads. The
before-window cuts already differ. The lower candidate endpoint RSS is an
observation at this cut, not a proven steady-state or retained-memory saving.
The final VM allocation is essentially equal, and the driver allocation is
small in both versions. The demonstrated memory benefit is reduced cumulative
allocation and copying work. The frontier itself retains scalar identities and
sequences, not a second decoded preparation. Reachable-state size, allocator
carriers, physical footprint and live-daemon retained-memory savings were not
measured.

The [aggregate run data](poll-reload-2026-10-14.json) records every measured CPU,
reduction, capacity and RSS cut, plus allocation totals and the source digest.
The complete synthetic raw log is local at
`/private/tmp/loom-poll-bench-20261014.log`. The baseline archive and compiled
fixture remain at `/private/tmp/loom-poll-baseline-20261014`; its runtime source
was restored and digest-checked after the mutation experiment below.

## Regression and independent verification

All 206 runtime tests passed in the final `make check-runtime`, including the
existing lost-doorbell, idle/occupied timer, retry, deferred, abort and restart
coverage. The private projection benchmark also passed after its State-layout
assertion was updated from 21 to 22 fields; the new frontier is appended so
existing projection slots retain their positions. Runtime lint passed with zero
errors.

Three added tests hold the provider until inspection is complete. They prove
that control reads continue while preparation reads stop, that quiet steering
invalidates the frontier before provider completion, and that independent leaf
and configuration changes force full loads. The unchanged baseline fails the
no-reload assertion. An isolated mutation forcing every successful control
probe to skip the load makes the quiet-steer test expire as intended; the
request is then released and the runtime drained before the failing assertion.
Independent adversarial review found no actionable correctness, simplification
or nearby variant findings.

The initial fixture used a release subject owned by the observing process,
which could not release the provider's receive; that attempt was cancelled.
The corrected fixture creates the release subject in the provider and transfers
it to the observer. No result from the cancelled attempt is used. A combined
filter string matched no tests and exited with status 2; the full runtime gate
provided the actual suite validation.

```sh
make check-runtime
make lint-runtime
make doc-check
bash scripts/poll_reload_perf.sh /path/to/built/baseline baseline cpu
bash scripts/poll_reload_perf.sh /path/to/built/candidate candidate cpu
bash scripts/poll_reload_perf.sh /path/to/built/baseline baseline allocation
bash scripts/poll_reload_perf.sh /path/to/built/candidate candidate allocation
```

The baseline must include the same test fixture, copied without changing its
production source; the wrapper compiles the common measurement helper against
each checkout's generated runtime header. Do not run two measurements in the
same checkout concurrently because the synthetic database path is fixed.
These commands inspect only their synthetic VM and database. Full repository
tests, hosted CI, Linux signoff and deployment verification have not been run
for this candidate. The installed daemon was not restarted or hotpatched.
