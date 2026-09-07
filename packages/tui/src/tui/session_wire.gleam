//// The live conversation transport accepts one correlated v2 response, plus
//// whatever the daemon volunteers.
////
//// Correlation is what splits the two. A frame carrying `reply_to` is the
//// answer to the terminal's one outstanding request and is held to the exact
//// identity it names. A frame carrying none was pushed: the daemon decided to
//// send it, so there is no identity to check and the frame is decoded through
//// the same total event vocabulary a recorded frame uses.
////
//// Recorded legacy frames still have their separate presentation decoder in
//// tui/protocol. Live sockets do not use that decoder as a version fallback:
//// this boundary validates v2, reply identity and frame size first.

import core/json
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import tui/protocol

/// One credited transfer response, bounded auxiliary command result, or
/// uncorrelated frame the daemon pushed on its own initiative.
pub type Reply {
  /// Validated further against the selected attachment by tui/snapshot.
  Begin(body: json.JsonValue)

  /// One independently base64-encoded raw fragment.
  Chunk(body: json.JsonValue)

  /// Completes a coherent cut; partial transfer data is not yet visible.
  End(body: json.JsonValue)

  /// The server acknowledged mutation admission or durable completion.
  Mutation(status: String)

  /// A bounded models/schedules reply or explicit refusal.
  Presentation(event: protocol.Event)

  /// A frame with no `reply_to`: the daemon volunteered it, so it belongs to
  /// no request and consumes no credit.
  Pushed(event: protocol.Event)
}

/// The exact opening bytes `command` produces, up to the request identity.
///
/// `tui/session_channel` re-allocates a request identity by splitting an
/// already-encoded frame rather than reparsing a body that may hold a
/// multi-megabyte image. That makes this module's field order and spelling
/// load-bearing at run time, so the three literals it depends on are named
/// here, beside the encoder that emits them, instead of being repeated as
/// string literals at the other end.
pub const command_prefix = "{\"v\":2,\"id\":"

/// The separator between the request identity and the command name.
pub const command_tag = ",\"cmd\":"

/// The separator between the command name and its body object.
pub const command_body = ",\"body\":"

/// Builds one version-two command; callers allocate monotonically increasing IDs.
///
/// ## Examples
///
/// ```gleam
/// // session_wire.command(1, "models", [])
/// ```
pub fn command(
  id: Int,
  name: String,
  fields: List(#(String, json.JsonValue)),
) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("id", json.Int(id)),
      #("cmd", json.String(name)),
      #("body", json.Object(fields)),
    ]),
  )
}

/// Grants exactly one next response for the selected snapshot cursor.
///
/// ## Examples
///
/// ```gleam
/// // session_wire.next(2, "transfer", 0)
/// ```
pub fn next(id: Int, transfer: String, index: Int) -> String {
  command(id, "snapshot_next", [
    #("snapshot_id", json.String(transfer)),
    #("index", json.Int(index)),
  ])
}

/// Reconciles durable entries and metadata, including unchanged durable cursors.
///
/// ## Examples
///
/// ```gleam
/// // session_wire.catch_up(3, 123)
/// ```
pub fn catch_up(id: Int, from_seq: Int) -> String {
  command(id, "catch_up", [#("from_seq", json.Int(from_seq))])
}

/// Totally decodes one bounded live frame: a response for the exact
/// outstanding request, or an uncorrelated push.
///
/// ## Examples
///
/// ```gleam
/// // session_wire.decode(text, expected_reply_id)
/// ```
pub fn decode(text: String, expected: Int) -> Result(Reply, String) {
  use <- bool.guard(
    string.byte_size(text) > 65_536,
    Error("conversation response exceeds bound"),
  )
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid conversation JSON"),
  )
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_)
    | json.Bool(_)
    | json.Null -> Error("conversation response is not an object")
  })
  use version <- result.try(field(fields, "v"))
  use <- bool.guard(
    version != json.Int(2),
    Error("conversation version or reply identity does not match"),
  )

  // The absent field, not a matching one, is what marks a push. A frame that
  // names a request identity is held to the outstanding one exactly as it was
  // before pushes existed, so a stale or forged correlation still fails
  // closed.
  case list.key_find(fields, "reply_to") {
    Error(Nil) -> protocol.decode_v2_pushed(text) |> result.map(Pushed)
    Ok(json.Int(id)) if id == expected -> correlated(fields, text)
    Ok(_) -> Error("conversation version or reply identity does not match")
  }
}

fn correlated(fields, text) {
  use name <- result.try(field(fields, "event"))
  use body <- result.try(field(fields, "body"))
  case name {
    json.String("snapshot_begin") -> Ok(Begin(body))
    json.String("snapshot_chunk") -> Ok(Chunk(body))
    json.String("snapshot_end") -> Ok(End(body))
    json.String("mutation_outcome") -> mutation(body)
    json.String("snapshot") | json.String("error") ->
      protocol.decode_v2_presentation(text) |> result.map(Presentation)
    json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Object(_)
    | json.Array(_)
    | json.Bool(_)
    | json.Null -> Error("unexpected conversation response")
  }
}

fn mutation(body) {
  case body {
    json.Object(fields) -> {
      use status <- result.try(field(fields, "status"))
      case status {
        json.String("admitted") -> Ok(Mutation("admitted"))
        json.String("committed") -> Ok(Mutation("committed"))

        // The daemon holds a prompt aimed at a busy strand and runs it on the
        // strand's next turn. That is an accepted submission, not the refusal
        // a conflict used to be.
        json.String("queued") -> Ok(Mutation("queued"))
        _ -> Error("invalid mutation outcome")
      }
    }
    _ -> Error("invalid mutation outcome")
  }
}

fn field(fields, key) {
  list.key_find(fields, key)
  |> result.replace_error("missing conversation field")
}
