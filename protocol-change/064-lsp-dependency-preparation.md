# protocol-change/064: prepare dependencies before offline LSP leases

**Status**: ACCEPTED 2026-10-03. The owner approved automatic, separately
network-authorized preparation while retaining the offline language server.
**Affects**: ADR-016 profile approval records and the language-server start
path. Broker, sandbox, capability and client wire schemas stay unchanged.

## Problem

A fresh worktree has source and package manifests but no installed dependency
inventory. `gleam lsp` calls the compiler's dependency downloader before loading
its project. An offline lease cannot complete a missing Hex download. Retrying
queries or sleeping cannot grant that missing authority. A host download in
another package also does not establish the selected package's inventory.

## Decision

A profile MAY declare `prepare = "gleam-dependencies"`. Omitting the key MUST
retain the previous behavior and MUST NOT acquire network authority after a
harness upgrade. Installation approves the recipe as part of the existing
profile record. Its approval text MUST disclose full network access for one
bounded setup call, project writes, and the private cache. An operator-written
catalogue table grants the same authority explicitly.

The decoder MUST require a command of `[executable, "lsp"]`, a writable project,
and `cache_env.XDG_CACHE_HOME`. No arbitrary preparation command or shell source
is accepted. The recipe executes that same resolved, vetted executable with
`deps download`, in the selected package, through the broker. Setup has at most
60 seconds wall and CPU time, one outstanding call, and 1 MiB per output stream.
Its network authority is full rather than domain-restricted: the current helper
cannot enforce the proxy mode. Profiles must not imply a host restriction the
helper does not enforce.

Setup MUST retain the approved filesystem boundary, executable mounts,
protected paths and enforcement demand. Only its finite call receives network
access; the subsequent LSP policy MUST remain network-off. Gleam setup and its
server use the same private HOME and XDG cache directory. On macOS, Gleam's cache
uses `HOME/Library/Caches`, so XDG alone cannot provide a writable private cache.
Neither job shares the operator's package archives or credentials.

A cold start MUST prove the jail, run preparation, verify dependency records,
and only then return the LSP transport. A failed or unsettled setup MUST refuse
startup with the selected package and the actual failure. A receive timeout
requests cancellation; broker settlement and the existing session-operation
abort remain the drain owners. No new retry worker or background lifetime is
introduced.

Before reusing a prepared server, the caller MUST fingerprint the selected
package's manifest and package inventory plus the configurations in its
workspace-local path dependency graph. Changed inputs evict the previous
server through the existing keeper ordering and rerun setup. Metadata reads
MUST respect protected paths and workspace containment. The walk is bounded by
64 packages and 128 KiB per metadata file; only digests enter manager state.
These reads discover invalidation inputs, never additional sandbox authority.
Source edits continue through the existing LSP synchronization path.

## Alternatives and costs

Enabling network for every LSP request would authorize a long-lived process
running project-influenced code to communicate indefinitely. Manual setup leaves
the first-query failure with the user. Arbitrary setup commands would turn a data
profile into an execution language. A fixed, finite recipe keeps consent and
teardown within the existing broker mechanism.

The first query pays dependency resolution and download time. Registry failures
still fail preparation; Loom reports them without an automatic retry loop.
Existing installed profiles require an explicitly approved update. This first
recipe supports workspace-local Gleam path dependencies; an outside-workspace
path dependency is refused during input inspection, even if another profile
field grants external reads. Go and Rust preparation are not added by this
proposal.

## Verification

Tests pin decoder defaults, malformed recipes, durable profile round trips,
setup-only network authority, finite limits, unchanged protected paths,
nonzero and incomplete setup refusals, and warm-server invalidation after
sibling configuration changes. A real-helper fixture begins without build or
manifest state, downloads a Hex dependency into the private cache, loads a
sibling package, and obtains semantic results from the offline server. Existing
LSP manager and jail suites exercise the unchanged lease and eviction paths.
