# Hero copy

The landing page's hero is a headline and a lede of two or three sentences. Three drafts follow. Variant 1 is the one in `src/site/landing.gleam`. To ship another, replace the `h1` and the `lede` paragraph in `hero()` there, and the page description in `index.html`.

Each variant says the same five things: Loom is written in Gleam, it runs on the BEAM, a session is an OTP supervision tree over a write-once SQLite store, commands run in kernel sandboxes, and the distributed runtime puts a session's runtime on an orchestrator and its tool calls on executors, with sessions that can move between orchestrators. The sources for each claim are in the table at the end.

## Variant 1: what it is (shipped)

**A coding agent harness written in Gleam, running on the BEAM.**

Each session is an OTP supervision tree over a write-once SQLite file, so a crashed process is restarted by its supervisor and a killed daemon loses no committed work. Commands run in kernel sandboxes. A distributed runtime puts a session's runtime on an orchestrator and its tool calls on executors, and lets a session move from one orchestrator to another.

This one names the language and the runtime in the headline, so a reader who skims only the headline gets the two facts the owner asked to state first. The lede then gives the three properties in the order a reader asks about them: survives crashes, sandboxed, distributed.

## Variant 2: what survives

**A coding agent whose sessions survive crashes and can move between machines.**

Loom is written in Gleam and runs on the BEAM. Each session is a supervision tree over a write-once SQLite file, and every command runs in a kernel sandbox. In the distributed runtime, a session's runtime lives on an orchestrator, its tool calls run on executors, and the session can move to another orchestrator.

This one leads with the two outcomes and puts the language in the first lede sentence. It is the better headline for a reader who does not yet care what Gleam is, and the weaker one for a reader who searches for a Gleam or BEAM project. "Survive crashes" is a claim about committed work and recovery from the file, which the crash figure shows, so keep the figure close to it.

## Variant 3: how it is built

**Every Loom session is a process tree on the BEAM, with its history on disk.**

Loom is a coding agent harness written in Gleam. OTP supervisors restart what crashes, the conversation is a write-once SQLite tree, and commands run under bubblewrap, Landlock and seccomp on Linux or Seatbelt on macOS. Run it on one machine, or split a session's runtime and tool calls across an orchestrator and executors.

This one is the most concrete about mechanism and names the sandbox layers. It is the strongest for an engineer who wants the architecture in three sentences. It does not mention that a session can move, which is a feature the replay and the distributed story show, so it would need that sentence added if it shipped.

## Why variant 1 ships

Of the three, only variant 1 states the language and the runtime as the headline's subject, says what each session is, and includes moving between orchestrators in the lede. Variants 2 and 3 each drop one of those. The owner asked for all of them up front, and a plain statement of what the thing is serves a first-time visitor best.

## Where each claim comes from

| Claim | Source on `main` |
|---|---|
| Written in Gleam, runs on the BEAM | `README.md`, "Why Gleam" and "Why the BEAM" |
| A session is a rest-for-one supervision tree; a strand crash restarts only that strand | `docs/architecture/orchestration.md`, "The supervision tree" |
| A session is a write-once SQLite file | `docs/architecture/durability.md` |
| A killed daemon loses no committed work | `docs/architecture/orchestration.md` and `docs/loom-design.md` section 4.1: recovery reads `op.state` and applies each tool's replay policy. The claim is about committed work, because a call in flight is reconciled by that policy and a `ReplayNever` call gets an explicit failure |
| Kernel sandboxes: bubblewrap, Landlock, seccomp, Seatbelt | `docs/architecture/effects.md`, `docs/adr/006-macos-seatbelt-boundary.md` |
| Runtime on an orchestrator, tool calls on executors | `docs/architecture/distributed.md`, "The cut: `ToolSurface.run`" |
| A session moves between orchestrators | `docs/architecture/distributed.md`, "Moving a session between orchestrators" |

## Other copy decisions

- The primary action is **Download**, linked to the latest release, with the version label from `src/site/release.gleam`. The secondary action is **Build from source**. A third, quiet link goes to the repository.
- The status line under the actions says that Loom is under active development and names the platforms the release workflow builds. It does not say that a release exists for a platform, because the macOS lane has not completed its first hosted comparison. The status table says so.
- The footer and the README say `License: TBD`. No licence is named anywhere else on the site.
- The site does not claim remote code mode for background executions, MCP on executors, or a replicated session directory. The limits list on the distributed runtime page is the one in `docs/architecture/distributed.md`.
