//// Operator evolution commands reuse the private daemon owner connection.
//// Discovery never starts a daemon or opens a saved session. Registration and
//// attachment must name the same resident incarnation before typed commands
//// enter its existing gateway. JSON arguments carry no connection authority.

import client/daemon/admin
import client/daemon/protocol as daemon_protocol
import client/evolution/record
import client/internal/ffi_os
import client/protocol
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/access
import host/websocket
import simplifile
import weft

/// A bounded command before native endpoint discovery.
@internal
pub opaque type Command {
  Command(
    /// The private daemon discovery root, never a JSON argument.
    directory: String,
    /// The exact resident session selected by the operator.
    session: String,
    /// One admitted native control action.
    action: String,
    /// Bounded data interpreted under authenticated connection authority.
    arguments: json.JsonValue,
  )
}

/// Failure categories distinguish refusal from an unacknowledged mutation.
@internal
pub type Failure {
  /// Validation stopped before sending a request.
  Invalid(reason: String)

  /// Discovery or attachment failed before the evolution command was sent.
  NotSent(reason: String)

  /// The authenticated gateway explicitly refused the command.
  Refused(reason: String)

  /// A sent request has no confirmed reply and requires exact receipt lookup.
  UnknownOutcome(reason: String)
}

/// The complete discoverable operator surface.
pub const usage =
  "usage: loomd evolution [--state-dir PATH] ACTION SESSION [--args FILE]\n       [--candidate-id ID] [--evidence-id ID] [--request-id ID]\n\nActions: catalogue, inspect, evidence, status, approve, revoke, select, rollback, admit_tasks, mark_outcome, core_status, core_upgrade, core_downgrade.\n\nArguments are a JSON object of at most 48 KiB. SESSION must already be resident. Authentication uses the private daemon owner credential; arguments cannot supply an authority or principal. Mutations require the fields advertised by their native control, including the expected selection and an exact request_id for select/rollback.\n\nOutput is one JSON value. Exit 0 means the response was acknowledged; status=queued means accepted, not completed. Use status with the exact request_id to recover a missing selection acknowledgement; use core_status for core_upgrade/core_downgrade receipts. Exit 2 means invalid arguments, 3 means not sent or refused, and 4 means unknown outcome.\n\nExamples:\n  loomd evolution catalogue SESSION\n  loomd evolution inspect SESSION --candidate-id SHA256\n  loomd evolution evidence SESSION --evidence-id SHA256\n  loomd evolution approve SESSION --args approval.json\n  loomd evolution select SESSION --args selection.json\n  loomd evolution status SESSION --request-id publish-1\n  loomd evolution core_status SESSION\n  loomd evolution core_upgrade SESSION --args upgrade.json\n  loomd evolution core_status SESSION --request-id scratch-upgrade-1"

/// Runs one authenticated operation and prints its original JSON result.
///
/// ## Examples
///
/// `main(["catalogue",session_id])` reads the resident session without opening it.
pub fn main(arguments: List(String)) -> Nil {
  let outcome = {
    use command <- result.try(parse(arguments))
    run(command)
  }
  case outcome {
    Ok(value) -> io.println(json.to_string(value))
    Error(failure) -> {
      io.println(json.to_string(failure_json(failure)))
      ffi_os.halt(exit_code(failure))
    }
  }
}

/// Parses explicit JSON arguments without discovering credentials or endpoints.
///
/// ## Examples
///
/// `parse(["status",session_id,"--request-id","publish-1"])` retains its exact ID.
@internal
pub fn parse(arguments: List(String)) -> Result(Command, Failure) {
  let #(directory, rest) = case arguments {
    ["--state-dir", directory, ..rest] -> #(directory, rest)
    rest -> #("", rest)
  }
  use #(action, session, options) <- result.try(case rest {
    [action, session, ..options] -> Ok(#(action, session, options))
    _ -> Error(Invalid(usage))
  })
  use Nil <- result.try(
    case
      list.contains(
        [
          "catalogue", "inspect", "evidence", "status", "approve", "revoke",
          "select", "rollback", "admit_tasks", "mark_outcome", "core_status",
          "core_upgrade", "core_downgrade",
        ],
        action,
      )
    {
      True -> Ok(Nil)
      False -> Error(Invalid("unknown evolution action"))
    },
  )
  use _ <- result.try(
    ids.parse_session_id(session)
    |> result.replace_error(Invalid(
      "SESSION must be a canonical session identity",
    )),
  )
  use fields <- result.try(parse_options(options, []))
  use arguments <- result.try(admit_arguments(json.Object(fields)))
  use _ <- result.try(
    protocol.decode_command(
      protocol.encode_command(protocol.CommandEnvelope(
        2,
        protocol.Evolution(action, arguments),
      )),
    )
    |> result.replace_error(Invalid("invalid or oversized evolution command")),
  )
  Ok(Command(directory, session, action, arguments))
}

fn parse_options(
  arguments: List(String),
  fields: List(#(String, json.JsonValue)),
) -> Result(List(#(String, json.JsonValue)), Failure) {
  case arguments {
    [] -> Ok(fields)
    ["--args", path, ..rest] -> {
      use info <- result.try(
        simplifile.file_info(path)
        |> result.map_error(fn(error) {
          Invalid(simplifile.describe_error(error))
        }),
      )
      use Nil <- result.try(case info.size <= 49_152 {
        True -> Ok(Nil)
        False -> Error(Invalid("argument file exceeds 48 KiB"))
      })
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(error) {
          Invalid(simplifile.describe_error(error))
        }),
      )
      use value <- result.try(
        json.parse(text)
        |> result.replace_error(Invalid("argument file is not JSON")),
      )
      use value <- result.try(admit_arguments(value))
      use added <- result.try(case value {
        json.Object(added) -> Ok(added)
        _ -> Error(Invalid("argument file must be an object"))
      })
      parse_options(rest, list.append(fields, added))
    }
    [flag, value, ..rest] -> {
      use key <- result.try(case flag {
        "--candidate-id" -> Ok("candidate_id")
        "--evidence-id" -> Ok("evidence_id")
        "--request-id" -> Ok("request_id")
        _ -> Error(Invalid("unknown option: " <> flag))
      })
      parse_options(rest, [#(key, json.String(value)), ..fields])
    }
    [_] -> Error(Invalid("an option is missing its value"))
  }
}

/// Admits bounded argument objects while keeping native authority out of JSON.
///
/// ## Examples
///
/// `admit_arguments(json.Object([]))` admits a read-only catalogue request.
@internal
pub fn admit_arguments(
  value: json.JsonValue,
) -> Result(json.JsonValue, Failure) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(Invalid("evolution arguments must be an object"))
  })
  let names = list.map(fields, fn(field) { field.0 })
  use Nil <- result.try(
    case
      list.length(names) == list.length(list.unique(names))
      && list.length(names) <= 32
      && string.byte_size(json.to_string(value)) <= 49_152
    {
      True -> Ok(Nil)
      False -> Error(Invalid("duplicate or oversized evolution arguments"))
    },
  )
  use Nil <- result.try(list.try_each(fields, admit_identity))
  case
    list.any(names, fn(name) {
      list.contains(
        [
          "authority", "principal", "approved_by", "session_id", "epoch",
          "connection_id",
        ],
        name,
      )
    })
  {
    True ->
      Error(Invalid(
        "authority and connection identity cannot be supplied in JSON",
      ))
    False -> Ok(value)
  }
}

fn admit_identity(field: #(String, json.JsonValue)) -> Result(Nil, Failure) {
  case field {
    #("candidate_id", json.String(id)) ->
      record.candidate_id(id)
      |> result.replace(Nil)
      |> result.replace_error(Invalid("invalid candidate_id"))
    #("evidence_id", json.String(id)) ->
      record.evidence_id(id)
      |> result.replace(Nil)
      |> result.replace_error(Invalid("invalid evidence_id"))
    #("request_id", json.String(id)) ->
      case string.byte_size(id) > 0 && string.byte_size(id) <= 256 {
        True -> Ok(Nil)
        False -> Error(Invalid("request_id must contain 1 to 256 bytes"))
      }
    #("candidate_id", _) | #("evidence_id", _) | #("request_id", _) ->
      Error(Invalid("invalid identity field type"))
    _ -> Ok(Nil)
  }
}

/// Executes under one weft deadline over the existing monitored socket owner.
///
/// ## Examples
///
/// `run(command)` prints neither credentials nor inferred completion.
@internal
pub fn run(command: Command) -> Result(json.JsonValue, Failure) {
  case
    weft.new([fn() { exchange(command) }])
    |> weft.deadline(30_000)
    |> weft.start
  {
    [weft.Completed(_, value)] -> Ok(value)
    [weft.Failed(_, error)] -> Error(error)
    _ ->
      Error(UnknownOutcome(
        "control deadline or connection ended; query the exact request_id before retrying",
      ))
  }
}

fn exchange(command: Command) -> Result(json.JsonValue, Failure) {
  use #(address, token, epoch) <- result.try(
    admin.peer_discover(command.directory) |> result.map_error(NotSent),
  )
  let request =
    access.raw_request(command.directory, "sessions.get", command.session, [
      #("session_id", json.String(command.session)),
    ])
  use _ <- result.try(
    daemon_protocol.decode(access.envelope(request, epoch))
    |> result.replace_error(NotSent("invalid resident lookup")),
  )
  use view <- result.try(
    admin.exchange(address, token, epoch, request) |> result.map_error(NotSent),
  )
  use incarnation <- result.try(resident(view, command.session))
  use parsed <- result.try(
    uri.parse(address)
    |> result.replace_error(NotSent("invalid private endpoint")),
  )
  let address =
    uri.to_string(
      uri.Uri(
        ..parsed,
        path: "/v2/sessions/" <> command.session <> "/ws",
        query: None,
        fragment: None,
      ),
    )
  let inbox = websocket.new_inbox()
  use socket <- result.try(
    websocket.connect(address, token, inbox) |> result.map_error(NotSent),
  )
  let outcome = session_exchange(command, socket, inbox, epoch, incarnation)

  // Explicit close covers replies; the transport also closes on reader death.
  websocket.close(socket)
  outcome
}

fn resident(view: json.JsonValue, session: String) -> Result(String, Failure) {
  use id <- result.try(text(view, "session_id") |> result.map_error(NotSent))
  use Nil <- result.try(case id == session {
    True -> Ok(Nil)
    False -> Error(NotSent("resident lookup returned another session"))
  })
  use status <- result.try(field(view, "status") |> result.map_error(NotSent))
  use state <- result.try(text(status, "state") |> result.map_error(NotSent))
  use Nil <- result.try(case state {
    "resident" -> Ok(Nil)
    _ -> Error(NotSent("session must already be resident"))
  })
  text(status, "incarnation") |> result.map_error(NotSent)
}

fn session_exchange(
  command: Command,
  socket: websocket.Connection,
  inbox: process.Subject(websocket.Message),
  epoch: String,
  incarnation: String,
) -> Result(json.JsonValue, Failure) {
  websocket.send(
    socket,
    protocol.encode_command(protocol.CommandEnvelope(
      1,
      protocol.Subscribe(command.session, None),
    )),
  )
  use #(attachment, subscribed) <- result.try(
    await_subscription(inbox, None, None, 128) |> result.map_error(NotSent),
  )
  use Nil <- result.try(verify_attachment(
    attachment,
    command.session,
    epoch,
    incarnation,
  ))
  use Nil <- result.try(
    verify_subscription(subscribed) |> result.map_error(NotSent),
  )
  websocket.send(
    socket,
    protocol.encode_command(protocol.CommandEnvelope(
      2,
      protocol.Evolution(command.action, command.arguments),
    )),
  )
  use reply <- result.try(
    await_reply(inbox, 2, 128) |> result.map_error(UnknownOutcome),
  )
  reply_value(reply)
}

fn verify_subscription(reply: protocol.EventEnvelope) -> Result(Nil, String) {
  case reply.event {
    protocol.SnapshotBegin(_)
    | protocol.SnapshotEnd(_)
    | protocol.SnapshotEvent(protocol.FullSnapshot(..))
    | protocol.SnapshotEvent(protocol.ResumeSnapshot(..)) -> Ok(Nil)
    protocol.ErrorEvent(code, message, _) -> Error(code <> ": " <> message)
    _ -> Error("unexpected subscription reply")
  }
}

// The bounded network subscribe header carries native attachment metadata.
// Legacy delivery pushes it separately, so that path retains both frames in
// either order. No mutation is sent before the original attachment verifies.
fn await_subscription(
  inbox,
  attachment: Option(json.JsonValue),
  reply: Option(protocol.EventEnvelope),
  remaining: Int,
) -> Result(#(json.JsonValue, protocol.EventEnvelope), String) {
  case attachment, reply {
    Some(attachment), Some(reply) -> Ok(#(attachment, reply))
    _, _ -> {
      let waiting = case attachment, reply {
        None, None -> "awaiting attachment and subscription reply"
        None, Some(_) -> "awaiting native attachment"
        Some(_), None -> "awaiting subscription reply"
        Some(_), Some(_) -> "subscription received"
      }
      use frame <- result.try(
        next_event(inbox, remaining)
        |> result.map_error(fn(reason) {
          reason
          <> "; "
          <> waiting
          <> "; frames received="
          <> int.to_string(128 - remaining)
        }),
      )
      case frame.event, frame.reply_to {
        protocol.SnapshotBegin(metadata), Some(1) ->
          await_subscription(inbox, Some(metadata), Some(frame), remaining - 1)
        protocol.AttachmentEvent(metadata), _ ->
          await_subscription(inbox, Some(metadata), reply, remaining - 1)
        _, Some(1) -> {
          use Nil <- result.try(verify_subscription(frame))
          await_subscription(inbox, attachment, Some(frame), remaining - 1)
        }
        _, _ -> await_subscription(inbox, attachment, reply, remaining - 1)
      }
    }
  }
}

fn await_reply(
  inbox,
  id: Int,
  remaining: Int,
) -> Result(protocol.EventEnvelope, String) {
  use frame <- result.try(next_event(inbox, remaining))
  case frame.reply_to == Some(id) {
    True -> Ok(frame)
    False -> await_reply(inbox, id, remaining - 1)
  }
}

fn next_event(inbox, remaining: Int) -> Result(protocol.EventEnvelope, String) {
  use Nil <- result.try(case remaining > 0 {
    True -> Ok(Nil)
    False -> Error("too many unrelated control frames")
  })
  use message <- result.try(
    process.receive(inbox, 5000)
    |> result.replace_error("control frame did not arrive"),
  )
  case message {
    websocket.Connected -> next_event(inbox, remaining - 1)
    websocket.Incoming(text) ->
      protocol.decode_event(text)
      |> result.replace_error("invalid session control frame")
    websocket.Closed(_) | websocket.NetworkFault(_) ->
      Error("session connection ended")
  }
}

/// Fences discovery against the authenticated session attachment.
///
/// ## Examples
///
/// `verify_attachment(metadata,session,epoch,incarnation)` refuses a restarted host.
@internal
pub fn verify_attachment(
  value: json.JsonValue,
  session: String,
  epoch: String,
  incarnation: String,
) -> Result(Nil, Failure) {
  use actual_session <- result.try(
    text(value, "session_id") |> result.map_error(NotSent),
  )
  use actual_epoch <- result.try(
    text(value, "epoch") |> result.map_error(NotSent),
  )
  use actual_incarnation <- result.try(
    text(value, "incarnation") |> result.map_error(NotSent),
  )
  case
    actual_session == session
    && actual_epoch == epoch
    && actual_incarnation == incarnation
  {
    True -> Ok(Nil)
    False -> Error(NotSent("resident session or daemon incarnation changed"))
  }
}

/// Extracts only a correlated evolution board or an explicit daemon refusal.
///
/// ## Examples
///
/// `reply_value(reply)` preserves a queued receipt without calling it complete.
@internal
pub fn reply_value(
  reply: protocol.EventEnvelope,
) -> Result(json.JsonValue, Failure) {
  case reply.event {
    protocol.SnapshotEvent(protocol.EvolutionSnapshot(board)) -> Ok(board)
    protocol.ErrorEvent(code, message, _) ->
      Error(Refused(code <> ": " <> message))
    _ ->
      Error(UnknownOutcome(
        "unexpected evolution reply; query the exact request_id",
      ))
  }
}

fn text(value: json.JsonValue, key: String) -> Result(String, String) {
  use value <- result.try(field(value, key))
  case value {
    json.String(text) if text != "" -> Ok(text)
    _ -> Error("invalid " <> key)
  }
}

fn field(value: json.JsonValue, key: String) -> Result(json.JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.map_error(fn(_) { "missing " <> key })
    _ -> Error("expected object")
  }
}

fn failure_json(failure: Failure) -> json.JsonValue {
  let #(code, message) = case failure {
    Invalid(reason) -> #("invalid_arguments", reason)
    NotSent(reason) -> #("not_sent", reason)
    Refused(reason) -> #("refused", reason)
    UnknownOutcome(reason) -> #("unknown_outcome", reason)
  }
  json.Object([
    #(
      "error",
      json.Object([
        #("code", json.String(code)),
        #("message", json.String(message)),
      ]),
    ),
  ])
}

fn exit_code(failure: Failure) -> Int {
  case failure {
    Invalid(_) -> 2
    NotSent(_) | Refused(_) -> 3
    UnknownOutcome(_) -> 4
  }
}
