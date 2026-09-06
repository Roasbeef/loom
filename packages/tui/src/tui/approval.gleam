//// Approval controls echo one captured action, requested grant set and CAS seq.
////
//// Storage grant JSON and conversation grant JSON are distinct frozen shapes.
//// This pure translator keeps the TUI independent of broker/runtime packages.
//// A missing action or unsupported grant prevents approval, while rejection
//// remains available against the captured sequence. Disappearance alone never
//// identifies the human who resolved a request.

import core/json
import core/message
import core/origin
import core/register
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import tui/session_wire
import tui/snapshot_view

/// Durable decision state, independent of a temporary absence from pending rows.
pub type Status {
  /// No decision has committed at this register sequence.
  Pending

  /// One human granted the exact captured authority.
  Approved

  /// One human refused the request.
  Rejected

  /// The granted authority has already been consumed by its operation.
  Consumed
}

/// What this captured record can authorize the approval UI to echo.
pub type Permission {
  /// Both values came from the same captured pending register.
  Exact(
    /// Digest binding the authority to the requested action.
    action: String,
    /// Requested grants translated to the conversation wire vocabulary.
    grants: List(json.JsonValue),
  )

  /// The terminal cannot safely encode approval; denial remains independent.
  Unavailable(
    /// The missing or unsupported captured information.
    reason: String,
  )
}

/// A displayed request and the exact sequence used by approve/deny.
pub type Review {
  Review(
    /// Exact durable escalation identity, without its namespace prefix.
    id: String,
    /// Captured register sequence used by both decision CAS commands.
    seq: Int,
    /// Durable pending, resolved or consumed status.
    status: Status,
    /// Requested tool name, empty when absent in the captured row.
    tool: String,
    /// Human-readable action preview, never executed or interpreted as markup.
    preview: String,
    /// Author stored by the winning decision, not inferred from disappearance.
    origin: Option(message.Origin),
    /// Exact captured authority or the reason approval cannot be encoded.
    permission: Permission,
  )
}

/// Decodes only escalation cells from a completed metadata cut.
///
/// ## Examples
///
/// ```gleam
/// // approval.records(view.cells)
/// ```
pub fn records(
  cells: List(snapshot_view.Cell),
) -> Result(List(Review), String) {
  cells
  |> list.filter(fn(cell) {
    cell.namespace == register.FactCustom
    && string.starts_with(cell.key, "escalation/")
  })
  |> list.try_map(decode)
}

/// Keeps the current pending cut and sixteen bounded resolved summaries.
///
/// ## Examples
///
/// ```gleam
/// // approval.project(previous, current_pending)
/// ```
pub fn project(previous: List(Review), current: List(Review)) -> List(Review) {
  let resolved =
    previous
    |> list.filter(fn(record) {
      record.status != Pending
      && !list.any(current, fn(new) { new.id == record.id })
    })
    |> list.take(16)
  list.append(current, resolved)
}

/// Applies exact decisions without allowing an older response to replace a newer seq.
///
/// Resolved records retain no grant payload and only a short presentation.
///
/// ## Examples
///
/// ```gleam
/// // approval.decisions(previous, looked_up, missing)
/// ```
pub fn decisions(
  previous: List(Review),
  current: List(Review),
  missing: List(String),
) -> List(Review) {
  let previous =
    list.filter(previous, fn(record) { !list.contains(missing, record.id) })
  let merged =
    list.fold(current, previous, fn(kept, record) {
      case
        list.any(kept, fn(old) { old.id == record.id && old.seq > record.seq })
      {
        True -> kept
        False -> [
          summary(record),
          ..list.filter(kept, fn(old) { old.id != record.id })
        ]
      }
    })
  list.append(
    list.filter(merged, fn(record) { record.status == Pending }),
    merged
      |> list.filter(fn(record) { record.status != Pending })
      |> list.take(16),
  )
}

fn summary(record: Review) {
  case record.status {
    Pending -> record
    Approved | Rejected | Consumed ->
      Review(
        ..record,
        tool: string.slice(record.tool, 0, 128),
        preview: string.slice(record.preview, 0, 512),
        permission: Unavailable("this decision is already resolved"),
      )
  }
}

/// Validates record identity against its exact durable register key.
///
/// ## Examples
///
/// ```gleam
/// // approval.decode(cell)
/// ```
pub fn decode(cell: snapshot_view.Cell) -> Result(Review, String) {
  use fields <- result.try(object(cell.value))
  use id <- result.try(text(fields, "id"))
  use <- bool.guard(
    cell.namespace != register.FactCustom
      || cell.key != "escalation/" <> id
      || id == ""
      || string.byte_size(id) > 256,
    Error("invalid captured escalation identity"),
  )
  use state <- result.try(text(fields, "status"))
  use state <- result.try(case state {
    "pending" -> Ok(Pending)
    "approved" -> Ok(Approved)
    "rejected" -> Ok(Rejected)
    "consumed" -> Ok(Consumed)
    _ -> Error("invalid captured escalation status")
  })
  use tool <- result.try(optional_text(fields, "tool"))
  use preview <- result.try(optional_text(fields, "preview"))
  use author <- result.try(
    origin.decode_field(fields)
    |> result.replace_error("invalid escalation decision origin"),
  )
  let permission = case exact(fields) {
    Ok(permission) -> permission
    Error(reason) -> Unavailable(reason)
  }
  Ok(Review(id, cell.seq, state, tool, preview, author, permission))
}

fn exact(fields) {
  use action <- result.try(text(fields, "action"))
  use <- bool.guard(
    action == "",
    Error("approval has no captured action digest"),
  )
  use denial <- result.try(field(fields, "denial") |> result.try(object))
  use wanted <- result.try(field(denial, "wanted"))
  use grants <- result.try(case wanted {
    json.Array(grants) -> list.try_map(grants, wire_grant)
    _ -> Error("approval has no captured requested grant set")
  })
  Ok(Exact(action, grants))
}

/// Encodes an approval from the displayed record, never from caller-supplied grants.
///
/// ## Examples
///
/// ```gleam
/// // approval.approve(4, displayed)
/// ```
pub fn approve(id: Int, record: Review) -> Result(String, String) {
  use _ <- result.try(details(record))
  case record.status, record.permission {
    Pending, Exact(action, grants) ->
      Ok(
        session_wire.command(id, "approve", [
          #("escalation_id", json.String(record.id)),
          #("expected_seq", json.Int(record.seq)),
          #("action", json.String(action)),
          #("grants", json.Array(grants)),
        ]),
      )
    Pending, Unavailable(reason) -> Error(reason)
    Approved, _ | Rejected, _ | Consumed, _ ->
      Error("approval is no longer pending")
  }
}

/// Maximum exact approval detail that this terminal can present for consent.
/// This is a presentation limit, independent of the larger wire/frame bounds.
pub const detail_limit = 16_384

/// Returns exact ASCII-escaped literal detail, never interpreted as markdown.
///
/// Controls, bidi characters and non-ASCII paths remain visible JSON escapes.
/// A detail beyond the display bound is rejected rather than partially shown
/// while leaving approval enabled. Denial remains available on the same seq.
///
/// ## Examples
///
/// ```gleam
/// // approval.details(captured_request)
/// ```
pub fn details(record: Review) -> Result(String, String) {
  use #(action, grants) <- result.try(case record.permission {
    Exact(action, grants) -> Ok(#(action, grants))
    Unavailable(reason) -> Error(reason)
  })
  let encoded =
    json.to_string(
      json.Object([
        #("id", json.String(record.id)),
        #("seq", json.Int(record.seq)),
        #("tool", json.String(record.tool)),
        #("preview", json.String(record.preview)),
        #("action", json.String(action)),
        #("grants", json.Array(grants)),
      ]),
    )
  use <- bool.guard(
    string.byte_size(encoded) > detail_limit,
    Error(
      "Incomplete detail: exact approval exceeds the 16KiB display bound; approve is disabled, deny remains available",
    ),
  )
  let literal =
    encoded
    |> string.to_utf_codepoints
    |> list.map(fn(point) {
      let code = string.utf_codepoint_to_int(point)
      case code {
        code if code < 0x7F -> string.from_utf_codepoints([point])
        code if code <= 0xFFFF -> escaped_unit(code)
        code -> {
          let adjusted = code - 0x10000
          escaped_unit(0xD800 + adjusted / 1024)
          <> escaped_unit(0xDC00 + adjusted % 1024)
        }
      }
    })
    |> string.concat
  use <- bool.guard(
    string.byte_size(literal) > detail_limit,
    Error(
      "Incomplete detail: escaped approval exceeds the 16KiB display bound; approve is disabled, deny remains available",
    ),
  )
  Ok(literal)
}

fn escaped_unit(code) {
  let hex = code |> int.to_base16 |> string.lowercase
  "\\u" <> string.repeat("0", 4 - string.length(hex)) <> hex
}

/// Encodes a rejection against the same captured record sequence.
///
/// ## Examples
///
/// ```gleam
/// // approval.deny(4, displayed)
/// ```
pub fn deny(id: Int, record: Review) -> Result(String, String) {
  case record.status {
    Pending ->
      Ok(
        session_wire.command(id, "deny", [
          #("escalation_id", json.String(record.id)),
          #("expected_seq", json.Int(record.seq)),
        ]),
      )
    Approved | Rejected | Consumed -> Error("approval is no longer pending")
  }
}

/// Translates the captured storage vocabulary without altering grant meaning.
///
/// ## Examples
///
/// ```gleam
/// // approval.wire_grant(stored_grant)
/// ```
pub fn wire_grant(value: json.JsonValue) -> Result(json.JsonValue, String) {
  use fields <- result.try(object(value))
  use kind <- result.try(text(fields, "grant"))
  use body <- result.try(case kind {
    "writable_root" | "readable_root" -> {
      use path <- result.try(text(fields, "path"))
      Ok([#("path", json.String(path))])
    }
    "env" -> {
      use name <- result.try(text(fields, "name"))
      Ok([#("name", json.String(name))])
    }
    "network" -> {
      use network <- result.try(field(fields, "network"))
      use _ <- result.try(object(network))
      Ok([#("network", network)])
    }
    "limit" -> limit(fields)
    "scratch" -> scratch(fields)
    _ -> Error("unsupported requested grant kind")
  })
  Ok(json.Object([#("type", json.String(kind)), ..body]))
}

fn limit(fields) {
  use name <- result.try(text(fields, "field"))
  use name <- result.try(case name {
    "cpu_s" -> Ok("cpu_seconds")
    "wall_s" -> Ok("wall_seconds")
    "mem_bytes" | "pids" | "fsize_bytes" | "output_bytes" -> Ok(name)
    _ -> Error("unsupported requested resource limit")
  })
  use value <- result.try(field(fields, "value"))
  case value {
    json.Int(n) if n >= 0 ->
      Ok([#("field", json.String(name)), #("value", value)])
    _ -> Error("invalid requested resource limit")
  }
}

fn scratch(fields) {
  use path <- result.try(text(fields, "scratch"))
  let scratch = case path {
    "tmpfs" -> json.Object([#("mode", json.String(path))])
    path ->
      json.Object([#("mode", json.String("path")), #("path", json.String(path))])
  }
  Ok([#("scratch", scratch)])
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected escalation object")
  }
}

fn field(fields, key) {
  list.key_find(fields, key) |> result.replace_error("missing escalation field")
}

fn text(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.String(text) -> Ok(text)
    _ -> Error("expected escalation string")
  }
}

fn optional_text(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.Null -> Ok("")
    json.String(text) -> Ok(text)
    _ -> Error("expected optional escalation string")
  }
}
