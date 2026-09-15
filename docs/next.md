# Next

**Read this first.** This is the handoff between sessions: where the tree
stands against the plan of record, what to work on next, the rulings
already made so nobody re-litigates them, what is deliberately left open,
and how to verify a change. Rewrite it when you finish a body of work.

It is deliberately not a history; the git log and the PR bodies carry how
each change was reviewed. Re-baselined 2026-09-15 against the branch
`explore/tool-roster-code-mode` at `81f2bb6a`, which is seventeen commits
ahead of its merge base `cc797e41` and is **not merged**. Every claim
below was checked against that tree, against GitHub, or against a named
gate run, rather than carried forward from the previous edition, and the
places where the previous edition was wrong are named as such.

---

## Where the tree is

The plan of record is `docs/issue-plan.md`. This branch is one body of
work outside a numbered phase: shrinking what every request pays for.

| Body of work | Where it stands |
|---|---|
| Updating a running daemon | #404 merged 2026-09-15. The previous edition called it open. |
| Daemon profiling, session archive, provider drain, numbered diffs | #417, #418, #420, #421 all merged 2026-09-15, as the previous edition said. |
| Streamed response handoff | #416 merged 2026-09-15. |
| L402 challenge seam | #395, #396, #397 still open, untouched by this branch. |
| Responses API | #278 still open, untouched by this branch. |
| Tool roster and the `cap://` read | Built on this branch through `81f2bb6a`. Protocol 039 accepted. No pull request opened yet. |
| `fs_read` scheme resolver | #192 open. Its `cap://` and `job://` half landed here; `history://`, `agent://` and the artifact schemes did not. |
| Tool-search token figures | #94 open. Its stale headline numbers are superseded by the measurements in [the roster note](design-notes/tool-roster-and-dyn.md). |

Main is at `d78e9e26`, well past this branch's merge base. The last
completed CI run on main, `35026113250` and `35026113744` at the #424
merge, succeeded on both the docker and CI workflows; the run for the
#432 merge, `35032875048`, was still in progress when this edition was
written. Rebasing this branch onto the advanced main is part of item 1
below.

### Corrections to the previous edition

**#404 is merged.** The previous edition said it remained open and that
its takeover still owed release checks, hosted CI and Linux signoff on a
pushed head. It merged at 2026-09-15T06:11Z. Its item 1, "validate and
present #404", is closed, as is #392, the issue behind it.

**The open pull request inventory is different.** The previous edition
named #397, #396, #395 and #278 as the live open set. Those four are
still open, and three more have appeared since: #429, #430 and #431.
None of the seven is touched by this branch.

**The previous edition's baseline is stale by construction.** It was
based on main `fe3cfbf2` plus a local takeover commit. Main has since
taken at least #404, #424 and #432, so no gate result recorded in that
edition says anything about today's main.

### What this branch built

`[tools] roster = "minimal" | "full"` is an operator setting in
`loom.toml`, carried by the `Roster` type (`catalog.gleam:233`) and
defaulting to `Full` (`default_tools`, `catalog.gleam:1064`). Under
`Minimal`, `built_in_for` (`contributions.gleam:286`) registers only
`bash`, `grep`, `fs_read`, `fs_write`, `fs_edit` and, when the host
opened the plane, `code_mode`. The fifteen it drops are the six `agent_*`
tools, the three `job_*`, the three `schedule_*`, `history_search`,
`remember` and `context_remaining`. Together with the six `Minimal`
keeps, that is the 21-tool `Full` roster Loom has always registered. An
unflagged `Minimal` serves both code-mode
seams (`seams_for`, `serve.gleam:1290`), because `cap/strand` is admitted
on the orchestration seam only and a narrowed door must not narrow the
ability. An explicit `--codemode-seams` word outranks the roster in
either direction. `bash` keeps the jobs door under `Minimal` and says to
read a job back through `fs_read` of `job://<id>` (`Readback`,
`bash.gleam:109`).

Per session, `loom --tools minimal|full` travels as an optional `roster`
field on `sessions.create`, specified in
[protocol-change/039](../protocol-change/039-session-tool-roster.md) and
documented in [the client protocol](client-protocol.md). It decodes into
`RosterRequest` (`client/daemon/protocol.gleam:30`), participates in the
create-retry idempotency equality, persists as a text column on
`catalogue_sessions` under the catalogue v4 migration
(`roster`, `catalogue_rosters.sql:5`), and is applied over the daemon
default by `resolve_managed` (`serve.gleam:784`) on every rebuild. An
inherited roster follows the daemon's configuration at each boot, while
the pinned system prompt and the seeded active set do not re-render. That
asymmetry is documented in 039 rather than mechanised.

Three capability modules are new and workspace-seam only: `cap/history`,
`cap/memory` and `cap/context`, served by `serviced_caps_on`
(`recall.gleam:232`) and advertised only when the plane behind them is
present. The extension bridge composes no recall arm, which is a
documented asymmetry rather than an oversight.

`fs_read` now takes schemes (`read_tool_with`,
`tools/src/tools/fs.gleam:650`). `cap://<name>` returns one prelude module's full surface, filtered by the
seams the session was offered, and `cap://` on its own lists them;
`job://<id>` is a zero-wait poll rendered the way `job_poll` renders.

The `code_mode` description now carries the module index plus `pub type`
blocks (`type_surfaces`, `prelude.gleam:1730`) and only the heading line
for MCP façades, with the full signatures one `cap://` read away
(`cap://`, `tools/src/tools/codemode.gleam:667`). Measured wire bytes
for name, description and schema: workspace-seam only went from 52,162
to 25,690, and both seams from 64,842 to 33,472. A 28,000-byte bound
built from `policy.default()` is pinned by
`the_workspace_description_stays_under_its_bound_test`
(`description_bound_test.gleam:60`).

Prompt pack `loom-default-8` selects its delegation wording by whether
`agent_spawn` and `code_mode` are registered, and carries the `cap://`
discovery sentence (`cap://`, `default.gleam:212`).

### What has not been run

`scripts/check.sh`, the full CI gate, exited 0 on this tree before the
review fixes, and exited 0 over prompt, tools, codemode, client, tui and
conformance after them. `make doc-check` exits 0 with zero citation
errors. An adversarial review found one HIGH, that a minimal session on a
default daemon could not reach `cap/strand`, which the `seams_for` commit
fixed; the mediums are fixed or documented.

Not run, and therefore not claimed: `make e2e-codemode` (needs a Linux
jail), the `daemon_shipped_*` fixtures (need `LOOM_BOOTSTRAP_E2E_SERVER`),
`scripts/cli_help_test.sh` (needs a release shipment), any real model
drive, and Linux signoff (`make signoff-remote`). The default roster
stays `full` until a drive decides it.

## What to do next

In this order. The first item is the body of work; the rest are smaller
and can be interleaved by whoever is not on it.

### 1. Drive `minimal` against `full`, then open the pull request

Two sessions on one scratch daemon, one `--tools minimal` and one
`--tools full`, on the Baseten OpenAI-dialect models and on Anthropic.
Measure how often each session reaches for code mode, how many compile
failures follow a `cap://` read against how many follow none, and
wall-clock to completion. Decide the default roster from those numbers
rather than from the byte figures alone, since the byte saving is already
known and the behavioural cost is not. Then rebase onto main, push, run
`make signoff-remote`, let hosted CI run, and open the pull request
against `main`.

Exit: a pull request against `main` carrying the drive's numbers in its
body, with the default roster decided and recorded.

Note what this does *not* do: it does not change the roster vocabulary,
does not add a scheme, and does not open the other items below.

### 2. Measure the compile-and-boot floor, only if the drive shows it hurting

A code-mode program pays a compile and a boot before it does anything, so
a one-shot bounded call that a wire tool would have answered directly is
the shape most exposed by `Minimal`. If the drive shows that floor
costing real time on such calls, measure it, then consider a compile
cache keyed by program digest or a kept-alive cell. [The roster
note](design-notes/tool-roster-and-dyn.md) has the argument for both.

Exit: either a measurement showing the floor does not matter, filed on
the note, or a cache with its own numbers.

Note what this does *not* do: no jailed `cap` CLI. That was considered
and rejected.

### 3. File the note's remaining open items as issues, once the owner agrees

Each is a separate issue, not a widening of item 1: `cap/context` on the
orchestration seam; the extension bridge and whether it composes a recall
arm; the `history://` and `agent://` schemes still owed to **#192**;
binding the roster into the prompt pin identity so an inherited flip
re-renders; and index-only against index-plus-types in the description.

Exit: an issue per item with the note's argument quoted into it, or the
owner's decision not to file one.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**The roster is an operator decision and a per-session decision, not a
view setting.** A session's registry is built during assembly and the
prompt's tool index is pinned from it, so nothing arriving later can
narrow it.
[Protocol 039](../protocol-change/039-session-tool-roster.md) owns the
wire field and [the roster note](design-notes/tool-roster-and-dyn.md) the
argument.

**`Minimal` is the five core tools and `code_mode`, and code mode is the
only other door.** Every dropped tool stays reachable through the
capability prelude, so the roster narrows the door and not the ability
(`Roster`, `catalog.gleam:233`).

**`cap://` is the on-demand signature read, and the types stay in the
prefix.** A program needs the constructors to compile against, so the
`pub type` blocks stay in the description and the function signatures
move behind the read (`cap://`, `tools/src/tools/codemode.gleam:667`).

**The per-request context footer is rejected.** A footer that changes
every request changes the bytes the provider caches, which costs more
than the number it carries is worth
([the note](design-notes/tool-roster-and-dyn.md)).

**A jailed `cap` CLI is rejected.** It is the closest port of oh-my-pi's
`dyn`, and code mode already is Loom's `dyn`
([the note](design-notes/tool-roster-and-dyn.md)).

**The recall modules are workspace-seam only.** `cap/history`,
`cap/memory` and `cap/context` read and write this repository's own
record, which is a workspace program's job; the orchestration
intersection stays `cap/report` (`cap/report`,
`vet/policy.gleam:538`).

**An unflagged `Minimal` serves both code-mode seams, and an explicit
seam word outranks it** (`seams_for`, `serve.gleam:1290`).

**Archive is visibility, not initialization or revocation.**
[Protocol 035](../protocol-change/035-session-archive.md) keeps
`Reserved` and `Saved` unchanged. Archive and restore are owner mutations
serialized with runtime admission and need no live slot.

**Activation is explicit and uncertain mutations are not retried.**
[The daemon ruling](design-notes/single-daemon.md#execution-ruling),
[ADR-009](adr/009-record-terminal-attempt-custody.md) and
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) own these
boundaries. Listing and preview do not start saved sessions.

**Cleanup requires the original owner's evidence.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains
native custody until observed exit, and
[protocol 028](../protocol-change/028-provider-failure-context.md)
preserves diagnostics without weakening that proof. Timeouts and late
`noproc` are not retirement witnesses.

**Presentation does not own durable truth.**
[Protocol 030](../protocol-change/030-context-observation.md) reads
captured state, [031](../protocol-change/031-tool-output-stream.md)
bounds live tool output, and
[033](../protocol-change/033-abort-halts-held-input.md) defines the
held-input halt.

**The update path carries build identity on the wire and returns held
input on drain.**
[Protocol 037](../protocol-change/037-build-identity.md) puts the
shipment identity in the control-plane `hello` body, and
[038](../protocol-change/038-held-input-custody-return.md) adds the one
pushed event that returns custody of held input. Both were accepted with
their review corrections, and #404 shipped them with immutable
installation directories and no automatic pruning.

**Authority and process boundaries remain explicit.**
[Protocols 015](../protocol-change/015-daemon-control-and-session-attachments.md)
and [020](../protocol-change/020-minimal-jail-root.md) define
server-owned activation and jail policy. Portable packages stay free of
I/O and externals, and process ownership follows
[the Weft mapping](weft.md).

## Deliberately open

Named, with an issue where one exists. None of these is unfinished work
somebody forgot.

- **Whether `cap/context` belongs on the orchestration seam.** Undesigned.
  A context read mints nothing durable and reaches no other strand, which
  is the bar `cap/report` clears, so the case for it is real and has not
  been argued through (`cap/context`, `vet/policy.gleam:542`).
- **The extension bridge composes no recall arm.** Unbuilt, and
  deliberately so until somebody states what an extension should be able
  to read of a repository's past.
- **The `history://`, `agent://` and artifact schemes on `fs_read`** (#192).
  Unbuilt. The scheme mechanism landed here; these resolvers did not.
- **An inherited roster is not bound into the prompt pin identity.**
  Undesigned, and the load-bearing one: flipping a daemon's `[tools]
  roster` changes what a rebuilt session registers without re-rendering
  its pinned prompt, and 039 documents that rather than fixing it.
- **Index-only against index-plus-types in the `code_mode` description.**
  Undesigned. The measurement that would settle it is a drive, not a
  byte count.
- **A durable restart-specific cancellation reason.** A separate protocol
  decision; 038 preserves the existing generic abort diagnostic.
- **Automatic installer pruning.** Deliberately absent. Manual cleanup
  must account for every live client and daemon.

## How to verify

```sh
make check
make doc-check
make codemode-seed
make e2e-codemode
make signoff-remote
bash scripts/test.sh codemode --match description_bound_test
bash scripts/test.sh client --match serve_test
```

Hazards, each of which has cost real time here:

**Verify a gate by its own exit code.** Capture the status of the command
you care about, not of the `tail` that read its log. This has produced a
confident false green here twice.

**Run `make codemode-seed` before any fresh-worktree drive.** A worktree
without the offline cache never reaches `codemode.ready`, and the drive
then measures the wrong thing.

**Keep enforced code-mode worktrees outside `/tmp`.** The Linux jail
replaces `/tmp` with a scratch tmpfs, so a cap socket there is correctly
refused.

**Re-sign off after a sibling merge.** Two independently green branches
have broken main together. This branch's merge base is far behind main,
so its earlier gate results do not transfer to the rebased head.

**Run `make doc-check` before every push.** It is not part of `make
check`, and citation drift reds the static signoff lane.

`docs/execution.md` is the rest: how a wave is planned, how sub-agents
are briefed and monitored, the standard of proof, and why a correction
goes on the issue rather than only in a commit.
