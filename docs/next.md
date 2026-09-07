# Next

Read this first. This is the handoff between bodies of work: what is
implemented, what proves it, which decisions are settled, and what remains
open. Rewrite it after the next completed body of work. Git and the review
records hold the history; this file should not accumulate old status reports.

Re-baselined on 2026-09-07 against `main` at `40fc5dcb` and the
`provider/responses-api` worktree. Current merge and hosted-CI claims were
checked live. Earlier daemon and jobs measurements remain in their review
records; they were not rerun merely to refresh this handoff.

## Where the tree is

| Body of work | Current state |
|---|---|
| Single daemon and multiplayer | The stack through PR #239 is merged. One daemon restores catalogue metadata, then opens session runtimes only on explicit authorized selection. Shared state, authority, attribution, invitations, revocation, and switching have shipped fixtures. Live delivery is still client-driven reconciliation. |
| Background jobs | PRs #260, #263, #267, #266, and #269 are merged; #183 is closed. Jobs can outlive their starting tool call, while ordinary satellite teardown aborts only its own step. |
| Socket admission | PR #268 is merged. Slow admission runs after the websocket initializer, with a barrier retaining the HTTP reservation until transfer is attempted. |
| Public Responses inference | Implemented on this branch under the distinct `openai-responses` dialect, with API-key authentication and caller-owned history. Existing dialects retain their configuration and wire behavior. Verification is recorded below. |
| Codex subscription inference | Deferred under #117's explicit support gate. No subscription dialect, credential reader, helper, or refresh path ships in this change. |

### Corrections to the previous edition

The previous edition said PRs #237, #238, and #239 were unmerged and the
latest published gate was red. All three merged on September 6 into
`3ef6ea09`. Current main's [run 34099262143](https://github.com/Roasbeef/loom/actions/runs/34099262143)
completed successfully across all 15 jobs. The workflow has since split its
platform work; the earlier four-job layout is historical.

The macOS package check in that run actually passed, rather than merely
being tolerated by its advisory policy. Its client suite reported 1,402
tests in 496.50 seconds, its TUI suite reported 211 in 11.16 seconds, and
the package wrappers exited zero. The final census ran clean. These are
main's results, not verification of the Responses branch.

The current workflow conditionally runs the macOS package-artifact download
and census when the advisory check succeeds. The previous blanket statement
that every final census remained hard was therefore too broad. A green
workflow still does not, by itself, prove that an advisory step passed.

Green CI and a merged daemon stack do not close the separately filed
confinement, pressure, scheduling, approval, and joined-fault requirements.
The [closing daemon review](review/single-daemon-acceptance-closing.md) and
[mutation record](review/single-daemon-mutation-gates.md) retain the earlier
evidence and its limits. Do not repeat already-proven startup or invitation
scenarios as if they were absent.

### Responses verification

[The Responses review record](review/responses-api.md) records the independent
findings, their fixes, five mutation checks, and native gate results. All
native package suites passed across split runs: the full loop stopped on a
formatter error in the new conformance test after client and TUI passed;
the formatter-only fix and remaining package checks then passed. Final
format, prelude, documentation, lint, skip census, release build, and release
smoke passed. This is not a claim that an uninterrupted `make check` passed.

Successful live inference remains unverified: the account returned
`credit_balance_exhausted`, with transport drain confirmed. The local Actions
emulator failed before tests installing OTP 29.0.5. Hosted CI status must
be read from the PR's current commit checks, not inferred from these results.

The offline full-turn fixture uses the real provider gateway, client wiring,
runtime, and memory store. Only HTTP delivery and a trusted pure fixture tool
are substituted. It checks two requests, one tool dispatch, the exact
four-message durable chain, both usage records, encrypted reasoning replay,
and request-only credential handling. It does not prove arbitrary successful
provider output is credential-free; that remains #148.

## What to do next

The first two items are the remaining issue #117 gates. The others can be
taken independently; they are not prerequisites for public Responses.

### 1. Complete the funded public API smoke, #117

The live runner observed a provider failure and confirmed transport drain.
A bounded diagnostic established `credit_balance_exhausted`. No further paid
requests were attempted. Run the explicit capped smoke below with a funded
API account; do not treat the scripted runtime fixture as live inference.

Exit: the runner reports the exact smoke answer, `Stop`, usage, confirmed
drain, and exit zero. This acceptance criterion is still unverified.

### 2. Establish the subscription support boundary, #117

Public Responses does not spend ChatGPT subscription credits. Reopen Track B
only with documented support or explicit OpenAI confirmation for an
integration that preserves Loom's ownership of history, tools, and the agent
loop. A working private-backend request or reusable Codex authentication code
is not that evidence. [ADR-012](adr/012-responses-and-subscription-boundaries.md)
records the decision and the reopening gate.

Exit: establish the supported boundary, then record credential lifecycle,
release, cancellation, and history ownership before implementing it. Do not
add a subscription configuration stub while that decision remains open.

### 3. Close the domain-teardown admission window

An explicit open naming a domain in `DomainClosing` is refused until its
retirement witness exits. The shipped schedule fixture waits on the domain
census after `Saved` to avoid that window. Queueing the open on the closing
slot is a proposed product improvement, not an implemented guarantee.

Exit: the open waits for retirement and is admitted without caller polling;
the schedule fixture no longer needs that second barrier and still passes.

### 4. Take the contained jobs follow-ups

`client/jobtools` still translates between the jobs and tools vocabularies.
Terminal `Held` entries remain retained, and `CallFailed` loses its detailed
cause when recorded as `HelperLoss`. These are source-backed follow-up
proposals, not separately filed issues or release blockers. Decide a terminal
retention rule before changing what a later poll observes. A loss-reason
change also needs its durable codec considered.

Exit: the selected cleanup has a stated invariant, a regression, and passing
client tests and lint. Prelude cost and shared-pool starvation remain
measurement/design questions, not demonstrated failures. Live `job_output`
belongs with existing #186 and the delivery work in #240.

### 5. Complete the filed daemon follow-ups

#240 owns pushed records/deltas and ordering of concurrent submits. #245
owns the explicit memory-off observation. #247 owns adoption of the SQLite
retirement repair in the reproducible shipping graph. The other remaining
acceptance requirements are listed below.

Exit: each chosen issue has evidence for the actual shipped artifact and
its platform limitations. Do not substitute a cache patch for a dependency
release, a component test for a joined scenario, or a polling refresh for
server-pushed delivery.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**One daemon, metadata-only restart.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) requires
explicit authorized opens. Listing and preview never resume work. Legacy
import and backwards compatibility were excluded from the daemon migration.

**Provider dialects do not alias.** `openai` remains Chat Completions;
`openai-responses` is public API-key inference. A catalogue entry name is
durable provider identity, so changing an existing entry's dialect can
reinterpret stored history. Use a new entry name. ADR-012 also preserves
#189: malformed model arguments yield an in-band corrective tool result;
conflicting provider stream witnesses are corruption.

**A routine teardown does not borrow the operator's reach.** Code-mode
satellites use `broker.abort_step`, not operation-wide `broker.abort`.
Background jobs belong to sibling steps and can outlive the starting call.
ADR-005's second addendum records the two abort counters and their combined
clearance check. The shipped jobs fixture must run against a rebuilt daemon
to test this boundary.

**Socket admission owes a transfer barrier.** Admission runs after the
initializer; the upgrading HTTP process retains its reservation until the
websocket process attempts transfer. This is an acknowledged ordering, not a
cross-sender mailbox assumption. PR #268 and the session-socket module docs
record the mechanism.

**Retirement requires original evidence.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains the
native port until observed exit. Caller timeout, port closure, and late
`noproc` do not prove transitive cleanup. Failed cleanup retains custody.

**Authority is checked at use.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md) and
[016](../protocol-change/016-record-human-origin.md) define membership,
activation, and human origin. Workspace memory is owner-private; sharing
requires session-only scope and explicit transcript acceptance.

**Uncertain mutation is not a replay permission.** ADR-009 retains attempt
identity; ADR-010 permits one unsent command during reconciliation. A terminal
does not resend an uncertain mutation. Runtime close does not abort durable
intent; a later explicit open can resume the admitted turn.

**Production SQL is generated; connection policy is centralized.**
`make gen-sql` owns query outputs; `storage/sqlite_policy` owns shared pragmas
and typed overrides. Raw SQL is acceptable in tests. Process machinery uses
Weft; Erlang stays limited to necessary host operations.

## Deliberately open

None of these is unfinished work somebody forgot.

- **#117, subscription inference:** the supported integration boundary is
  unresolved, rather than an unimplemented login command.
- **#147 and #148, provider transport/redaction:** native non-success-body
  buffering and successful-stream credential redaction remain separate
  boundaries. The Responses adapter does not claim to repair them.
- **#242, native filesystem confinement:** membership is not proof that a
  model cannot read daemon credentials or another workspace's database. The
  excluded native-policy worktree remains outside this change.
- **#243, shipped approval route:** ordinary Bash policy does not expose the
  narrower wall budget needed by that acceptance scenario. A fake approval or
  native execution error is not a substitute.
- **#244 and #246, scheduling/pressure/joined faults:** recurring cursors,
  whole-VM schedule recovery, maximum-image and rapid-switch load, final
  dependency resource observations, and the remaining authority/fault matrix
  are not established by the one-shot schedule or cooperative-stop fixtures.
- **#240 and #245, live delivery and memory off:** the former needs design
  and implementation; the latter has a designed observation still to build.
- **#247, SQLite retirement:** shipping still resolves sqlight 1.2.0 and Hex
  esqlite 0.9.0. The evaluated repair is not a shipping-artifact guarantee;
  ADR-002 records why a plain Gleam Git/path dependency cannot build the
  required Rebar package.
- **#248, toolchain freshness:** repeated Hex resolution is a Gleam
  fingerprint issue, not a failing test. Do not patch dependency caches or
  disguise a registry failure as a source failure.
- **#241, hosted macOS performance, and #255, crash-rider marker waits:**
  both remain open. Advisory policy is not a performance repair.
- **Jobs conversion and follow-ups:** automatically converting a bounded
  foreground call into a job needs an explicit opt-in or policy decision.
  The other jobs proposals above do not gate this provider change.

## How to verify

Build current prerequisites before trusting shipped fixtures:

```sh
make binaries server-shipment
LOOM_BOOTSTRAP_E2E_SERVER="$PWD/bin/loomd" \
LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key \
LOOM_TEST_TIMEOUT_SECONDS=600 \
python3 scripts/with_timeout.py 1800 -- make check
make doc-check
make release release-smoke
```

For a narrow Responses change, run `bash scripts/test.sh provider --match responses`,
the client catalogue/domain-resolution fixtures, and
`bash scripts/test.sh conformance --match responses_e2e`. The opt-in paid smoke is
`gleam dev` in `packages/provider`, under a 90-second outer deadline, with
`OPENAI_API_KEY` and `LOOM_RESPONSES_MODEL=gpt-4.1-mini-2025-04-14` explicitly
set. It sends one capped text request and requires confirmed drain. No key
means a safe nonzero result, not a skipped passing test.

**Capture each gate's own exit code.** A successful log tail is not a test
result. Freeze source during a gate and inspect its actual skip census.

**Rebuild the shipment before testing it.** Shipped fixtures drive
`bin/loomd`, not a newly compiled source file. A mutation confined to source
can otherwise false-pass.

**Keep deadlines and notifications active.** Test wrappers enforce process
deadlines and scoped idle-sleep prevention. Writer-lease recovery can
intentionally wait 60 seconds; timeout is failure, never drain proof.
Re-arm Substrate after notifications. [execution.md](execution.md) records
the remaining operating hazards.
