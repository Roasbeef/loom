# Next

Read this first for the current work, settled boundaries and remaining
acceptance. Detailed verification belongs in the linked review records.

This edition is based on merged main `228078b6`, including updater #423 and
compiler-pin #424, plus the local `make update` and release-automation changes,
checked September 15, 2026. PR #424 passed hosted CI and Linux signoff before
merge. The new tag workflow has passed local script tests and workflow lint;
its native macOS reproduction and GitHub draft upload remain unverified until
hosted execution. No release was tagged or published by this work.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Daemon profiling, session archive, provider completion cleanup and numbered diffs | #417, #418, #420 and #421 are merged ancestors of the baseline. Their current code was retained. |
| Updating a running daemon | #404 is merged at the baseline. It supplies immutable installation, graceful drain, build identity and reconnect. |
| Broad closure captures | #414 is merged and included in the baseline. R12 warns about retained outer records used only through direct field access; no duplicate implementation issue is needed. |
| Native release updater | `loom update` resolves manifests, optionally verifies local-keyring signatures, downloads through Gun, stages checked archives, publishes complete trees and gracefully restarts the shared daemon. Installed bundled and slim transitions passed on macOS arm64. |
| Release reproduction | Canonical archives, complete manifests, a committed seed lock, toolchain inventory and a two-runner Linux x86_64 candidate workflow are implemented. Two clean Linux containers on one host produced identical complete artifacts with the patched compiler. The standalone workflow supports independent hosted comparison; the new combined tag workflow still needs validation. |
| Compiler pin and version reporting | The maintained Gleam patch is applied in CI and both Docker recipes, with cache-key separation and a cold-build fixture. `loom version` and `loom --version` report the invoked client build without starting a daemon. |
| Release operations | `make update` builds and installs the current checkout. `make release-tag` previews an atomic main/tag push; `RELEASE_ARGS=--push` executes it. The tag workflow builds Linux x86_64 and macOS arm64 twice, compares and binds artifacts, then creates a draft. |
| Broader Gun adoption | [#422](https://github.com/Roasbeef/loom/issues/422) owns the transport assessment. It is an inventory and requirements comparison, not a blanket migration. |

[Release updater verification](review/release-updater.md) records the updater's
review and gates. PR #423 at `21da91d8` has successful CI run
[34953017891](https://github.com/Roasbeef/loom/actions/runs/34953017891) and
`signoff/linux`. The compiler-pin changes passed 513 TUI tests, TUI lint,
17 Python script tests, the compiler cache fixture, launcher regressions,
bundled-client smoke and documentation checks; warnings remain in the existing
lint and documentation censuses. [Compiler evidence](review/compiler-cache.md)
separates these checks from the pending hosted comparison.

Main's regular CI at `cc797e41` passed run
[34935852229](https://github.com/Roasbeef/loom/actions/runs/34935852229).
Its later scheduled Nightly run
[34968828045](https://github.com/Roasbeef/loom/actions/runs/34968828045)
failed the cold gate and seeds 1001 onward soak job. Their causes have not been
classified here; the successful regular run does not make that nightly green.

### Corrections to the previous edition

The earlier handoff said #404 remained open; it is merged. Its deliberate
manual restart procedure remains valid for `make install` and
`loom update --install-only`; the new default `loom update` performs an
authenticated graceful restart after publication.

Canonical packaging alone does not establish reproducibility of a release that
also carries OTP, native libraries and compiler caches. The new recipe fixes
the source prefix, records the toolchain and locks the seed's complete dependency
graph. The previous edition had no successful Linux comparison. The patched
compiler now gives same-host repeatability across all five release files; the
remaining claim is comparison across independent hosts, then other platforms.
The compiler pin is maintained locally and has not been accepted upstream.

A portable slim client cannot use its builder's platform as its update target.
Its launcher now detects the execution host. The archive reader also admits
Gleam's generated `@` module separators while preserving path containment.
Both corrections are covered by the installed-release smoke.

## What to do next

1. Review and merge the local update wrapper and release-automation changes.
   **Exit:** applicable CI and signoff at the proposed head. No live daemon or
   installed prefix is a test fixture.
2. Exercise the tag workflow on the intended first release after that merge.
   **Exit:** two matching native builds per platform, successful smoke checks,
   and a draft with all ten expected assets bound to the requested commit.
   The new macOS fixed-prefix recipe has not yet run on hosted builders. Inspect
   any interrupted draft upload before retrying; existing assets are not replaced.
3. Establish production release keys when signing is enabled. **Exit:** approved
   fingerprints, independently distributed trust roots and a tested overlap
   rotation. Unsigned releases remain permitted by default in this change;
   a present signature always requires a valid supplied keyring.
4. Assess other HTTP consumers under **#422**. **Exit:** each consumer has a
   documented keep/adopt/defer decision based on its streaming, policy and
   ownership requirements. No transport migration is bundled into this updater.

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

## Deliberately open

- Production signing and default embedded release trust roots are not enabled.
- Independent-host full-artifact reproduction is pending. Same-host Linux
  repeatability passed; other supported platforms remain unverified.
- Old immutable release trees require coordinated manual cleanup. Neither the
  installer nor updater infers that every process has stopped using them.
- Broader transport adoption belongs to #422. R12 closure-capture lint is already
  implemented by #414.

## How to verify

```sh
make check
make doc-check
make codemode-seed release release-client tui-shipment
make release-smoke release-client-smoke
make check-release-update
make update-release-smoke
python3 scripts/release-compare.py first/dist second/dist
```

**Capture each gate's own exit status.** A successful log reader proves nothing
about the process that wrote it. Do not edit a shell driver while it is running:
a changed file offset can turn a successful package suite into a failed wrapper.

**Use one build per checkout.** Installed-bundle smoke tests use private copied
release trees and state roots. Enforced code-mode worktrees belong outside
`/tmp`, which the Linux jail replaces with scratch.

**Reap fixture-owned children concurrently.** A stopped but unreaped daemon is
still a native lifetime; an updater correctly refuses replacement while it is
present. Keep failed fixture trees until their processes have retired.

**Keep local gates separate from release certification.** Only
`scripts/signoff.sh` posts Linux signoff for a pushed head. Native unit tests,
canonical packaging tests and a local installed-update smoke do not certify
independent artifact reproduction. See [execution](execution.md).
