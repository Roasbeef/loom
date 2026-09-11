# UX polish resource comparison

Baseline: `3ce454e6`. Candidate implementation: `89a80579`. Measurements use
separate self-contained installations of each tree on the same macOS host.
The candidate's full gate and final native acceptance passed before these runs.
No build or test suite overlapped a measurement.

A loopback provider emits thinking deltas at 20 Hz. The long fixture first
performs 160 real file reads. Each CPU interval lasts ten seconds, with process
census work outside that interval. CPU percent is a fraction of one logical
core. RSS is sampled after the census in MiB. Four runs alternate baseline and
candidate by scenario. These are short observations, not a long-duration leak
or external-provider benchmark.

## Installed process observations

| Scenario | Baseline daemon CPU / RSS | Candidate daemon CPU / RSS | Baseline TUI CPU / RSS | Candidate TUI CPU / RSS |
|---|---|---|---|---|
| detached idle | 0.10% / 88.8 | 0.10% / 89.0 | — | — |
| attached idle | 1.80% / 399.2 | 1.80% / 379.2 | 2.00% / 93.3 | 2.20% / 96.1 |
| short stream | 4.70% / 432.2 | 4.00% / 421.6 | 9.49% / 110.7 | 11.80% / 112.4 |
| long stream | 9.50% / 460.4 | 9.79% / 439.9 | 11.10% / 107.8 | 10.19% / 114.4 |
| post-long idle | 1.80% / 419.9 | 2.10% / 414.1 | 1.90% / 97.6 | 2.10% / 100.2 |

RSS is **instrumented RSS**. Collecting binary references and process ownership
allocates within the measured VM; the diagnostic RPC itself appears in the
per-process census at roughly 25–34 MiB in the inspected daemon samples. These
figures must not be presented as the uninstrumented release footprint. CPU
intervals exclude the census, but prior instrumentation can still affect later
GC. Both versions use the same probe.

The long-stream TUI uses less CPU in this sample, while short-stream TUI CPU is
higher. The candidate displays full retained reasoning rather than the
baseline's abbreviated text, so the visible work differs. The observations do
not establish an across-the-board speedup or explain the original user's
full-core daemon sample.

## Responsiveness

Twenty native tmux typing probes measure input injection to captured painted
text, including tmux and polling overhead. They are an upper bound on the
software path, not physical monitor latency. Twenty further prompt submissions
measure recorded request to its correlated terminal reply at the same boundary
in both versions. Each run has four queued acknowledgements and sixteen
explicit queue-full conflicts; these are response distributions, not twenty
successful admissions. Refused drafts are cleared before the next probe.

| Scenario | Baseline paint median / p95, ms | Candidate paint median / p95, ms | Baseline command response median / p95, ms | Candidate command response median / p95, ms |
|---|---|---|---|---|
| short | 16.14 / 17.71 | 17.63 / 18.76 | 10.0 / 11.0 | 10.0 / 11.0 |
| long | 16.33 / 17.77 | 16.28 / 16.86 | 9.5 / 11.0 | 10.0 / 11.0 |

## BEAM and transport census

The following values are sampled at the end of the long streaming interval.
Heap words cover all processes; binary memory is VM-wide. Rates use the
surrounding census interval, slightly longer than the CPU interval. Socket
totals exclude the diagnostic distribution connection and include all ordinary
fixture sockets. Diagnostic reductions and transient heaps remain part of VM
aggregates, so these rates are attribution aids rather than production budgets.

| Quantity | Baseline | Candidate |
|---|---|---|
| daemon heap MiB | 287.33 | 285.89 |
| daemon binary MiB | 3.85 | 4.37 |
| daemon queued messages | 0.00 | 0.00 |
| daemon million reductions/s | 9.94 | 9.88 |
| daemon sent KiB/s | 21.19 | 20.69 |
| daemon received KiB/s | 3.14 | 3.12 |
| daemon snapshot transfers/s | 3.19 | 3.18 |
| daemon event serializations/s | 17.08 | 17.01 |
| tui heap MiB | 4.29 | 5.87 |
| tui binary MiB | 0.19 | 0.26 |
| tui queued messages | 1.00 | 1.00 |
| tui million reductions/s | 13.70 | 11.88 |
| tui sent KiB/s | 0.73 | 0.73 |
| tui received KiB/s | 20.75 | 20.68 |
| tui snapshot transfers/s | 0.00 | 0.00 |
| tui event serializations/s | 0.00 | 0.00 |

Each retained process row includes PID, reductions, heap, referenced binary
bytes, mailbox length, current function, and its registered name or recorded
initial call. In the baseline's final daemon census, an OTP actor at `<0.188.0>`
had about 1.48 billion cumulative reductions but only 2.8 KiB of process memory
after GC;
Weft actors at `<0.221.0>` and `<0.204.0>` retained about 22.8 and 11.0 MiB.
This separates CPU history from live retention. Their initial calls identify
actor wrappers, not a proven application-level cause. The census is insufficient
to assign the earlier real-session CPU spike to one source function.

After releasing the stream, settling queued work, and observing ten seconds of
idle time, the probe requests GC of the owned node's processes and takes another
census. Process and binary figures below remain instrumented and are not RSS.

| Scenario/process | Baseline process / binary MiB | Candidate process / binary MiB |
|---|---|---|
| short daemon | 179.56 / 2.79 | 177.37 / 2.85 |
| short tui | 13.59 / 0.13 | 13.90 / 0.18 |
| long daemon | 176.87 / 2.02 | 180.50 / 2.82 |
| long tui | 14.54 / 0.18 | 14.41 / 0.13 |

No mailbox or memory plateau is inferred from a single before/after pair.

## Original transcript replay and retained model

The valid private recording contains 532 records and produces 537 frames at
160×48. Three fresh baseline/candidate process pairs ran in alternating order.
A separate fresh process discards captured frames, forces GC, and measures the
retained model. This measurement does not load the RPC census probe.

| Version | Replay seconds, three runs | Median seconds | Retained process / referenced binary MiB |
|---|---|---|---|
| base | 4.112, 4.062, 4.177 | 4.112 | 3.93 / 0.59 |
| head | 3.408, 3.311, 2.989 | 3.311 | 6.36 / 0.79 |

Both retained models contain 532 records. The candidate retains 2,990 rendered
rows versus 460 on the baseline; compact history and full reasoning
intentionally retain more visible content.

The first candidate implementation took 16.2 seconds. Profiling identified
repeated terminal sanitization and rebuilding of source anchors. Lazy anchors
and bounded call/narrative caches removed that repeated work. All candidate
frames remained identical across these optimizations; the final frame SHA-256
is `7615427262ae9b15ca808bf592a492f32b8344a4409fcd2507930193bfa4f2a3`.
Baseline and candidate frames differ because the presentation itself changed.

The caches rebuild from currently retained entries and clear on replacement
snapshots. A regression verifies that releasing history releases both caches.
The 600-descriptor/16 MiB history limit bounds encoded payload, not the entire
BEAM heap or process RSS.

Raw JSON, per-process censuses, and the probe outputs are retained locally with
the native acceptance evidence. The source recording is private and is not
included in the repository. These measurements close the local comparison;
hosted latency and sustained memory observations retain their separate scope.
