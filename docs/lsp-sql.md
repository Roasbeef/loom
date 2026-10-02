# Query language-server facts with SQL

Use `cap/lsp_sql` in code mode when a question needs joins, counts, or filtering
over several language-server answers. A program collects explicit outlines and
reference targets once, then queries the returned observation locally. SQL
runs in the jailed satellite over four fixed in-memory tables.

**Integration status:** the complete program in the
[design note](design-notes/lsp-sql.md#a-complete-program) has compiled
warning-free. Real jailed Gleam and Go SQL cases also pass using an isolated
experimental native wrapper. The native and companion forks have merged, but
Hex publication, final dependency pins and
the cold published-package seed remain pending. An older installed Loom daemon
does not acquire this module by installing a language profile.

## Prepare the existing LSP setup

Use a Loom build that includes the SQL observation capability and its native
SQLite dependency. The runtime dependency belongs to Loom's bundled code-mode
environment; there is no separate SQL profile to install. A language profile
still selects the server, project markers, and sandbox permissions. Follow the
[language-server setup guide](language-servers.md) for the daemon environment,
toolchain, caches, and profile installation.

For Gleam, the existing profile check is:

```sh
gleam --version
command -v rg
loomd ext install https://github.com/Roasbeef/loom-lsp-gleam --rev v0.1.0
loomd ext check lsp_gleam
```

If `lsp_gleam` is already installed, run its check rather than reinstalling it.
Prepare missing project dependencies outside the jail with `gleam deps download`.
The jailed server has no network. Start a new session after installing a
profile; an existing resident session needs a graceful daemon restart followed
by explicitly reopening that session to reload its profiles.

Ask the agent to use `cap/lsp_sql` in code mode for the selected files and
symbols. The configured server name comes from `[lsp.<name>]`, for example
`"gleam"`, rather than the extension name `lsp_gleam`. `root: "."` selects the
workspace root only when that root owns the requested project. For a nested
package, name that package root. Every requested file must belong to the same
configured server and project root.

## Choose what to collect

The plan has two independent lists:

```gleam
lsp_sql.Plan(
  server: "gleam",
  root: ".",
  outlines: ["src/greeter.gleam"],
  targets: [
    lsp_sql.Target("greet", "src/greeter.gleam", None),
    lsp_sql.Target("unused", "src/greeter.gleam", None),
  ],
)
```

`outlines` requests symbols in those files. `targets` requests references for
those exact seeds. Every target needs a symbol spelling and file path;
`Some(12)` can narrow it to line twelve when `None` would be ambiguous. Lines
are one-based. Collection never searches the workspace for a bare symbol or
requests references for every symbol in an outline.

Either list can be empty, but the plan needs at least one file or target.
Use at most sixteen outline files and thirty-two reference targets. Keeping
those lists small also leaves room for results within the fact and time bounds.
An ambiguous or unsupported seed is a collection error, not an empty reference
list.

### Compare the tool calls

The three queries below use two known targets (`greet` and `unused`) and one
outline file. The following counts assume complete answers, known paths, and
one probe per model-visible tool call. They exclude setup, API discovery,
retries and reads needed to locate an unknown symbol. These are worked call
counts, not measured inference or latency savings.

| Query below | Separate LSP/read calls with no saved answers | Further calls when the earlier answers are retained | Text-search workflow with no saved answers |
| --- | --- | --- | --- |
| [Count external references](#count-references-in-other-files). | Two reference queries, one per target; then filter by path, count and sort. | Zero if both reference answers are already available. | One batched `grep`/`rg` search for both names, plus `C` context reads with `fs_read` or `sed`. |
| [Find targets with no external reference](#query-the-same-observation-again). | Two reference queries, then keep the targets with no external locations. | Zero after the preceding count query if its complete reference answers were retained. | One batched search plus `C` context reads, or zero new searches after retaining the preceding search results and context. |
| [Join outline symbols to document evidence](#query-the-same-observation-again). | One outline query plus one full-file read/digest command for the example file. Point queries do not expose the observation's LSP document version. | Zero for names, kinds, positions and the disk digest if the outline and matching file evidence are retained. The LSP version is still unavailable. | One full-file read plus one digest command; declaration search and parsing still need to recover names, nesting and kinds. |

`C` is the number of separate context reads needed to inspect ambiguous hits.
It can be zero when search output supplies enough context. A shell script can
combine the searches, reads and digest command into one Bash call. Text search
still finds spellings rather than resolved symbols: comments, strings, aliases
and unrelated same-named declarations require inspection. `sed` supplies
context but does not turn those hits into semantic references or a typed outline.

The former `lsp_references` and `lsp_symbols` tools exposed individual queries.
On this branch, the corresponding operations are `cap/lsp.references` and
`cap/lsp.outline` inside code mode. A program can batch those ordinary point
queries, retain their answers, and perform the same counts and filters in one
model-visible `code_mode` call. SQL provides reusable tables and joins, with
checked observation scope and provenance; a lower tool-call count is not
exclusive to SQL. Check `Found.total` against the returned item count before
using a point-query answer to count references or report absence.

For the plan above, one successful collection currently spends five semantic
LSP requests: one requested outline, two further outlines to resolve the two
line-less targets, and two reference requests. Giving both targets an explicit
`Some(line)` reduces that count to three. Initialization and document
synchronization are outside this count. `metadata(observation).requests`
records the actual semantic request count.

After collection, each of the three SQL queries makes zero further LSP
requests. Run collection and all three queries in one code-mode program and
the model makes one tool call, returning only the selected reports. Each SQL
query still creates a fresh in-memory database and consumes local execution
resources. Reuse the plan to collect fresh facts after edits; reuse the
observation for more queries over the already captured facts.

## Save a tested summary program

After testing the program below against your project, save its adapted source
as `analysis/lsp_summary.gleam`. Add a brief module comment stating its purpose,
expected server/root, outline files and reference targets. Then submit the file
instead of repeating the source. Keep the module readable using the
[style guide](gleam-style.md#orientation-in-large-modules): large modules explain
their call flow (R13), critical machines document checked transitions (R14), state
types precede functions (R15), and domain calls name their owning module (R16).
R17/R18 are warning censuses for flow order and unnamed helpers, not reasons to
pad comments. Literate comments explain the assumptions and ordering a later
reader must preserve.

Submit the saved source:

```json
{
  "program_path": "analysis/lsp_summary.gleam",
  "within_ms": 120000
}
```

Supply exactly one of `program` or `program_path`. Relative paths resolve
against the workspace; absolute source paths use the same canonical read
authorization as `fs_read`. The tool reads complete UTF-8 source under the
existing eight-MiB file limit, then vets, compiles and runs it through the
ordinary jail. Each new invocation reloads the file; an execution approval
retry in the same invocation retains the already loaded bytes.

Saving the program saves its collection plan and queries, not the LSP facts or
authority. Its `main` must call `lsp_sql.collect` again on each run. Reuse that
observation for the queries in that invocation; later calls collect again.
Programs can read changing inputs through existing capabilities or files.
See [protocol 063](../protocol-change/063-saved-code-mode-programs.md).

## Count references in other files

The following complete program is copied from the checked design-note example.
It expects `greet` and `unused` in `src/greeter.gleam`; adapt the plan to your
project. Its output includes scope and provenance alongside the counts.

```gleam
import cap/lsp_sql
import cap/report
import gleam/list
import gleam/option.{None}
import gleam/string

type ReferenceCount {
  ReferenceCount(name: String, external_references: Int)
}

pub fn main() -> report.Outcome {
  let plan = lsp_sql.Plan(
    server: "gleam",
    root: ".",
    outlines: ["src/greeter.gleam"],
    targets: [
      lsp_sql.Target("greet", "src/greeter.gleam", None),
      lsp_sql.Target("unused", "src/greeter.gleam", None),
    ],
  )

  case lsp_sql.collect(plan) {
    Error(error) -> report.failure(string.inspect(error))
    Ok(observation) -> summarize(observation)
  }
}

fn summarize(observation: lsp_sql.Observation) -> report.Outcome {
  let sql = "
    SELECT t.symbol, COUNT(r.path) AS external_references
    FROM targets AS t
    LEFT JOIN \"references\" AS r
      ON r.target_id = t.id AND r.path <> t.path
    WHERE t.symbol LIKE ?
    GROUP BY t.id, t.symbol
    ORDER BY external_references DESC, t.symbol
  "

  case lsp_sql.query(observation, sql, [lsp_sql.Text("%")], read_count) {
    Error(error) -> report.failure(string.inspect(error))
    Ok(answer) ->
      report.value(report.object([
        #("server", report.string(answer.observation.server)),
        #("root", report.string(answer.observation.root)),
        #("generation", report.string(answer.observation.generation)),
        #("started_ms", report.int(answer.observation.started_ms)),
        #("finished_ms", report.int(answer.observation.finished_ms)),
        #("withheld", report.int(answer.observation.withheld)),
        #("rows", report.list(list.map(answer.rows, render_count))),
      ]))
  }
}

fn read_count(cells: List(lsp_sql.Cell)) -> Result(ReferenceCount, String) {
  case cells {
    [lsp_sql.Text(name), lsp_sql.Integer(count)] ->
      Ok(ReferenceCount(name, count))
    _other -> Error("expected a text name and an integer reference count")
  }
}

fn render_count(row: ReferenceCount) -> report.Value {
  report.object([
    #("name", report.string(row.name)),
    #("external_references", report.int(row.external_references)),
  ])
}
```

The query joins `"references".target_id` to `targets.id`. It counts locations
whose path differs from the resolved target's path. The server's reference
answer can include declarations, so the path condition matters. A left join
keeps targets that received no matching external locations.

Pass values through `List(Cell)` and `?` placeholders. The `Text("%")` parameter
is bound data, even if a value contains SQL punctuation. Table and column names
come from the fixed schema; a parameter cannot replace an identifier. Quote
`"references"` because it is a SQLite keyword.

`read_count` checks the projection's storage classes and creates a Gleam row
type. SQL remains runtime-parsed, and changing the projection can make its
decoder return `DecodeFailed`. `Null`, `Integer`, `Real`, and `Text` preserve
their tags; `NULL` is not an empty string or a missing row. Blobs, invalid UTF-8,
and non-finite real results are refused.

## Query the same observation again

Another `lsp_sql.query` call with the same observation makes no LSP requests.
For example, this SQL selects the requested targets with no returned reference
in another file:

```sql
SELECT t.symbol, t.path, t.line
FROM targets AS t
WHERE NOT EXISTS (
  SELECT 1 FROM "references" AS r
  WHERE r.target_id = t.id AND r.path <> t.path
)
ORDER BY t.symbol;
```

Supply a decoder matching those three projected columns. The result means
“no admitted external reference was returned for this requested target.” It
does not prove that a function is dead code. `answer.observation.withheld`
counts locations the host could not admit, and the server can omit references
even when that count is zero. A withheld count is aggregate, so it cannot name
the particular target affected.

For outline evidence, query `symbols` independently:

```sql
SELECT s.name, s.kind, s.path, s.line, d.digest, d.version
FROM symbols AS s
JOIN documents AS d ON d.path = s.path
ORDER BY s.path, s.line, s.column;
```

`symbols.id` and `parent_id` describe the outline hierarchy. They do not join
to target IDs. References were collected only for `targets`, regardless of
how many outline symbols exist. IDs are local to one observation.

## Read the evidence with the answer

`lsp_sql.metadata(observation)` and every successful query result expose the
same metadata: server, canonical root, opaque generation, collection start and
finish, answered outlines, requested targets, semantic request count, withheld
count, fact count, and conservative fact byte count. Start and finish use the
host's monotonic clock. Their difference measures an interval; the values are
not calendar timestamps.

The `documents` table records each retained document's SHA256 content address
and the LSP client's version when it held that text. A reference file read
without being opened in the client has SQL `NULL` for its version. Sites use
canonical admitted paths, one-based lines and codepoint columns, the source
line in `text`, and the ordinary hashline `anchor`.

Collection checks observed texts and client state before returning. A detected
change, busy or failed server, unsupported method, malformed site, or exceeded
limit refuses the entire observation. A successful empty result is therefore
different from collection failure.

The checks cover a finite interval over the documents observed by this request.
They do not freeze the whole project. Unseen dependencies can change, and a
reference file discovered in an answer is checked from its read through
publication. Keep the metadata when reporting absence or making a later edit,
and collect again when fresh evidence matters.

## Limits and errors

| Work | Maximum |
| --- | --- |
| Captures | Four admissions per code-mode invocation. |
| Explicit scope | Sixteen outline files and thirty-two targets under one server/root. |
| Collection | 128 semantic requests, 10,000 fact rows, 4 MiB of retained text/facts, and 75 seconds narrowed by the invocation deadline. |
| SQL input | 16 KiB SQL, sixty-four bound parameters, 128 KiB per text parameter/value. |
| Native SQL work | Two seconds and one million progress-counted operations per query. |
| Query output | Five hundred rows, thirty-two columns, and 1 MiB including column names and cell overhead. |
| SQLite heap | At most 32 MiB shared by SQLite connections in the satellite. |

The semantic request count includes outline requests used to resolve targets.
Initialization requests and lifecycle/document synchronization notifications
are outside this semantic count. Loading the
private tables, running your decoder, and issuing repeated local queries still
spend the enclosing invocation's time and resources. The two-second native SQL
limit does not cover the whole public `query` call. Limits return errors without
partial rows; adding SQL `LIMIT` can intentionally request a smaller result.

| Error | Next step |
| --- | --- |
| `InvalidScope` | Use the configured server name, its project root, and explicit owned paths. |
| `Changed` | Collect again after edits or server analysis settle. |
| `QueryFailed` | Read the reason; disambiguate a seed or correct the server's unsupported method/load problem. |
| `LimitExceeded`, `DeadlineExceeded`, `CaptureCeilingReached` | Narrow collection or start another invocation when fresh captures are required. |
| `ReadOnlyDenied`, `MultipleStatements` | Use one allowed read-only statement over the fixed tables. |
| `InvalidQuery` | Correct syntax or the number and types of bound parameters. |
| `QueryLimitExceeded` | Reduce the projection, rows, joins, or SQL work. Its `QueryLimit` identifies the budget. |
| `DecodeFailed` | Match the decoder to the selected columns and their storage classes; the row index is zero-based. |
| `UnsupportedValue` | Project supported finite numbers, UTF-8 text, and `NULL`. |
| `Unavailable`, `SqlUnavailable`, `Denied`, `SqlRefused`, `QueryCancelled` | Preserve the reported reason or original code and inspect the runtime, host policy, or cancellation. |

SQL permits reads of the fixed tables and a small pure-function allowlist.
Writes, schema inspection, pragmas, attachments, virtual tables, extensions,
recursive SQL, and additional statements are refused. Queries cannot request
new LSP facts or rename source files. The observation tables contain no
diagnostics or call hierarchy.

Cancelling the program withdraws its capture work and pending LSP request IDs.
The shared language server stays available to other callers; its cancellation
notification is best effort. Native SQL checks process liveness during bounded
execution. See the [architecture](architecture/lsp-sql.md) for cancellation
ownership, native enforcement, and the complete table schema.

## Semantic access through code mode

The default registry exposes semantic operations through code mode rather
than seven top-level LSP tools. Use `cap/lsp` for definitions, references,
hover, outlines, calls, diagnostics and rename; use `cap/lsp_sql` for explicit
collection followed by joins and aggregates. Automatic post-edit diagnostics
remain on ordinary write tools. Rename preview and apply remain separate
programs with a model judgment step between them.

The system prompt prefers the modules when offered. Read `cap://lsp` for its
API and the served language profiles' naming hints, and `cap://lsp_sql` for
the observation/query API. Module discovery follows the same offered-seam
allowlists as vetting, so an unavailable server is not advertised as usable.
