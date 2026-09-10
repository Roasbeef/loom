//// The local recording identity is independent of every server identifier.
////
//// Two connections may both issue request one. These events preserve which
//// terminal attempt sent that request and when its validated cut was adopted.
//// Selectors are bounded protocol metadata; credentials and command bodies do
//// not belong in this format.

import core/json
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/connection
import tui/snapshot

/// An increasing terminal-local identity, never a server-issued identifier.
pub type Id {
  Id(
    /// Positive local sequence, allocated before explicit selection begins.
    value: Int,
  )
}

/// The nonsecret selector needed to validate the corresponding response.
pub type Selection {
  /// Ordinary commands expose no body in a recording.
  NoSelection

  /// One stop-and-wait snapshot credit.
  Credit(
    /// The transfer identity returned by its matching begin response.
    snapshot_id: String,
    /// The exact next fragment index, starting at zero.
    index: Int,
  )

  /// The completed conversation cursor from which reconciliation begins.
  Cursor(
    /// The next durable sequence from the last completed conversation cut.
    from_seq: Int,
  )

  /// At most eight exact escalation keys, not their actions or grants.
  Decisions(
    /// Distinct exact keys whose resolution may update the approval view.
    ids: List(String),
  )
}

/// One issued command without its potentially sensitive body.
pub type Request {
  Request(
    /// Monotonically increasing request identity within one connection.
    id: Int,
    /// Closed command vocabulary decoded by the recording boundary.
    kind: String,
    /// Only the bounded nonsecret selector needed to validate this response.
    selection: Selection,
  )
}

/// A closed set of local facts; only Adopted changes the visible attachment.
pub type Event {
  /// The socket has an authenticated target but remains provisional.
  Started(
    /// The terminal's replacement attempt, not a socket-local request ID.
    attempt: Id,
    /// The authenticated session, daemon epoch and runtime incarnation.
    expected: snapshot.Expected,
  )

  /// A request was issued on this attempt before any matching response.
  Issued(
    /// The attempt whose socket received the write.
    attempt: Id,
    /// The command identity and bounded nonsecret response selector.
    request: Request,
  )

  /// Original socket bytes or a transport lifecycle fact.
  Received(
    /// The originating attempt, retained even after another is adopted.
    attempt: Id,
    /// The unmodified frame or typed transport notification.
    message: connection.Message,
  )

  /// The terminal committed a complete, validated initial cut.
  Adopted(
    /// The validated candidate the terminal has actually made visible.
    attempt: Id,
  )

  /// The terminal abandoned or closed this attempt and releases its state.
  Closed(
    /// The attempt whose retained replay buffer may now be released.
    attempt: Id,
  )

  /// A rejected replacement preserves the current view and its local diagnosis.
  Failed(
    /// The failed selection, which may precede socket preparation.
    attempt: Id,
    /// The local diagnostic, without credentials or request bodies.
    reason: String,
  )
}

/// An optional recorder callback, invoked only by the terminal itself.
pub type Trace {
  Trace(
    /// Terminal-local attempt identity, never a credential or socket address.
    id: Id,
    /// Appends synchronously before the terminal processes the next event.
    note: fn(Event) -> Nil,
  )
}

/// Writes a local event if recording is enabled.
///
/// ## Examples
///
/// ```gleam
/// attempt.note(None, attempt.Closed(attempt.Id(1)))
/// ```
pub fn note(trace: Option(Trace), event: Event) -> Nil {
  case trace {
    Some(trace) -> trace.note(event)
    None -> Nil
  }
}

/// Encodes a format-two attempt event as the fields of one recorded line.
///
/// The fields are returned rather than an object because the recorder splices
/// them into its own line, and a `JsonValue` it had to re-match would give it
/// an unreachable arm that silently wrote a line with no `t` discriminator.
///
/// ## Examples
///
/// ```gleam
/// let fields = attempt.encode(attempt.Closed(attempt.Id(1)))
/// ```
pub fn encode(event: Event) -> List(#(String, json.JsonValue)) {
  let #(Id(id), tag, fields) = case event {
    Started(id, expected) -> #(id, "attempt_started", [
      #("session", json.String(expected.session)),
      #("epoch", json.String(expected.epoch)),
      #("incarnation", json.String(expected.incarnation)),
    ])
    Issued(id, Request(request, kind, selection)) -> #(id, "attempt_requested", [
      #("id", json.Int(request)),
      #("kind", json.String(kind)),
      ..encode_selection(selection)
    ])
    Received(id, connection.Incoming(text)) -> #(id, "attempt_frame", [
      #("text", json.String(text)),
    ])
    Received(id, connection.Connected) -> #(id, "attempt_connected", [])
    Received(id, connection.Closed(reason)) -> #(id, "attempt_disconnected", [
      #("reason", json.String(reason)),
    ])
    Received(id, connection.NetworkFault(reason)) -> #(id, "attempt_fault", [
      #("reason", json.String(reason)),
    ])
    Adopted(id) -> #(id, "attempt_adopted", [])
    Closed(id) -> #(id, "attempt_closed", [])
    Failed(id, reason) -> #(id, "attempt_failed", [
      #("reason", json.String(reason)),
    ])
  }
  [#("t", json.String(tag)), #("attempt", json.Int(id)), ..fields]
}

fn encode_selection(selection) {
  case selection {
    NoSelection -> []
    Credit(id, index) -> [
      #("snapshot_id", json.String(id)),
      #("index", json.Int(index)),
    ]
    Cursor(seq) -> [#("from_seq", json.Int(seq))]
    Decisions(ids) -> [#("ids", json.Array(list.map(ids, json.String)))]
  }
}

/// Totally decodes the bounded identities and selectors in one local event.
///
/// ## Examples
///
/// ```gleam
/// assert attempt.decode(json.Object(attempt.encode(attempt.Closed(
///   attempt.Id(1),
/// ))))
///   == Ok(attempt.Closed(attempt.Id(1)))
/// ```
pub fn decode(value: json.JsonValue) -> Result(Event, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("attempt event must be an object")
  })
  use id <- result.try(integer(fields, "attempt"))
  use <- bool.guard(id < 1, Error("attempt identity must be positive"))
  use tag <- result.try(text(fields, "t"))
  decode_tag(tag, Id(id), fields)
}

fn decode_tag(tag, id, fields) {
  case tag {
    "attempt_started" -> {
      use session <- result.try(identity(fields, "session"))
      use epoch <- result.try(identity(fields, "epoch"))
      use incarnation <- result.map(identity(fields, "incarnation"))
      Started(id, snapshot.Expected(session, epoch, incarnation))
    }
    "attempt_requested" -> {
      use request <- result.try(integer(fields, "id"))
      use <- bool.guard(request < 1, Error("request identity must be positive"))
      use kind <- result.try(identity(fields, "kind"))
      use selection <- result.map(decode_selection(kind, fields))
      Issued(id, Request(request, kind, selection))
    }
    "attempt_frame" -> {
      use bytes <- result.try(text(fields, "text"))
      use <- bool.guard(
        string.byte_size(bytes) > 65_536,
        Error("recorded frame exceeds the live ingress bound"),
      )
      Ok(Received(id, connection.Incoming(bytes)))
    }
    "attempt_connected" -> Ok(Received(id, connection.Connected))
    "attempt_disconnected" ->
      result.map(text(fields, "reason"), fn(reason) {
        Received(id, connection.Closed(reason))
      })
    "attempt_fault" ->
      result.map(text(fields, "reason"), fn(reason) {
        Received(id, connection.NetworkFault(reason))
      })
    "attempt_adopted" -> Ok(Adopted(id))
    "attempt_closed" -> Ok(Closed(id))
    "attempt_failed" ->
      result.map(text(fields, "reason"), fn(reason) { Failed(id, reason) })
    _ -> Error("unknown attempt event")
  }
}

fn decode_selection(kind, fields) {
  case kind {
    "snapshot_next" -> {
      use id <- result.try(identity(fields, "snapshot_id"))
      use index <- result.try(integer(fields, "index"))
      use <- bool.guard(index < 0, Error("negative snapshot credit"))
      Ok(Credit(id, index))
    }
    "catch_up" -> {
      use seq <- result.try(integer(fields, "from_seq"))
      use <- bool.guard(seq < 0, Error("negative catch-up cursor"))
      Ok(Cursor(seq))
    }
    "escalations_get" -> {
      use values <- result.try(case list.key_find(fields, "ids") {
        Ok(json.Array(values)) -> Ok(values)
        Ok(_) | Error(Nil) -> Error("missing exact decision selectors")
      })
      use <- bool.guard(
        values == [] || list.drop(values, 8) != [],
        Error("decision selector count exceeds bound"),
      )
      use ids <- result.try(
        list.try_map(values, fn(value) { identity([#("id", value)], "id") }),
      )
      use <- bool.guard(
        list.unique(ids) != ids,
        Error("duplicate decision selector"),
      )
      Ok(Decisions(ids))
    }
    "subscribe"
    | "models"
    | "notes"
    | "queued_input"
    | "edit_queued_input"
    | "worktree_diff"
    | "live_jobs"
    | "schedules"
    | "schedule_cancel"
    | "prompt"
    | "prompt_content"
    | "steer"
    | "follow_up"
    | "abort"
    | "fork"
    | "set_config"
    | "navigate"
    | "compact"
    | "create_strand"
    | "approve"
    | "deny" -> Ok(NoSelection)
    _ -> Error("unknown recorded command kind")
  }
}

fn identity(fields, name) {
  use value <- result.try(text(fields, name))
  use <- bool.guard(
    value == "" || string.byte_size(value) > 256,
    Error("invalid recorded identity"),
  )
  Ok(value)
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error("missing recorded " <> name)
  }
}

fn integer(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error("missing recorded " <> name)
  }
}
