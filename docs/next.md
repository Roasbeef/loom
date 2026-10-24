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
Steps 1, 2a, 2b and 3 are merged. Step 4 is in progress on another branch and
is not merged; treat it as next work, not as done.

1. **Step 4, the executor's evolution plane.** One actor per scope in the
   executor stages, runs, hooks, migrates, retires and inventories generations,
   files its cleanup under the scope's custody, and takes `<state>/evolution`
   as a masked path. **Exit:** raw protocol messages stage and run the fixture
   extension through a real executor, a `Close` after a stage still retires it,
   and `retire_all` is terminal so a stage that arrives after it is refused. The
   last point came from the PR #1092 review. It also needs
   `extension/memory.over_facts` and the `ext/` fact prefix on the owner port.
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
