# Current handoff

Baselined October 13, 2026 against `bcb02be01` on `fix/strand-tps`,
with main through `e86d6fddd` integrated.
This edition covers per-strand generation timing. The installed daemon has
not been updated. Rewrite this file when the next body of work finishes.

The previous edition covered web history browsing and reported gates for its
own head. Those results do not validate this branch. Its evidence and open
history decisions remain in the
[prior handoff](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
The project-wide plan remains `docs/issue-plan.md`.

Main also includes the register-decode cache from merged PR #972. Its exact
blob keys, bounded store-owned inventory and corruption/lease regressions live
in the storage package. The [measurement report](review/register-decoding-2026-10-12.md)
records its performance evidence and limits. Its complete prior handoff and
live memory follow-ups remain in the
[register-decoding handoff](https://github.com/Roasbeef/loom/blob/e86d6fddd/docs/next.md).
Those branch results are historical evidence, not validation of this combined
head. No storage source conflict occurred during integration.

## Where the tree is

The terminal and web view now share `session_view/generation_rate.State`,
a session-scoped ledger indexed by strand. Every observed strand owns its
request clock and last measured output rate, including background agents.
The header reads the selected strand through `session_view/model` accessors.
Switching focus neither clears a running clock nor borrows the parent's rate.

Live phase events and fresh coherent captures update the ledger. Captures
observe phases after transcript stream retirement, and reprojecting an older
capture on focus does not observe its phases again. Request identity survives
the active-only stream projection, so a lagging capture cannot turn a partial
background window into a complete measurement. Settlement consumes only its
strand's clock. Roster replacement prunes removed strands; a session change
clears the ledger.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**A partial observation cannot measure full-request TPS.** A client joining an
already running generation cannot know its original start from the current
wire data. The ledger can show elapsed observation time, but retains that
strand's previous complete rate, or no rate if none exists. The rule lives in
`generation_rate` and its regression tests. No protocol extension was added.

**Focus selects timing; it does not own timing.** The ledger belongs to the
shared session state. Both hosts use the same strand-specific accessors.

## How to verify

`make check-affected` selects the gates affected by the current diff against
main, together with the static gates and native prerequisites.
Full Linux signoff remains required for the combined head. Run `make signoff-remote` against the pushed head; the PR's exact-head
commit statuses are the record of hosted checks and Linux signoff.

`packages/web_view/test/strand_rate_test.gleam` drives the actual component and
header with an injected clock. It covers independent parent/child rates,
switching back, focusing a background generation midway through it, attaching
mid-generation, consecutive requests, and lagging captures. The shared ledger
suite checks clock consumption, new request identity and roster removal.

Mutation checks restored three old behaviors separately: reading main's rate
for every strand, resetting a clock on focus, and accepting a lagging background
phase. Each compiled and failed its corresponding header assertion. The
independent review's capture-ordering findings were fixed and rechecked.

**Read a gate's own exit code.** `check-affected` records each lane's status and
its skip census under `build/affected`. Native socket tests need the host's
normal permissions. Preparation must finish before package lanes start.
`docs/execution.md` carries the remaining gate and sandbox hazards.

## What to do next

1. Review and land the per-strand TPS PR once its exact-head affected checks,
   hosted checks and required Linux signoff pass. Exit: the reviewed head is
   merged. Deployment remains a separate operation.
2. Follow `docs/issue-plan.md` for the next project milestone. The queue-control
   PR is separate work and is not included in this branch.

## Deliberately open

An exact TPS for a request already running before attachment would require an
original start timestamp or duration from the server. The current client
conservatively leaves that request unmeasured. None of this is unfinished work
somebody forgot.
