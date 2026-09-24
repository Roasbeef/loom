# Current handoff

This file records the latest scoped work and retains the prior collaboration
handoff below it. Use the architecture and protocol documents for enduring
contracts.

## Virtual reads and peer-link controls

The September 2026 collaboration stack is ordered as PRs
[#494](https://github.com/Roasbeef/loom/pull/494),
[#499](https://github.com/Roasbeef/loom/pull/499),
[#502](https://github.com/Roasbeef/loom/pull/502), and
[#503](https://github.com/Roasbeef/loom/pull/503). It adds virtual `cap://`
and `job://` reads, owner CLI controls for directional peer links, TUI link
administration, and a runnable collaboration example. The code-mode and
collaboration guides describe the callable surfaces; this file records the
operator flow and remaining boundary.

In the TUI, `/sessions` is the normal target-discovery path. Selecting a
resident row and pressing `l` starts a link from the currently attached
session and strand. Enter still opens a session. The form asks for the exact
receiving strand and shows both endpoints and wake permission before sending
the grant. Escape returns to the same session selection. `/agents` plus `p`
selects another source strand, and `/peers` opens inspection and revocation
directly. A saved session must be opened explicitly before it can receive a
link. The daemon does not enumerate target strands or activate saved sessions
as a side effect of discovery.

The stack's images in `docs/images/peer-links-*.png` come from the native
116-by-38 terminal with two resident sample sessions. The target name and
source name are fixture metadata, and no model request was sent. The current
design leaves cross-machine routing, saved-session outboxes, deadline renewal,
and actor-heap recovery for separate work.

PR #484 merged at `77269e50`. The native Collaboration tab projects
captured execution, workflow and peer-message facts without starting work.
Protocol 048 owns the backend contracts. The sections below record
earlier validation and follow-ups as a historical handoff.

## Shell approval recovery

A running shell can hit a kernel permission error after earlier effects. It
still settles in band: stderr cannot supply a trusted canonical grant, and
replaying a `Never` command could repeat those effects. A failed `bash` call
now tells the agent to make a fresh invocation with `permissions` declaring
the needed roots. For a quoted Git lock path, it names the reported `.git`
directory as a possible writable root. The declared request goes through
canonicalization, protected-path checks and the ordinary operator dialog
before the new command starts.

The real-jail Git worktree regression exercises the denied write and the
approved retry. The client regression checks the durable question, displayed
command and exact grants through production wiring. `make check` and
`make doc-check` passed on the isolated branch. A trusted helper-side denial
report would be needed before an automatic prompt could safely identify a
resource from an already-running command; stderr remains diagnostic only.

## Prior collaboration handoff

### Where the tree was

| Body of work | Current state |
|---|---|
| Async execution, #107 | Launch/send/check/join/cancel, fixed authority and deadline, immutable readiness, typed endpoints, intermediate progress, explicit idle expiry and cumulative launch limits are implemented. |
| Peer messaging, #382 | Exact directional grants, resident routing, atomic receipt/message admission, owner-authenticated control send and structured peer origins are implemented. |
| Named workflows | Named steps reconcile original child operations and durable results; version, input and assignment remain immutable. |
| Presentation and examples | F2 now has a Collaboration tab for peer-origin messages, background execution custody and readiness, outgoing links, and named workflow intents. Standalone notes accept Up/Down navigation. The main transcript shows delivered advisor advice in full, labels pending advice as not delivered, and shows captured advisor-only commentary separately from delivered messages. TUI link controls are #485, CLI conveniences are #488, and a complete example is #489. |
| Code-mode surface | The default server admits the full capability set from either program mode. Omitted `seam` selects workspace. An explicit workspace-only host remains effect-only; extensions and resident hooks keep their own policies. |
| Integration | PR #484 is merged. The inspector adds a read-only TUI projection and fixes admission of an advisor nudge that arrives after the primary run-end hook but before its terminal commit. A delivered block still enters the primary's ordinary steer queue and waits for a safe checkpoint; priority and in-flight interruption need a separate protocol decision. |

The [architecture](architecture/async-collaboration.md) explains host and
satellite ownership. The [API guide](async-collaboration.md) gives callable
examples and limits. [Protocol 048](../protocol-change/048-async-collaboration.md)
owns the wire and custody decisions, and the
[follow-up review](review/async-collaboration-followups.md) records the adversarial
finding and its validation.

#### Corrections to the previous edition

The previous edition described PR #484 as an open branch. It is merged on
`main`. The TUI can now inspect the new collaboration records, but owner
link and revoke controls remain in #485. The Collaboration tab labels a peer
entry as stored, execution endpoints as published only when their readiness fact exists,
and a named step as an intent rather than a completed child.

The first two findings on PR #484's latest review are fixed. A detached HEAD
retains the observed repository identity with `branch: null`, and the source
Agency refuses a 65th distinct outgoing link before its index becomes
unreadable. A repeat link remains valid at the bound.

Hosted CI for #484 passed before merge. The terminal branch needs its own
hosted result after push.

### Integration with current main

Main also includes the code-mode notes and utilities work merged in #483.
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

### What to do next

1. Add owner-authorized link and revoke controls in **#485**. The terminal
   currently inspects source links but cannot change them or show wake scope;
   that scope is absent from the source fact. Scripts still need **#488**.
   Neither issue authorizes saved-session activation or cross-machine routing.
2. Add the complete collaboration workflow example in **#489**. The example
   should launch named children, exchange granted messages, observe progress,
   and recover durable results, with executable validation.
3. Measure the enlarged model-facing code-mode description and decide whether
   both equivalent mode names still earn their cached-prefix cost. Any narrower
   deployment must advertise only capabilities its router services.

### Rulings already made

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

### Deliberately open

None of these is unfinished work somebody forgot.

- Operator CLI convenience (#488), TUI link controls (#485), and the full
  workflow example (#489) remain follow-ups. The inspector is read-only.
- Saved-session outboxes, cross-machine transport, automatic deadline renewal
  and actor-heap persistence are unbuilt extensions with separate authority
  and recovery questions.
- General effect replay and an automatic workflow retry language are undesigned.
  The current primitive reconciles named child operations.

### Validation evidence

The inspector's focused `make check-tui` passed with exit zero and 726 tests.
New fixtures cover execution readiness, directional link display, workflow
intent labels, authenticated peer origins and keyboard selection without
retargeting the composer. The complete repository and documentation gates
must be run after the final terminal edits. Hosted CI must be checked on the
new PR head after push.

The merged backend's validation remains in
[the #484 review record](review/async-collaboration-followups.md). Its jailed
tests cover typed actor state, rejected input, progress, idle reaping and named
child workflows. Those tests do not turn a TUI rendering fixture into a live
peer-link administration test; #485 owns that separate path.

### How to verify

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
