# Live render optimization, October 6, 2026

Pickglass attributed substantial cumulative allocation to tool-step bodies
and settled reasoning previews in the running daemon. In this pass, we move
refusal preparation behind the failed-step branch and blankness checking into
the preview's existing leaf memo. Three regressions fail against the baseline
and pass with the narrower work boundaries. This is a source-level CPU and
allocation result; the candidate has not been installed.

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

The existing client runner skipped shipped-server fixtures because
`LOOM_BOOTSTRAP_E2E_SERVER` is unset. Conformance's existing LSP end-to-end
fixtures skipped because this worktree has no code-mode seed. No test,
assertion, fixture requirement, or skip condition was changed. These runs
do not establish shipped-release or seeded code-mode validation.

A single independent report-only review found no actionable issue. It also
ran 70 repeated regression executions concurrently and verified that an
exception from the profiling callback leaves the trace-session inventory
unchanged. The nearby eager trim in `more_of` was dismissed for this production
path: `turns.prose` changes assistant thinking to ReasoningDigest, bypassing
the raw-reasoning arms that call it. No speculative variant patch was added.

The full `make check-web_view` remains blocked: its formatter rejects nine
unchanged baseline files under the installed Gleam 1.19.0. The whole-tree
formatter census reports 119 unchanged files. A formatter-only patch was
prepared privately, and the owner was asked whether to include that separate
scope. It has not been applied. The affected selector requires fmt, lint,
doc-check, prelude-check, client-check and the web-view, web-client, client,
and conformance package gates. It reports signoff not required. Passing
focused suites is not a green affected gate or merge readiness.

## Evidence and next experiment

Private raw files are `/private/tmp/loom-live-20261006-initial.pgcap`,
`loom-live-20261006-final.pgcap`, `loom-live-20261006-daemon.speedscope.json`,
`loom-live-20261006-daemon-allocation.txt`, the daemon/client native samples,
and the focused/full/parallel test and lint logs sharing that prefix.
`/private/tmp/loom-live-20261006/` contains the synthetic runner,
original-module control, alternating performance logs and formatter-only patch.

Resolve the formatter scope before claiming the full gate. Shipment of the
merged previous fixes and this candidate is a separate operational transition.
Reopen a terminal with profiling enabled for direct client attribution, and
compare the same active, idle and released workload before and after installation.
Installed candidate RSS and physical footprint remain unmeasured. SQLite
bursts and retained registry ownership remain outside this source fix.
