# Current handoff

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
