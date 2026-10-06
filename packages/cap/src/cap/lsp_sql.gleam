//// One immutable LSP capture queried with SQL; use it for joins across two or
//// more symbols, counts, overlaps and anti-joins.
////
//// A finite LSP observation with SQL evaluated inside this satellite only.
////
//// Collection names one configured server, one root, explicit outline files
//// and explicit reference seeds. A complete observation is immutable and may
//// answer several local SELECTs; none of those queries asks the language server.
//// Every result retains the observation's scope, generation and interval beside
//// the projected rows. SQL runs in a fresh private in-memory SQLite database,
//// under native read-only authorization and fixed execution/output budgets.
////
//// The tables are documents(path,digest,version), symbols(id,parent_id,name,
//// kind,detail,path,line,column,text,anchor), targets(id,symbol,asked_path,
//// asked_line,path,line,column,text,anchor), and "references"(target_id,path,
//// line,column,text,anchor). Reference targets are separate from outline symbols:
//// an anti-join proves absence only for explicitly requested targets, during
//// this observation interval, and server-withheld results remain visible.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/ffi_lsp_sql
import cap/internal/wire
import core/msgpack as m
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A reference seed with an explicit file and optional one-based line.
///
/// The language server resolves `symbol` by name within `path`. A bare method
/// name such as `AcceptForScheme` may not resolve: servers often want the
/// qualified spelling, `package.Name` for package-level items or
/// `Receiver.Method` for methods, and a miss comes back as
/// `QueryFailed("symbol not found: ...")` from `collect`.
pub type Target {
  Target(
    /// The symbol spelling to resolve, qualified when the server needs it.
    symbol: String,
    /// The workspace file in which to resolve it.
    path: String,
    /// Optional positive one-based line narrowing the symbol.
    line: Option(Int),
  )
}

/// The complete finite capture scope. Collection never expands these lists.
pub type Plan {
  Plan(
    /// The configured language-server name.
    server: String,
    /// One admitted project root for that server.
    root: String,
    /// At most sixteen explicit outline files.
    outlines: List(String),
    /// At most thirty-two explicit reference seeds.
    targets: List(Target),
  )
}

/// Infers the configured server and project root from the explicit files.
///
/// Every source must still belong to the same server and root. Paths resolve
/// against the session workspace, so worktree files must name that worktree.
/// Use `Plan` directly when an exact server/root assertion is required.
///
/// ## Examples
///
/// ```gleam
/// let plan = lsp_sql.plan(["src/app.gleam"], [])
/// // lsp_sql.collect(plan)
/// ```
pub fn plan(outlines: List(String), targets: List(Target)) -> Plan {
  Plan(server: "", root: "", outlines:, targets:)
}

/// Scope and provenance that survive every SQL projection.
pub type Metadata {
  Metadata(
    /// The configured language-server name.
    server: String,
    /// The admitted canonical root.
    root: String,
    /// The opaque content address of the server incarnation.
    generation: String,
    /// Observation start in the host's monotonic clock.
    started_ms: Int,
    /// Observation finish in the same clock.
    finished_ms: Int,
    /// Exactly the canonical files whose outlines were answered.
    outlined: List(String),
    /// Exactly the reference seeds whose references were requested.
    targets: List(Target),
    /// Semantic protocol requests spent by collection.
    requests: Int,
    /// Server locations withheld by admission, never read as documents.
    withheld: Int,
    /// Retained facts across the four tables.
    facts: Int,
    /// Retained UTF-8 facts with conservative row overhead.
    fact_bytes: Int,
  )
}

/// An immutable complete capture; callers cannot construct or mutate its facts.
pub opaque type Observation {
  Observation(
    metadata: Metadata,
    documents: List(List(Cell)),
    symbols: List(List(Cell)),
    targets: List(List(Cell)),
    references: List(List(Cell)),
  )
}

/// A SQLite value whose storage class remains explicit.
pub type Cell {
  /// SQL NULL, distinct from absent rows and empty text.
  Null

  /// A signed SQLite integer.
  Integer(value: Int)

  /// A SQLite floating-point value.
  Real(value: Float)

  /// UTF-8 SQLite text. Blob projections are refused by the native boundary.
  Text(value: String)
}

/// A satellite-local decoder for one projected row.
pub type RowDecoder(a) =
  fn(List(Cell)) -> Result(a, String)

/// Typed projected rows with unchanged capture provenance beside them.
pub type QueryResult(a) {
  QueryResult(
    /// Column names in projection order, at most thirty-two.
    columns: List(String),
    /// Complete decoded output, at most five hundred rows and one MiB.
    rows: List(a),
    /// Provenance retained outside the SQL projection.
    observation: Metadata,
  )
}

/// A capture refusal or disagreement on the capability channel.
pub type Error {
  /// The explicit scope was invalid or crossed the configured root.
  InvalidScope(reason: String)

  /// The server generation or an observed document changed.
  Changed(reason: String)

  /// A complete capture exceeded its fixed fact or request limits.
  LimitExceeded(reason: String)

  /// The observation or enclosing invocation exhausted its deadline.
  DeadlineExceeded

  /// Four captures were already admitted for this invocation.
  CaptureCeilingReached

  /// A required semantic query failed or was unsupported.
  QueryFailed(reason: String)

  /// An unrecognized host policy refusal retains its original code.
  Denied(code: String, message: String)

  /// The host could not be reached or returned malformed facts.
  Unavailable(reason: String)
}

/// A local SQL refusal or typed row-decoder failure.
pub type QueryError {
  /// SQLite authorization refused an effect or an unapproved table/function.
  ReadOnlyDenied(reason: String)

  /// More than one executable statement was submitted.
  MultipleStatements

  /// SQL syntax or bound parameters were invalid.
  InvalidQuery(reason: String)

  /// A fixed output or execution budget was exhausted, with no partial rows.
  QueryLimitExceeded(limit: QueryLimit, reason: String)

  /// A blob, invalid UTF-8 text or non-finite real could not become a Cell.
  UnsupportedValue(reason: String)

  /// The native boundary was unavailable or could not build its private table.
  SqlUnavailable(reason: String)

  /// The native query was interrupted.
  QueryCancelled

  /// An unknown native refusal preserves its original code and message.
  SqlRefused(code: String, message: String)

  /// The projected storage classes did not match the decoder.
  DecodeFailed(row: Int, reason: String)
}

/// The fixed native budget that prevented a complete query result.
pub type QueryLimit {
  /// More than five hundred projected rows.
  Rows

  /// More than thirty-two projected columns.
  Columns

  /// More than one MiB of projected output.
  Bytes

  /// The process-global lower-only SQLite heap ceiling.
  Memory

  /// More than one million SQLite VM operations.
  Instructions

  /// The two-second monotonic query deadline.
  Time
}

/// Captures one complete bounded observation, spending one capture admission.
///
/// The host admits at most four collections per invocation. Every capture is
/// complete or refused: no truncation can turn an anti-join into a false claim.
/// Prefer `plan(outlines, targets)` to infer scope from files. An explicit
/// `Plan.server` is the configuration key (for example `go`), which may differ
/// from its executable (`gopls`). Paths are workspace-relative, including files
/// in nested worktrees; selecting a shell cwd does not move these paths.
///
/// ## Examples
///
/// ```gleam
/// lsp_sql.collect(lsp_sql.plan(["src/app.gleam"], []))
/// ```
pub fn collect(plan: Plan) -> Result(Observation, Error) {
  let targets =
    list.map(plan.targets, fn(t) {
      wire.args([
        #("symbol", wire.string(t.symbol)),
        #("path", wire.string(t.path)),
        #("line", optional_int(t.line)),
      ])
    })
  use value <- result.try(
    dispatch.call_within(
      "lsp.snapshot",
      wire.args([
        #("server", wire.string(plan.server)),
        #("root", wire.string(plan.root)),
        #("outlines", wire.string_array(plan.outlines)),
        #("targets", m.ArrayValue(targets)),
      ]),
      75_000,
    )
    |> result.map_error(call_error),
  )
  decode(value) |> result.map_error(Unavailable)
}

/// Returns the declared scope and checked observation interval.
///
/// ## Examples
///
/// ```gleam
/// lsp_sql.metadata(observation).withheld
/// ```
pub fn metadata(observation: Observation) -> Metadata {
  observation.metadata
}

/// Executes one bounded read-only SQLite statement over the captured facts.
///
/// SQL and the decoder remain inside the satellite. Native authorization
/// refuses writes, schema access, attachment, pragmas, extensions and additional
/// statements. Joins, aggregates and anti-joins are allowed. Every query opens
/// and closes a fresh memory database and has a two-second execution deadline,
/// one-million-operation bound, thirty-two columns and a one-MiB output cap.
/// Bound parameters are Cells; blobs are unavailable in this vocabulary.
///
/// The tables are listed by `schema()`; `"references"` is an SQL keyword, so
/// quote it. Joining `targets` to `"references"` on `target_id = id` pairs each
/// requested target with its references, and a LEFT JOIN with `WHERE
/// r.target_id IS NULL` proves a requested target has none.
/// File columns are named `path`, never `file`.
///
/// ## Examples
///
/// ```gleam
/// lsp_sql.query(observation, "SELECT count(*) FROM symbols", [], fn(row) {
///   case row {
///     [lsp_sql.Integer(n)] -> Ok(n)
///     _ -> Error("expected one integer count")
///   }
/// })
/// ```
///
/// Join each requested target to its references:
///
/// ```sql
/// SELECT t.symbol, r.path, r.line, r.text
/// FROM targets t JOIN "references" r ON r.target_id = t.id
/// ORDER BY t.symbol, r.path, r.line
/// ```
///
/// The anti-join that proves a requested target has no references in this
/// observation:
///
/// ```sql
/// SELECT t.symbol FROM targets t
/// LEFT JOIN "references" r ON r.target_id = t.id
/// WHERE r.target_id IS NULL
/// ```
pub fn query(
  observation: Observation,
  sql: String,
  params: List(Cell),
  decoder: RowDecoder(a),
) -> Result(QueryResult(a), QueryError) {
  use projected <- result.try(
    ffi_lsp_sql.query(
      observation.documents,
      observation.symbols,
      observation.targets,
      observation.references,
      sql,
      params,
    )
    |> result.map_error(native_error),
  )
  use rows <- result.try(decode_rows(projected.1, decoder, 0))
  Ok(QueryResult(columns: projected.0, rows:, observation: observation.metadata))
}

fn decode_rows(
  rows: List(List(Cell)),
  decoder: RowDecoder(a),
  index: Int,
) -> Result(List(a), QueryError) {
  case rows {
    [] -> Ok([])
    [row, ..rest] -> {
      use value <- result.try(
        decoder(row)
        |> result.map_error(fn(reason) { DecodeFailed(index, reason) }),
      )
      use remaining <- result.try(decode_rows(rest, decoder, index + 1))
      Ok([value, ..remaining])
    }
  }
}

fn call_error(error: channel.CallError) -> Error {
  case error {
    channel.Unreachable(reason) -> Unavailable(reason)
    channel.Denied(code, message) ->
      case code {
        "invalid_scope" | "invalid_argument" -> InvalidScope(message)
        "observation_changed" -> Changed(message)
        "observation_limit" -> LimitExceeded(message)
        "observation_deadline" | "unsettled" -> DeadlineExceeded
        "snapshot_ceiling" -> CaptureCeilingReached
        "observation_query" -> QueryFailed(message)
        _unknown -> Denied(code, message)
      }
  }
}

fn optional_int(value: Option(Int)) -> m.MsgPackValue {
  case value {
    None -> m.NilValue
    Some(n) -> m.IntValue(n)
  }
}

fn target(value: m.MsgPackValue) -> Result(Target, String) {
  use symbol <- result.try(wire.string_field(value, "symbol"))
  use path <- result.try(wire.string_field(value, "path"))
  use raw <- result.try(wire.field(value, "line"))
  use line <- result.try(case raw {
    m.NilValue -> Ok(None)
    m.IntValue(n) if n > 0 -> Ok(Some(n))
    _other -> Error("invalid target line")
  })
  Ok(Target(symbol:, path:, line:))
}

fn text(value: m.MsgPackValue) -> Result(String, String) {
  case value {
    m.StringValue(s) -> Ok(s)
    m.NilValue
    | m.BoolValue(_)
    | m.IntValue(_)
    | m.FloatValue(_)
    | m.BinaryValue(_)
    | m.ArrayValue(_)
    | m.MapValue(_) -> Error("expected text")
  }
}

fn cell(value: m.MsgPackValue) -> Result(Cell, String) {
  case value {
    m.NilValue -> Ok(Null)
    m.StringValue(s) -> Ok(Text(s))
    m.IntValue(n) -> Ok(Integer(n))
    m.BoolValue(_)
    | m.FloatValue(_)
    | m.BinaryValue(_)
    | m.ArrayValue(_)
    | m.MapValue(_) -> Error("invalid observation cell")
  }
}

fn row(value: m.MsgPackValue) -> Result(List(Cell), String) {
  case value {
    m.ArrayValue(cells) -> list.try_map(cells, cell)
    m.NilValue
    | m.BoolValue(_)
    | m.IntValue(_)
    | m.FloatValue(_)
    | m.StringValue(_)
    | m.BinaryValue(_)
    | m.MapValue(_) -> Error("expected fact row")
  }
}

fn decode(value: m.MsgPackValue) -> Result(Observation, String) {
  use server <- result.try(wire.string_field(value, "server"))
  use root <- result.try(wire.string_field(value, "root"))
  use generation <- result.try(wire.string_field(value, "generation"))
  use started_ms <- result.try(wire.int_field(value, "started_ms"))
  use finished_ms <- result.try(wire.int_field(value, "finished_ms"))
  use outlined <- result.try(wire.array_of(value, "outlined", text))
  use targets <- result.try(wire.array_of(value, "asked_targets", target))

  // The counts describe complete capture and withheld locations, independently
  // of the SQL projection a caller will choose later.
  use requests <- result.try(wire.int_field(value, "requests"))
  use withheld <- result.try(wire.int_field(value, "withheld"))
  use facts <- result.try(wire.int_field(value, "facts"))
  use fact_bytes <- result.try(wire.int_field(value, "fact_bytes"))
  let metadata =
    Metadata(
      server:,
      root:,
      generation:,
      started_ms:,
      finished_ms:,
      outlined:,
      targets:,
      requests:,
      withheld:,
      facts:,
      fact_bytes:,
    )

  // Facts remain private immutable rows. The only model-visible projection is
  // a native query decoded locally with its provenance beside it.
  use documents <- result.try(wire.array_of(value, "documents", row))
  use symbols <- result.try(wire.array_of(value, "symbols", row))
  use targets <- result.try(wire.array_of(value, "targets", row))
  use references <- result.try(wire.array_of(value, "references", row))
  Ok(Observation(metadata:, documents:, symbols:, targets:, references:))
}

// The native boundary names a refused table only in SQLite's own words, so a
// model that wrote `sqlite_master` or guessed `facts` learned nothing about
// what exists. The two refusals an unknown table produces are given the table
// list here, in the one place that already knows the schema.
fn native_error(error: #(String, String)) -> QueryError {
  let #(code, reason) = error
  case code {
    "read_only_denied" if reason == "read_only_denied" ->
      ReadOnlyDenied(
        "an unapproved table or function was named; " <> table_hint,
      )
    "read_only_denied" -> ReadOnlyDenied(reason)
    "multiple_statements" -> MultipleStatements
    "sql_error" ->
      case string.contains(reason, "no such table") {
        True -> InvalidQuery(reason <> "; " <> table_hint)
        False -> InvalidQuery(reason)
      }
    "invalid_argument" -> InvalidQuery(reason)
    "row_limit" -> QueryLimitExceeded(Rows, reason)
    "column_limit" -> QueryLimitExceeded(Columns, reason)
    "byte_limit" -> QueryLimitExceeded(Bytes, reason)
    "memory_limit" -> QueryLimitExceeded(Memory, reason)
    "instruction_limit" -> QueryLimitExceeded(Instructions, reason)
    "timeout" -> QueryLimitExceeded(Time, reason)
    "blob_not_supported" | "invalid_text" | "non_finite_real" ->
      UnsupportedValue(reason)
    "unsupported_build" | "sqlite_failed" -> SqlUnavailable(reason)
    "cancelled" -> QueryCancelled
    _unknown -> SqlRefused(code, reason)
  }
}

/// A one-line rendering of a capture `Error`, for a program building a report out of what went wrong.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_sql.error_text(lsp_sql.QueryFailed("symbol not found: main")) == "query failed: symbol not found: main"
/// ```
///
pub fn error_text(error: Error) -> String {
  case error {
    InvalidScope(reason:) -> "invalid scope: " <> reason
    Changed(reason:) -> "observation changed: " <> reason
    LimitExceeded(reason:) -> "capture limit exceeded: " <> reason
    DeadlineExceeded -> "capture deadline exceeded"
    CaptureCeilingReached ->
      "capture ceiling reached: at most four captures per invocation"
    QueryFailed(reason:) -> "query failed: " <> reason
    Denied(code:, message:) -> "denied (" <> code <> "): " <> message
    Unavailable(reason:) -> "unavailable: " <> reason
  }
}

/// A one-line rendering of a `QueryError`, for a program building a report out of what went wrong.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_sql.query_error_text(lsp_sql.DecodeFailed(2, "expected text")) == "row 2 did not decode: expected text"
/// ```
///
pub fn query_error_text(error: QueryError) -> String {
  case error {
    ReadOnlyDenied(reason:) -> "read-only denied: " <> reason
    MultipleStatements -> "more than one statement was submitted"
    InvalidQuery(reason:) -> "invalid query: " <> reason
    QueryLimitExceeded(limit:, reason:) ->
      "query limit exceeded (" <> limit_text(limit) <> "): " <> reason
    UnsupportedValue(reason:) -> "unsupported value: " <> reason
    SqlUnavailable(reason:) -> "sql unavailable: " <> reason
    QueryCancelled -> "query cancelled"
    SqlRefused(code:, message:) -> "refused (" <> code <> "): " <> message
    DecodeFailed(row:, reason:) ->
      "row " <> int.to_string(row) <> " did not decode: " <> reason
  }
}

// The one definition of the schema. `schema()` renders it and the table hint
// in a refusal quotes its names. `schema`'s doc repeats it as prose, because
// the prelude generator keeps only the paragraphs before a doc's first
// heading and a fenced block would not survive. A cap test runs every listed
// column against the native boundary, and a tools test checks that the
// generated surface carries each line of `schema()`, so neither this list nor
// that prose can drift from the tables the bridge creates.
const tables = [
  #("documents", ["path", "digest", "version"]),
  #("symbols", [
    "id", "parent_id", "name", "kind", "detail", "path", "line", "column",
    "text", "anchor",
  ]),
  #("targets", [
    "id", "symbol", "asked_path", "asked_line", "path", "line", "column", "text",
    "anchor",
  ]),
  #("\"references\"", ["target_id", "path", "line", "column", "text", "anchor"]),
]

const table_hint =
  "the tables are documents, symbols, targets, \"references\" (see lsp_sql.schema())"

/// The fixed tables and columns every query runs against, one table per
/// line, so a program can print them instead of probing `sqlite_master`, which
/// the read-only authorizer refuses.
///
/// Only these four tables exist: documents(path, digest, version),
/// symbols(id, parent_id, name, kind, detail, path, line, column, text,
/// anchor), targets(id, symbol, asked_path, asked_line, path, line, column,
/// text, anchor) and "references"(target_id, path, line, column, text,
/// anchor). A requested target is one row of targets, and
/// "references".target_id points at targets.id.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(lsp_sql.schema(), "documents(path, digest, version)")
/// ```
///
pub fn schema() -> String {
  tables
  |> list.map(fn(table) { table.0 <> "(" <> string.join(table.1, ", ") <> ")" })
  |> string.join("\n")
}

/// A query cell as text: `NULL` for `Null`, the printed number for
/// `Integer` and `Real`, and the text itself for `Text`.
///
/// ## Examples
///
/// ```gleam
/// assert lsp_sql.cell_text(lsp_sql.Null) == "NULL"
/// assert lsp_sql.cell_text(lsp_sql.Integer(7)) == "7"
/// assert lsp_sql.cell_text(lsp_sql.Text("main")) == "main"
/// ```
///
pub fn cell_text(cell: Cell) -> String {
  case cell {
    Null -> "NULL"
    Integer(value:) -> int.to_string(value)
    Real(value:) -> string.inspect(value)
    Text(value:) -> value
  }
}

fn limit_text(limit: QueryLimit) -> String {
  case limit {
    Rows -> "rows"
    Columns -> "columns"
    Bytes -> "bytes"
    Memory -> "memory"
    Instructions -> "instructions"
    Time -> "time"
  }
}
