# Current handoff

The collaboration stack is being rebased onto current `main`. PR #484 already
merged the async execution, resident peer messaging, and named workflow core.
The four PRs below add model-visible virtual reads, owner controls, a terminal
link manager, and executable collaboration examples. Merge the stack from the
bottom after CI passes on the rebased heads.

| PR | Result |
|---|---|
| [#494](https://github.com/Roasbeef/loom/pull/494) | `fs_read` discovers full capability declarations at `cap://` and polls caller-owned jobs at `job://`. Prompt pack v9 describes both program modes. |
| [#499](https://github.com/Roasbeef/loom/pull/499) | The owner CLI inspects, links, unlinks, and sends across exact session and strand pairs. |
| [#502](https://github.com/Roasbeef/loom/pull/502) | The TUI manages directional links, wake policy, and paged grants and targets. |
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

1. Rebase and submit the entire stack. Verify each PR's base and exact head.
2. Capture the real #502 peer-link terminal and post screenshots on its PR.
3. Wait for Linux and macOS CI on the rebased heads, then merge the stack
   through #503. Close #485, #488, and #489 through their PRs.
4. After merge, update this handoff with the resulting `main` commit and any
   measured limits. The enlarged code-mode description may still merit a
   cached-prefix measurement.

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

The four PRs passed Linux and macOS CI before this rebase. That result does
not establish the rebased heads. Run the repository checks on the new commits
and use each command's exit status. The top example layer previously passed
all 2,093 client tests; the shipped bootstrap fixture covered peer delivery
on a clean CI host. Keep those results separate from the new CI run.
