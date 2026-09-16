# Next

Read this first for the current work, settled boundaries and remaining
acceptance. Detailed verification belongs in the linked review records.

Reconciled September 16, 2026 for PR #433: its CI repair `1cf4c371` plus
merged main `c5fb6038`, including PR #434. The combined tree still needs
its own gates. A passing result on either parent does not certify this
integration, and PR #433 remains open with `full` as the default roster.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Tool roster and capability discovery | PR #433 implements per-session `minimal` and `full`, catalogue schema v4, `cap://` and `job://` reads, and workspace history, memory and context capabilities. Protocol 039 records the semantics. The real-model comparison is pending. |
| CLI help regression | `1cf4c371` preserves general launcher help before version checks reuse stdout. The original script fails and the repaired full script passes against fresh `c74b527a` shipments. The same assertion caused hosted bootstrap, macOS e2e and Linux signoff failures on that head. |
| Code-mode diagnostics, source preview and image handling | PR #434 merged as `c5fb6038`. It includes source diagnostics, the compact program preview, image reads, vision routing, provider image budgets, README assets and the advisor fixture ordering correction. Integration must preserve those features alongside scheme reads. |
| Native updates and release tooling | PRs #423, #424 and #432 are merged ancestors of this baseline. The implementation and its historical validation are recorded in the release and compiler review documents. Release certification is separate from this roster change. |
| Advisor delivery and prompt-cache feedback | PRs #430 and #431 are merged. Their implementation is retained by this integration. |

[Release updater verification](review/release-updater.md),
[compiler evidence](review/compiler-cache.md), and the PR bodies retain
the earlier test records. This handoff makes no fresh claim about live
providers, installed-daemon behavior or independent-host release reproduction.
No installed configuration or running user daemon is part of the CI fixture.

### Corrections to the previous editions

The roster edition said no PR existed and named `81f2bb6a` as its head.
PR #433 is open, and its original reviewed head was `c74b527a`. Its
not-run list is also stale: the shipped help test was run and its failure
was reproduced and repaired. Linux signoff ran on `c74b527a` and was red
on that same assertion; it was not still queued.

The incoming main edition described PR #434 as unmerged. It is merged at
`c5fb6038`. PRs #430, #431 and #432 are also merged. The earlier gate
counts remain historical evidence, not results for this combined tree.

### Roster behavior and limits

The [roster design note](design-notes/tool-roster-and-dyn.md) owns the
architecture and reported byte measurements. `minimal` retains `bash`,
`grep`, `fs_read`, `fs_write`, `fs_edit` and, when available, `code_mode`.
Its unflagged configuration offers both code-mode seams; an explicit
`--codemode-seams` still wins. The default remains `full`.

[Protocol 039](../protocol-change/039-session-tool-roster.md) owns
per-session persistence and creation-retry equality. An explicit roster
survives restart. An inherited roster follows the daemon configuration
at each boot, while its pinned prompt and seeded active tool names do
not follow that change. That mismatch is documented and remains open.

`cap://` reads expose capability declarations without adding authority.
`job://` reads reuse zero-wait job polling. Ordinary filesystem reads
retain PR #434's image support; `cap/fs.read` remains text-only. The
workspace and orchestration seams remain disjoint except for `cap/report`.

The default prompt pack is version 8. It chooses direct-tool or code-mode
delegation text from the registry and adds capability-discovery guidance.
The new fragments are required by pack validation, so older custom packs
need updating. Minimal delegation currently omits some of the general
briefing, waiting and communication guidance retained by the full roster.

## What to do next

1. Finish CI verification for PR #433's integrated head. **Exit:** the
   relevant local gates, hosted Linux/macOS CI and Linux signoff pass on
   the same pushed commit. Preserve all image and scheme regression tests;
   do not infer success from either parent. This does not authorize merge.
2. Drive `minimal` and `full` on equivalent scratch sessions. **Exit:**
   repeated matched tasks report completion, total calls, token usage,
   elapsed time and compilation failures, including failures after a
   `cap://` read. Keep the default `full` until evidence supports changing it.
3. Refresh the complete-roster measurements under **#94**. **Exit:**
   same-head figures separate description trimming from schema-count
   reduction and compare equivalent seams. The existing 28 KB bound is
   workspace-description coverage, not a bound on default minimal's full
   both-seam array.
4. Settle inherited-session consistency and prompt parity. **Exit:** the
   effective registry, pinned instructions and active names agree after
   restart, with a documented compatibility choice; common delegation
   principles survive both roster renderings. These are follow-up decisions,
   not behavior silently changed by the CI repair.
5. Pursue saved programs under **#435** independently. **Exit:** program
   bytes are resolved and bound before vetting and execution. Persistent
   satellites and continuation handles remain the separate **#107** design.

## Rulings already made


Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Archive is visibility, not initialization or revocation.**
[Protocol 035](../protocol-change/035-session-archive.md) keeps `Reserved` and
`Saved` unchanged. Archive and restore are owner mutations serialized with
runtime admission and require no live slot. Restore neither opens a runtime
nor restores a workspace default. Memberships, domains, and conversation files
remain; ordinary owner/member pages exclude archived rows before pagination.

**Activation is explicit and uncertain mutations are not retried.**
[The daemon ruling](design-notes/single-daemon.md#execution-ruling),
[ADR-009](adr/009-record-terminal-attempt-custody.md), and
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) own these boundaries.
Listing and preview do not start saved sessions.

**Cleanup requires the original owner's evidence.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains native
custody until observed exit. [Protocol 028](../protocol-change/028-provider-failure-context.md)
preserves diagnostics without weakening that proof. Timeouts and late `noproc`
are not retirement witnesses.

**Presentation does not own durable truth.**
[Protocol 030](../protocol-change/030-context-observation.md) reads captured
state; [protocol 031](../protocol-change/031-tool-output-stream.md) bounds live
tool output; [protocol 033](../protocol-change/033-abort-halts-held-input.md)
defines the held-input halt. Exact entry identity, rather than equal text or
capture timing, determines the streamed response handoff in #416.

**Authority and process boundaries remain explicit.**
[Protocols 015](../protocol-change/015-daemon-control-and-session-attachments.md)
and [020](../protocol-change/020-minimal-jail-root.md) define server-owned
activation and jail policy. Portable packages stay free of I/O and externals;
process ownership follows [the Weft mapping](weft.md). Use the design/spec and
owning architecture documents for the older subsystem rulings.

**Release authenticity and restart are explicit.**
[ADR-012](adr/012-release-manifests-and-updates.md) defines the manifest, optional
signatures, explicit local trust, fixed-prefix reproduction and native download
boundary. [Updating](updating.md) defines publication and graceful restart.
Socket loss alone never authorizes replacement; the captured native lifetime
must retire and the accepting daemon must report the expected full commit.

**Roster selection changes presentation, not the capability boundary.**
[Protocol 039](../protocol-change/039-session-tool-roster.md) and the
[design note](design-notes/tool-roster-and-dyn.md) retain vetted code mode
as the long-tail entry point. A jailed capability CLI was considered and
rejected. Unflagged minimal offers both seams; explicit seam selection wins.

## Deliberately open

None of these is unfinished work somebody forgot.

- The inherited-roster/pinned-prompt mismatch and custom-pack migration
  guidance remain open; see protocol 039.
- Whether `cap/context` belongs on the orchestration seam is undesigned.
  The extension bridge deliberately composes no recall arm.
- `history://`, `agent://` and artifact resolvers remain under **#192**.
- Index-only versus index-plus-types descriptions need model measurements.
- Typed MCP schema refresh remains **#112**; third-party validation remains
  **#110**. Lazy documentation does not itself settle either boundary.
- Async code-mode lifecycle and recovery remain **#107**, separate from
  source reuse in **#435**.
- Release trust roots, independent-host reproduction and safe cleanup of old
  immutable installations remain separate release work. No pruning is implied.
- Broader HTTP transport adoption remains **#422**.

## How to verify

```sh
make check
make doc-check
make codemode-seed tui-shipment server-shipment
bash scripts/cli_help_test.sh
make e2e-codemode
LOOM_SIGNOFF_HOST=<linux-host> make signoff-remote
```

**Capture each gate's own exit status.** A successful log reader proves
nothing about the command that wrote it.

**Build shipments at the tested commit.** The help regression checks build
identity, and a binary from a parent commit is not an exact-head result.

**Use one build per checkout and keep enforced fixtures outside `/tmp`.**
Run the seed before a fresh code-mode drive, and do not edit a shell driver
while it is running. User daemons and installed prefixes are not fixtures.

**Verify the integration again.** Independently green parents can conflict
semantically. Only the gate's own verdict may post Linux signoff; see
[execution](execution.md) for the complete process.
