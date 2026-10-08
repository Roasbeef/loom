# Current handoff

This edition records the October 8, 2026 code-mode and language-server
readiness changes, integrated with main `16f886bd0` after PRs #925 and #926
merged. The original validation used base `ae262a81374542b7cdbf63b3983a48c77c5a2e01`.
The implementation is isolated in `.worktrees/codemode-lsp-readiness`; the
original checkout's unrelated files remain untouched. The evidence and
validation limits are in [the readiness report](review/codemode-lsp-readiness-2026-10-08.md).

## Where the tree is

| Work | Current evidence |
|---|---|
| Compile/export reuse | PR #917 merged into the base named above. Its implementation remains in `scripts/shipment.py`; the earlier compile report records matched timing evidence, not a new measurement here. |
| Large TUI output | PR #925 merged as `fa4e45f8b`; its hosted CI and exact-head Linux signoff are green. |
| Code-mode module availability | Seed verification refuses a missing admitted static cap/ext module; automatic selection can use a valid bundle instead of an incomplete workspace seed. |
| Workspace language-server preparation | `make lsp-seed` prepares all workspace package closures explicitly, separate from satellite preparation and distribution. |
| Git subprocess resolution | Language servers use the host-resolved Git directory ahead of the macOS shim, within existing filesystem grants. |
| Diagnostics scope | Workspace publications are always partial (`Unsettled`); an explicit file retains the existing settlement behavior. |
| Browser result access | Draft PR #928 implements paged viewing and complete downloads; its local affected gate passed and hosted validation is pending. |

The previous edition's outstanding PR #917 CI/merge work is stale: #917 is in
the current base. Its historical local fixture failures remain observations of
those older runs, rather than the verdict for this change.

## What to do next

1. Finish PR #927's hosted CI and Linux signoff on its integrated head.
   **Exit:** green required checks, with the actual
   jailed recipe and language-server tests distinguished from full workspace
   coverage. Original package gates and Linux signoff passed. The macOS
   aggregate exposed two undeclared existing `/proc` prerequisites; the
   Darwin-only census declaration corrects that metadata without altering
   tests. Fresh validation is required after integration.
2. Integrate PR #928 with the readiness head and finish its required gates.
   **Exit:** its exact head is green before merging, as authorized.
3. Finish the separate browser result-access verification. **Exit:** an initial
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

Browser result access has its own worktree and PR. PR #926's Link-form fix
is included from main without editing its implementation. Provider cancellation
confirmation failures are separate from the TUI wrapping problem. Nothing in
this change installs a shipment or restarts a live daemon. Full workspace LSP
coverage is not claimed. Native compilation caching and further export savings
remain separate measured opportunities from the earlier compile iteration.
