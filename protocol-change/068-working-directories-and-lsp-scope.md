# protocol-change/068: shell directories and inferred LSP scope

**Status**: IMPLEMENTED LOCALLY 2026-10-06; Linux signoff and publication pending. The owner requested per-call and persistent
working directories, plus code-mode improvements grounded in a live session.

## Problem

Every shell starts in the workspace, so an agent reviewing a linked worktree
repeats `cd` on every call. Changing the harness VM's directory would move
unrelated strands and corrupt relative-path authority. Meanwhile, finite LSP
captures require the agent to know a configuration key and project root that
ownership already derives from each source file. In the observed session,
`gopls` was the executable but `go` was the configured key; the generic scope
error sent the agent into repeated root guesses.

## Decision

`bash.cwd` selects one command's directory. `working_directory` reads or sets
one persistent shell default per authenticated calling strand. Missing state
means the workspace. Fresh strands start there independently. The reserved
`client/working_directory/<strand>` fact stores a canonical absolute path.
Updates compare the prior sequence; storage failure or corrupt state refuses
explicitly. A remembered target is checked again on use. An absolute selection
allows recovery from a deleted previous directory.

A selection MUST NOT grant filesystem authority or change the workspace.
Relative shell selections resolve against the strand default; native file,
search and LSP paths remain workspace-relative. Every shell mode MUST capture
cwd before launch. Running jobs retain their admitted directory. `cap/proc`
uses the same per-strand default; `proc.in_dir` selects one process's directory.
Unsupported process options retain their existing refusal behavior. The setter
uses `Never` replay because repeating a relative selection can change its
meaning after the first commit.

The directory inspection reports both workspace and the actual `TMPDIR` from
the invocation environment. Cross-call temporary files belong there. Native
file calls must use its actual absolute path or `.codemode/tmp` relative to the
workspace; a path under the user's home is not inferred authority.

`lsp_sql.plan(outlines, targets)` leaves server/root assertions empty. The
collector derives both from the first explicit source and requires all other
sources to share that owner before acquiring a server or reading text. An
explicit `Plan` retains exact assertion checks. Scope mismatch errors name
the offending file, its actual configured server/root and the requested pair.
Capture bounds, deadlines, protected paths and complete-or-refused publication
remain the same. Returned metadata names the resolved owner.

Installed Gleam inventory fingerprints compare parsed TOML contents with
recursively sorted table keys. The compiler rewrites those keys in arbitrary
order, so serializer order MUST NOT invalidate a warm server. Every value and
sequence order remains significant. Manifest and project configuration hashes
remain byte-based. Existing metadata bounds and read-authority checks apply.

On-demand `cap://` function documentation retains examples with their source
indentation. The cached type-only description excludes those examples. This
keeps runnable syntax near the functions without growing every request's
cached prefix.

## Cost and alternatives

We add a small fact store and one tool, and pass captured cwd through jobs.
A persistent shell would also retain environment, traps and unrelated state;
we do not need that machinery to choose a directory. Parsing `cd` from shell
source would mistake shell syntax for a state protocol. Keeping the LSP scope
explicit-only preserves repeated guesses rather than using known ownership.

## Verification

The final complete client gate passed all 2,878 tests with the repository's
shipped-server fixture environment. Tools passed 636 tests, cap passed 175, and
the generated-reference renderer passed six. The broader run and remaining
package gates covered the other suites; formatting, lint, doc-check, prelude
freshness and client assets passed separately with their own exit codes.

Regressions cover shell modes, durable strand separation, SQLite reopen,
invalid-state recovery, captured job cwd, nested-worktree ownership and real
jailed process overrides. Four mutations restored the underlying job-cwd,
inferred-owner, relative-process redirection and inventory-order defects;
each intended regression failed, then passed after source restoration.

The independent review found the relative-process redirection gap, which was
fixed and checked again. It found no issue in the bounded inventory fix.

The original broad run exposed the inventory-order failure and shifted doc
citations; both were fixed. A manual rerun also used the wrong provider fixture
key; the final complete run used `loom-provider-fixture-key` and passed.
The macOS skip census still refuses two helper-kill checks requiring `/proc`.
Rust-analyzer is unavailable here. No skip waiver was added, and Linux signoff
has not been run. These local results do not authorize merge or deployment.
