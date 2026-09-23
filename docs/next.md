# Collaboration handoff

This file records the current collaboration implementation, its verification
boundary and the next scoped work. Rewrite it after the next body of work;
use the architecture and protocol documents for enduring contracts.

The collaboration implementation is in PR #484, rebased onto `main` after
#482, #490 and #278. This edition records the current behavior and the follow-ups
that remain after the platform gate and merge.

## Where the tree is

| Body of work | Current state |
|---|---|
| Async execution, #107 | Launch/send/check/join/cancel, fixed authority and deadline, immutable readiness, typed endpoints, intermediate progress, explicit idle expiry and cumulative launch limits are implemented. |
| Peer messaging, #382 | Exact directional grants, resident routing, atomic receipt/message admission, owner-authenticated control send and structured peer origins are implemented. |
| Named workflows | Named steps reconcile original child operations and durable results; version, input and assignment remain immutable. |
| Presentation and examples | TUI linking is #485, CLI conveniences are #488, and a complete collaboration workflow example is #489. |
| Code-mode surface | The default server admits the full capability set from either program mode. Omitted `seam` selects workspace. An explicit workspace-only host remains effect-only; extensions and resident hooks keep their own policies. |
| Integration | PR #484 carries the implementation for #107 and #382. GitHub closes both issues on merge. |

The [architecture](architecture/async-collaboration.md) explains host and
satellite ownership. The [API guide](async-collaboration.md) gives callable
examples and limits. [Protocol 048](../protocol-change/048-async-collaboration.md)
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

After the previous rebase, hosted CI passed both Linux and macOS gates at
`fb1eff2a`. The later `main` merges and the broader code-mode surface require
a new hosted result on the final PR head. The earlier macOS bootstrap timeout
did not recur on `fb1eff2a`.

## Integration with current main

The branch also includes the code-mode notes and utilities work merged in #483.
Both workspace and orchestration are offered by default; an omitted seam still
selects workspace, and explicit workspace-only configuration remains supported.
The host-installed `cap/notes` door exposes session-local durable data to both
program modes. It does not itself grant agent lifecycle authority to an explicit
workspace-only host. Backend note-read
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

1. Add operator convenience surfaces in **#488** and **#485**. Scripts and
   terminal users need to inspect and administer directional links through
   the existing owner/epoch-checked protocol. These issues do not authorize
   saved-session activation or cross-machine routing.
2. Add the complete collaboration workflow example in **#489**. The example
   should launch named children, exchange granted messages, observe progress,
   and recover durable results, with executable validation.
3. Measure the enlarged model-facing code-mode description and decide whether
   both equivalent mode names still earn their cached-prefix cost. Any narrower
   deployment must advertise only capabilities its router services.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Authority and communication are separate.** Protocol 048 makes peer links
directional, with a separate wake permission. They confer neither child
custody nor join, cancel or filesystem authority. Peer identity is bound by
the harness and stored as structured attribution; rendered text is not an
access-control record.

**Readiness and custody are separate.** `Running` can include compilation and
startup. Sends require an immutable registered endpoint. Progress and latest
delivery are volatile observations, while input admission is durable. A callback
which enqueues actor work has not proved that work complete. Protocol 048 and
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
intentional retry. Protocol 048 records this ordering.

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

The prior PR head `fb1eff2a` passed the complete local gate and hosted CI on
Linux and macOS. The final rebase and full code-mode widening need their own
complete local and hosted checks; the PR and CI run are the result authority.
Focused codemode, tools and prompt gates passed after widening the capability
policy. The client gate passed all 2,072 tests, including real jailed programs
combining `cap/fs` with named child workflow steps in both modes. The
model-facing description checks both offers and installed MCP surfaces.

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

The earlier integration review found no actionable issue in notes/router
composition, caller identity, fixed authority or workflow/map coexistence.
An independent review of the broader program surface found no mismatch in
host routing, the prompt or the model-facing capability description.

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
