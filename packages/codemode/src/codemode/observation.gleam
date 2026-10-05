//// The finite observation router keeps SQL and projection outside the harness.
////
//// A valid capture request becomes a scoped service. Its worker owns collection
//// and the shared LSP client withdraws requests when that worker dies. Only a
//// complete bounded batch crosses the channel; tables are immutable facts, never
//// virtual tables that could issue hidden server requests during a SQL join.

import broker/framing
import codemode/internal/args
import codemode/satellite
import core/msgpack as m
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/observation as o
import lsp/query
import tools/hashline

/// The only harness call required by cap/lsp_sql.
pub const snapshot_cap = "lsp.snapshot"

/// The lifetime capture ceiling per invocation.
pub const max_admissions = 4

/// The capture ceiling used by both satellite boot shapes.
///
/// ## Examples
///
/// ```gleam
/// observation.ceilings()
/// ```
pub fn ceilings() -> List(satellite.CapCeiling) {
  [
    satellite.CapCeiling(
      cap: snapshot_cap,
      admissions: max_admissions,
      code: "snapshot_ceiling",
    ),
  ]
}

/// Installs capture over the invocation's absolute deadline and clock.
///
/// ## Examples
///
/// ```gleam
/// // observation.routing(door, control, over: inner)
/// ```
pub fn routing(
  door: o.Door,
  control: o.Control,
  over inner: satellite.CapRouter,
) -> satellite.CapRouter {
  let collect = door.collect
  fn(request: satellite.CapRequest) {
    case request.cap {
      "lsp.snapshot" -> {
        use scope <- result.try(decode_request(request.args))
        Ok(
          satellite.ScopedService(fn() {
            case collect(scope, control) {
              Ok(batch) -> framing.CapOk(encode(batch))
              Error(error) -> refusal(error)
            }
          }),
        )
      }
      _other -> inner(request)
    }
  }
}

fn decode_request(
  value: m.MsgPackValue,
) -> Result(o.Request, satellite.CapDenial) {
  use server <- result.try(args.string(value, "server"))
  use root <- result.try(args.string(value, "root"))
  use raw_outlines <- result.try(bounded_array(
    value,
    "outlines",
    o.max_outline_files,
  ))
  use outlines <- result.try(
    list.try_map(raw_outlines, fn(item) {
      case item {
        m.StringValue(path) -> Ok(path)
        m.NilValue
        | m.BoolValue(_)
        | m.IntValue(_)
        | m.FloatValue(_)
        | m.BinaryValue(_)
        | m.ArrayValue(_)
        | m.MapValue(_) -> Error(args.invalid("outline entries must be text"))
      }
    }),
  )
  use raw_targets <- result.try(bounded_array(value, "targets", o.max_targets))
  use targets <- result.try(list.try_map(raw_targets, decode_target))
  Ok(o.Request(server:, root:, outlines:, targets:))
}

// Fixed list bounds are checked before decoding any entry, so malformed large
// requests spend no collector work and build no second unbounded target list.
fn bounded_array(
  value: m.MsgPackValue,
  key: String,
  limit: Int,
) -> Result(List(m.MsgPackValue), satellite.CapDenial) {
  use raw <- result.try(args.field(value, key))
  case raw {
    m.ArrayValue(items) ->
      case list.drop(items, limit) {
        [] -> Ok(items)
        [_first, ..] ->
          Error(args.invalid(key <> " exceeds its fixed capture bound"))
      }
    m.NilValue
    | m.BoolValue(_)
    | m.IntValue(_)
    | m.FloatValue(_)
    | m.StringValue(_)
    | m.BinaryValue(_)
    | m.MapValue(_) -> Error(args.invalid(key <> " must be an array"))
  }
}

fn decode_target(
  value: m.MsgPackValue,
) -> Result(query.SymbolQuery, satellite.CapDenial) {
  use symbol <- result.try(args.string(value, "symbol"))
  use path <- result.try(args.string(value, "path"))
  use raw <- result.try(args.field(value, "line"))
  use line <- result.try(case raw {
    m.NilValue -> Ok(None)
    m.IntValue(n) if n > 0 -> Ok(Some(n))
    _other -> Error(args.invalid("target line must be positive or nil"))
  })
  Ok(query.SymbolQuery(symbol:, path: Some(path), line:))
}

fn refusal(error: o.Error) -> framing.CapOutcome {
  let #(code, message) = case error {
    o.InvalidScope(reason) -> #("invalid_scope", reason)
    o.Changed(reason) -> #("observation_changed", reason)
    o.LimitExceeded(reason) -> #("observation_limit", reason)
    o.DeadlineExceeded -> #(
      "observation_deadline",
      "observation deadline expired",
    )
    o.QueryFailed(error) -> #("observation_query", query_message(error))
  }
  framing.CapErr(code:, message:)
}

fn map(fields: List(#(String, m.MsgPackValue))) -> m.MsgPackValue {
  m.MapValue(list.map(fields, fn(pair) { #(m.StringValue(pair.0), pair.1) }))
}

fn optional_int(value) {
  case value {
    None -> m.NilValue
    Some(n) -> m.IntValue(n)
  }
}

fn optional_text(value) {
  case value {
    None -> m.NilValue
    Some(s) -> m.StringValue(s)
  }
}

fn site(site: query.Site) -> List(m.MsgPackValue) {
  [
    m.StringValue(site.path),
    m.IntValue(site.line),
    m.IntValue(site.column),
    m.StringValue(site.text),
    m.StringValue(hashline.anchor(site.text)),
  ]
}

fn rows(values, render) {
  m.ArrayValue(list.map(values, fn(value) { m.ArrayValue(render(value)) }))
}

// Metadata is outside the tables, so every projected query keeps the same
// declared scope, generation, interval and withheld count.
fn encode(batch: o.Batch) -> m.MsgPackValue {
  map([
    #("server", m.StringValue(batch.requested.server)),
    #("root", m.StringValue(batch.root)),
    #("generation", m.StringValue(batch.generation)),
    #("started_ms", m.IntValue(batch.started_ms)),
    #("finished_ms", m.IntValue(batch.finished_ms)),
    #("outlined", m.ArrayValue(list.map(batch.outlined, m.StringValue))),
    #(
      "asked_targets",
      m.ArrayValue(
        list.map(batch.requested.targets, fn(target) {
          map([
            #("symbol", m.StringValue(target.symbol)),
            #("path", optional_text(target.path)),
            #("line", optional_int(target.line)),
          ])
        }),
      ),
    ),
    #("requests", m.IntValue(batch.counts.requests)),
    #("withheld", m.IntValue(batch.counts.withheld)),
    #("facts", m.IntValue(batch.counts.facts)),
    #("fact_bytes", m.IntValue(batch.counts.fact_bytes)),
    #(
      "documents",
      rows(batch.documents, fn(d) {
        [
          m.StringValue(d.path),
          m.StringValue(d.digest),
          optional_int(d.version),
        ]
      }),
    ),
    #(
      "symbols",
      rows(batch.symbols, fn(s) {
        [
          m.IntValue(s.id),
          optional_int(s.parent_id),
          m.StringValue(s.name),
          m.StringValue(s.kind),
          optional_text(s.detail),
          ..site(s.site)
        ]
      }),
    ),
    #(
      "targets",
      rows(batch.targets, fn(t) {
        [
          m.IntValue(t.id),
          m.StringValue(t.asked.symbol),
          optional_text(t.asked.path),
          optional_int(t.asked.line),
          ..site(t.site)
        ]
      }),
    ),
    #(
      "references",
      rows(batch.references, fn(r) { [m.IntValue(r.target_id), ..site(r.site)] }),
    ),
  ])
}

// A bare name is the usual reason a seed misses: the server indexes a method
// under its receiver and a package-level item under its package, and a program
// that wrote only the last segment gets no more than "not found" to go on. The
// resolver is unchanged; only the reason says what to try.
fn not_found_message(symbol: String) -> String {
  case string.contains(symbol, ".") {
    True -> "symbol not found: " <> symbol
    False ->
      "symbol not found: "
      <> symbol
      <> "; the name is unqualified, and the server may want the qualified "
      <> "form (package.Name, or Receiver.Method for a method)"
  }
}

fn query_message(error: query.QueryError) -> String {
  case error {
    query.NoServer(reason) | query.Unavailable(reason) -> reason
    query.ServerRefused(message) -> message
    query.Unsupported(server, request) ->
      server <> " does not support " <> request
    query.NotFound(asked) -> not_found_message(asked.symbol)
    query.Ambiguous(_) -> "reference seed is ambiguous; narrow its line"
  }
}
