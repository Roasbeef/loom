# Next

The current directory-permission work is based on merged main `c5fb6038`,
checked September 16, 2026. The earlier sections below describe their own
historical verification. In particular, their claim that PR #434 is unmerged
is obsolete: this branch starts at its merge commit. Installed-release status
has not been rechecked.

## Session directory access

The `session-directory-permissions` branch adds `/add-dir PATH` for
read-only access and `/add-write-dir PATH` (also `/add-dir --write PATH`) for read/write access. Additions
are durable for one saved session and apply to subsequent native file tools,
foreground commands, background jobs and code-mode workspace capabilities.
Existing executions keep their captured authority. Protected writes remain
denied. Proposal 040 records the ownership and wire contract; the
[review record](review/session-directory-permissions.md) records the findings,
regressions and remaining boundaries. The full `make check` gate passed with
exit status zero, including 464 tools, 1,843 client and 555 TUI tests. Lint and
documentation checks report zero errors; warning censuses remain. Seeded
code-mode checks also passed: 304 code-mode tests and 13 client live tests,
with the Linux-only MCP death-observation fixture reporting a skip.

Shell and code-mode arguments can request extra filesystem or full-network
permissions through existing action-bound approvals before execution. Native
file tools can ask for their missing target access directly. Kernel errors
remain tool results because automatically retrying an arbitrary program could
repeat earlier effects.

Boot defaults are unchanged. Host-filtered networking remains issue #214;
full secret-store backend support remains issue #181. Host-command secret
resolution and origin-bound brokered HTTP credential injection already exist.
Neither issue is part of this directory-permission implementation. No daemon
or installed configuration was changed.

## Earlier work and verification

## Jailed scratch follow-up

The `codex/jail-scratch` branch is based on merged main `c5fb6038`.
The earlier #434 paragraphs below describe its pre-merge validation;
#434 is included in this branch's base.

The helper now publishes `LOOM_SCRATCH_DIR` through the effective environment
allowlist. It names the private macOS directory, Linux's mounted `/tmp`, or
the configured host scratch path. It is absent when degraded Linux has no
scratch mount. Explicit `TMPDIR` values remain intact. Shell guidance uses
`${LOOM_SCRATCH_DIR:-$TMPDIR}` and explains that private scratch lasts for one
command or background job; later calls need workspace files.

The native regression reaches the real helper, writes and reads scratch,
checks macOS cleanup and sibling isolation, and verifies environment filtering
and explicit `TMPDIR`. Removing scratch publication makes the regression fail.
The client fixture also exercises the portable expression through the real
shell tool and broker. The independent review found no correctness or security
issues; its stale environment documentation finding was corrected.

Native sandbox vet/build/tests, all 459 tools tests and all 1,834 client
tests passed on macOS. Lint, formatting and documentation gates passed
with existing warnings. Hosted CI is recorded in the PR. Linux kernel execution
and separate Linux signoff have not been run locally for this branch. No
installed daemon was changed.

## Code-mode and image fixes (PR #434)

PR #434 on `fix/codemode-diagnostics` combines the September 15 code-mode
diagnostics, compact source preview, and image-handling fixes. It addresses the
attachment reports. The composer shows a count and one row per accepted image;
the existing four-image/20-MiB limit remains, with a named rejection for a fifth
file. GLM-5.3 defaults to text-only without a configuration migration, while
explicit overrides and the distinct Flash model retain their behavior.

Vision classification now distinguishes a new attributed prompt from old failed
image turns after projection removes error responses. It also reads the whole
immutable admission batch, so releasing a held image and text together keeps
the image. Image-bearing admitted runs stay on vision through tool and run-end
continuations; a new text-only run does not inherit that requirement. Durable
images are preserved. Unknown model identifiers retain the legacy image-capable
default; this is not automatic capability discovery for arbitrary endpoints.

The independent review found and verified the held-batch correction. TUI tests,
focused vision regressions, both package lints and documentation checks pass.
The final package gate passed 551 TUI and 1,828 client tests with its own exit
status checked. Optional seed-dependent and shipped-server fixtures reported
skips; live provider requests and installed-release behavior were not tested. No daemon was restarted and no
installed configuration was edited. These changes are not merged or installed.

The disk-read follow-up extends `fs_read` to PNG, JPEG, GIF, and WebP files.
It returns the existing durable image block, uses file signatures rather than
extensions, and retains the workspace checks and 8 MiB file limit. A tool-result
image now routes admission and dispatch through vision when the primary model
is text-only. Following text prompts placeholder old tool images without
altering durable history. OpenAI serialization now preserves these images in a
user turn after the complete tool-result batch, with captions naming each call;
Anthropic and Gemini already supported tool-result images. `cap/fs.read`
continues to return text.

The disk-read package gate passed 454 tools, 214 provider, and 1,830 client tests,
including a real PNG read through production tool dispatch, durable history,
vision admission and OpenAI serialization. All three package lints have zero
errors, with existing warning censuses retained. Documentation checks pass
with existing warnings. The independent review found no actionable issues.
Optional code-mode seed, Linux-only and shipped-release fixtures reported skips;
live provider calls and an installed daemon remain untested. The follow-up is
included in PR #434, not merged or installed.

The request-budget follow-up keeps the same conversation context for vision
routing and adds a positive per-model `max_images` setting, default eight.
Every actual provider attempt bounds attached and tool-result images against
its own limit. The oldest historical images become explicit placeholders;
current-run images remain intact or cause a local terminal refusal before HTTP.
Text, answers, tool metadata and stored image bytes remain unchanged. Fallbacks
start from the original request, so a larger fallback retains its full allowance.
This does not identify or deduplicate versions of the same image.

Held prompt batches use the operation's immutable source leaf to protect all
current images even when the last prompt is text. Review caught a compaction
case that counted copied historical images as current. A regression reproduced
the false refusal with eight historical images and one current image, then
passed after counting original message entries through the preserved parent
chain. The reviewer verified that correction. A later operation starts a new
protection boundary and can recover after an oversized image request.

The request-budget gates passed 222 provider tests and, after the compaction
correction, 1,834 client tests. Provider/client lint and documentation checks
have zero errors with existing warnings retained. Optional seed-dependent,
Linux-only and shipped-server fixtures reported skips. Live provider calls and
installed-daemon behavior remain untested. The changes are included in
PR #434, not merged or installed.

The integrated branch retains the original parse diagnostics and the 60-line
compact code-mode preview alongside these image fixes. Execution of reusable
programs from files or named notes remains separate in issue #435.

The integrated gate passed 459 tools, 222 provider, 304 code-mode, 1,834 client,
and 553 TUI tests, including the seeded code-mode fixture. The gate exited zero;
package lint and the documentation gate also passed with existing warnings.
The integration review found no actionable issues. The client suite reported
Linux-only and shipped-release fixture skips; live provider requests and an
installed daemon remain untested. Check the updated PR head's hosted CI before
merge. Nothing was merged or installed by this integration.

The README now introduces the implemented features, setup and update paths,
with diagrams and a real code-mode terminal capture using a scripted local
provider. The former launch reference is preserved in [Running Loom](running.md).
Documentation checks, local links, rendered diagrams and the capture were
verified; the public-facing claims received an independent source review.
The selected woven logo is included as font-independent SVG assets, with
light and dark README variants and separate color and monochrome marks.

The advisor integration fixture now holds its scripted nudge until the second
operator turn has settled, then observes delivery before admitting the third.
The earlier ordering let a valid run-start drain share an operator request,
making the expected five requests become four. The exact count, quiet-verdict
bound and final duplicate-fence assertion remain intact. Twenty focused runs
under constrained scheduling, all 1,834 client tests, lint, documentation checks
and independent review passed. Hosted CI and Linux signoff must be checked again
at the commit containing this fixture fix.

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
| Advisor nudge priority | Landed on `advisor/nudge-priority`: a nudge now delivers at the primary's run end or at once on an idle primary, rather than waiting only for its next run start, bounded by one unsolicited delivery per operator turn; a new `advisor_pending` observation lets the terminal show the undelivered queue beside the composer. See [the design doc](architecture/advisor.md) and issue #425 for what is still open — the pending panel's three-row cap has no way to expand. |

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

The local `fix/codemode-diagnostics` branch also keeps up to 60
syntax-highlighted source lines in compact code-mode calls. The preview is
present while awaiting a result and survives success or failure; Ctrl+G exposes
the full program. The TUI gate passed 551 tests; lint, documentation checks and
independent review passed. It is not yet merged or installed.

The local `fix/codemode-diagnostics` branch improves code-mode parse refusals
with submitted-source line/column, a bounded excerpt and caret, source-token
spelling, and a grouping-parenthesis hint. The reported failure was invalid Gleam
expression grouping, confirmed by the compiler formatter. Tools (455 tests),
code mode (304 tests, including the seeded end-to-end run), package lint, the
documentation gate and independent review passed. The branch is not yet merged
or installed; no user session was changed or restarted.

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
