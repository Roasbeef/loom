//// Closed finite LSP semantic content crosses the authenticated endpoint.
////
//// The raw scanner checks fixed byte/depth/node profiles before MessagePack
//// allocates terms. Total field decoders then preserve complete query meanings;
//// canonical re-encoding admits one immutable spelling. Interactive results
//// use a shared 10000-row/four-MiB content budget. Observation separately retains
//// its existing complete fact budget and the larger echoed scope/path shell.
//// Neither this codec nor an identity constructor grants physical authority.
//// Owner admission and the executor service compare original mutation/write
//// references and readmit executor paths before any physical read or landing.
////
//// ## Flow
////
//// `encode_request` and `decode_request` retain the complete finite request.
//// `semantic_input` fixes its exact bytes and digest before pure capture.
//// `encode_result` and `decode_result` check request compatibility and shared
//// complete content accounting. `encode_capture_envelope` and
//// `encode_invocation_envelope` keep header and body profiles independent;
//// `decode_result_envelope` compares the retained timed identity before result
//// decoding. `split_envelope` bounds declared header lengths before allocation.

import core/generation
import core/internal/msgpack_scan
import core/lsp_command as identity
import core/msgpack as m
import executor/remote/lsp_wire/observation as batch
import executor/remote/lsp_wire/query as rows
import executor/remote/lsp_wire/value as v
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/observation
import lsp/query

/// The complete finite semantic request body ceiling.
pub const max_request_bytes = 131_072

/// The complete result body, including observation's separately charged shell.
pub const max_result_bytes = 4_464_896

/// Identity, timing and control-reference bytes share this fixed ceiling.
pub const max_header_bytes = 8192

/// The exact invocation content envelope ceiling.
pub const max_invocation_bytes = 139_268

/// The exact result content envelope ceiling.
pub const max_result_envelope_bytes = 4_473_092

/// Fixed failures retain no rejected peer body.
pub type CodecError {
  /// Unknown shape, invalid field or noncanonical spelling.
  InvalidPayload

  /// Raw bytes, nesting, nodes or a container exceed the fixed profile.
  PreflightRefused

  /// The complete semantic content exceeds its reservation.
  LimitExceeded

  /// A result tag cannot answer the retained request.
  ResponseMismatch

  /// The exact body digest differs from its retained identity.
  DigestMismatch
}

/// The closed complete request vocabulary in protocol-076 declaration order.
pub type Request {
  /// Definitions for an original symbol query.
  Definition(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
  )

  /// References for an original symbol query.
  References(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
  )

  /// Complete hover contents, independent of display clipping.
  Hover(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
  )

  /// The complete outline for an admitted path.
  Outline(
    /// The original admitted workspace path spelling.
    path: String,
  )

  /// One direction of the call hierarchy.
  Calls(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
    /// The closed incoming or outgoing call direction.
    direction: query.CallDirection,
  )

  /// Current diagnostics for one path or the active project.
  Diagnostics(
    /// The original admitted workspace path spelling.
    path: Option(String),
  )

  /// A complete read-only rename preview.
  PrepareRename(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
    /// The exact requested replacement symbol spelling.
    new_name: String,
  )

  /// A mutation whose original approved child reference is checked at admission.
  ApplyRename(
    /// The complete original symbol, optional path and one-based line.
    query: query.SymbolQuery,
    /// The exact requested replacement symbol spelling.
    new_name: String,
    /// The complete original mutation child, verified against owner approval at admission.
    approved: identity.OriginalChildRef,
  )

  /// Post-write observation of the original physically landed write.
  AfterWrite(
    /// The original admitted workspace path spelling.
    path: String,
    /// The complete original landed write, verified against physical write custody.
    write: identity.OriginalChildRef,
  )

  /// A separate finite complete observation scope.
  Observe(
    /// The original explicitly scoped observation request.
    request: observation.Request,
  )
}

/// Explicit checked limit categories; overflow cannot advertise a prefix success.
pub type LimitKind {
  /// Shared nested row count exceeded.
  Rows

  /// Shared retained strings/texts and conservative overhead exceeded.
  ContentBytes

  /// Bounded source, protocol or request inventory exceeded.
  Inventory
}

/// Complete results retain existing query and observation semantics.
pub type ResultValue {
  /// Every admitted definition site.
  Definitions(
    /// The complete original semantic payload, before display projection.
    value: query.Served(List(query.Site)),
  )

  /// Every reference site and its optional container.
  ReferenceSites(
    /// The complete original semantic payload, before display projection.
    value: query.Served(List(query.Reference)),
  )

  /// Complete hover value before display projection.
  Hovered(
    /// The complete original semantic payload, before display projection.
    value: query.Served(query.Hover),
  )

  /// Complete outline, encoded flat in preorder.
  Outlined(
    /// The complete original semantic payload, before display projection.
    value: query.Served(List(query.SymbolEntry)),
  )

  /// Complete call hierarchy rows and nested call sites.
  Called(
    /// The complete original semantic payload, before display projection.
    value: query.Served(List(query.Call)),
  )

  /// Diagnostics preserve their original settlement status.
  Diagnosed(
    /// The complete original semantic payload, before display projection.
    value: query.Served(query.Diagnostics),
  )

  /// Exact rename preimage and edited material for every file.
  RenamePrepared(
    /// The complete original semantic payload, before display projection.
    value: query.Served(List(query.FileEdit)),
  )

  /// Exact complete partial file landing report.
  RenameApplied(
    /// The complete original semantic payload, before display projection.
    value: query.Served(query.RenameReport),
  )

  /// No owning server or exact post-write diagnostic evidence.
  WriteObserved(
    /// The complete original semantic payload, before display projection.
    value: Option(query.Diagnostics),
  )

  /// The existing complete finite observation batch.
  Observed(
    /// The complete original semantic payload, before display projection.
    value: observation.Batch,
  )

  /// Existing closed interactive failure vocabulary.
  QueryFailed(
    /// The complete existing closed semantic failure.
    error: query.QueryError,
  )

  /// Existing closed observation failure vocabulary.
  ObservationFailed(
    /// The complete existing closed semantic failure.
    error: observation.Error,
  )

  /// Checked overflow without claiming a complete prefix.
  Limited(
    /// The explicit checked overflow category.
    kind: LimitKind,
  )
}

/// Encodes and checks every field before emitting canonical semantic bytes.
///
/// ## Examples
///
/// A line without a path refuses before finite capture.
pub fn encode_request(request: Request) -> Result(BitArray, CodecError) {
  let value = request_value(request)
  use _ <- result.try(
    parse_request(value) |> result.replace_error(InvalidPayload),
  )
  encode(value, msgpack_scan.lsp_request)
}

/// Scans the complete bounded request before term allocation and semantic checks.
///
/// ## Examples
///
/// Nonminimal scalar widths or surplus fields are refused.
pub fn decode_request(bytes: BitArray) -> Result(Request, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_request))
  use request <- result.try(
    parse_request(value) |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_request(request))
  use Nil <- result.try(
    v.check(fn() { canonical == bytes }) |> result.replace_error(InvalidPayload),
  )
  Ok(request)
}

/// Supplies pure identity with checked semantic bytes and their actual SHA256.
///
/// ## Examples
///
/// The request's input digest is fixed before timing capture.
pub fn semantic_input(
  request: Request,
) -> Result(identity.SemanticInput, CodecError) {
  use bytes <- result.try(encode_request(request))
  use digest <- result.try(
    generation.digest(crypto.hash(crypto.Sha256, bytes))
    |> result.replace_error(InvalidPayload),
  )
  identity.semantic_input(bytes, digest, request_tag(request))
  |> result.replace_error(InvalidPayload)
}

/// Projects the fixed request tag without choosing an arbitrary service role.
///
/// ## Examples
///
/// Observe retains tag nine regardless of display or transport mode.
pub fn request_tag(request: Request) -> Int {
  case request {
    Definition(_) -> 0
    References(_) -> 1
    Hover(_) -> 2
    Outline(_) -> 3
    Calls(_, _) -> 4
    Diagnostics(_) -> 5
    PrepareRename(_, _) -> 6
    ApplyRename(_, _, _) -> 7
    AfterWrite(_, _) -> 8
    Observe(_) -> 9
  }
}

fn request_value(request: Request) -> m.MsgPackValue {
  case request {
    Definition(query) -> m.ArrayValue([m.IntValue(0), rows.symbol_value(query)])
    References(query) -> m.ArrayValue([m.IntValue(1), rows.symbol_value(query)])
    Hover(query) -> m.ArrayValue([m.IntValue(2), rows.symbol_value(query)])
    Outline(path) -> m.ArrayValue([m.IntValue(3), m.StringValue(path)])
    Calls(query, direction) ->
      m.ArrayValue([
        m.IntValue(4),
        rows.symbol_value(query),
        m.IntValue(case direction {
          query.Incoming -> 0
          query.Outgoing -> 1
        }),
      ])
    Diagnostics(path) ->
      m.ArrayValue([m.IntValue(5), v.option(path, m.StringValue)])
    PrepareRename(query, name) ->
      m.ArrayValue([
        m.IntValue(6),
        rows.symbol_value(query),
        m.StringValue(name),
      ])
    ApplyRename(query, name, approved) ->
      m.ArrayValue([
        m.IntValue(7),
        rows.symbol_value(query),
        m.StringValue(name),
        identity.original_child_value(approved),
      ])
    AfterWrite(path, write) ->
      m.ArrayValue([
        m.IntValue(8),
        m.StringValue(path),
        identity.original_child_value(write),
      ])
    Observe(request) ->
      m.ArrayValue([m.IntValue(9), rows.observation_request_value(request)])
  }
}

fn parse_request(value: m.MsgPackValue) -> Result(Request, Nil) {
  case value {
    m.ArrayValue([m.IntValue(0), query]) ->
      rows.parse_symbol(query) |> result.map(Definition)
    m.ArrayValue([m.IntValue(1), query]) ->
      rows.parse_symbol(query) |> result.map(References)
    m.ArrayValue([m.IntValue(2), query]) ->
      rows.parse_symbol(query) |> result.map(Hover)
    m.ArrayValue([m.IntValue(3), path]) -> v.path(path) |> result.map(Outline)
    m.ArrayValue([m.IntValue(4), query, direction]) -> {
      use query <- result.try(rows.parse_symbol(query))
      use direction <- result.try(case direction {
        m.IntValue(0) -> Ok(query.Incoming)
        m.IntValue(1) -> Ok(query.Outgoing)
        _ -> Error(Nil)
      })
      Ok(Calls(query, direction))
    }
    m.ArrayValue([m.IntValue(5), path]) ->
      v.optional(path, v.path) |> result.map(Diagnostics)
    m.ArrayValue([m.IntValue(6), query, name]) -> {
      use query <- result.try(rows.parse_symbol(query))
      use name <- result.try(v.name(name, 131_072))
      Ok(PrepareRename(query, name))
    }
    m.ArrayValue([m.IntValue(7), query, name, approved]) -> {
      use query <- result.try(rows.parse_symbol(query))
      use name <- result.try(v.name(name, 131_072))
      use approved <- result.try(
        identity.decode_child_ref_value(approved) |> result.replace_error(Nil),
      )
      Ok(ApplyRename(query, name, approved))
    }
    m.ArrayValue([m.IntValue(8), path, write]) -> {
      use path <- result.try(v.path(path))
      use write <- result.try(
        identity.decode_child_ref_value(write) |> result.replace_error(Nil),
      )
      Ok(AfterWrite(path, write))
    }
    m.ArrayValue([m.IntValue(9), request]) ->
      rows.parse_observation_request(request) |> result.map(Observe)
    _ -> Error(Nil)
  }
}

fn encode(
  value: m.MsgPackValue,
  scan: fn(BitArray) -> Result(Nil, core_report),
) -> Result(BitArray, CodecError) {
  use bytes <- result.try(
    m.encode(value) |> result.replace_error(InvalidPayload),
  )
  use Nil <- result.try(scan(bytes) |> result.replace_error(PreflightRefused))
  Ok(bytes)
}

fn decode(
  bytes: BitArray,
  scan: fn(BitArray) -> Result(Nil, core_report),
) -> Result(m.MsgPackValue, CodecError) {
  use Nil <- result.try(scan(bytes) |> result.replace_error(PreflightRefused))
  use value <- result.try(
    m.decode(bytes) |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(
    m.encode(value) |> result.replace_error(InvalidPayload),
  )
  use Nil <- result.try(
    v.check(fn() { canonical == bytes }) |> result.replace_error(InvalidPayload),
  )
  Ok(value)
}

/// Encodes complete request-matched results under their semantic reservation.
///
/// ## Examples
///
/// A hover result cannot answer a retained Definition request.
pub fn encode_result(
  expected: Request,
  completed: ResultValue,
) -> Result(BitArray, CodecError) {
  use Nil <- result.try(matches(expected, completed))
  use Nil <- result.try(result_budget(completed))
  use value <- result.try(result_value(completed))
  use _ <- result.try(
    parse_result(value) |> result.replace_error(InvalidPayload),
  )
  encode(value, msgpack_scan.lsp_result)
}

/// Applies raw preflight before allocating rows and checks the retained request.
///
/// ## Examples
///
/// Unknown data does not become an empty successful result or QueryFailed.
pub fn decode_result(
  expected: Request,
  bytes: BitArray,
) -> Result(ResultValue, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_result))
  use completed <- result.try(
    parse_result(value) |> result.replace_error(InvalidPayload),
  )
  use Nil <- result.try(matches(expected, completed))
  use Nil <- result.try(result_budget(completed))
  use canonical <- result.try(encode_result(expected, completed))
  use Nil <- result.try(
    v.check(fn() { canonical == bytes }) |> result.replace_error(InvalidPayload),
  )
  Ok(completed)
}

fn matches(
  expected: Request,
  completed: ResultValue,
) -> Result(Nil, CodecError) {
  case expected, completed {
    Definition(_), Definitions(_)
    | References(_), ReferenceSites(_)
    | Hover(_), Hovered(_)
    | Outline(_), Outlined(_)
    | Calls(_, _), Called(_)
    | Diagnostics(_), Diagnosed(_)
    | PrepareRename(_, _), RenamePrepared(_)
    | ApplyRename(_, _, _), RenameApplied(_)
    | AfterWrite(_, _), WriteObserved(_)
    -> Ok(Nil)
    Observe(request), Observed(value) ->
      v.check(fn() { value.requested == request })
      |> result.replace_error(ResponseMismatch)
    Observe(_), ObservationFailed(_) -> Ok(Nil)
    _, Limited(_) -> Ok(Nil)
    Observe(_), QueryFailed(_) -> Error(ResponseMismatch)
    _, QueryFailed(_) -> Ok(Nil)
    _, _ -> Error(ResponseMismatch)
  }
}

fn result_value(completed: ResultValue) -> Result(m.MsgPackValue, CodecError) {
  use #(tag, payload) <- result.try(case completed {
    Definitions(value) ->
      Ok(#(
        0,
        rows.served_value(value, fn(value) { v.array(value, rows.site_value) }),
      ))
    ReferenceSites(value) ->
      Ok(#(
        1,
        rows.served_value(value, fn(value) {
          v.array(value, rows.reference_value)
        }),
      ))
    Hovered(value) -> Ok(#(2, rows.served_value(value, rows.hover_value)))
    Outlined(value) -> {
      use outline <- result.try(
        rows.outline_value(value.value) |> result.replace_error(LimitExceeded),
      )
      Ok(#(3, m.ArrayValue([rows.warmth_value(value.warmth), outline])))
    }
    Called(value) ->
      Ok(#(
        4,
        rows.served_value(value, fn(value) { v.array(value, rows.call_value) }),
      ))
    Diagnosed(value) ->
      Ok(#(5, rows.served_value(value, rows.diagnostics_value)))
    RenamePrepared(value) ->
      Ok(#(
        6,
        rows.served_value(value, fn(value) {
          v.array(value, rows.file_edit_value)
        }),
      ))
    RenameApplied(value) ->
      Ok(#(7, rows.served_value(value, rows.rename_report_value)))
    WriteObserved(value) -> Ok(#(8, v.option(value, rows.diagnostics_value)))
    Observed(value) -> Ok(#(9, batch.batch_value(value)))
    QueryFailed(error) -> Ok(#(10, rows.error_value(error)))
    ObservationFailed(error) -> Ok(#(11, batch.error_value(error)))
    Limited(kind) ->
      Ok(#(
        12,
        m.IntValue(case kind {
          Rows -> 0
          ContentBytes -> 1
          Inventory -> 2
        }),
      ))
  })
  Ok(m.ArrayValue([m.IntValue(1), m.IntValue(tag), payload]))
}

fn parse_result(value: m.MsgPackValue) -> Result(ResultValue, Nil) {
  case value {
    m.ArrayValue([m.IntValue(1), m.IntValue(0), payload]) ->
      rows.parse_served(payload, fn(value) {
        v.items(value, 10_000, rows.parse_site)
      })
      |> result.map(Definitions)
    m.ArrayValue([m.IntValue(1), m.IntValue(1), payload]) ->
      rows.parse_served(payload, fn(value) {
        v.items(value, 10_000, rows.parse_reference)
      })
      |> result.map(ReferenceSites)
    m.ArrayValue([m.IntValue(1), m.IntValue(2), payload]) ->
      rows.parse_served(payload, rows.parse_hover) |> result.map(Hovered)
    m.ArrayValue([m.IntValue(1), m.IntValue(3), payload]) ->
      rows.parse_served(payload, rows.parse_outline) |> result.map(Outlined)
    m.ArrayValue([m.IntValue(1), m.IntValue(4), payload]) ->
      rows.parse_served(payload, fn(value) {
        v.items(value, 10_000, rows.parse_call)
      })
      |> result.map(Called)
    m.ArrayValue([m.IntValue(1), m.IntValue(5), payload]) ->
      rows.parse_served(payload, rows.parse_diagnostics)
      |> result.map(Diagnosed)
    m.ArrayValue([m.IntValue(1), m.IntValue(6), payload]) ->
      rows.parse_served(payload, fn(value) {
        v.items(value, 10_000, rows.parse_file_edit)
      })
      |> result.map(RenamePrepared)
    m.ArrayValue([m.IntValue(1), m.IntValue(7), payload]) ->
      rows.parse_served(payload, rows.parse_rename_report)
      |> result.map(RenameApplied)
    m.ArrayValue([m.IntValue(1), m.IntValue(8), payload]) ->
      v.optional(payload, rows.parse_diagnostics) |> result.map(WriteObserved)
    m.ArrayValue([m.IntValue(1), m.IntValue(9), payload]) ->
      batch.parse_batch(payload) |> result.map(Observed)
    m.ArrayValue([m.IntValue(1), m.IntValue(10), payload]) ->
      rows.parse_error(payload) |> result.map(QueryFailed)
    m.ArrayValue([m.IntValue(1), m.IntValue(11), payload]) ->
      batch.parse_error(payload) |> result.map(ObservationFailed)
    m.ArrayValue([m.IntValue(1), m.IntValue(12), m.IntValue(0)]) ->
      Ok(Limited(Rows))
    m.ArrayValue([m.IntValue(1), m.IntValue(12), m.IntValue(1)]) ->
      Ok(Limited(ContentBytes))
    m.ArrayValue([m.IntValue(1), m.IntValue(12), m.IntValue(2)]) ->
      Ok(Limited(Inventory))
    _ -> Error(Nil)
  }
}

fn result_budget(completed: ResultValue) -> Result(Nil, CodecError) {
  use charge <- result.try(case completed {
    Definitions(value) ->
      Ok(with_warmth(sites_charge(value.value), value.warmth))
    ReferenceSites(value) ->
      Ok(with_warmth(
        list.fold(value.value, #(0, 0), fn(total, row) {
          add(
            total,
            add(site_charge(row.site), #(1, 64 + optional_bytes(row.container))),
          )
        }),
        value.warmth,
      ))
    Hovered(value) ->
      Ok(with_warmth(
        add(site_charge(value.value.site), #(
          1,
          64 + string.byte_size(value.value.contents),
        )),
        value.warmth,
      ))
    Outlined(value) -> {
      use flat <- result.try(
        rows.outline_value(value.value) |> result.replace_error(LimitExceeded),
      )
      use charge <- result.try(
        outline_charge(flat) |> result.replace_error(LimitExceeded),
      )
      Ok(with_warmth(charge, value.warmth))
    }
    Called(value) ->
      Ok(with_warmth(
        list.fold(value.value, #(0, 0), fn(total, row) {
          add(
            total,
            add(add(site_charge(row.site), sites_charge(row.at)), #(
              1,
              64 + string.byte_size(row.name),
            )),
          )
        }),
        value.warmth,
      ))
    Diagnosed(value) ->
      Ok(with_warmth(diagnostics_charge(value.value), value.warmth))
    RenamePrepared(value) ->
      Ok(with_warmth(
        list.fold(value.value, #(0, 0), fn(total, row) {
          add(total, #(
            1,
            64
              + string.byte_size(row.path)
              + string.byte_size(row.base)
              + string.byte_size(row.edited),
          ))
        }),
        value.warmth,
      ))
    RenameApplied(value) ->
      Ok(with_warmth(
        add(
          list.fold(value.value.files, #(0, 0), fn(total, row) {
            add(total, landing_charge(row))
          }),
          diagnostics_charge(value.value.diagnostics),
        ),
        value.warmth,
      ))
    WriteObserved(value) ->
      Ok(case value {
        None -> #(0, 0)
        Some(value) -> diagnostics_charge(value)
      })
    Observed(value) -> {
      use _ <- result.try(
        batch.parse_batch(batch.batch_value(value))
        |> result.replace_error(InvalidPayload),
      )
      Ok(#(value.counts.facts, value.counts.fact_bytes))
    }
    QueryFailed(error) -> Ok(query_error_charge(error))
    ObservationFailed(error) -> Ok(observation_error_charge(error))
    Limited(_) -> Ok(#(0, 0))
  })
  v.check(fn() { charge.0 <= 10_000 && charge.1 <= 4_194_304 })
  |> result.replace_error(LimitExceeded)
}

fn site_charge(site: query.Site) -> #(Int, Int) {
  #(1, 64 + string.byte_size(site.path) + string.byte_size(site.text))
}

fn sites_charge(sites: List(query.Site)) -> #(Int, Int) {
  list.fold(sites, #(0, 0), fn(total, site) { add(total, site_charge(site)) })
}

fn add(a: #(Int, Int), b: #(Int, Int)) -> #(Int, Int) {
  #(a.0 + b.0, a.1 + b.1)
}

fn optional_bytes(value: Option(String)) -> Int {
  case value {
    None -> 0
    Some(value) -> string.byte_size(value)
  }
}

fn with_warmth(charge: #(Int, Int), warmth: query.Warmth) -> #(Int, Int) {
  #(
    charge.0,
    charge.1
      + case warmth {
      query.Warm -> 0
      query.Started(server) -> string.byte_size(server)
    },
  )
}

fn diagnostics_charge(value: query.Diagnostics) -> #(Int, Int) {
  let rows = case value {
    query.Settled(rows) | query.Unsettled(rows) -> rows
  }
  list.fold(rows, #(0, 0), fn(total, row) {
    add(
      total,
      add(site_charge(row.site), #(1, 64 + string.byte_size(row.message))),
    )
  })
}

fn landing_charge(value: query.Landing) -> #(Int, Int) {
  case value {
    query.Landed(path, _) | query.NotAttempted(path) -> #(
      1,
      64 + string.byte_size(path),
    )
    query.Rejected(path, reason) -> #(
      1,
      64 + string.byte_size(path) + string.byte_size(reason),
    )
  }
}

fn outline_charge(value: m.MsgPackValue) -> Result(#(Int, Int), Nil) {
  case value {
    m.ArrayValue(rows) ->
      list.try_fold(rows, #(0, 0), fn(total, row) {
        case row {
          m.ArrayValue([
            _,
            m.StringValue(name),
            m.StringValue(kind),
            detail,
            site,
          ]) -> {
            use detail <- result.try(
              v.optional(detail, fn(value) { v.text(value, 4_194_304) }),
            )
            use site <- result.try(rows.parse_site(site))
            Ok(add(
              total,
              add(site_charge(site), #(
                1,
                64
                  + string.byte_size(name)
                  + string.byte_size(kind)
                  + optional_bytes(detail),
              )),
            ))
          }
          _ -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

fn symbol_bytes(value: query.SymbolQuery) -> Int {
  string.byte_size(value.symbol) + optional_bytes(value.path) + 32
}

fn query_error_charge(error: query.QueryError) -> #(Int, Int) {
  case error {
    query.NoServer(reason)
    | query.ServerRefused(reason)
    | query.Unavailable(reason) -> #(0, string.byte_size(reason))
    query.Unsupported(server, request) -> #(
      0,
      string.byte_size(server) + string.byte_size(request),
    )
    query.NotFound(query, searched) -> #(
      0,
      symbol_bytes(query) + optional_bytes(searched),
    )
    query.Ambiguous(sites) -> sites_charge(sites)
  }
}

fn observation_error_charge(error: observation.Error) -> #(Int, Int) {
  case error {
    observation.InvalidScope(reason)
    | observation.Changed(reason)
    | observation.LimitExceeded(reason) -> #(0, string.byte_size(reason))
    observation.QueryFailed(error) -> query_error_charge(error)
    observation.DeadlineExceeded -> #(0, 0)
  }
}

/// Encodes the complete lease header under the aggregate header profile.
///
/// ## Examples
///
/// Startup has nil timing and nil parent control.
pub fn encode_lease(
  lease: identity.LspServiceKey,
) -> Result(BitArray, CodecError) {
  encode(identity.lease_value(lease), msgpack_scan.lsp_header)
}

/// Decodes one canonical lease header without granting startup authority.
///
/// ## Examples
///
/// Invocation headers cannot enter the lease branch.
pub fn decode_lease(
  bytes: BitArray,
) -> Result(identity.LspServiceKey, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use lease <- result.try(
    identity.decode_lease_value(value) |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_lease(lease))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(lease)
}

/// Encodes preliminary capture with the exact checked original request digest.
///
/// ## Examples
///
/// A caller cannot substitute a different semantic body under the capture.
pub fn encode_capture(
  capture: identity.FiniteCapture,
  request: Request,
) -> Result(BitArray, CodecError) {
  use Nil <- result.try(verify_write_reference(request, capture))
  use input <- result.try(semantic_input(request))
  use checked <- result.try(
    identity.decode_capture_value(identity.capture_value(capture), input)
    |> result.replace_error(DigestMismatch),
  )
  use Nil <- result.try(
    v.check(fn() { checked == capture }) |> result.replace_error(InvalidPayload),
  )
  encode(identity.capture_value(capture), msgpack_scan.lsp_header)
}

/// Decodes capture after the request body has passed its independent profile.
///
/// ## Examples
///
/// Capture keeps the original control reference and contains no timing proposal.
pub fn decode_capture(
  bytes: BitArray,
  request: Request,
) -> Result(identity.FiniteCapture, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use input <- result.try(semantic_input(request))
  use capture <- result.try(
    identity.decode_capture_value(value, input)
    |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_capture(capture, request))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(capture)
}

/// Encodes the exact immutable timing proposal with the original request body.
///
/// ## Examples
///
/// Timing adds bytes inside the fixed aggregate header reservation.
pub fn encode_invocation(
  invocation: identity.LspInvocation,
  request: Request,
) -> Result(BitArray, CodecError) {
  use Nil <- result.try(verify_write_reference(
    request,
    identity.invocation_capture(invocation),
  ))
  use Nil <- result.try(verify_parent_digest(invocation))
  use input <- result.try(semantic_input(request))
  use checked <- result.try(
    identity.decode_invocation_value(
      identity.invocation_value(invocation),
      input,
    )
    |> result.replace_error(DigestMismatch),
  )
  use Nil <- result.try(
    v.check(fn() { checked == invocation })
    |> result.replace_error(InvalidPayload),
  )
  encode(identity.invocation_value(invocation), msgpack_scan.lsp_header)
}

/// Decodes historical timed identity without producing a live timing claim.
///
/// ## Examples
///
/// An old clock era remains history until the custody service checks its era.
pub fn decode_invocation(
  bytes: BitArray,
  request: Request,
) -> Result(identity.LspInvocation, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use input <- result.try(semantic_input(request))
  use invocation <- result.try(
    identity.decode_invocation_value(value, input)
    |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_invocation(invocation, request))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(invocation)
}

/// Encodes a checked closed startup/search command parent.
///
/// ## Examples
///
/// A long legal search root still consumes the command's complete header cap.
pub fn encode_command(
  command: identity.LspCommandRef,
) -> Result(BitArray, CodecError) {
  use Nil <- result.try(case identity.command_parent(command) {
    identity.Startup(_) -> Ok(Nil)
    identity.Search(invocation, _, _) -> verify_parent_digest(invocation)
  })
  encode(identity.command_value(command), msgpack_scan.lsp_header)
}

/// Decodes search against the retained immutable inventory and manager selection.
///
/// ## Examples
///
/// Cold roots equal the enrolled workspace root; warm roots equal selected roots.
pub fn decode_command(
  bytes: BitArray,
  request: Request,
  inventory: identity.EnrolledProfiles,
  selected: Option(identity.SelectedProject),
) -> Result(identity.LspCommandRef, CodecError) {
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use input <- result.try(semantic_input(request))
  use command <- result.try(
    identity.decode_command_value(value, input, inventory, selected)
    |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_command(command))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(command)
}

/// Encodes the executor capture reply without exporting the local E0 tick.
///
/// ## Examples
///
/// The nonce and parent digest bind one unspent capture anchor.
pub fn encode_anchor(
  anchor: identity.FiniteAnchor,
) -> Result(BitArray, CodecError) {
  use bytes <- result.try(encode(
    identity.anchor_value(anchor),
    msgpack_scan.lsp_header,
  ))
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 128 })
    |> result.replace_error(LimitExceeded),
  )
  Ok(bytes)
}

/// Decodes the fixed bounded capture reply as data rather than effect permission.
///
/// ## Examples
///
/// A reply larger than 128 bytes refuses before MessagePack allocation.
pub fn decode_anchor(
  bytes: BitArray,
) -> Result(identity.FiniteAnchor, CodecError) {
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 128 })
    |> result.replace_error(PreflightRefused),
  )
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use anchor <- result.try(
    identity.decode_anchor_value(value) |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_anchor(anchor))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(anchor)
}

/// Encodes the preliminary capture and unchanged semantic request content.
///
/// ## Examples
///
/// The envelope has a four-byte header length, followed by header then body.
pub fn encode_capture_envelope(
  capture: identity.FiniteCapture,
  request: Request,
) -> Result(BitArray, CodecError) {
  use header <- result.try(encode_capture(capture, request))
  use body <- result.try(encode_request(request))
  envelope(header, body, max_invocation_bytes)
}

/// Splits bounded capture content before allocating either MessagePack value.
///
/// ## Examples
///
/// A declared 8193-byte header refuses before the semantic body is decoded.
pub fn decode_capture_envelope(
  bytes: BitArray,
) -> Result(#(identity.FiniteCapture, Request), CodecError) {
  use parts <- result.try(split_envelope(
    bytes,
    max_invocation_bytes,
    max_request_bytes,
  ))
  use request <- result.try(decode_request(parts.1))
  use capture <- result.try(decode_capture(parts.0, request))
  Ok(#(capture, request))
}

/// Encodes timed Submit without changing its retained semantic request.
///
/// ## Examples
///
/// Clock-era and nonce bytes stay in the original invocation header.
pub fn encode_invocation_envelope(
  invocation: identity.LspInvocation,
  request: Request,
) -> Result(BitArray, CodecError) {
  use header <- result.try(encode_invocation(invocation, request))
  use body <- result.try(encode_request(request))
  envelope(header, body, max_invocation_bytes)
}

/// Decodes timed content with complete request/body digest agreement.
///
/// ## Examples
///
/// A canonical replacement body with another digest cannot answer this header.
pub fn decode_invocation_envelope(
  bytes: BitArray,
) -> Result(#(identity.LspInvocation, Request), CodecError) {
  use parts <- result.try(split_envelope(
    bytes,
    max_invocation_bytes,
    max_request_bytes,
  ))
  use request <- result.try(decode_request(parts.1))
  use invocation <- result.try(decode_invocation(parts.0, request))
  Ok(#(invocation, request))
}

/// Encodes complete result content for the retained original timed invocation.
///
/// ## Examples
///
/// Observation's separately charged shell may exceed the four-MiB fact budget.
pub fn encode_result_envelope(
  invocation: identity.LspInvocation,
  expected: Request,
  completed: ResultValue,
) -> Result(BitArray, CodecError) {
  use header <- result.try(encode_invocation(invocation, expected))
  use body <- result.try(encode_result(expected, completed))
  envelope(header, body, max_result_envelope_bytes)
}

/// Requires exact retained timed header bytes before decoding a result body.
///
/// ## Examples
///
/// Changed timing under the original invocation address is an identity conflict.
pub fn decode_result_envelope(
  bytes: BitArray,
  retained: identity.LspInvocation,
  expected: Request,
) -> Result(ResultValue, CodecError) {
  use parts <- result.try(split_envelope(
    bytes,
    max_result_envelope_bytes,
    max_result_bytes,
  ))
  use header <- result.try(encode_invocation(retained, expected))
  use Nil <- result.try(same_bytes(parts.0, header))
  decode_result(expected, parts.1)
}

fn same_bytes(actual: BitArray, expected: BitArray) -> Result(Nil, CodecError) {
  v.check(fn() { actual == expected }) |> result.replace_error(InvalidPayload)
}

fn envelope(
  header: BitArray,
  body: BitArray,
  limit: Int,
) -> Result(BitArray, CodecError) {
  let header_size = bit_array.byte_size(header)
  let body_size = bit_array.byte_size(body)
  use Nil <- result.try(
    v.check(fn() {
      header_size > 0
      && header_size <= max_header_bytes
      && 4 + header_size + body_size <= limit
    })
    |> result.replace_error(PreflightRefused),
  )
  Ok(<<header_size:32-big, header:bits, body:bits>>)
}

fn split_envelope(
  bytes: BitArray,
  limit: Int,
  body_limit: Int,
) -> Result(#(BitArray, BitArray), CodecError) {
  use Nil <- result.try(
    v.check(fn() {
      bit_array.bit_size(bytes) % 8 == 0 && bit_array.byte_size(bytes) <= limit
    })
    |> result.replace_error(PreflightRefused),
  )
  case bytes {
    <<length:32-big-unsigned, rest:bits>> -> {
      use Nil <- result.try(
        v.check(fn() {
          length > 0
          && length <= max_header_bytes
          && bit_array.byte_size(rest) > length
          && bit_array.byte_size(rest) - length <= body_limit
        })
        |> result.replace_error(PreflightRefused),
      )
      case rest {
        <<header:size(length)-bytes, body:bits>> -> {
          // Both raw profiles pass before either MessagePack term is allocated.

          use Nil <- result.try(
            msgpack_scan.lsp_header(header)
            |> result.replace_error(PreflightRefused),
          )
          Ok(#(header, body))
        }
        _ -> Error(InvalidPayload)
      }
    }
    _ -> Error(InvalidPayload)
  }
}

/// Encodes the complete original control reference inside its own fixed bound.
///
/// ## Examples
///
/// AfterWrite retains both original write and admitted post-write child.
pub fn encode_parent(
  parent: identity.OriginalParentControlRef,
) -> Result(BitArray, CodecError) {
  use bytes <- result.try(encode(
    identity.parent_value(parent),
    msgpack_scan.lsp_header,
  ))
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 1024 })
    |> result.replace_error(LimitExceeded),
  )
  Ok(bytes)
}

/// Decodes a durable original control reference without live timing authority.
///
/// ## Examples
///
/// A 1025-byte reference refuses before MessagePack allocation.
pub fn decode_parent(
  bytes: BitArray,
) -> Result(identity.OriginalParentControlRef, CodecError) {
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 1024 })
    |> result.replace_error(PreflightRefused),
  )
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use parent <- result.try(
    identity.decode_parent_value(value) |> result.replace_error(InvalidPayload),
  )
  use canonical <- result.try(encode_parent(parent))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(parent)
}

/// Hashes the one canonical complete parent representation used by timing.
///
/// ## Examples
///
/// The input-body digest cannot substitute for the original control digest.
pub fn parent_digest(
  parent: identity.OriginalParentControlRef,
) -> Result(generation.Digest, CodecError) {
  use bytes <- result.try(encode_parent(parent))
  generation.digest(crypto.hash(crypto.Sha256, bytes))
  |> result.replace_error(InvalidPayload)
}

/// Encodes the exact unchanged five-field timing proposal.
///
/// ## Examples
///
/// Proposal bytes exclude every owner absolute tick and executor E0.
pub fn encode_timing(
  proposal: identity.FiniteTimingProposal,
) -> Result(BitArray, CodecError) {
  use bytes <- result.try(encode(
    identity.timing_value(proposal),
    msgpack_scan.lsp_header,
  ))
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 128 })
    |> result.replace_error(LimitExceeded),
  )
  Ok(bytes)
}

/// Decodes historical timing bound to the retained complete original parent.
///
/// ## Examples
///
/// A proposal naming another complete control digest is refused.
pub fn decode_timing(
  bytes: BitArray,
  parent: identity.OriginalParentControlRef,
) -> Result(identity.FiniteTimingProposal, CodecError) {
  use Nil <- result.try(
    v.check(fn() { bit_array.byte_size(bytes) <= 128 })
    |> result.replace_error(PreflightRefused),
  )
  use value <- result.try(decode(bytes, msgpack_scan.lsp_header))
  use proposal <- result.try(
    identity.decode_timing_value(value, parent)
    |> result.replace_error(InvalidPayload),
  )
  use actual_digest <- result.try(parent_digest(parent))
  use Nil <- result.try(check_timing_digest(proposal, actual_digest))
  use canonical <- result.try(encode_timing(proposal))
  use Nil <- result.try(same_bytes(bytes, canonical))
  Ok(proposal)
}

/// Hashes the exact canonical retained proposal for the custody admission row.
///
/// ## Examples
///
/// Changed remaining allowance changes this digest under the original address.
pub fn timing_digest(
  proposal: identity.FiniteTimingProposal,
) -> Result(generation.Digest, CodecError) {
  use bytes <- result.try(encode_timing(proposal))
  generation.digest(crypto.hash(crypto.Sha256, bytes))
  |> result.replace_error(InvalidPayload)
}

fn verify_parent_digest(
  invocation: identity.LspInvocation,
) -> Result(Nil, CodecError) {
  let capture = identity.invocation_capture(invocation)
  use actual_digest <- result.try(
    parent_digest(identity.capture_parent(capture)),
  )
  check_timing_digest(identity.invocation_proposal(invocation), actual_digest)
}

fn check_timing_digest(
  proposal: identity.FiniteTimingProposal,
  actual: generation.Digest,
) -> Result(Nil, CodecError) {
  case identity.timing_value(proposal) {
    m.ArrayValue([_, _, _, _, m.BinaryValue(digest)]) ->
      v.check(fn() { digest == generation.digest_bytes(actual) })
      |> result.replace_error(DigestMismatch)
    _ -> Error(InvalidPayload)
  }
}

fn verify_write_reference(
  request: Request,
  capture: identity.FiniteCapture,
) -> Result(Nil, CodecError) {
  case request {
    AfterWrite(_, original_write) -> {
      case identity.parent_value(identity.capture_parent(capture)) {
        m.ArrayValue([m.IntValue(1), retained_write, _]) ->
          v.check(fn() {
            retained_write == identity.original_child_value(original_write)
          })
          |> result.replace_error(ResponseMismatch)
        _ -> Error(InvalidPayload)
      }
    }
    _ -> Ok(Nil)
  }
}
