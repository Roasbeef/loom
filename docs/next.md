# Next

Read this first for the current work, settled boundaries and remaining
acceptance. Detailed verification belongs in the linked review records.

Reconciled September 16, 2026 for PR #433's gap fixes on top of `3b6f6d3d`.
That integrated parent passed hosted CI. The follow-up keeps `full` as the
default and repairs prompt parity, custom-pack compatibility and inherited
restart consistency. Its own verification is recorded in
[the gap-fix review](review/pr433-gap-fixes.md). PR #433 remains open; no merge
is authorized.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Tool roster and capability discovery | PR #433 implements per-session `minimal` and `full`, catalogue schema v4, `cap://` and `job://` reads, and workspace history, memory and context capabilities. Protocol 039 records the semantics. The effective roster is now pinned before recovery. A matched Kimi smoke comparison completed; a broader promotion benchmark remains open. |
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
per-session persistence and creation-retry equality. Its addendum makes
inheritance a first-activation choice. `session/tool-roster` stores the
resolved roster and seams before recovery; a changed daemon default cannot
replace that surface on restart. Existing prompt and active-name registers,
including restricted child lists, are preserved.

`cap://` reads expose capability declarations without adding authority.
`job://` reads reuse zero-wait job polling. Ordinary filesystem reads
retain PR #434's image support; `cap/fs.read` remains text-only. The
workspace and orchestration seams remain disjoint except for `cap/report`.

The default prompt pack is version 9. Both rosters retain common delegation
principles, with separate API instructions. Checkpoint boards use
`cap/strand`; long-term consolidation uses `cap/memory`. Inline custom packs
remain valid, while packs opting into new bindings must supply the selected
fragments. Complete-array measurements and model-smoke limitations are in the
[gap-fix review](review/pr433-gap-fixes.md).

## What to do next

1. Finish CI verification for PR #433's new head. **Exit:** focused local
   gates and hosted Linux/macOS CI pass on the pushed commit. Remote Linux
   signoff still needs explicit authorization after automatic approval review
   rejected the PR-specific remote run. This does not authorize merge.
2. Broaden the model comparison before any default change. **Exit:** repeated
   matched tasks across models report completion, calls, tokens, elapsed time
   and compile failures after discovery. The Kimi smoke completed under both
   rosters but minimal needed more calls and recoveries; keep default `full`.
3. Use the checked-in complete-roster measurement under **#94**. **Exit:**
   future cost claims compare equivalent seams and separate tool-array bytes,
   prompt bytes and provider tokens. The older 28 KB check covers only a
   workspace description, not default minimal's both-seam array.
4. Preserve the repaired prompt and restart contracts. **Exit:** new changes
   keep common delegation principles in both renderings and never silently
   widen existing strand active lists during restart.
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
