# protocol-change/062 — SQL over explicit LSP observations

**Status**: ACCEPTED 2026-10-01; implementation and verification in progress.
**Affects**: Part 1.4 capability calls, the model-visible code-mode prelude,
and the LSP collection boundary. The owner requested the SQL LSP capability
and authorized carrying its design through implementation and a pull request.

## Problem

A program can already ask the session's language server for definitions,
outlines and references through `cap/lsp`. Answering a question across several
of those results still requires the program to assemble its own relational
operations, or return the intermediate facts to the model. We want joins,
aggregates and anti-joins over a bounded set of semantic facts, while keeping
model-written SQL out of the harness VM.

An anti-join also needs an honest account of coverage. An outline says which
symbols a server returned for a file; it does not say that references were
requested for every symbol. An empty reference result is a statement about a
particular request during a particular interval, not proof of dead code.

## Decision

Add `cap/lsp_sql` with three operations:

```gleam
collect(Plan) -> Result(Observation, Error)
metadata(Observation) -> Metadata
query(Observation, String, List(Cell), RowDecoder(a))
  -> Result(QueryResult(a), QueryError)
```

`Plan` selects one configured server and one admitted project root. It names
explicit outline files and explicit reference targets. Every target has a
symbol spelling, a file path and an optional positive one-based line. A bare
workspace-wide symbol search is not part of collection. `Observation` is
opaque and immutable. `Cell` preserves SQLite's NULL, signed integer, finite
real and UTF-8 text classes. `RowDecoder(a)` is a caller-owned, satellite-local
decoder. A query returns typed rows, column names and unchanged observation
metadata; a failed decoder returns its zero-based row and reason.

The host exposes only `lsp.snapshot`. SQL, bound parameters and the row decoder
never cross that boundary. The call uses the existing authenticated capability
envelope and outcome frames, so neither the exec protocol version nor the
capability envelope version changes. This adds a named capability and its
payload rather than an exec-helper frame kind or field.

The capture arguments are `server`, `root`, `outlines` and `targets`. A target
contains `symbol`, `path` and `line`, where a missing line is encoded as nil.
A successful answer carries the declared scope, canonical root, opaque server
generation, start and finish times, request and withheld-location counts, fact
and byte counts, and four fixed row arrays:

| Table | Columns |
| --- | --- |
| `documents` | `path`, `digest`, `version` |
| `symbols` | `id`, `parent_id`, `name`, `kind`, `detail`, `path`, `line`, `column`, `text`, `anchor` |
| `targets` | `id`, `symbol`, `asked_path`, `asked_line`, `path`, `line`, `column`, `text`, `anchor` |
| `"references"` | `target_id`, `path`, `line`, `column`, `text`, `anchor` |

IDs are observation-local. `parent_id` describes outline nesting; `target_id`
joins a reference to an explicitly requested seed. They are not interchangeable.
Paths are canonical admitted paths. Positions are one-based codepoint positions
converted from validated LSP positions. `digest` names the source content;
`version` is nil for a returned file the actor did not have open. Anchors use
the existing hashline convention over the retained line text.

## Collection and consistency

Collection is complete or refused. It never returns a truncated batch that
could make a missing row look like an absence of references. Admission checks
both requested files and returned locations. Withheld server locations are
counted but never read, opened or inserted into the tables. A required method
that is unsupported or fails refuses the observation.

The collector checks the server incarnation, document/activity revision and
retained failure state across its interval, and rereads admitted source text
before publication. It refuses a detected change. This is a finite checked
observation, not a project-wide transaction: standard LSP exposes no common
project revision, and an unobserved dependency edit can remain undetected.
Consumers must retain scope, times and withheld counts when stating a result.

The limits are four captures per invocation, sixteen outline files, thirty-two
reference targets, 128 semantic protocol requests, 10,000 retained facts and
four MiB of retained source text and fact payload with conservative row
overhead. Semantic requests include resolution queries and exclude document
sync and lifecycle notifications. Collection has a seventy-five-second maximum
additionally bounded by the invocation's absolute deadline.

`ScopedService` gives host-side collection the invocation's custody. The host
owns a weft cancellation handle before starting its worker and fires it on
program cancellation, expiry or resident-host release. The LSP actor monitors
the owner of each pending request, withdraws its ID on owner death, and sends
best-effort `$/cancelRequest`. That notification cannot force a server to stop,
but the abandoned collector cannot publish a result or continue fanout. The
shared language-server lease stays alive for other requests.

## Satellite SQL enforcement

Each query materializes the four trusted tables into a fresh private
`:memory:` database and closes it afterward. Fixed DDL and parameterized
inserts are separate from model SQL. The existing SQLite dependency family
gains a native read-only query entry point: authorizer-before-prepare, exactly
one executable statement, an allowlist of fact tables and pure functions,
memory-only temporary storage, and tagged values. DDL, writes, schema reads,
attachment, pragmas, extension loading, virtual tables and recursive SQL are
refused. BLOBs, invalid UTF-8 and non-finite reals cannot enter the public cell
vocabulary. Prepared statements are finalized before database close.

Native limits are sixteen KiB of SQL, sixty-four parameters, 128 KiB per bound
text value, thirty-two columns, five hundred rows, one MiB of output, one
million VM operations and two seconds of query execution. SQLite's lower-only
thirty-two-MiB heap limit is process-global: it is installed inside the
satellite, never in the harness. Fixed-table materialization and the Gleam row
decoder are also subject to the enclosing invocation budget, and are not
included in the native query timer.

The new NIF entry point belongs in the existing `esqlite_loom` dependency rather
than a second SQLite implementation or a SQL evaluator in the harness. Its
companion `sqlight_loom` keeps the dependency graph on one native version. The
offline code-mode seed must carry that resolved native dependency and its
compiled library; source presence alone does not prove a usable release.

## Alternatives considered

A live SQL virtual table that calls LSP from a join would make request count
depend on SQLite's query planner. Capturing facts first makes fanout explicit
and reusable. Automatically requesting references for every outlined symbol
would spend work the caller did not request, and would still not prove whole
workspace coverage.

Evaluating SQL in the harness would violate Rule Zero. A hand-written SQL
dialect would duplicate parsing, joins, aggregation and budgeting machinery.
The existing native SQLite family provides the required parser and execution
controls without adding a second database engine.

A mutable database handle in the public API would make handle ownership and
cleanup another caller obligation. An opaque immutable observation and a fresh
database per query eliminate that state.

## Verification and costs

This changes cap, code mode, the client LSP manager and the LSP protocol client,
with a native dependency update. The generated capability prelude and the
offline seed lock must be regenerated. Extension and resident-hook allowlists
do not gain this capability; only configured native workspace and orchestration
hosts offer it.

Required checks include native authorization and resource limits; malformed
positions and paths; exact invocation routing and capture admission; caller
death and cancellation without killing the shared lease; document-change
refusal; typed row-decoder failure; and real jailed Gleam and Go queries. The
[design note](../docs/design-notes/lsp-sql.md) contains the schema and complete
examples. Focused checks, independent review corrections and actual jailed
Gleam and Go SQL tests pass. Those jailed tests used an isolated native wrapper
in the experimental seed. Final published-package resolution, seed locking
and aggregate verification remain pending.

## Accepted addendum, 2026-10-02: one model-facing semantic entry point

The owner authorized removing the seven top-level LSP tools from the default
registry alongside this feature. `code_mode` is the semantic entry point:
`cap/lsp` handles individual queries and explicit rename preview/apply, while
`cap/lsp_sql` handles joins and aggregates over finite observations. This
changes default tool advertisement, not the capability envelope or the LSP
lease protocol. The existing post-edit diagnostics observer remains active.

Approved language naming hints move into offered code-mode discovery and the
full `cap://lsp` read. Neither unconfigured hosts nor disallowed seams advertise
those hints. The shipped prompt directs agents to the two modules conditionally
on their availability, preserves setup/unsupported failure guidance and keeps
an agent judgment step between rename preview and apply.

Existing rename, stale-content and multi-root real-server acceptance tests
move to actual `cap/lsp` code-mode programs rather than being dropped. The
legacy tools' constructor, renderer and landing tests remain intact.

## Accepted addendum, 2026-10-02: delete retired tool constructors

The owner authorized deleting all seven top-level `lsp_*` constructors and their
obsolete tests. This supersedes the preceding claim that their constructor and
renderer tests remain intact. Shared rename landing, diagnostics rendering, the
post-edit observer, clipping and changed-span helpers remain for code mode and
ordinary writes. Their focused tests and the real-server capability programs
retain the corresponding behavior checks. [Protocol 063](063-saved-code-mode-programs.md)
adds reusable source-file input without preserving SQL observations or authority.

## Verification update, 2026-10-02: published native integration

This supersedes the experimental-wrapper status in the original verification
section. `esqlite_loom` 0.9.1 and `sqlight_loom` 1.2.1 are published and selected
by the normal package manifests and offline seed lock. Six real jailed Gleam
and Go fixtures, full local package checks and distribution builds pass with
that normal seed. The complete Linux container run also passed all six lanes,
release/update verification and its strict skip census. Current-head hosted
checks and Linux signoff remain the merge criteria; this verification does not
update a running daemon or change the accepted API.
