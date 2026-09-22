# Async collaboration follow-up review

The reviewed delta extends `0bb8233e0c29692f73a6cc41323bf6b43c58aa10` on
`feature/async-collaboration`. It adds structured peer origins, input readiness,
typed endpoints, intermediate progress, idle expiry and cumulative launch
limits. The review included the working tree and new tests, not only committed
files. It was a read-only pass; the coordinator owns validation.

## Finding and disposition

The idle-expiry regression originally checked an idle response and subsequent
input refusal, then stopped the service. That could hide a worker which had
never been cancelled. The test now observes the original broker-step abort,
monitors the worker, waits for its durable `Lost("execution idle timeout")`
outcome, and asserts worker exit before service teardown.

The revised host suite passed all six tests. A temporary mutation removing the
service's three `weft.cancel(held.cancel)` calls compiled, then failed the idle
regression: the observed phase stayed `Draining` instead of becoming `Lost`.
The source was restored immediately. An earlier mutation replacing the calls
with standalone `Nil` failed compilation with unused-literal warnings and was
not counted as regression evidence.

The pass found no confirmed production correctness or authority defect.
It verified that peer origins survive codec and provider projection, typed
endpoint decoders precede callbacks, readiness remains immutable, progress is
bounded and volatile, and cumulative launch counts recover from durable records.

## Boundaries retained

The input service reads an externally written operation-abort fence before
appending data, but those two actions do not share a transaction. A racing
abort can therefore leave one additional bounded input value. That value
confers no broker or child-admission authority; those boundaries retain their
own fences. The review did not justify new transaction machinery for this case.
Service-local cancellation and send are serialized by the execution actor.

Idle expiry is checked at input receive boundaries. The original wall deadline
bounds callbacks and work between receives. Delivery status reports a program
callback outcome, not independent proof that an actor completed its work.
`Exclusive` governs the tool invocation; admitted background executions can
overlap later calls with distinct broker steps.

The real jailed async selection passed all 13 tests with no skips, including
typed actor state, malformed input rejection, progress and idle reaping, and
named child workflows. The package and full-gate results at the final committed
head are recorded in [the handoff](../next.md). These local results do not
substitute for hosted platform checks.

## Full-gate corrections

The first full client run exposed a provenance fixture error: the `Hangs`
provider never reaches the boundary which places queued steering input into
conversation history. The busy-peer assertion now reads the durable
`PendingEntry`, decodes it with the machine codec and verifies the peer origin
and message-codec round trip. The wake-path test retains the placed-entry
assertion. The corrected peer selection passed all 11 tests.

The gate also reproduced the prior Linux CI failure in
`layer_cleanup_uses_one_deadline_for_failed_starters_test`: 517 ms locally
against an unchanged 500 ms ceiling. Inspection found that each parallel MCP
retirement collector received a fresh relative timeout when it started.
`close_clients` now fixes a monotonic cutoff before issuing stops and gives
collectors only the remaining budget. The outer collection margin is unchanged.
This correction did not resolve the full-suite failure: three focused runs
passed, but the next client run still measured 519 ms.

A probe inside one sequential EUnit invocation identified the actual suite
contamination. The runner mailbox held 1,897 messages before `goalcheck_test`
and 1,001,799 after it. The never-free-slot fixture had preloaded one million
refusal tokens into that shared mailbox and consumed only a small fraction.
Subsequent tests scanned the remaining tokens on every selective receive.
Fresh EUnit invocations for individual modules hid the problem.

The permanent-refusal fixture now returns `OutstandingCapReached` directly on
every clearance attempt. The finite three-refusal fixture retains its countdown.
The original unfinished-result and repeated-attempt assertions remain in place,
as does MCP's 500 ms ceiling. An earlier advisor-teardown experiment did not
reduce the measured process count and was reverted; no unrelated lifecycle
change remains in the patch.

The unchanged MCP deadline regression took 118 ms in the corrected full client
run. Before the fixture correction, tracing showed all eight collectors
returning around 101 ms while the contaminated caller returned at 449 ms.
The final package-gate exit status is recorded in the handoff. The ancillary
source and fixture changes received a separate narrow review with no actionable
findings. The shared cutoff limits collector wait allowances; it cannot promise
a total return latency under arbitrary scheduler pressure.
