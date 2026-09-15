# Next

Read this first for the current work, settled boundaries, and remaining
acceptance. Detailed measurements and review findings belong in their own
records.

This edition is based on main `fe3cfbf2` and the local #404 takeover commit
`dde20ee8`, checked September 14, 2026 (September 15 UTC). GitHub still has
#404 at `3b2dafb9`; the takeover commits have not been pushed. The broader
feature, issue, and memory audit from the previous edition was not repeated.
Its historical detail remains available at `6f598fc0:docs/next.md`.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Daemon profiling | #417 merged as `e41298c5` after hosted CI and Linux signoff passed at its final head. |
| Session archive | #418 merged as `9a00da99` after hosted CI and Linux signoff passed at its final head. Protocol 035 owns archive/restore. |
| Provider completion cleanup | #420 merged as `991a2c31` after hosted CI and Linux signoff passed at its final head. |
| Numbered diff previews | #421 merged as `fe3cfbf2` after hosted CI and Linux signoff passed at its final head. Its macOS test failure passed one bounded rerun after a clean-HOME local module run passed. |
| Updating a running daemon | #404 remains open. The local takeover integrates all four merges and fixes drain ordering in `dde20ee8`. All 1,807 client tests passed; independent drain review found no actionable defects. Installer repair and final shipment validation remain outstanding. See [the takeover record](review/update-takeover.md). |

The latest main CI run, `34923050531`, was still in progress at this check.
The preceding main run at `991a2c31` succeeded. The PR-head gates above do not
establish the outcome of that later main run.

### Corrections to the previous edition

The previous edition called #417, the archive branch, and the provider cleanup
fix unfinished. All three are merged, along with #421. Its update row also
claimed versioned installation never mutates a live daemon's tree. That claim
was false: replacement, legacy migration, and pruning still lack sufficient
live-process ownership evidence. The installer has not yet been repaired.

The original drain fixtures missed the authenticated production path, which
re-enters the registry during delivery. Running callbacks inside the registry
blocked that path. The takeover invokes a snapshot of callbacks outside the
registry and root receive loops, fences gateway mutations, and flushes held
returns through the real socket before teardown. Worker completion still does
not replace the original lifetime witness.

## What to do next

1. Finish **#404**, addressing **#392**. The pending installer preference is
   whether each installation may use a fresh immutable directory and retain old
   trees for manual cleanup. Automatic cleanup requires a separate ownership
   design; retaining only the current and previous release cannot identify
   every live process. **Exit:** settle that preference, implement and test the
   installer, finish review of the remaining update path, run the full gate and
   release checks, push to the existing PR, and obtain hosted CI plus Linux
   signoff on the final head before normal merge. Do not restart the user's
   daemon as part of verification. Protocols 037 and 038 remain proposed.
2. Verify the paired client/server release after the update path lands.
   **Exit:** release smoke and update/reconnect evidence from the actual bundle,
   with its build identity recorded. Local client tests alone do not establish
   installer or shipment acceptance.
3. Revisit older work only through its owning issue. The live open PR inventory
   also contains **#397**, **#396**, **#395**, and **#278**; they were left
   untouched by this merge pass. **Exit:** obtain scope for that work and check
   current evidence before carrying forward an old diagnosis.

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

## Deliberately open

None of these is unfinished work somebody forgot.

- A durable restart-specific cancellation reason remains a separate protocol
  decision; protocol 038 preserves the existing generic abort diagnostic.
- Installer cleanup policy is undecided. The proposed immutable-directory
  repair has not been implemented while that preference is pending.
- Earlier memory footprint observations, startup timing, jailed CLI credential
  setup, advisor deferrals, and the wider issue inventory were not re-audited.
  Consult their owning records before treating them as current defects.

## How to verify

```sh
make check
make doc-check
make codemode-seed
make release-smoke
bash scripts/test.sh client --match daemon_root_test
bash scripts/test.sh client --match gateway_test
bash scripts/test.sh client --match session_socket_test
```

**Capture the gate's own exit status.** A successful log reader proves nothing
about the command that wrote the log. **Use one build/gate at a time per
checkout.** Enforced code-mode worktrees belong outside `/tmp`, which the Linux
jail replaces with scratch.

**Use an empty HOME for isolated integration fixtures.** Personal hooks can
change fixture behavior. Preserve required tool and cache paths explicitly.
Keep modules using VM-global capability fixtures in `scripts/serial-tests`.

Only `scripts/signoff.sh` posts Linux signoff for a pushed head. Local package
gates do not establish Linux enforcement or shipment acceptance. See
[execution](execution.md) for the remaining operational rules.
