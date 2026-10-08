# Code-mode and language-server readiness

This change addresses [issue #924](https://github.com/Roasbeef/loom/issues/924)
and its [same-run diagnostics evidence](https://github.com/Roasbeef/loom/issues/924#issuecomment-6068516729).
The implementation is isolated in `.worktrees/codemode-lsp-readiness`, against
base `ae262a81374542b7cdbf63b3983a48c77c5a2e01`.

## What failed

A code-mode seed could satisfy its dependency-table check while lacking an
admitted capability module. In particular, an old workspace seed could omit
`cap/lsp_sql` even though the model-visible prelude advertised it and the vetter
admitted it. The workspace language servers have a different dependency closure
from the satellite: preparing `build/codemode-seed` alone does not install
broker/tools' `envoy` dependency. On macOS, a server invoking Apple's Git shim
inside its private environment can also fail before the actual Git binary runs.

The amended example exposed a separate coverage claim. The manager owns one
package server at a time. A workspace diagnostics request returned the last
server's publications as `Settled([])` even after other package servers failed.
A healthy control package cannot prove that the workspace is clean.

## Changes

Seed verification checks the union of the admitted static cap/ext module lists.
An incomplete automatic workspace seed falls through to the bundled seed;
an explicitly supplied seed remains authoritative and its build reports the
missing module with `make codemode-seed`. This is a module-presence check, not a
source-content fingerprint for modules whose names did not change. Generated
MCP facades still install after the verified seed is cloned.

`make lsp-seed` prepares every workspace package's dependencies on the host and
stabilizes path-dependency metadata, with a six-pass resolution bound and the
existing Hex retry wrapper. A terminal failure identifies the package and exits
nonzero. It is an explicit preparation target, separate from distribution and
code-mode export. Servers retain their network-off lease and existing grants.

The existing host Git resolver also supplies subprocess PATH for the jailed
language server. Resolution does not grant access to another filesystem root.
The actual Git binary must already lie within the configured readable roots.

Workspace diagnostics preserve failures and successful publications, but always
label those successful publications `Unsettled`. An explicit file query keeps
its settlement behavior. [Protocol change 078](../../protocol-change/078-lsp-diagnostics-scope.md)
records this narrower coverage contract without another failure ledger or a wire
shape change. The regenerated prelude describes the distinction to the model.

## Validation

The full package gate completed with all checks passing: format, warning-free
Gleam builds, all package tests, Go sandbox tests, generated artifacts and lint.
The affected wrapper nevertheless returned exit 2 after its skip census: two
existing broker kill-evidence tests require `/proc` and are undeclared on this
macOS host. Those tests and the declarations are unchanged. The existing real
MCP death-observation and rust-analyzer prerequisites were separately declared.
This is not a complete green macOS affected-gate verdict.

The client suite passed 3,085 tests and the code-mode suite passed 407. Code-mode
E2E actually compiled and ran the `cap/lsp_sql` recipe in a jailed satellite
against a newly prepared seed; no language server is supplied to that recipe,
so it proves recipe availability rather than workspace coverage. Existing real
Gleam/gopls and dependency-preparation tests ran in the client suite.

The new same-run regression queries two failed owners, then a healthy control,
then workspace and explicit-file diagnostics. It passes with the change in
0.357 seconds. Restoring only the old workspace diagnostics implementation
makes the identical regression fail: `Settled([])` versus `Unsettled([])`.
The fixed source was restored and rebuilt afterward.

All three script regressions passed. An actual `make lsp-seed` prepared all 25
workspace packages; the first invocation encountered Hex's rate limit and the
subsequent bounded-wrapper invocation completed. Module-presence and Git PATH
regressions also passed. `make doc-check` returned zero errors.

A fresh independent review found no concrete reachable defects or warranted
simplifications. It independently ran the three script tests and whitespace
checks. It did not independently verify real jailed execution or Linux signoff.
Linux signoff and hosted CI remain required on the published head. No installed
client or daemon was replaced, restarted or patched by this change.
