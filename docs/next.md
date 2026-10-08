# Current handoff

This edition records the October 8, 2026 code-mode and language-server
readiness changes against main `ae262a81374542b7cdbf63b3983a48c77c5a2e01`.
The implementation is isolated in `.worktrees/codemode-lsp-readiness`; the
original checkout's unrelated files remain untouched. The evidence and
validation limits are in [the readiness report](review/codemode-lsp-readiness-2026-10-08.md).

## Where the tree is

| Work | Current evidence |
|---|---|
| Compile/export reuse | PR #917 merged into the base named above. Its implementation remains in `scripts/shipment.py`; the earlier compile report records matched timing evidence, not a new measurement here. |
| Large TUI output | PR #925's head `16c3c0ee5` passed hosted CI. Its separate required Linux signoff was dispatched before merging; merge is authorized only after that gate passes. |
| Code-mode module availability | Seed verification refuses a missing admitted static cap/ext module; automatic selection can use a valid bundle instead of an incomplete workspace seed. |
| Workspace language-server preparation | `make lsp-seed` prepares all workspace package closures explicitly, separate from satellite preparation and distribution. |
| Git subprocess resolution | Language servers use the host-resolved Git directory ahead of the macOS shim, within existing filesystem grants. |
| Diagnostics scope | Workspace publications are always partial (`Unsettled`); an explicit file retains the existing settlement behavior. |
| Browser result access | Paged viewing and full download are authorized and being implemented separately in `.worktrees/browser-tool-output`. |

The previous edition's outstanding PR #917 CI/merge work is stale: #917 is in
the current base. Its historical local fixture failures remain observations of
those older runs, rather than the verdict for this change.

## What to do next

1. Publish the readiness fixes for issue #924 and finish hosted CI and Linux
   signoff on that exact head. **Exit:** green required checks, with the actual
   jailed recipe and language-server tests distinguished from full workspace
   coverage. The local package gate passed; the affected wrapper returned red
   for two existing `/proc` prerequisite skips on macOS.
2. Finish PR #925's Linux signoff and merge the verified head as authorized.
   **Exit:** the merge is recorded and the required status belongs to that head.
3. Finish the separate browser result-access change. **Exit:** an initial
   bounded preview, authenticated bounded pages and a complete download, with
   Unicode boundaries, page isolation, expiry and credential revocation tested
   through the real HTTP router, followed by review and required gates.

## Rulings already made

**Prepare the two dependency graphs explicitly.** The satellite seed does not
prepare the workspace's package servers. The new target grants no server network
access and is not added to every export or distribution command.

**Represent partial coverage honestly.** One current package server cannot
attest to an entire workspace. Protocol change 078 uses `Unsettled` for an
unscoped diagnostics request, preserves error results, and keeps explicit-file
settlement. A complete workspace sweep and a failed-server ledger are deferred.

**Keep the seed gate's claim narrow.** It proves admitted module presence and
the existing pinned dependency-table/inventory checks. It does not fingerprint
unchanged module names against the current source. Dynamic MCP facades are
installed after the clone, rather than being required in the static seed.

## Deliberately open

Browser result access has its own worktree and PR. Provider cancellation
confirmation failures are separate from the TUI wrapping problem. Nothing in
this change installs a shipment or restarts a live daemon. Full workspace LSP
coverage is not claimed. Native compilation caching and further export savings
remain separate measured opportunities from the earlier compile iteration.
