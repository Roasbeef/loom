# Current handoff

This edition covers the shell-directory and code-mode work on
`codex/working-directory-code-mode`, based on `153fc6b60`, on 2026-10-06.
The original checkout was left alone. The work lives in
`.worktrees/working-directory-code-mode`; it has not been installed into the
running daemon, pushed, or merged.

The previous edition was baselined on `556e419af` on 2026-10-04. Its hosted
PR status and release claims were not refreshed in this work. Read the relevant
issue or branch before continuing those lanes; do not treat the old snapshot
as current status. Their design rulings remain in the architecture documents,
protocol changes, and design notes named below.

## Where this work stands

The owner requested both per-call and persistent shell directories, then
supplied a live session showing repeated code-mode LSP failures. The session
passed `gopls` as its server assertion, although `go` was the configured key.
It then guessed roots and API argument shapes. A later temporary-file write
guessed `/Users/roasbeef/.codemode/tmp`, outside the actual workspace.

`bash.cwd` now selects one call's directory. `working_directory` reads or sets
a reserved, durable default for the authenticated calling strand. Foreground,
background and auto jobs capture it before launch. The production host gives
`cap/proc` the same default; `proc.in_dir` overrides one process. Native file,
search and LSP paths continue to resolve against the session workspace.

`working_directory` also reports the actual invocation `TMPDIR`. Loom's
cross-call temporary directory is `<workspace>/.codemode/tmp`. The execution's
private `/tmp` is not the place for files another invocation must reopen.
Guessing a path under the user's home does not grant access to it.

`lsp_sql.plan(outlines, targets)` infers the configured server and project root
from explicit files. All sources must share that owner before a server is
acquired. Explicit `Plan` assertions still receive exact checks. Errors name
the offending file, its actual owner and the requested pair. The SQL docs name
`path` columns and the quoted `"references"` table. The on-demand `cap://`
function surface retains its examples; the cached type surface does not.

The full gate also exposed a warm-server restart caused by generated inventory
key order. Gleam rewrote `packages.toml` with the same installed versions in a
different order. `lsp/dependency_state` now hashes parsed inventory contents
with recursively sorted table keys, preserving every value and sequence order.
Manifest and project configuration hashes remain byte-based. The deterministic
inventory regression and the real preparation fixture pass.

The contract and alternatives are in
[protocol-change/068](../protocol-change/068-working-directories-and-lsp-scope.md).
The production seams are `client/serve`, `client/working_directory`,
`tools/working_directory`, `tools/bash`, and `client/lsp/manager`.

## Rulings for the next reader

A directory selection grants no filesystem authority. Keep the workspace and
policy roots immutable; do not call a VM-wide `chdir`. Relative shell paths
resolve against the strand default, while native paths remain workspace-relative.
Fresh strands begin in the workspace rather than inheriting another strand's
shell state. Updates compare the reserved fact's sequence. A storage failure,
corrupt fact, missing target or redirected saved target is a refusal.

Validate a remembered directory before appending a relative process override.
The independent review found that validating only omitted cwd let
`proc.in_dir(".")` follow a replacement symlink. Omitted and relative cwd now
share that check. Absolute overrides bypass a broken saved default so callers
can recover. The live jailed test covers the redirected relative override.

The setter uses `Never` replay: replaying a relative selection after its first
commit could select a different directory. Running jobs retain their admitted
cwd even if the strand's default later changes.

## Verification and next actions

The complete final client gate passed 2,878 tests using a freshly rebuilt
server and the repository's fixture environment. Tools and cap passed 636 and
175 tests; the generator suite passed six. The broader run and remaining
package runs covered the other suites. Formatting, lint, doc-check, prelude
freshness and client assets passed separately. Four defect mutations each
failed their intended regression, then passed after restoration. The required
independent review and bounded fix rechecks are complete.

The first broad run was red for shifted citations, the inventory-order defect,
and two undeclared macOS `/proc` skips. The citations and defect were fixed;
the final client and static gates passed. A manual client run also supplied
the wrong provider fixture key. That setup failure was corrected, the shipped
fixtures passed, and the complete client gate was run again to exit zero.
The correct key is `loom-provider-fixture-key`, as supplied by
`scripts/check_affected.sh`. No tests or skip waivers were removed.

Linux enforcement and `signoff/linux` have not been run. macOS live code-mode
runs report the existing address-space, process-limit and process-lifecycle
limitations. The `/proc` helper-kill checks and rust-analyzer fixture remain unverified on
this host; no new skip waiver was added. Local test success is not Linux signoff. The owner must authorize
installation, publication or merge separately.

Other work should begin by inspecting its current issue and branch. The prior
handoff named terminal drives and follow-ups (#656, #763–#766), web workspace
mode (`design-notes/web-workspace-mode.md` and protocol-change/065), remote
access (#654 and protocol-change/052), executor follow-ups (#703 and #283),
and matched installed memory measurements (#454). Their current status was
outside this work. Terminal decisions live in `design-notes/terminal-design.md`;
workspace mode decisions live in its design note and protocol change, rather
than in this status snapshot.

Use the pinned Gleam 1.19.0 toolchain. Build code-mode seeds after capability
changes. Keep verification worktrees outside `/tmp`, where the jail replaces
the socket directory. `docs/execution.md` describes gate selection, required
prerequisites and the skip census; `docs/updating.md` describes installation.
