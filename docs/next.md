# Current handoff

This handoff covers governed runtime evolution, checked on October 24, 2026
against `dbf33ff0c` (main after PR #1096). It is a scoped handoff, not a fresh
audit of the whole repository or of hosted CI. Rewrite it after the next body
of work.

The previous handoff, a profiling pass over the terminal and the live daemon,
is preserved in [next-2026-10-24-before-evolution-ui.md](next-2026-10-24-before-evolution-ui.md).
Its terminal patch merged as PR #1080. Its first item, profiling the live
daemon through Pickglass, was not worked in this pass and is still open there.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Local evolution | An agent proposes, tests, compares and inspects candidates, an operator approves and selects, and a session serves the selected version. Extensions, programs and model profiles all work. This is governed by [the architecture page](architecture/evolution.md) and passes `make e2e-evolution`. |
| Reach | A model reaches evolution only through a `code_mode` program importing `cap/evolution` (PR #1091). The six direct tools are gone and cost no prompt bytes. Listing `evolution` in `LOOM_DISABLE_TOOLS` withholds the module from a session. |
| Tool calls | A tool call, a hook fold or an invocation takes a lease from the live owner and runs on its own process (PR #1087). The owner runs no tool. |
| Operator UI | Complete. The `board` action, the `evolution_changed` push, page owner authority and the `via` audit field are protocol-change/099 (PR #1088). The `session_view` lane is PR #1093, the terminal `/evolution` overlay is PR #1094, the web Evolution tab is PR #1096, and PR #1099 makes an owner page record `web`. The docs for all of it are [evolution](architecture/evolution.md), [web view](architecture/web-view.md), [terminal](architecture/terminal.md) and [live upgrades](architecture/live-upgrades.md). |
| Remote evolution | Slice 3 is partly done. The seam narrowed to plain data (PR #1086), the catalogue-free check core (PR #1089), protocol version 5 with the evolution messages, the census field and arms that refuse (PR #1092), and the split of staging into a plain `Staged` value and a wrapper (PR #1098) are merged. The 098 as-built addendum is PR #1097. |
| Not built | No executor builds an evolution plane, so every version-5 evolution arm still answers `NoEvolution` and the census reports `Uncompiled`. An executor session cannot use evolution. |

## What to do next

Slice 3 of [remote evolution](design-notes/remote-evolution.md) has seven steps.
Steps 1, 2a, 2b and 3 are merged. The step-by-step plan, with every type, actor
arm, file and test for steps 4 to 7, is
[remote-evolution-slice3-plan.md](design-notes/remote-evolution-slice3-plan.md).
Read its status note first: the plan predates steps 1 to 3, and where it
disagrees with the code, the code and 098's as-built addendum win.

**First, check that `main` builds.** As of this handoff `main`'s CI is red on
every job that builds the code-mode seed (`deps`, `jail`, `stock compiler`):
PR #1100's lint sweep (commit `de81892d3`) duplicated the parameter
`requested: Decision,` in `finish` in
`packages/ext/src/ext/internal/live_runtime.gleam`, so `ext` does not compile.
The fix is deleting the second copy of that line, and another session owns it.
Nothing below can go green until it lands, and PR #1101 (this handoff) fails
those jobs for the same reason.

1. **Step 4, the executor's evolution plane.** One actor per scope in the
   executor stages, runs, hooks, migrates, retires and inventories generations,
   files its cleanup under the scope's custody, and takes `<state>/evolution`
   as a masked path. **Exit:** raw protocol messages stage and run the fixture
   extension through a real executor, a `Close` after a stage still retires it,
   and `retire_all` is terminal so a stage that arrives after it is refused. The
   last point came from the PR #1092 review. The plan's "Step 4 acceptance, as
   briefed" section lists the five requirements a reviewer should hold it to.

   **State of the work.** The branch `runtime/executor-evolution` is pushed
   and has no PR. It is based on `5395e640e` (after PR #1098) and has two
   commits. `dcea651a2` is finished: `extension/memory.over_facts` builds the
   memory door over the owner's `FactAccess`, and
   `owner_services.served_prefixes` admits `ext/`, with tests. `0c875675b` is
   an explicit WIP commit and must not merge as is. It holds
   `client/executor_evolution.gleam` (about 2,000 lines: the actor, its state,
   the stage, transition, retire, hook, inventory, evaluate and run arms, and
   the terminal `retire_all`) and `candidate.source_path`, which lets the
   executor authorise a snapshot directory without a catalogue. The module has
   never been compiled, has no tests, and nothing starts it.

   What is left: rebase onto `main`; make the module compile; review it
   against `docs/weft.md`, and rewrite it from the plan if it reads as too
   large; write `executor_evolution_test` over hand-built `Staged` values
   through `start_over` (the P model's probes as Gleam tests, plus a close
   before and after a stage completes); start it in `executor_plane.start` with
   the `local.Config` the plan lists; add the `<state>/evolution` mask; fill
   `plane_over`'s `evolution` field and the census identity; decide how secrets
   are served on an executor; add the `executor_plane_test` cases.
2. **Step 5, `machine/remote` and the `serve` wiring.** A registered session
   gets an evolution wiring whose machine sends the version-5 messages.
   **Exit:** a session on an executor registers the evolution operations when
   the census says `Compiles`, none when it says `Uncompiled`, and a minimal
   author, test, approve, select and invoke runs on two daemons. This is the
   step that first lets an executor session use evolution.
3. **Step 6, refuse `sessions.move` with a selection.** **Exit:** moving a
   session that has a session-scoped selection is refused with a message naming
   `evolution revoke`, and a session with only a workspace selection still moves.
4. **Step 7, acceptance and records.** **Exit:** a shipped two-daemon fixture
   covers a fixed executor, a pool of one, an executor restart with a selected
   extension, and a program candidate. Protocol 098 gains its implemented line,
   and `distributed.md`, `executor.md` and the package docs are brought up to
   date.
5. **Slice 4, trials and profiles remotely.** A model profile's paired trials
   run on a registered session instead of answering `Authority`. Until then the
   guard stays: prompt trials run on a local workspace only.
6. **Slice 5, core upgrades remotely.** The core upgrade and downgrade path,
   which is command-line only today, reaches a session on an executor.
7. **Slice 6, two-daemon acceptance for the failure cases.** A link cut during
   staging and an orchestrator restart, which step 7 leaves out on purpose.

The order is firm up to step 5. Steps 6 and 7 are independent of each other.

## Rulings not to re-litigate

**A model reaches evolution through code mode only.** There are no direct
evolution tools. A candidate can never import `cap/evolution`, and a program
candidate runs with the door withdrawn.

**Tool calls hold leases.** The live owner serializes a replacement against
outstanding leases and does not serialize calls against each other. A running
call must not request a second lease.

**Refuse `sessions.move` when the session has a selection.** Carrying catalogue
rows in the manifest was considered and left out. Refusal is one read.

**One catalogue.** A daemon that serves local and executor sessions keeps both
placements' candidates in `<state>/evolution/evolution.db`. Reads filter by
visibility and a stale identity is refused as `Changed`, so the mix is safe. The
catalogue page shows the other placement's candidates as not authorised.

**Per-strand evolution gating is accepted as a cost.** A strand that holds
`code_mode` can `propose`, `compare` and `trace`, but cannot run a candidate
because `invoke` needs the operator's exact selection. The one switch is
`evolution` in `LOOM_DISABLE_TOOLS`.

**Owner page authority.** The gateway hands the evolution door `Owner` when an
operator attachment's principal is the daemon's owner, for every action except
`core_upgrade` and `core_downgrade`. A page never attaches as `Owner`. A member
acts on this session's rows only, and an observer reads only.

**The page door decides `via`.** `web` comes from the page's door and sign-in,
never from a request argument. A terminal's `terminal` is audit text and grants
nothing.

## Known open items

- Protocol 098 is still PROPOSED. Its header records slice 3's messages as
  implemented at version 5, and the status changes only after slices 4 and 5.
- `client/remote/protocol.gleam` imports `client/extension/hooks`. This is a
  layering nit: the wire vocabulary should not depend on the extension package.
  Nothing is broken by it.
- On a Mac, the local client suite needs `rust-analyzer` and times out without
  it. [language-servers.md](language-servers.md) says how to install it.
- `serve_test` times out on git-identity setup under load. It has flaked under
  contention and passes when rerun alone. A flake does not block a merge here.
- An executor's rolling output tail is absent for a remote author check, because
  the door call's id is not on the wire. The plan accepts this for slice 3.

## How this work was run, and what bit

Each PR in this series was written by one worker in its own git worktree off
`origin/main`, reviewed once by a separate reviewer reading the diff cold, fixed,
and merged with a merge commit (`gh pr merge N --merge --admin
--match-head-commit <sha>`) once `gate (linux)` was green on that head. The macOS
gates are advisory. Signoff boxes were unavailable, so hosted CI was the gate.
Every review found something real (a selection-blind size bound in #1088, a
paired-reply bug in #1093, the owner page recording `cli` in #1096, a grant
carried from the wrong list in #1092), so the review pass is worth keeping.

Hazards that cost time in this series:

- **Merge before the aggregate.** `gate (linux)` appears only after every
  Linux job finishes. Several workers merged on the individual jobs before the
  aggregate existed (#1097, #1099). Wait for the aggregate check itself.
- **Mac load.** Running more than two or three client builds at once on one Mac
  produced false failures: `serve_test`'s git-identity timeout (32 of 96 once,
  96 of 96 green when rerun alone on both `main` and the branch) and
  `live_upgrade_acceptance_test` answering `strand_busy`. Rerun alone before
  believing a client failure. The full `make check-client` also stops at the
  `rust-analyzer` LSP test on a Mac without it, so later modules never run.
- **Unix socket length.** A worktree under `.claude/worktrees/agent-...` is deep
  enough that a scratch state dir inside it pushes the code-mode cap socket past
  the 100-byte Unix limit. Live drives used short paths under `$HOME` and
  removed them afterwards. Never use `/tmp`, which the jail replaces.
- **Rebase drift.** After a rebase, run the affected client tests again. #1096
  went red once on a terminal parity test because #1094's merge changed when
  the terminal reads the board.
- **Pipe hides status.** One worker read `make e2e-evolution` through `grep`,
  which dropped `make`'s exit code. Read each gate's own exit code.
- **A branch named `evolution/...` cannot be created.** A stale local branch
  named `evolution` in the main checkout blocks the prefix. Use another name.

## How to verify

```sh
make check-client
make e2e-evolution
make doc-check
```

`make e2e-evolution` needs `make binaries codemode-seed` first, and runs against
a scripted loopback provider, so it proves the loop and not commercial-model
quality. Read each gate's own exit code. See [execution.md](execution.md) for
the remaining hazards, including the one where a green `tail` hides a red
`make`.
