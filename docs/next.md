# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain historical measurements in their evidence
documents rather than carrying old validation forward.

Baselined October 18, 2026 against source head
`2a99a8b448c3b79fc4ebe6b5a744a5a465fd5dc6` on
`perf/daemon-resource-cost`, from `928d0ae50dfe70277512a4c05116626c7c28d942`.
The claims below were checked against this tree, local test logs, and recorded
measurements. This is a local performance handoff, not a new project-wide CI
or release audit. The local `main` ref pointed to the older `e289d93ab` when checked;
the publication base is `origin/main` at `928d0ae50`. The profiling evidence
and architecture note are committed at `de96eff4f`.

## Where the tree is

| Work | Verified state |
|---|---|
| Local daemon profiling | Memory snapshot, 10-second CPU profile, 5-second allocation trace, and a snapshot after workload completion recorded on unchanged PID 71417. |
| Call-worker copying | `c470b82a0` projects the precheck and settlement subject before constructing closures; both independent broad-capture mutations fail the regression. |
| Provider request lifetime | `2a99a8b44` confines gateway/request/time inputs to the parked phase, transferring them to the pump on begin. |
| Local validation | Code-mode 413 tests and provider 319 tests pass. Package lint has zero errors. Independent source review found no actionable findings. |
| Deployment and overall savings | No installation or restart. Daemon-wide CPU/RSS improvement has not been demonstrated. Full repository checks, hosted CI, and Linux signoff are unverified for this branch. |

The [resource report](review/daemon-resources-2026-10-18.md) contains the exact
scope, drivers, aggregate results, capture hashes, negative controls,
validation, and limits. In the 5,000-extra-ceiling synthetic fixture, worker
heap capacity falls from 372,240 to 2,728 bytes; median CPU for 50 complete
fixtures falls from 76 to 70 ms across five pairs. The zero-extra-ceiling CPU
control is unchanged at median 68 ms. In the 10,000-message provider fixture,
active guard application-state size falls from 160,219 to 146 words while the
pump and encoded body retain their required sizes. These are fixture results,
not a measured percentage reduction for the operator's daemon.

The previous edition mixed configuration, startup, distributed-runtime,
side-query, and memory-recall handoffs from several heads and CI runs. It is
preserved verbatim in [the prior snapshot](next-2026-10-18-before-resources.md).
Its historical PR, merge, CI, and signoff claims were not reverified in this
performance task and must not be read as validation or authorization for this
branch. In particular, a prior head's green run does not establish that this
head is green. No earlier measurement is replaced by a claim about the current
daemon.

## What to do next

1. PR [#1008](https://github.com/Roasbeef/loom/pull/1008) publishes the focused
   ownership changes. The owner authorized its merge once review, hosted CI,
   and strict Linux signoff are green. Rebase
   onto the chosen publication base and repeat affected gates if it advances.
   **Exit:** exact published head has the required CI and Linux evidence.
   The owner also approved a separate CI repair: the ordinary Linux runner
   declares the existing remote-depth prerequisite skip, while a dedicated
   delegated step must run that fixture with an empty skip allowance. Fixture
   assertions and prerequisite conditions are unchanged. The JSON/polling path
   has no change in this branch.
2. Obtain operator authorization for installation and a coordinated daemon
   restart, then measure a matched busy workload. **Exit:** compare CPU,
   cumulative allocation, process/binary memory, and RSS at matching request,
   concurrency, runtime, and lifecycle cuts. The current run has completed;
   comparing its old busy capture to a new idle daemon proves no optimization.
3. Investigate polling/decoding only if a new profile supports it. The trace
   attributed cumulative allocation to `read_decoded`, SQLite register reads,
   and JSON parsing, but did not establish retained memory or a leak.
   **Exit:** a bounded source path and reproducible workload establish the
   cost before another change is proposed.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Memory metrics describe different properties.** The
[BEAM review guidance](../skills/beam-memory-review/SKILL.md) and
[resource report](review/daemon-resources-2026-10-18.md) distinguish cumulative
allocation, application-state words, post-collection heap capacity, binary
ownership, and RSS. None substitutes for another.

**Request ownership follows the begin transition.** The
[effects architecture](architecture/effects.md), under stream ownership and
cancellation, assigns prepared inputs to the parked guard and active inputs
to the pump. Adoption, cancellation, terminal races, and drain remain the
guard/pump custody protocol; memory savings do not weaken them.

**Capture only what crosses the worker boundary.** The
[code-mode package account](../packages/codemode/CLAUDE.md) describes the
call-worker ownership rule. The precheck and settlement closures need their
individual capabilities, not sibling host state.

## Deliberately open

None of these is unfinished work somebody forgot.

- Matched live validation is unperformed. It requires deployment permission
  and another comparable busy workload. The after-workload snapshot shows
  natural retirement on unchanged code, not a branch improvement.
- The owner labels declared one session and two strands while the census
  showed many workers. Peak concurrency and complete worker-to-strand
  attribution are not established by those labels.
- The sampled CPU trace contains only 80 active observations and covers
  selected processes. Its safe-point method does not fully account for NIF
  work. Longer profiling of a suitable busy run may change the attribution.
- Historical project-wide follow-ups remain in the prior snapshot and their
  owning specifications/issues. Their current status is unverified here.

## How to verify

`make codemode-seed`, then `make check-codemode` and `make check-provider`
exercise the affected packages. Run `make lint-codemode lint-provider`
explicitly: a narrowed package check does not include the global lint step.
`make doc-check` checks documentation coverage/mirrors, and `git diff --check`
checks whitespace. Full `make check`, exact-head hosted CI, and strict Linux
signoff remain publication gates where required.

**Do not rebuild a package while its tests are using the build artifacts.**
An earlier run loaded an old Erlang fixture with a newly compiled Gleam test
and failed on a missing helper export. The final stable 413-test run includes
the real jailed code-mode path with no skip lines.

**Check each gate's own exit status.** Read failures and skip diagnostics in
the saved logs. A successful final `tail` or an advisory workflow badge is
not proof that a gate passed. See [execution guidance](execution.md) for the
remaining verification rules.
