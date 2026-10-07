# Live render optimization, October 6, 2026

Pickglass attributed substantial cumulative allocation to tool-step bodies
and settled reasoning previews in the running daemon. In this pass, we move
refusal preparation behind the failed-step branch and blankness checking into
the preview's existing leaf memo. Three regressions fail against the baseline
and pass with the narrower work boundaries. This is a source-level CPU and
allocation result; the candidate has not been installed.

## Remeasurement after rebase

PR [#903](https://github.com/Roasbeef/loom/pull/903) is out of draft at the
owner's direction. The branch was rebased onto
`3644b079059570cf7cc3c7fe98add693bb6adbcc`, including the restricted signoff
driver in #902. This section records the new source and measurements;
the following original-pass sections retain their earlier source identities
and validation snapshots.

A separate, clean repository-local checkout compiled that exact main revision.
The controls below are newly compiled from it; the earlier saved BEAM modules
were not reused. Candidate dependencies come from the rebased checkout using
Gleam 1.19.0 and OTP 29.0.5. Control and candidate alternate twice in disposable
single-scheduler VMs. Builds finished before measurement. Timing and reductions
are untraced, followed by a separate allocation pass. These remain synthetic
source fixtures; no candidate application was installed or restarted.

The rebased rendering implementation is `cc1f2e3ee`; generated stylesheet
sources were rebuilt with `make gen-client`, committed at `1f2fbaaca`.
All 866 current web-view tests pass, including the upstream reasoning-row
changes. Each of the three work regressions fails against newly compiled
main modules. The source review named in the snapshot CPU report found no
actionable issue and ran thirty concurrent render regressions.

| 100 unchanged renders | Control reductions | Candidate reductions | Control allocated words | Candidate allocated words |
| --- | ---: | ---: | ---: | ---: |
| Done | 28,771,286 | 8,454 | 88,522,625 | 12,619 |
| Pending | 28,770,977 | 8,164 | 88,522,652 | 12,619 |
| Failed | 57,719,231 | 57,718,101 | 177,068,702 | 177,068,744 |
| Settled reasoning | 28,804,244 | 72,218 | 88,631,219 | 122,119 |
| Blank reasoning | 3,766,903 | 72,225 | 132,319 | 122,119 |

Both repetitions reproduce each reduction and allocation count exactly.
Done/Pending remove about 99.97% of reductions, settled reasoning 99.75%,
and blank reasoning 98.08%. Failed rendering performs the same work within
counter overhead. Output fingerprints match for Done, Pending, Failed and
nonblank reasoning. Blank output retains the previously documented invisible
20-byte memo placeholder; the blank/text transition regressions pass.
The fixture keeps settled reasoning text unchanged; upstream work that changes
that text must invalidate the memo, as covered by the current tests.

The private fresh control is `rebase-control-ebin/`, and raw repetitions are
`render-{control,candidate}-rebase-{1,2}.log`, under
`/private/tmp/loom-live-20261006/`. The original-pass sections below retain the
live attribution and earlier local gate limitations. Fresh exact-head hosted
checks and Linux signoff are pending at this publication snapshot; follow
PR #903 for their final verdicts.

The fresh full local affected wrapper returns make status 2
(underlying 124) in 112 seconds. Static checks and a 64-second fresh server
preparation pass; the unchanged 20-second aggregate Python-suite deadline
expires before package tests. Its clean census saw no package skips and does
not certify those tests. The named reproduction and stack dump reach upstream
`test_signoff_gate` fixtures. This Mac has no `flock`; the gate waits repeatedly
when that command is absent. A separate 120-second diagnostic reaches per-test
30-second lock timeouts and was stopped with status 143. No repository deadline
or test was changed. These new Linux gate fixtures must run on Linux.

Installed CPU and RSS savings remain unmeasured.

## Identities and measurement boundaries

The source control is `cc9ec305da544c45609c959ed933d797930cac16`.
The implementation is `669a8274e`, followed by the generated stylesheet
digest commit `b6f0a54e`. Work is isolated on
`codex/perf-live-render-20261006`; the original checkout was left untouched.

The daemon is PID 53549 in `~/.local/lib/loom/server.bRY4moOX`. The active
terminal is PID 67235 in `~/.local/lib/loom/client.CfFYJjsd`. Both release
launchers embed `11454cba77ca96acc6b3be85f1da72ba469dd976`, confirmed by the
terminal's version command. Their runtime is OTP 29, ERTS 17.0.5, ARM64 JIT.
The daemon exposes 16 schedulers; the terminal launcher selects four.
Pickglass's capture does not discover this build revision, so the launcher
identity is separate evidence, not a populated capture provenance field.

The installed revision predates the previous render optimization. The
editor memo, refusal-counter regression, and final source comparison from
[the October 5 investigation](beam-cpu-2026-10-05.md) are absent from its
ancestry. [PR #873](https://github.com/Roasbeef/loom/pull/873) has merged at
`bf4334140911296e3f393482f8d5c5c7c454e764`. Repeated completion-table work in
this live profile therefore does not establish a defect in that merged memo.

No application was restarted, hotpatched, or forced through collection.
Pickglass's bounded agent attachment and allocation instrumentation were
used under the owner's profiling request. No state, dictionaries, mailbox
contents, credentials, or conversation text were printed. The terminal's
node is unnamed and cannot accept a distributed Pickglass attachment;
native sampling supplies only partial client evidence.

## Live observations

A ten-second Pickglass stack probe pinned the eight busiest listed processes.
It achieved 99 Hz, counted 742 running/runnable samples out of 6,894 total,
and reported two target exits. `string:trim_t/3` appeared in 42.8% of counted
stacks; caller stacks reached the step-body preparation, reasoning preview,
and completion table. These are shares of reduction-safe-point samples,
not shares of CPU time. Native calls and long BIFs/NIFs are under-sampled.

A separate allocation probe selected four busy processes and matched
`web_view*`, `session_view*`, and `core@json`. Its requested window was five
seconds and its observed window was 5.22 seconds. All 1,265 called functions
had allocation readings. The displayed list was truncated to the largest
200 functions; the aggregate covered all functions read.

| Function | Calls | Allocated words | Allocated bytes |
| --- | ---: | ---: | ---: |
| `web_view@view@fold_row:step_body/4` | 19,999 | 121,627,327 | 973,018,616 |
| `web_view@view@lane:preview/1` | 827 | 63,484,237 | 507,873,896 |
| All matched functions read | | 327,742,371 | 2,621,938,968 |

Words are cumulative process-heap allocation, at eight bytes per word.
They exclude off-heap binary payload, ETS and native allocations. Traced
functions exclude their traced callees' words and include untraced callees.
The two highlighted functions account for 56.5% of the matched allocation,
but that is not a prediction that the candidate removes 56.5% of live work:
failed steps still need their refusal text, and the workload changes.

Two unforced census cuts show why live memory needs a matched workload:

| Counter | Initial | Later |
| --- | ---: | ---: |
| VM allocated total | 267.43 MiB | 294.62 MiB |
| Process allocated capacity | 197.22 MiB | 213.67 MiB |
| VM binary allocation | 26.24 MiB | 36.99 MiB |
| OS RSS | 280.22 MiB | 349.33 MiB |
| Process count | 448 | 411 |

These cuts observed the same installed build during different activity, with
no candidate deployment. They establish neither a leak nor an improvement.
The process-detail capture lists only 200 processes. Its largest initial
session actor held 14.66 MB of allocated capacity; four static supervisors
each held about 5.2 MB. Neither figure is exclusive reachable-state size.
The later native daemon sample reported 367.8M physical footprint and 404.5M
peak; the terminal sample reported 60.9M and 69.8M. Native footprint, RSS,
VM categories and process capacity are distinct counters.

## Changes and preserved behavior

`fold_row.step_body` now dispatches on standing first. Done and Pending
keep the original rows, in order, through their existing line memos. Failed
retains the same refusal partition, whitespace rules, sentence, escaping,
and fallback when no refusal text exists. Previously every standing joined
and trimmed its result rows before the successful/pending branches discarded
that assembled text.

`lane.preview` checks blankness inside its existing memo, whose dependency
is still the complete text. Unchanged renders avoid both trimming and Markdown
construction. The body retains its separate line memos; no enclosing memo
can drop their cache entries. Whitespace-only text produces an empty memo
placeholder instead of an empty child list. It has no handler and no visible
preview, but adds 20 bytes of Lustre bookkeeping in the synthetic serialized
HTML. The blank/nonblank transitions are tested through the real patch cache.

Only the two source digests changed in the regenerated stylesheet. Its body
and the existing client bundle are unchanged. No public interface, type,
message, dependency, authorization rule, or session custody changed.

## Alternating control and candidate

Both sides use the same Gleam 1.19.0 and OTP 29 toolchain and compiled
dependencies. Fresh single-scheduler VMs alternated control, candidate,
control, candidate. The control overlays only the two original view modules
from the pinned baseline; the candidate uses the changed modules. Each
workload carries Lustre's real cache through 100 unchanged renders after
warmup. Timing and reductions are untraced; allocation is a separate pass.

Tool and nonblank reasoning text contain a 120 KiB repeated-word body plus
a short Markdown prefix. The blank fixture is 12 KiB of space/tab/newline.
These intentionally expose the large-text scan; they are not a typical-turn
forecast. Reductions and words repeated exactly across the two runs.

| Workload | Control reductions | Candidate reductions | Control words | Candidate words |
| --- | ---: | ---: | ---: | ---: |
| Done step | 28,770,597 | 8,452 | 88,522,628 | 12,619 |
| Pending step | 28,770,644 | 8,164 | 88,522,631 | 12,619 |
| Failed step | 57,717,581 | 57,717,284 | 177,068,714 | 177,068,669 |
| Settled reasoning digest | 28,798,744 | 71,953 | 88,631,219 | 122,119 |
| Blank reasoning digest | 3,766,780 | 71,916 | 132,319 | 122,119 |

Done/Pending remove about 99.97% of reductions and 99.986% of words in this
fixture. Nonblank reasoning removes 99.75% and 99.862%. The Failed control
is effectively unchanged. Complete serialized HTML hashes match for Done,
Pending, Failed and nonblank reasoning. Blank serialization has the stated
empty-placeholder difference, with no visible preview. Elapsed times vary
with desktop load, so the comparison claim rests on reductions and words.

## Validation and remaining gates

All three new tests fail against the original modules on unexpected trim
calls (two rather than zero). The changed modules pass them, including Unicode
whitespace, repeated unchanged cache hits, changed escaped Markdown, and both
successful and pending row preservation. Existing failed-step and hostile-text
regressions remain in the suite.

The complete web-view suite passed all 811 tests sequentially and with
parallelism eight. The other runners report 265 web-client, 47 focused client
UI-socket, 2,945 full client and 97 conformance passes. The generated-asset
gate and prelude-check passed. House lint returned zero errors and 2,175
warnings; the final doc-check returned zero errors and 196 warnings. Changed
Gleam files pass formatting. Each command's own exit status was captured.

Those earlier direct client runs skipped shipped-server fixtures because
`LOOM_BOOTSTRAP_E2E_SERVER` was unset. The earlier conformance run skipped LSP
end-to-end fixtures because the worktree then had no code-mode seed. No test,
assertion, fixture requirement, or skip condition was changed. These runs
do not establish shipped-release or seeded code-mode validation.

A single independent report-only review found no actionable issue. It also
ran 70 repeated regression executions concurrently and verified that an
exception from the profiling callback leaves the trace-session inventory
unchanged. The nearby eager trim in `more_of` was dismissed for this production
path: `turns.prose` changes assistant thinking to ReasoningDigest, bypassing
the raw-reasoning arms that call it. No speculative variant patch was added.

The earlier formatter diagnosis was wrong. A login shell resolves
`/opt/homebrew/bin/gleam`, version 1.18.1, while the inherited non-login path
resolves the installed Loom bundle's compiler, version 1.19.0. CI pins 1.19.0.
The nine-file package failure and 119-file census came from the older
formatter; they do not establish drift under the repository's pinned compiler.
An explicit 1.19.0 whole-tree format check returns zero without source edits.
The private formatter-only patch has not been applied and is unnecessary.

The first complete affected run used the pinned compiler, a real server
shipment and code-mode seed. Static checks, the fast package lane and
conformance passed. Client reported 2,944 passes and one failure in
`sqlite_read_timeout_poison_stops_original_incarnation_without_self_wait_test`.
The skip census also failed despite two matching declarations already being
present. The wrapper returned a nonzero status after 606 seconds.

The census failure was a pipe ordering defect. Under `pipefail`, the quiet
matching grep closed its input early and the producing grep exited on SIGPIPE
with status 141. Consuming the matching stream instead preserves the existing
declarations. The owner approved this separate CI repair, committed at
`1f0c7c6e5`; no declaration changed. Its permitted-long-log and
undeclared-skip regressions both fail against the original runner. All 18
selector/runner tests pass with the fix, as does shell syntax checking. A
separate report-only review found no actionable issue.

The prepared full client rerun again reports 2,944 passes and the same
failure. The gateway, manager and regression are unchanged against the pinned
baseline. The assertion receives `Error(Nil)` while waiting for the callback's
admission report; it does not observe the expected `Stopping` status. Both
gateway regressions pass in a focused run with the same fixture environment.
A bounded trace in a disposable focused-test VM observes the five-second
reader timeout, then `Stopping`, then gateway shutdown. That passing trace
does not establish why the full-suite run fails. Running the immediate
predecessor module before the regression also passes, so that two-module
sequence is insufficient to reproduce it. No assertion, timeout or
test requirement has been weakened.

The same regression passes in the full repository run after the CI repair.
The observed full runs therefore establish intermittent behavior, while its
cause remains unresolved. The passing run does not erase the two earlier
failures or establish that the CI pipe repair changed gateway behavior.

The added CI scope selects every package through the full repository check
and requires Linux signoff. The complete local affected wrapper returned
nonzero after 1,029 seconds. All Gleam and JavaScript suites passed, including
2,945 client tests, 1,241 TUI tests and 97 seeded conformance tests. The Go
sandbox gate failed because the inherited path selected Codex's app-private
`rg`; its Seatbelt fixture deliberately grants Homebrew's location. A package
gate rerun with Homebrew first returned zero without changing source.

The skip census now correctly preserves both existing Darwin declarations.
It still refuses two additional markers from the newly selected broker suite:
`real_helper_kill_ordering` and `real_helper_witnessed_kill`, whose evidence
reader requires Linux `/proc`. These tests and the declaration file are
unchanged against the pinned baseline. All package gates therefore have a
passing local result, but the complete affected wrapper remains red. No skip
declaration was added to make that result green. Candidate hosted checks and
Linux signoff remain unperformed.

Use a non-login shell with
`PATH=/Users/roasbeef/.local/lib/loom/server/bin:/opt/homebrew/bin:$PATH`:
this selects both CI-pinned Gleam 1.19.0 and the sandbox fixture's Homebrew
tools. The wrapper log is
`/private/tmp/loom-live-20261006-affected-full.log`; its package and census
logs are in this worktree's `build/affected/`. The successful sandbox rerun is
`/private/tmp/loom-live-20261006-sandbox-path-rerun.log`.

## Continued memory observation

A new unforced Pickglass census on the same daemon records 264,257,263 bytes
of VM allocation, including 180,860,344 process bytes and 37,334,896 binary
bytes, across 395 processes. A nearby OS sample reports 326,944 KiB RSS.
Daemon and active-client CPU were about 0.3% and 0.1% in that sample. This is
a quieter workload, not a before/after candidate comparison.

The final CLI capture records 264,516,815 total bytes, 184,369,744 process
bytes and 34,047,928 binary bytes, again across 395 processes. It observes the
same installed revision and does not measure candidate savings.

Pickglass's live Memory page adds allocator evidence absent from the one-shot
capture. At one displayed cut, heap carriers hold 212 MiB of capacity with
178 MiB used and 33.8 MiB unused. Binary carriers hold 53.5 MiB with 27.3 MiB
used and 26.2 MiB unused; their pool holds another 19.7 MiB with 4.89 MiB used
and 14.8 MiB unused. The Overview shows 337 MiB of carrier capacity against
255 MiB of VM allocation and 309 MiB RSS. These are rounded observations at
different instants: reserved carrier capacity can exceed resident pages.
Neither the unused capacity nor the derived gaps establish a leak or promise
an equal RSS reduction. ETS metadata covers all 55 tables and about 1.50 MiB
of table storage; no table contents were read.

The largest listed page socket has about 13.9 MiB of allocated process
capacity. Another page socket's unlabelled child varies from about 7.28 MiB
to 3.94 MiB without forced collection. Bounded metadata identifies that parent
edge and shows its old heap becoming empty in a later cut. This supports
ordinary allocation and collection churn; it does not measure every retained
root or establish a socket's exclusively reachable size.

A ten-second, 100 Hz profile of that child completed with 1,000 samples,
only six running/runnable and 994 waiting. Its observed leaf frames include
string trimming, Unicode grapheme scanning, keyed-child extraction and JSON
parsing. Six samples are insufficient evidence for a new optimization. The
profile was exported, and the viewer was detached: its agent modules, pins
and probes were removed from the target. Remaining probes use the CLI.

## Evidence and next experiment

Private raw files are `/private/tmp/loom-live-20261006-initial.pgcap`,
`loom-live-20261006-final.pgcap`, `loom-live-20261006-daemon.speedscope.json`,
`loom-live-20261006-daemon-allocation.txt`, the daemon/client native samples,
and the focused/full/parallel test and lint logs sharing that prefix.
`/private/tmp/loom-live-20261006/` contains the synthetic runner,
original-module control, alternating performance logs and formatter-only patch.

Obtain required Linux signoff and resolve the Darwin full-scope skip census
before claiming readiness. Preserve the intermittent gateway-test evidence
as an unresolved validation limit. Shipment of the
merged previous fixes and this candidate is a separate operational transition.
Reopen a terminal with profiling enabled for direct client attribution, and
compare the same active, idle and released workload before and after installation.
Installed candidate RSS and physical footprint remain unmeasured. SQLite
bursts and retained registry ownership remain outside this source fix.
