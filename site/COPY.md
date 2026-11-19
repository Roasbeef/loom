# Landing page copy

The landing page is short, and this file is the record of how its words were chosen. Each claim on the page is stated once, with its mechanism, and the explanation is left to the documentation page it links to. `test/page_test.gleam` puts a word budget on the page.

## How the copy is written

One engineer telling another what the thing does. A claim names the mechanism (two commits, a digest, a TLA+ model) where an adjective would have gone. Sentences are plain statements, contractions are fine, and there are no em dashes.

Things to keep out, because each of them was on the page once: three adjectives in a row as a headline, a heading that defines its subject by what it isn't, a paragraph that ends by restating itself, a sentence that describes the page ("the table says..."), and a qualifier stacked on a qualifier. `scripts/copy-check.sh` catches the banned words and the em dash. The rest is on whoever edits the page.

A claim is only as strong as its source. Where the source carries a condition, the sentence carries it too: "seccomp when the network is off", "a once-only yes", "a model of one move". The table at the end names the source of each claim and says why the wording stops where it does.

## The hero

**A durable, distributed, self-evolving coding harness.**

Loom runs coding agents, and it's written in Gleam on the BEAM. A session is one SQLite file and survives a crash. Its tool calls can run on another machine, in a kernel sandbox. And the agent can write its own tools, which you approve.

The headline is the owner's, and it is the positioning: three words, each a property the page then has to show. So the lede cashes each word out as one plain sentence, in the headline's order, and the page gives each word a section with a figure: Durability, Distributed runtime, Self-evolution. If a word is ever added to the headline, it gets a lede sentence and a section, or it doesn't go in.

Two alternatives were tried and set aside. "A coding agent harness written in Gleam, running on the BEAM" says what Loom is made of and not what it does for you. "A coding agent whose sessions survive a crash" is testable with `kill -9` but leaves out two of the three things Loom is for.

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
- The status line under the actions says that Loom is under active development and names the two platforms a release is published for. It links to the platform table on the install page, which says what is not built and not supported.
- The footer names the MIT License, as the repository's `LICENSE` does.
- What a remote session can and can't do changes often. The landing page links to the limits list on the distributed runtime page and doesn't repeat it, so there is one list to keep in step with `docs/architecture/distributed.md`.
