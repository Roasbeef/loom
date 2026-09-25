# Current handoff

The collaboration stack landed on `main` in [#510](https://github.com/Roasbeef/loom/pull/510)
at `645b8faf`. PR #484 had already merged async execution, resident peer
messaging, and the named workflow core. The four review layers below add
model-visible virtual reads, owner controls, a terminal link manager, and
executable collaboration examples. GitHub marked #494 merged and the other
three layers were closed as landed through #510; their diffs remain available
for review.

| PR | Result |
|---|---|
| [#494](https://github.com/Roasbeef/loom/pull/494) | `fs_read` discovers full capability declarations at `cap://` and polls caller-owned jobs at `job://`. Prompt pack v9 describes both program modes. |
| [#499](https://github.com/Roasbeef/loom/pull/499) | The owner CLI inspects, links, unlinks, and sends across exact session and strand pairs. |
| [#502](https://github.com/Roasbeef/loom/pull/502) | `/sessions` links the attached strand to a selected resident target; `/peers` inspects and revokes directional grants, and `/agents` can choose another source strand. |
| [#503](https://github.com/Roasbeef/loom/pull/503) | A coordinator and two specialists exercise durable child steps and granted peer exchange in jailed code mode. |

The [code-mode architecture](architecture/code-mode.md) explains virtual-read
routing. The [async architecture](architecture/async-collaboration.md) and
[messaging architecture](architecture/messaging.md) explain execution custody
and peer delivery. The [API guide](async-collaboration.md) and
[collaboration example](examples/collaboration.md) show the calls. Protocol 048
owns the async and peer wire; protocol 049 adds owner inspection.

In the TUI, `/sessions` is the normal target-discovery path. Selecting a
resident row and pressing `l` starts a link from the currently attached
session and strand. Enter still opens a session. The form asks for the exact
receiving strand and shows both endpoints and wake permission before sending
the grant. Escape returns to the same session selection. `/agents` plus `p`
selects another source strand, and `/peers` opens inspection and revocation
directly. A saved session must be opened explicitly before it can receive a
link. The daemon does not enumerate target strands or activate saved sessions
as a side effect of discovery.

Main's #495 TUI split moved this flow into `tui/interaction`,
`tui/session_control`, `tui/model`, and `tui/render`. The native screenshots
were recaptured from the post-split client.

The stack's images in `docs/images/peer-links-*.png` come from the native
116-by-38 terminal with two resident sample sessions. The target name and
source name are fixture metadata, and no model request was sent. The current
design leaves cross-machine routing, saved-session outboxes, deadline renewal,
and actor-heap recovery for separate work.

PR #484 merged at `77269e50`. The native Collaboration tab projects
captured execution, workflow and peer-message facts without starting work.
Protocol 048 owns the backend contracts. The sections below record
earlier validation and follow-ups as a historical handoff.

## Shell approval recovery on main

A running shell can hit a kernel permission error after earlier effects. It
still settles in band: stderr cannot supply a trusted canonical grant, and
replaying a `Never` command could repeat those effects. A failed `bash` call
now tells the agent to make a fresh invocation with `permissions` declaring
the needed roots. For a quoted Git lock path, it names the reported `.git`
directory as a possible writable root. The declared request goes through
canonicalization, protected-path checks, and the operator dialog before the
new command starts.

The real-jail Git worktree regression exercises the denied write and approved
retry. The client regression checks the durable question, displayed command,
and exact grants through production wiring. A trusted helper-side denial
report would be needed before an automatic prompt could safely identify a
resource from an already-running command; stderr remains diagnostic only.

## Rulings to preserve

**Authority and communication are separate.** A link grants neither child
custody nor filesystem access. The source index permits discovery; the
recipient grant authorizes admission. A peer receipt proves durable message
admission, not model consumption or review completion. `busy_only` never wakes
an idle target; `may_wake` is a separate owner choice.

**A virtual read is a capability call.** `cap://` serves generated declarations
for modules the selected code-mode seam admits. `job://` exposes only the
calling strand's jobs. Neither is an operating-system mount. Ordinary file
reads and image support retain their path. Prompt guidance must match the
installed router and generated prelude in both workspace and orchestration.

**Recovery retains identity, not execution state.** Typed input is admitted
before callback completion. Progress is an intermediate observation. A named
workflow step reconciles its original child operation and result after a lost
satellite. It cannot replay arbitrary effects or restore an actor heap.

**Operator surfaces do not open saved sessions.** CLI and TUI use the
owner/epoch-checked control protocol. Inspection is bounded into pages. A
large catalogue or grant set is not permission to activate a saved target.
The CLI reports partial unlink when source authority was removed but
recipient revocation could not finish.

## Remaining work

1. Measure how virtual-read discovery affects prompt size and cached-prefix
   reuse in real sessions. The prompt-size repository budget is a test
   threshold, not a provider token limit.
2. Add an example in which a coordinator does independent work after launching
   children, then sends follow-up tasks to those same children.
3. Design saved-session outboxes, cross-machine transport, and durable actor
   recovery separately from the resident-session link path.

The current examples demonstrate fan-out, a bounded join, named steps, progress,
and recovery. They do not yet show one coordinator doing independent work after
launching children and then sending follow-up tasks to the same children.

Saved-session outboxes, cross-machine peer transport, actor-heap persistence,
automatic deadline renewal, general effect replay, and an automatic workflow
retry language remain separate designs. At the outgoing-link limit, creation
can still write a recipient grant before the source refuses its 65th distinct
link. This pre-existing sequence cannot send without the source index, but it
can leave a stale incoming grant. A future atomic or reserved link-admission
protocol should address it; a compensating revoke can race a successful link
to the same pair.

## Validation boundary

The exact combined tip `f63deb04` passed fresh-container obelisk
`signoff/linux`: client, mid, conformance, fast, static, enforcement, release
update, and a clean skip census. Its hosted Linux client and jail jobs also
passed. The first signoff exposed a fixture collision: two deterministic
specialist sessions could select the same code-mode build root and remove one
another's files or cap socket. Each session now uses its own workspace; the
real-satellite collaboration test passed on the corrected obelisk run. The
merged `main` commit is `645b8faf`; the signoff belongs to its PR head, not
to that new merge-commit SHA. Issues #485, #488, and #489 closed with #510.
