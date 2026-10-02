# protocol-change/063: saved code-mode source files

**Status**: ACCEPTED 2026-10-02; implementation and verification in progress.
**Affects**: the model-visible `code_mode` input schema and native source read.
The owner authorized a `program_path` alternative to inline `program` source.

## Problem

A tested summary or inspection program can be useful again after the workspace
changes. Inline `program` makes the agent retransmit the same source on each
call. A workspace file gives that source a stable location, where its purpose
and input assumptions can be documented and revised.

Reusing source must preserve the existing vetting, compilation and execution
boundary. A file path cannot become a saved grant or select a compiled binary.
And a pending execution approval must not cause the tool to reopen a file that
may have changed since the invocation loaded it.

## Decision

A synchronous run or background launch MUST supply exactly one nonblank string:
`program` for inline Gleam source, or `program_path` for a real source file.
Both fields, neither field, a non-string field or a blank value MUST be refused
before source I/O or execution. `program_path` accepts workspace-relative and
absolute paths. Virtual `cap://`, note, job and other discovery references are
not source-file inputs.

The tool MUST decode source selection and select an offered seam before
requesting authority. It MUST authorize invocation `permissions` before loading
the source. The file read MUST use the native `fs_read` boundary: resolve the
canonical target, judge current readable/writable roots and any invocation
additions, and request any missing exact-target read authority before I/O.
Symlink targets are judged by their canonical locations. Read approval belongs
to this invocation and MUST NOT widen later invocations.

The load MUST return the complete UTF-8 text under the existing eight-MiB
`fs.max_read_bytes` limit. It MUST NOT use rendering windows, hashline anchors,
image interpretation or truncated source. A missing, unreadable, oversized,
invalid UTF-8 or blank file MUST return an in-band error before the pipeline
starts. The limit is the existing whole-file admission check, not a new claim
that the filesystem allocates at most eight MiB before checking the file.

After loading, the tool MUST put those bytes into the ordinary `Request.source`.
It MUST use the same import vetting, warning-free hermetic compilation, jailed
satellite execution, broker checks and resource limits as inline source. An
execution approval retry within that invocation MUST retain the loaded source
and MUST NOT reopen the file. A later invocation MUST load the file afresh.
Background launch MUST use the same selection, authorization and loading path.
Existing async interaction modes MUST neither load nor replace program source.

Saving a source file MUST NOT preserve grants, compiled binaries, observations
or cache authority. No invoke-by-name registry, parameter API or execution cache
is added. Programs can read changing inputs through existing capabilities and
files. A reusable LSP program collects fresh observations on every invocation;
queries can share an observation only inside the invocation that collected it.

## Usage

Save a tested program as `analysis/lsp_summary.gleam`, with a module comment
stating its purpose and expected server, root, files and symbols. Its `main`
collects the current facts and returns the selected report. Then call:

```json
{
  "program_path": "analysis/lsp_summary.gleam",
  "within_ms": 120000
}
```

When background execution is offered, the same source input can accompany
`"mode": "launch"`. Permissions remain explicit invocation inputs. A source
file outside currently readable roots still needs read authority, even if an
earlier invocation successfully ran it.

## Alternatives and costs

Invoke-by-name storage would add a naming, revision and lifecycle contract for
source that already has a filesystem home. Loading a compiled artifact would
bypass the existing source checks. Caching source by path would make a later
invocation depend on hidden stale data. The file alternative adds one bounded
native read per invocation and leaves the pipeline unchanged.

Holding source through an approval retry means a file edited while approval is
pending does not alter that invocation. A new call is required to run the edit.
The path recorded in tool arguments is not a durable source revision; existing
source/artifact persistence work is separate from this input contract.

## Verification

Required checks cover source exclusivity and field types; relative and absolute
paths; canonical symlink targets; declared and exact-target read authority;
missing, invalid UTF-8, oversized and blank files; synchronous/background
parity; unchanged bytes through an approval retry; a fresh read on the next
invocation; and no source reads for async interactions. A real jailed program
must execute through `program_path`, with current capabilities and fresh LSP
collection. Aggregate release and dependency checks remain separate evidence.
