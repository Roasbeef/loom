# Web reasoning renders and idle gateway pulls

Measured October 24, 2026 against main `1dfef315fd3b44d35a51ea21a6d5fda45f4869a3`. Candidate source through `64a30c125` contains implementation commits `d240d5492` (web) and `f08c1179f` (gateway). The candidate changes reasoning-block memo ownership and skips branch attribution when an entry cut is empty. The installed daemon has not been replaced or hotpatched.

## Live attribution

Standard read-only Erlang RPCs reached `laptop@100.75.241.68`, daemon PID 1513, OTP 29, through an enrolled hidden, non-listening tool. Over a 30.17-second OS observation, daemon CPU time increased by 28.40 seconds (94.13% of one core); RSS ranged from 1040.28 to 1099.36 MiB. Process heaps and binaries dominated the separate BEAM censuses. These live observations are not a matched before/after workload.

The fixed Pickglass scratch build subsequently attached to the same daemon. Its one-shot census recorded 758 processes and 1,021,058,914 bytes of BEAM allocation: 719,363,064 process bytes and 245,070,672 binary bytes. The capture reports unknown application/build identity; source revision is not inferred from a checkout.

A 20-second, 100 Hz CPU probe selected eight busy processes from the bounded process listing. Of 16,000 samples, 556 were running/runnable. SQLite fetchall1 accounted for 183 flat samples; q appeared in 223 cumulative samples. These are sampled shares, not percentages of daemon CPU time, and long NIFs are under-sampled. A separate five-second call-memory probe selected the lane and SQLite modules in eight busy processes: 584 matched functions, 47 called/read, 76,085,320 cumulative allocated bytes, no unavailable readings. The selected lane block/piece rendering and SQLite calls support the chosen paths, not a whole-daemon allocation total.

The enrolled tool directory was the sole credential input. Authority keys, root cookies, passphrase files and daemon state were not used for this attachment. The scratch Pickglass build was not installed. Its attach-dir shorthand initially failed command parsing; the equivalent explicit TLS flags succeeded. The persistent UI uses the same inspector identity, so no second viewer/profile VM is started concurrently under that name.

## Matched disposable fixtures

Both revisions use Gleam 1.19.0, OTP 29, eight-byte words and one scheduler. Production baseline source is untouched in a separate managed worktree. Startup and fixture construction precede timed work. CPU is VM runtime without tracing; wall time is separate. Heap words are measured in a later call-memory window. Allocation bytes are cumulative heap work, not retained memory, RSS, binary ownership or a leak estimate.

Web runs use the real operator page, synthetic fixed history and Lustre diff cache. Three trials alternate baseline/candidate order. Gateway CPU trials use two alternating pairs with no other benchmark/build running, a real synthetic SQLite store, and a same-sender pull/barrier. The same compiled gateway fixture is used with both production revisions. Raw trial values and medians are in the adjacent JSON file. Background host activity was not controlled; work counters are more stable than timing.

| Fixture | CPU ms before / after | Reductions before / after | Cumulative heap bytes before / after |
| --- | ---: | ---: | ---: |
| 1,000 unchanged renders, 40 completed reasoning answers | 2,379 / 445 | 182,631,337 / 47,522,695 | 3,584,796,432 / 624,165,240 |
| 1,000 unchanged renders, 40 reasoning steps in a running turn | 781 / 682 | 70,115,855 / 51,158,920 | 1,016,563,912 / 712,485,408 |
| 1,000 unchanged ordinary sibling renders | 61 / 57 | 7,216,490 / 7,223,654 | 90,336,152 / 90,384,152 |
| 200 idle pulls, 128 strands | 1,669.5 / 1,299 | 27,419,731.5 / 19,592,325.5 | 317,094,844 / 232,297,180 |

The completed-answer fixture uses 81.3% less observed CPU, 74.0% fewer reductions and 82.6% fewer heap bytes. The idle gateway fixture uses 22.2% less observed CPU, 28.5% fewer reductions and 26.7% fewer heap bytes. Native SQL calls decrease from 77,800 to 52,200 per 200 pulls (389 to 261 per pull, 32.9% fewer). The gate also checks 1, 8 and 64 strands.

First paint is measured separately over thirty fresh caches. Completed-answer reductions are 20,098,274 before and 20,095,360 after; allocation is 321,727,352 and 322,205,200 bytes (0.15% more). Running-step reductions are 15,220,225 and 15,201,491; allocation is 221,262,040 and 220,417,096 bytes. No meaningful first-paint or ordinary-control work regression was observed.

Fixture RSS overlaps: web completed-answer observations span 86.8–99.2 MiB before and 87.5–95.7 MiB after; gateway observations span 79.6–85.0 and 80.8–84.7 MiB. These observations do not establish a retained-memory or live RSS reduction. The demonstrated memory improvement is reduced allocation churn.

## Mechanism and correctness

The reasoning block is one memo leaf. Source-derived line counts, expansion, Markdown previews and bodies are computed only on a miss. Its keys retain source block, held body, elapsed time, fold controls, session and the relevant newest-row handoff. Its descendants draw directly because Lustre drops nested memo cache entries after a parent hit. Ordinary rows keep their existing leaves.

The gateway returns the existing attribution cache and an empty list when the entry-head cut is empty. No branch can be claimed in that case. Nonempty branch attribution and all operation/result register reads keep their original order. A broader batch-read design was discarded after identifying a reachable high-water race; no new snapshot/fence/cache machinery was introduced.

Synthetic initial HTML is identical after removing Lustre memo bookkeeping comments, and unchanged patches remain two bytes. Regressions cover consecutive memo reuse, changed source/body/time, escaped text and newest-row handoff. Gateway regressions cover read counts, nonempty entry attribution and once-only terminal delivery. The new stored-reasoning regression fails on baseline because it observes sixteen unexpected trims; the idle-read regression fails on baseline because it observes a strand-leaf read.

## Validation and limits

Independent Astra review found no actionable correctness, simplification or same-shape issue in the affected implementation, tests and benchmark scripts. Full web-view tests passed all 1,330 cases. Affected package lint passes. All 203 gateway-focused client tests passed, including the three new regressions. Their initial linked-process teardown cancellation was fixed by unlinking immediately before intentional cleanup; the independent reviewer verified that links remain active during execution. A full client gate remains incomplete: its first attempt exposed missing fixture prerequisites, and preparing the code-mode seed exposes a compile error in untouched ext/internal/live_runtime.gleam on main. The failed seed build is not reported as a passing end-to-end gate.

The global documentation gate reports exactly the same 83 errors on pristine main and the candidate, after updating the three gateway citations shifted by this patch. They are existing symbol/line drift, mainly from earlier terminal formatting changes. No documentation gate waiver or disabled assertion was added.

The web asset body is unchanged; its generated source digest was rebuilt. Three pre-existing formatter-rejected blank lines in ui_socket/evolution control were removed so the client gate can reach tests. The daemon was not restarted or modified, so installed CPU/RSS savings remain unmeasured.

## Reproduction

Build packages/web_view and packages/client in each checkout. Run the candidate scripts against each built tree, alternating order:

```sh
bash scripts/web_view_perf.sh /path/to/baseline before answers
bash scripts/web_view_perf.sh /path/to/candidate after answers
bash scripts/web_view_perf.sh /path/to/baseline before reasoning
bash scripts/web_view_perf.sh /path/to/candidate after reasoning
bash scripts/web_view_perf.sh /path/to/baseline before siblings
bash scripts/web_view_perf.sh /path/to/candidate after siblings
bash scripts/gateway_read_perf.sh /path/to/baseline before /path/to/candidate/packages/client/build/dev/erlang/client/ebin/client@gateway_read_fixture.beam
bash scripts/gateway_read_perf.sh /path/to/candidate after
```

Raw local artifacts are under /private/tmp/loom-profile-20261024, /private/tmp/loom-web-final-*, /private/tmp/loom-gateway-clean-* and /private/tmp/loom-web-sqlite-*. They contain synthetic fixture output and observation metadata, not credential contents.
