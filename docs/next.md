# Next

## Stock compiler source builds, September 18

This dependency update is based on `83facc0f`; the executable and build changes
were checked at `97071d80`. Ordinary builds now resolve `sqlight_loom` 1.2.0
and `esqlite_loom` 0.9.0 from Hex. The native package retains OTP application
`esqlite` and the private-query retirement repair; the companion keeps the
existing `sqlight` modules and API. All six affected lockfiles were regenerated
with released Gleam 1.18.1, without changing unrelated package versions.
[ADR-002](adr/002-sqlite-binding.md#addendum-hex-distribution-for-stock-compiler-builds)
records the package boundary and maintenance cost.

The previous instruction to use a patched compiler for ordinary development is
obsolete. Hex provides the native Rebar metadata that stock Gleam needs. The
maintained compiler remains part of reproducible release certification; its
deterministic-output and path-cache patches have not been retired.

On macOS arm64, stock Gleam passed the full `make check` gate with exit zero,
including 104 storage, 1,870 client, 563 TUI and 306 code-mode tests. Lint had
zero errors and 814 warnings. `make -j1 dist` also exited zero, including server
and client smoke checks; the server release contains
`lib/esqlite-0.9.0/priv/esqlite3_nif.so`. Independent review found no actionable
issue. The new uncached stock-compiler jobs build and smoke-test complete
distributions on Linux and macOS and feed both aggregate CI gates.

Next, require the proposed head's hosted CI and Linux signoff before merge.
These local results do not certify Linux execution or reproducible artifacts.
The updater implementation is unchanged, and no installed daemon was restarted.
The sections below retain their historical verification baselines; their older
pending-work and CI statements are not current status for this dependency PR.

## Retrievable compaction payloads, September 18

Compaction now shortens eligible large successful tool-result text in its
retained tail after the cut is selected. The stub names the original session and
message entry for `history_search action=read`; original durable messages and
tool-call arguments remain unchanged. The transform is available only when
the host registered `history_search` and the strand activated it. Failures,
images, small results, unread newest exchanges and inexact provenance remain
verbatim.

The focused production fixture publishes the frozen preparation through
`api.compact` into SQLite, closes the runtime, and recovers the original entry
through SQLite's read-only exact-entry path. Provider serialization is covered
for Anthropic, OpenAI and Gemini. The remaining deliberate limitation is large
tool-call arguments: Loom retains them because rewriting arbitrary arguments
can violate tool schemas or invalidate opaque provider signatures.

## Git identity and Linux startup, September 17

PR #444's source repair is `0ea1269a`, based on `5c5ed817`; the following
release-workflow change pins its rebuilt toolchain image. This section reflects
that repair and its measured checks. The older sections retain their historical
baselines and were not reverified as part of this startup fix.

The operator's global `user.name` and `user.email` are resolved by a read-only
brokered Git query, including workspace-dependent includes. Publication is a
fixed helper operation that checks the original policy and walks existing
directory descriptors without following tool-home symlinks. It atomically
replaces only the generated configuration and always sets `user.useConfigOnly`.
Repository overrides and preserved commit authors retain their normal behavior.
[Protocol 043](../protocol-change/043-git-identity-publication.md) owns the
private helper CLI; the framed execution protocol is unchanged.

The previous edition's claim that publication ran through the broker is
obsolete. On Linux, that namespace setup could create host directories for
absent protected SQLite side files. The fixed publisher creates no mounts.
Startup also captures its final policy after database probes, and protected
mount validation ignores child masks already covered by an emitted ancestor.
The fixed read-only metadata query does not require delegated memory/process
cgroups; model executions keep their original limits and enforcement demand.

That repair originally pinned esqlite
`813d37449f1d9222c8bc3bc2374856f0fd371509` from the maintained fork and required
the patched compiler to build its native Git dependency. The September 18 Hex
publications above replace that distribution mechanism while retaining the
repair. [ADR-002](adr/002-sqlite-binding.md) records both decisions, statement
ownership and adoption evidence.

Full native and Linux gates pass: 1,868 client, 563 TUI and 306 code-mode tests,
with zero lint errors and 809 warnings. All seven identity regressions pass.
Both release smokes pass, including the Linux bundled compiler's offline build.
Linux's real-daemon soak retains 35 descriptors after every retirement across
16 measured cycles. Hosted Linux jail and complete bootstrap lanes pass at
the source repair. The rebuilt toolchain also produces matching release
artifacts on two independent Linux runners. The
[review record](review/git-identity-linux.md) distinguishes these results from
container setup failures and records the two pre-existing residuals.

Next, use the current PR head's complete CI status for review and merge.
Retiring the Git pin for a same-version Hex package requires a clean build;
the compiler's existing source-kind freshness limitation remains. General
startup directory creation can still follow a planted `.codemode` symlink
before the publisher refuses it; that separate path remains source-traced.
No installed daemon or running user session was changed by this work.

## Resident host capture and memory review

PR #441 adds the optional BEAM memory review skill in both
`skills/beam-memory-review` and `.claude/skills/beam-memory-review`, linked from
the root instructions. It also narrows the persistent assembly builder to its
command subject and build callbacks, preventing capture of the manager book and
earlier resident instances in both session and domain hosts. The regression
fails against both original captures and passes after projection. Independent
review is complete. The full `make check` gate passed with exit status zero:
1,859 client, 563 TUI, and 304 code-mode tests; lint reports zero errors and
809 warnings. A preceding run hit a schedule-residency shutdown failure; that
fixture then passed five isolated runs with each of the original and projected
managers, followed by the successful full gate. No daemon installation is part
of this work.
See the September 17 section of `docs/design-notes/daemon-memory.md`.

## Whole-host system aliases

`sandbox: resolve inherited system aliases` repairs Linux jail startup when
a whole-root policy inherits paths such as `/bin -> usr/bin`. It resolves
automatic system roots before building one plan for audit and execution,
retaining their read-only permissions and the existing masks. The original
failures reproduce on `928b3dd9`; patched focused Linux tests pass three
race-enabled runs, and full native and Linux sandbox race suites pass.
The independent review and remaining explicit-policy alias limitation are in
[the review note](review/system-root-aliases.md). Hosted CI and merge are
pending; no daemon installation is part of this work.

## Child run lifecycle

The `agent/child-run-lifecycle` branch is rebased onto `eadc0587`, including
merged PR #438. Its Agency roster
selects current or latest work, while historical handles preserve earlier
results. Resumed runs receive a fresh ten-minute default or an explicit
`agent_send.within_ms`, with per-operation parent custody and stop reasons.
Proposal 042 records the contract. The independent review and remaining
schedule/rule limitations are in `docs/review/child-run-lifecycle.md`.

Before the conflict-free source rebase, the full `make check` gate passed with
exit status zero, including 1,855 client, 466 tools, 304 code-mode and 558 TUI
tests. Lifecycle coverage includes 59
Agency, 51 agent-tool and 12 runtime lineage tests, with a deterministic
parent-finalization race regression. After rebasing, the affected package gates
also passed: 144 runtime, 466 tools, 304 code-mode and 1,858 client tests.
The rebased source commit is patch-equivalent to the reviewed implementation.
Lint reports zero errors and 809 warnings; the documentation check passes.
This work merged as PR #440 at `928b3dd9`. Installation state has not been
reverified here. The sections below retain their historical baselines.

## JSON in code mode

The `codemode/json` branch starts at `eadc0587`. Workspace and orchestration
programs can import `gleam/json`, `gleam/dynamic` and `gleam/dynamic/decode`.
The compiler seed already pins the JSON package; no dependency or capability
was added. Extension and resident module membership is unchanged.

The API is `json.parse(raw, decoder)`. The documented
[review example](examples/json_reviews.gleam) decodes records, filters them,
and encodes its result in the real jailed satellite. Both new regressions
fail on the original import policy, and all 306 code-mode tests pass with
the new policy. The independent review found no production defect; its
extension-documentation correction is fixed. Full `make check` passed with
exit status zero, including 306 code-mode, 1,853 client and 558 TUI tests.
Lint reports zero errors and 804 existing warnings; the documentation and
prelude checks pass. No installed daemon has been changed.

## Closure retention, September 16

The `memory/closure-retention` branch starts at rebased PR #437 head
`7662215415a74de5b4ca7a0547b637a21d20e41d`. It narrows supervisor restart
inputs, extension hook/tool wrappers, and nested provider observation facades.
The [measurement note](design-notes/daemon-memory.md#2026-09-16-supervisor-restart-inputs-and-provider-facades)
and [review inventory](review/closure-retention.md) distinguish reproduced
retention from remaining candidates. The 90-warning base census falls to 78;
R12 still warns and does not prove a memory bound.

The new regressions fail against the old captures and pass after projection.
The runtime fixture measures an actual started supervisor; the client fixtures
measure flattened hook and provider terms. Independent review found no
production defect; its preview-layer assertion and comment-spacing findings
are fixed. Full `make check` passed with exit status zero, including 140
runtime, 222 provider, 1,852 client, and 558 TUI tests. Documentation and lint
checks pass with existing warning censuses. The default gate reported skips
for unseeded code-mode and extension fixtures, opt-in packaged-daemon fixtures,
and platform-specific cases; those extra lanes were not run in this patch.

The initial patch is published as PR #438. The operator has updated and
restarted the daemon; the first ordinary profile reports 1,311 MiB VM memory,
mostly process heaps, with allocator instrumentation available. Workload and
resident counts differ from the earlier daemon, so this is not a matched
reduction measurement. One sampled gateway retains full runtime instances in
its socket authentication callbacks. The follow-up projects that attachment
to binding, permit and registry, and its real WebSocket regression fails on
the old code and passes with the projection. All ten socket tests pass. The follow-up full `make check` also passes
with 1,853 client, 558 TUI and 304 code-mode tests. Independent review found
no defect; opt-in shipped-daemon and Linux-only checks remain unexercised.

Take matched admission, idle, and explicit post-collection cuts before claiming
an installed memory reduction. Inspect one large state at a time from an
external process with a bounded heap. Remaining job/schedule/workspace
captures need measurements before edits. Generic receive code lacks the
fresh-reference optimization, but no observed mailbox backlog or accumulating
loop allocation justifies changing it here.

## Earlier directory-permission work

## Transcript copy and assistant presentation

The `tui/transcript-copy` branch is based directly on merged main
`b3bb6b9d`, checked September 16, 2026. PR #437 is merged in this base;
the directory-permission notes below describe its earlier verification.
Memory-retention work is separate in PR #438 and is not included here.

Transcript selection now removes the selected portion of each speaker gutter
while preserving authored indentation and blank lines. Gutter metadata is
built with the rendered rows and captured with the displayed frame, so a
paced scroll cannot apply a newer layout to older selected cells. Screen-row
line breaks remain screen-row line breaks; soft-wrap reconstruction is not
implemented. Assistant replies retain the blue diamond, omit the Agent label,
and use a subtle blue-green background across the reply area.

The independent review identified frame/metadata mismatch, unnecessary history
projection during streaming, and a quadratic gutter traversal; all three were
fixed and checked. Plain Markdown spans share their shaded style within each
reply to preserve the existing streaming-memory bound. All 563 TUI tests pass,
including the unchanged heap bound and new rendered selection and pacing
regressions. TUI lint and documentation checks pass with zero errors.

Next, check the published branch's CI and exercise copy/paste in the installed
terminal after updating the client. Exit: paragraph and code indentation paste
correctly, reverse and partial selections agree, and the reply shading remains
readable with the user's terminal palette. No installed client or daemon was
changed by this work.

## Earlier work and verification

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
exit status zero after the dialog follow-up, including 464 tools, 1,850 client
and 558 TUI tests. Lint and documentation checks report zero errors; warning
censuses remain. Seeded
code-mode checks also passed: 304 code-mode tests and 13 client live tests,
with the Linux-only MCP death-observation fixture reporting a skip.

Shell and code-mode arguments can request extra filesystem or full-network
permissions through existing action-bound approvals before execution. Native
file tools can ask for their missing target access directly. Kernel errors
remain tool results because automatically retrying an arbitrary program could
repeat earlier effects.

PR #437 also adds automatic permission dialogs with Allow once, Allow for
session, and Deny. Remembered filesystem and full-network grants survive a
session reopen. Proposal 041 records the atomic approval-and-permission write
and the captured-question contract. A fresh independent review identified and
verified a fix for a late lookup replacing an open dialog. Raw syscall errors
still require the agent to submit a new permission request; no command is
automatically replayed after partial execution. Manual installed-TUI testing
remains the next operator check.

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
