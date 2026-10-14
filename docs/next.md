# Current handoff

Baselined October 13, 2026 against `c37d9a892` on `fix/strand-tps`,
with main through `c47175004` integrated.
This edition covers per-strand generation timing. The installed daemon has
not been updated. Rewrite this file when the next body of work finishes.

The previous edition covered web history browsing and reported gates for its
own head. Those results do not validate this branch. Its evidence and open
history decisions remain in the
[prior handoff](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
The project-wide plan remains `docs/issue-plan.md`.

Main also includes the register-decode cache from merged PR #972. Its exact
blob keys, bounded store-owned inventory and corruption/lease regressions live
in the storage package. The [measurement report](review/register-decoding-2026-10-12.md)
records its performance evidence and limits. Its complete prior handoff and
live memory follow-ups remain in the
[register-decoding handoff](https://github.com/Roasbeef/loom/blob/e86d6fddd/docs/next.md).
Those branch results are historical evidence, not validation of this combined
head. No storage source conflict occurred during integration.

Main also includes the Responses validation diagnostics and deployment CI
correction from merged PR #979. Provider acceptance predicates and redaction
bounds remain as reviewed in that work; its diagnostic limits and provider-error
follow-ups are preserved in the
[Responses handoff](https://github.com/Roasbeef/loom/blob/c47175004/docs/next.md)
and `packages/provider/README.md`. The deployment-status fixture now executes
in the delegated Linux jail job with no skip allowance. This branch keeps main's
CI repair exactly once rather than duplicating the independently landed fix.
No provider or runtime source required manual conflict resolution.

## Where the tree is

The terminal and web view now share `session_view/generation_rate.State`,
a session-scoped ledger indexed by strand. Every observed strand owns its
request clock and last measured output rate, including background agents.
The header reads the selected strand through `session_view/model` accessors.
Switching focus neither clears a running clock nor borrows the parent's rate.

Live phase events and fresh coherent captures update the ledger. Captures
observe phases after transcript stream retirement, and reprojecting an older
capture on focus does not observe its phases again. Request identity survives
the active-only stream projection, so a lagging capture cannot turn a partial
background window into a complete measurement. Settlement consumes only its
strand's clock. Roster replacement prunes removed strands; a session change
clears the ledger.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**A partial observation cannot measure full-request TPS.** A client joining an
already running generation cannot know its original start from the current
wire data. The ledger can show elapsed observation time, but retains that
strand's previous complete rate, or no rate if none exists. The rule lives in
`generation_rate` and its regression tests. No protocol extension was added.

**Focus selects timing; it does not own timing.** The ledger belongs to the
shared session state. Both hosts use the same strand-specific accessors.

## How to verify

`make check-affected` selects the gates affected by the current diff against
main, together with the static gates and native prerequisites.
Full Linux signoff remains required for the combined head. Run `make signoff-remote` against the pushed head; the PR's exact-head
commit statuses are the record of hosted checks and Linux signoff.

`packages/web_view/test/strand_rate_test.gleam` drives the actual component and
header with an injected clock. It covers independent parent/child rates,
switching back, focusing a background generation midway through it, attaching
mid-generation, consecutive requests, and lagging captures. The shared ledger
suite checks clock consumption, new request identity and roster removal.

Mutation checks restored three old behaviors separately: reading main's rate
for every strand, resetting a clock on focus, and accepting a lagging background
phase. Each compiled and failed its corresponding header assertion. The
independent review's capture-ordering findings were fixed and rechecked.

**Read a gate's own exit code.** `check-affected` records each lane's status and
its skip census under `build/affected`. Native socket tests need the host's
normal permissions. Preparation must finish before package lanes start.
`docs/execution.md` carries the remaining gate and sandbox hazards.

## What to do next

1. Per-strand TPS PR #982 is merged in `99975fe00`. Land helper retirement
   #975, then retarget concurrent helpers #978 to main after their exact-head
   checks and independent reviews pass. Deployment remains separate.
2. Follow `docs/issue-plan.md` for the next project milestone. The queue-control
   PR is separate work and is not included in this branch.

## Deliberately open

An exact TPS for a request already running before attachment would require an
original start timestamp or duration from the server. The current client
conservatively leaves that request unmeasured. None of this is unfinished work
somebody forgot.

## Concurrent helper integration checkpoint

Baselined October 13, 2026 on `codex/helper-concurrency`, starting from
`b28dd654e2cb05a5f05257ea149cddfc91ebfadb` on the open idle-retirement
[PR #975](https://github.com/Roasbeef/loom/pull/975). This is a separate,
stacked concurrency change. Current integration also includes main `e86d6fddd` (merged register decoding
#972) through the updated #975 branch; historical benchmarks retain their
original source and binary hashes.
The installed daemon remains untouched; no merge, installation, restart or
recurring automation was performed. The broader project plan remains
`docs/issue-plan.md`.

## Concurrent executions per native helper

The user explicitly requested a working concurrency implementation in a
separate PR. [Proposal 087](../protocol-change/087-concurrent-helper-executions.md)
records the protocol-4 wire changes, capacity semantics and shared failure
domain. Broker and helper must be rebuilt together. Capability-channel
cancellation keeps its existing encoding.

One Go helper and one BEAM owner carry at most four concurrent jailed
executions. Each checkout receives a registered single-use lease; stale
handles cannot dispatch, cancel or return another borrower's capacity. Each
execution has independent stdin, output and cancellation deadlines. The
configured pool size still bounds execution slots, including all quota held
by draining or unconfirmed helpers. A shared helper failure settles every
accepted sibling once. Idle retirement starts only when the last lease returns,
and still requires native exit plus the original normal owner-exit witness.

Stdin admission refuses overflow without blocking sibling controls and cancels
only the overflowing target. Four bounded native workers reserve custody before
acquisition, then independently start, settle, clean up and report. Early stdin
and EOF transfer in order; early cancellation reaches the real jail after
acquisition. Reporting writes hold no registry mutex, and shutdown joins starting
workers too. Darwin trackers take fresh snapshots under a process-local capture
mutex, which bounds overlapping large buffers without sharing stale snapshots.

## Evidence and gates

The [startup follow-up](review/helper-startup-2026-10-13.md) supersedes the
original report's batch slowdown for the final implementation. Three rotated
production comparisons against complete separate-helper and frozen #978 stacks
measure four-slot batches at 21.055 / 24.883 / 21.056 ms and eight-slot batches
at 24.831 / 27.909 / 23.343 ms. Final batches improve 15.38% / 16.36% against
frozen multiplexing, and match / improve 5.99% against separate helpers.

Summed helper RSS remains 69.59% / 68.72% lower than separate helpers, saving
36.50 / 73.36 MiB. Eight-slot RSS is 2.72 MiB above frozen multiplexing; the
report records this cost and the intermediate memory regression that led to
the capture bound. These isolated local fixtures do not establish installed
application memory savings, total CPU savings, Linux latency or end-to-end
distributed RPC latency. Both workspace planes share the changed helper pool.

Independent review found no reachable correctness issue in startup custody,
pending input/cancellation transfer, reporting admission, capture lock ordering,
freshness or ledger isolation. Deterministic private mutations fail the new
capacity, ordered-input and held-terminal regressions. Fresh native race and
full repository gates passed exit 0. The full gate's first run had one fake-LSP
cancellation timeout outside the native path; all 17 focused observation tests
and the unchanged full rerun passed. Its cause remains unclassified, with both
logs preserved in the follow-up report.

[PR #978](https://github.com/Roasbeef/loom/pull/978) targets
`codex/helper-idle-retirement` while #975 remains open. The original hosted run
exposed two concrete Linux failures: an untargeted protocol-4 stdin fixture and
a registry mutex held over terminal I/O. Both are fixed with regression coverage.
Its macOS e2e job failed fetching the Hex pc plugin before assertions, with DNS
failure during artifact upload. Run 38493712617 reported successful substantive
job conclusions on `03cac66db`, then its Linux
aggregate rejected an undeclared deployment-status enforcement skip. The CI-only
fix from #979 now pairs the ordinary-runner declaration with strict execution
in the delegated Linux jail lane. Real local deployment, census controls and
independent review pass. Inspecting the advisory log also found a linked test
peer that recursed after reporting shutdown, later cancelling the broker group.
It now returns normally, and all four multiplex tests require its original
normal-exit monitor witness. A compiled old-recursion mutant fails that witness;
focused tests and independent review pass. The fresh full gate passed exit 0
on an unchanged rerun after one unrelated web-operator deadline failure; focused
reproduction passed and the cause remains unclassified. Fresh hosted checks
remain a separate gate for the updated workflow head. The owner authorized landing #975 first, then retargeting and merging #978
on main after exact-head green checks and sufficient review. No deployment
or daemon restart is authorized.

## Follow-ups

Repeated register decoding
[PR #972](https://github.com/Roasbeef/loom/pull/972) is now merged on main and
included through integration. Its report remains separate evidence. Prior
busy-period sampling found JSON parsing prominent, but stack-sample shares are
not CPU-time percentages. Re-profile the installed system after an explicitly
requested upgrade before attributing production memory or CPU savings to either
optimization. Further tuning of concurrency should compare short-command
throughput against its memory savings and retain the existing slot ceiling and
retirement custody guarantees.

A separate session timing investigation confirmed that independent log fetches
were written with sequential `gleam/list.map` around blocking `cap/proc.run`.
Their start offsets tracked the preceding command durations. That is program
sequencing; existing `cap/task.parallel_map` can express independent fetches
concurrently. Helper multiplexing does not automatically parallelize sequential
Gleam programs.

## Main integration checkpoint

The updated idle-retirement branch integrates main `e86d6fddd` and the strict
deployment CI correction. Merging it here conflicted only in this handoff;
production helper concurrency code merged unchanged. Fresh local gates and
independent integration review must precede publication. Hosted run 38498413979
on superseded `c9781b6ac` proved the strict delegated deployment fixture and
passed the Linux aggregate, but its advisory macOS underlying web-view delivery
assertion failed despite a green job conclusion. Focused unchanged reproduction
passed; cause remains unclassified. Fresh hosted checks on the integrated head
must complete both hard gates and underlying advisory tests before landing.

The final published #975 integration is `450ad56e2`, with a passing full local
gate and independent review. This merge also carries its validation report;
production source remains identical to the earlier integration. #975 must pass
fresh hosted CI and merge before #978 is retargeted to main.

The integrated LSP fixture now establishes the server/document before its
unchanged 150-ms cancellation budget and explicitly requires the positioned
reference to arrive. Focused module tests and independent review pass. This
branch also carries #975's reviewed provider admission and advisory scheduling
fixes; fresh complete local and hosted checks remain the landing gates.

The real-server full gate passed exit 0 through integration `2e712451f`, using
the same eight-way mode/environment as advisory CI. The current-main Responses
integration is checked separately and fresh hosted results must attest to the
final published head. Log: `/private/tmp/pr978-final-real-server-full-check.log`.

Current #975 head `53fec5003` also integrates main `c47175004` (#979). Merging
it here conflicts only in this handoff. Provider/runtime match main, while
concurrency production code and reviewed fixture corrections are unchanged.
The entered provider/runtime slice and fresh hosted final-head checks remain
required before landing.

The entered current-main provider/runtime slice passed exit 0. The full
real-server gate validates the unchanged concurrency/fixture implementation;
fresh hosted CI must validate the final complete publication before merging.

PR #975 now integrates main `99975fe00` through `9585ecc0e`, including
merged strand-rate PR #982. This branch incorporates that integration without
changing helper production, benchmark or corrected fixture sources. The only
conflict was this handoff, and both project and helper checkpoints are retained.
Fresh hosted CI must validate the resulting head before landing. Merge order
remains #975, then retarget #978 to main. No daemon restart is authorized.
