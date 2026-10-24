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

## Reachable callback terms

The installed daemon's census attributes 686 MiB to processes and 234 MiB to
binaries; its three largest listed processes are static supervisors at roughly
24 to 26 MiB each. About 575 MiB of process memory lacks a declared ownership
label. These are allocation observations, not proof that a particular source
closure owns those bytes. The installed serve BEAM imports build_effects_held,
so the older tool-registry multiplication diagnosis cannot simply be applied
to this daemon.

Two new source fixes remove broad Settings captures. The hub restart callback
now captures its remote reach field directly. Evolution callbacks capture their
secret store, helper path, source session and gateway before closure construction;
native model and authority reads remain at their original call boundaries.
Prompt trials retain their required source settings.

Matched real disposable assemblies use OTP 29 and eight-byte words. The first
fixture reads its service supervisor state; the second enables the real evolution
plane, asserts its capability cell exists, and borrows the actual callback door.
The varied input is 4,096 startup-only diagnostics, already consumed by logging.
Its flattened term size is 53,248 words. Both new regressions fail for their
intended assertions against the corresponding unfixed source.

| Flattened words | Before | After |
| --- | ---: | ---: |
| Ordinary service supervisor state | 377,991 | 377,303 |
| Supervisor state with diagnostic padding | 484,487 | 377,303 |
| Ordinary evolution trace callback | 1,014 | 748 |
| Padded evolution trace callback | 54,262 | 748 |
| Ordinary whole evolution door | 51,930 | 40,586 |
| Padded whole evolution door | 1,809,114 | 93,834 |

The ordinary evolution door is 21.8% smaller by this metric. Diagnostic
amplification falls from two copies to zero in supervisor state and from
33 copies to one in the whole evolution door. The remaining copy belongs to
unchanged prompt-trial assembly. The supervisor fixture's ordinary reduction
is only 5,504 bytes, so its padding result is not a claim of a large default
footprint saving. The regressions preserve custody retirement and lease release.

erts_debug:flat_size removes sharing and counts closure environments. These
figures describe reachable terms and their flattened copy cost; they are not
physical retained heap, unique off-heap binary bytes or RSS. The live daemon
has not received either fix. An installed RSS reduction remains unmeasured.

## Second round: configuration and parked preparation

At the owner's request the loop continued from the first round at 4231f7cf2.
The paired module experiments keep the previous fixes and use the same OTP 29,
eight-byte-word host. Candidate implementation commits are 1bd9f39e9 and
7c466fead; 23acc9315 repairs references shifted by the source change.

The model-facts lookup now projects model entries before constructing its
callback. Previously it captured the complete Catalog even though lookup reads
only models. Real owned assemblies keep their Gateway and models fixed while
varying valid unused named profiles. They measure actual Runtime.effects and
also verify known-model admission, missing-model fallback, adapter identity,
orderly custody retirement and lease release.

| Unused profiles | Effects words before | Effects words after |
| --- | ---: | ---: |
| 0 | 39,231 | 39,112 |
| 64 | 48,121 | 39,112 |
| 256 | 75,001 | 39,112 |

The unused table is 1,270 words at 64 profiles and 5,110 at 256. Its previous
contribution is exactly seven times those sizes. The 256-profile fixture removes
287,112 bytes of flattened terms; the ordinary fixture removes only 952 bytes.
Neither figure is a claim about installed daemon RSS or its actual catalogue.
The regression fails for its intended size assertion on the unfixed source,
then passes after projection; all 55 focused assembly/wiring tests pass.

The private provider custodian now stores preparation and timeout in Startup
rather than the entire surface. A prepared surface's unused compatibility
request callback no longer travels into its parked worker. Legacy requests
retain their original deferred semantics, and the first provider instruction
still follows Begin. A native EUnit fixture identifies exactly the newly linked
worker, excluding the public custodian, and inspects that disposed fixture's
parked state without a production FFI bridge.

| Parked worker flattened words | Before | After |
| --- | ---: | ---: |
| Ordinary prepared surface | 113 | 101 |
| Compatibility request closure padded by 8,192 words | 8,305 | 101 |

Both new native tests pass, including deferred preparation, terminal delivery,
normal worker exit and full-subtree drain. The thirteen existing startup,
recovery and cancellation tests pass. The complete runtime package gate passes
210 tests. These are copied-term improvements for pending requests, not idle
whole-daemon retention figures. The complete client gate at 23acc9315 also
passes with exit zero: 5,317 EUnit tests in 631.16 seconds. Its prerequisite
skip diagnostics remain separate from executed acceptance. Client lint passes
with zero errors and 7,795 warnings; the runtime helper gained its explanatory
doc comment after lint identified it, then runtime lint passed.

## Fresh live metadata during the second round

The existing authenticated viewer still targets laptop@100.75.241.68, PID 1513.
A complete 692-process census showed roughly 593 MiB of process memory,
222 MiB of binary memory and 1.08 GiB RSS. Values vary with ongoing work: a
later pass showed 565 MiB of process memory and 1.03 GiB RSS. These are fresh
baseline readings, not a matched comparison against the uninstalled patch.
The largest three listed processes stayed around 26/24/24 MiB with empty
mailboxes. The largest pinned process had 21 links, a 64-byte stack and no
ownership label; its parent was <0.6937.0>. Its bounded binary-reference probe
was refused for exceeding 50,000 references. No partial byte figure was read,
and no binary contents, state, dictionary or forced GC was requested.

The viewer was subsequently closed with explicit owner approval to release the
single enrolled inspector identity for CLI use, then reopened. CLI snapshot
`daemon-loop2-before.pgcap` records 889,064,418 total bytes, 598,902,840 process
bytes and 233,485,144 binary bytes. A new 20-second, eight-process 100 Hz sample
captures 13,152 samples: 501 running/runnable and 12,651 waiting, with two targets
exiting during collection. Its selected active samples include Lustre diff and
cache work; widths remain shares of samples, not CPU time. A broad allocation
pattern was refused at the 5,000-function budget. The narrowed five-module
probe matched 625 functions and read all 189 called functions over 5.12 seconds:
3,471,823 allocated words, or 27,774,584 bytes. The stepping closure accounts for
17,119,096 of those selected bytes, while UUID formatting accounts for 722,176.
These scopes exclude other functions and native allocations. The raw CLI logs,
Speedscope JSON and capture files are under `/private/tmp/loom-profile-20261024`.
Neither capture represents an installed candidate or a matched live after run.

## Validation and limits

Independent Astra review found no actionable issue in the rendering, gateway,
callback projections, regressions and benchmark scripts. Full web-view tests
passed all 1,330 cases; all 203 gateway-focused tests passed. Both affected lints
pass. Real evolution acceptance passed both lifecycle scenarios; model scope
passed ten tests and capability handling passed twelve. All ten owned-assembly
tests and the new evolution retention regression pass without prerequisite skips.

The approved baseline repairs remove a duplicate private extension argument,
restore comment-only parity between host and satellite literal-atom walkers,
and repair 83 stale documentation citations. The seed builds, all 441 code-mode
tests including jailed satellite acceptance pass, and documentation checking
reports zero errors with 232 existing warnings. Exact-source security checks
pass all sixteen cases; no assertion, deadline or gate was weakened.

The first full client run exposed a native-transport test monitor race. Monitoring
is asynchronous, and begin releases a different process. A test-only aliveness
barrier guarantees delivery of the earlier monitor signal before release while
keeping strict normal-exit and once-only assertions. The original race reproduced
once in 2,000 parallel iterations; all 2,000 pass after the barrier, as do all six
native transport tests. The ordering guarantee is specified by
[OTP](https://www.erlang.org/doc/apps/erts/erlang.html#is_process_alive/1).

The final client package gate at implementation head 403c314d6 exits zero in
625.46 seconds with 5,316 EUnit passes, including the real native TUI drive and
both memory regressions. Source and compiled implementations were held fixed.
The log contains 57 existing prerequisite-skip diagnostics: 51 require the shipped
server fixture, four require dedicated evolution/live-upgrade acceptance flags,
one requires Linux /proc, and one requires a working rust-analyzer. Those returns
are included in EUnit's pass count and are not claimed as executed acceptance
proof. The two evolution lifecycle scenarios described above ran separately
with their flag enabled. Hosted CI and Linux signoff were not run here.
The local origin/main tracking ref has two later TLS attachment commits at
3e258a2f3; these measurements and tests retain their stated base. Current-base
integration is still required before publication or merge.

The earlier broad run loaded the unfixed serve module before a new retention
test was compiled. Its expected baseline assertion and two subsequently repaired
failures are retained in the raw log, not used as final-head evidence.

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
