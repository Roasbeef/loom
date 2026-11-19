# Landing page copy

The landing page is short, and this file is the record of how its words were chosen. Each claim on the page is stated once, with its mechanism, and the explanation is left to the documentation page it links to. `test/page_test.gleam` puts a word budget on the page.

## How the copy is written

One engineer telling another what the thing does. A claim names the mechanism (two commits, a digest, a TLA+ model) where an adjective would have gone. Sentences are plain statements, contractions are fine, and there are no em dashes.

Things to keep out, because each of them was on the page once: three adjectives in a row as a headline, a heading that defines its subject by what it isn't, a paragraph that ends by restating itself, a sentence that describes the page ("the table says..."), and a qualifier stacked on a qualifier. `scripts/copy-check.sh` catches the banned words and the em dash. The rest is on whoever edits the page.

A claim is only as strong as its source. Where the source carries a condition, the sentence carries it too: "seccomp when the network is off", "a once-only yes", "a model of one move". The table at the end names the source of each claim and says why the wording stops where it does.

## The hero

**A coding agent whose sessions survive a crash.**

Loom is a coding agent harness written in Gleam, on the BEAM. Each session is one SQLite file. Commands run in a kernel sandbox, and tool calls can run on a different machine from the one that holds your keys.

The headline is the one claim a reader can test with `kill -9`, and the recording under it shows it. The lede's first sentence names the language and the runtime for a reader who came looking for a Gleam or BEAM project, and the page title leads with those two for the same reason.

Two headlines were set aside. "A coding agent harness written in Gleam, running on the BEAM" says what Loom is made of and not what it does for you. "A durable, distributed, self-evolving coding harness" is three adjectives, and the reader has to take each one on trust.

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
| Every tool call is committed twice, and a call that isn't safe to repeat gets an outcome-unknown result | `docs/architecture/orchestration.md`, the intent and settle commits and the replay policies. `bash` is `ReplayNever` in `docs/architecture/tools.md` |
| A session resumes when it is opened again | `docs/architecture/daemon.md`: after a restart every session starts closed, and one reopens when a client asks for it. This is why the page says "open the session again" and doesn't say the daemon picks up by itself |
| Commands, authored programs and MCP servers never run in the harness VM | `docs/loom-design.md`, Rule Zero. The claim names those three because `docs/architecture/tools.md` says most built-in tools do run in the harness VM on model-supplied arguments |
| seccomp when the network is off | `docs/architecture/effects.md`, the helper's setup order |
| A once-only yes covers one call by a digest of its arguments | `docs/architecture/approvals.md`. The claim says "once-only" because an approval for the session records grants that later calls pick up |
| What a program imports bounds what it can do | `docs/architecture/code-mode.md`. Vetting also refuses `@external`, which is the other way a program could reach past its imports |
| A TLA+ model of one move, with a crash between any two writes | `docs/architecture/distributed.md`, on `protocol/models/session-move`. The model covers one move and is not run in CI, so the page says "a model of one move" and names the one invariant |
| Every prompt and approval records who sent it | `docs/architecture/multiplayer.md` |

## Other copy decisions

- The primary action is **Download**, linked to the latest release, with the version label from `src/site/release.gleam`. The secondary action is **Build from source**. A third, quiet link goes to the repository.
- The status line under the actions says that Loom is under active development and names the platforms the release workflow builds. It does not say that a release exists for a platform, because the macOS lane has not completed its first hosted comparison. The platform table on the install page says so, and the status line links to it.
- The footer names the MIT License, as the repository's `LICENSE` does.
- The site does not claim remote code mode for background executions, MCP on executors, or a replicated session directory. The limits list on the distributed runtime page is the one in `docs/architecture/distributed.md`.
