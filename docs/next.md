# Collaboration handoff

This file records the current collaboration implementation, its verification
boundary and the next scoped work. Rewrite it after the next body of work;
use the architecture and protocol documents for enduring contracts.

Baseline: `fc9528e4` on `feature/async-collaboration`, September 22, 2026.
The source, issue scope and validation claims below were checked for this
edition. The complete local and documentation gates passed on this head;
hosted platform checks remain separate.

## Where the tree is

| Body of work | Current state |
|---|---|
| Async execution, #107 | Launch/send/check/join/cancel, fixed authority and deadline, immutable readiness, typed endpoints, intermediate progress, explicit idle expiry and cumulative launch limits are implemented. |
| Peer messaging, #382 | Exact directional grants, resident routing, atomic receipt/message admission, owner-authenticated control send and structured peer origins are implemented. |
| Named workflows | Named steps reconcile original child operations and durable results; version, input and assignment remain immutable. |
| Presentation and examples | TUI linking is #485, CLI conveniences are #488, and a complete collaboration workflow example is #489. |
| Validation | `make check` passed, including 2,067/2,067 client tests; `make doc-check` passed with zero errors. Hosted checks have not run on this head. |
| Merge state | PR #484 is the integration vehicle. Its closing references target #107 and #382 on merge; neither issue is closed by local implementation alone. |

The [architecture](architecture/async-collaboration.md) explains host and
satellite ownership. The [API guide](async-collaboration.md) gives callable
examples and limits. [Protocol 047](../protocol-change/047-async-collaboration.md)
owns the wire and custody decisions, and the
[follow-up review](review/async-collaboration-followups.md) records the adversarial
finding and its validation.

### Corrections to the previous edition

The previous edition listed typed endpoints, intermediate progress, readiness,
idle limits, the exclusive invocation contract and structured entry provenance
as missing. They are now implemented and covered by the current tests. CLI and
TUI conveniences remain open in explicit follow-up issues.

The first two findings on PR #484's latest review are fixed. A detached HEAD
retains the observed repository identity with `branch: null`, and the source
Agency refuses a 65th distinct outgoing link before its index becomes
unreadable. A repeat link remains valid at the bound.

The hosted checks for `93032b53`, before these fixes, completed successfully on
the applicable platforms. They do not certify this head. Read the new head's
checks separately from the local client and documentation results below.

## Integration with current main

The branch also includes the code-mode notes and utilities work merged in #483.
Both workspace and orchestration are offered by default; an omitted seam still
selects workspace, and explicit workspace-only configuration remains supported.
The host-installed `cap/notes` door exposes session-local durable data to both
seams without giving workspace code agent lifecycle authority. Backend note-read
failures remain refusals rather than empty results, including completed-child
joins. `note://` is a capability view, not an operating-system mount.

`report.decode_json` and `report.encode_json` share core's lossless conversion.
`strand.map` admits bounded batches and preserves ordered results, known handles
and unstarted assignments when a batch cannot complete. The real jailed recipe
fixtures cover these utilities alongside the collaboration fixtures. See
[notes](../protocol-change/045-code-mode-notes.md),
[utilities](../protocol-change/046-code-mode-utilities.md), and their review
records for the enduring contracts. The validation below covers their resolved
integration with collaboration, including the regenerated prelude and seed.

## What to do next

1. Complete PR #484's hosted checks and merge review for **#107** and **#382**.
   **Exit:** passing applicable platform checks at the proposed head, followed
   by an authorized merge. Do not treat local package results as release or
   Linux certification, and do not use installed daemons as test fixtures.
2. Implement operator convenience surfaces in **#488** and **#485**.
   **Exit:** scripts and terminal users can inspect and administer directional
   links through the existing owner/epoch-checked protocol. These issues do
   not authorize saved-session activation or cross-machine routing.
3. Add the complete collaboration workflow example in **#489**.
   **Exit:** the example launches named children, exchanges granted messages,
   observes progress and recovers durable results, with executable validation.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Authority and communication are separate.** Protocol 047 makes peer links
directional, with a separate wake permission. They confer neither child
custody nor join, cancel or filesystem authority. Peer identity is bound by
the harness and stored as structured attribution; rendered text is not an
access-control record.

**Readiness and custody are separate.** `Running` can include compilation and
startup. Sends require an immutable registered endpoint. Progress and latest
delivery are volatile observations, while input admission is durable. A callback
which enqueues actor work has not proved that work complete. Protocol 047 and
the async architecture state these acknowledgement boundaries.

**The execution retains its original limits.** Interaction never changes its
source, token, grants or wall deadline. The session admits eight live executions
and each initiating operation admits 32 in total, including settled records.
Typed idle service renews only on successful callback delivery and is checked
at receive boundaries. `Exclusive` governs the tool invocation, not the
remaining lifetime of an admitted background.

**Recovery preserves durable identity, not actor heaps.** A lost satellite is
not replayed. Named step intents recover their original caller coordinates;
the original-child-operation pointer commits with child admission. Completed
and failed child results remain authoritative, and a new step name selects an
intentional retry. Protocol 047 records this ordering.

**A peer receipt proves admission.** The recipient checks its grant and commits
the receipt and message in one transaction. It does not prove model consumption.
Saved targets stay saved; an unavailable target does not prevent outgoing-link
removal or discovery of healthy peers. The messaging architecture describes
these residency and revocation boundaries.

## Deliberately open

None of these is unfinished work somebody forgot.

- Operator CLI convenience (#488), TUI linking (#485), and the full workflow
  example (#489) are scoped follow-ups to the implemented backend.
- Saved-session outboxes, cross-machine transport, automatic deadline renewal
  and actor-heap persistence are unbuilt extensions with separate authority
  and recovery questions.
- General effect replay and an automatic workflow retry language are undesigned.
  The current primitive reconciles named child operations.

## Validation evidence

The complete `make check` passed with its own exit status **0** on `fc9528e4`.
It includes script/release checks, generated-prelude checks, all package gates,
sandbox Go formatting/vet/build/tests, and house lint. The client package passed
**2,067** tests, including both new regressions. `make doc-check` passed with
zero errors. Hosted checks still need to run on the pushed head.

The unchanged MCP deadline regression took 119 ms against its 500 ms ceiling.
Earlier staged runs exposed a queued-provenance assertion error and a goal-check
fixture that left one million messages in EUnit's shared runner. Both were
corrected before this complete gate. The review record preserves that evidence
and the separate shared-cutoff correction.

The focused async selection ran all 13 tests without skips, including real
jailed typed actor state, malformed input rejection, progress, idle reaping,
and named child workflows. The host suite also covers readiness, launch-count
recovery and overlapping lifetimes. The idle-cancellation mutation compiled
and failed the intended regression; restoring cancellation returned the source
to the passing implementation.

The integration review found no actionable issue in notes/router composition,
caller identity, fixed authority or workflow/map coexistence.

The independent feature review found one weak idle test, which was strengthened to
observe broker abort, durable loss and worker exit before teardown. It found
no confirmed production correctness or authority defect. Documentation received
technical-writing and package-graph passes, including legacy origin encoding
and the distinction between admission, dispatch and application completion.

## How to verify

```sh
make sandbox codemode-seed
make check
make doc-check
```

For focused development, use `bash scripts/test.sh client --match async_`,
`bash scripts/test.sh client --match peer_`, and the runtime/capability suites.
The offline seed must include the current capability API before jailed tests.
Regenerate the committed prelude with `make gen-prelude` after public cap changes.

**Capture each gate's own exit status.** A successful log reader does not prove
the command which wrote it succeeded. **Use one build per checkout.** Concurrent
builds can replace BEAM modules while EUnit loads them. **Keep enforced test
workspaces outside `/tmp`.** The jail replaces that path with scratch storage.
See [execution](execution.md) for the remaining verification rules.
