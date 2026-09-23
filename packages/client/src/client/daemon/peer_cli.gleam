//// Owner commands for directional peer links and durable message admission.
////
//// Each command names both endpoint coordinates. Sending requires a caller
//// chosen message ID, so a lost response can be retried with the same ID and
//// body. Discovery and transport are shared with the access CLI. Neither
//// inspection nor a failed send starts a saved conversation.

import client/daemon/admin
import client/internal/ffi_os
import core/json.{type JsonValue}
import gleam/io
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// A validated command and its operator-facing identity.
@internal
pub opaque type Command {
  Command(
    directory: String,
    request: admin.Request,
    name: String,
    source_session: String,
    source_strand: String,
    target: JsonValue,
    wake: JsonValue,
    message_id: JsonValue,
  )
}

/// Complete help for the peer operator commands.
pub const usage = "usage: loomd peer [--state-dir PATH] inspect SOURCE_SESSION SOURCE_STRAND\n       loomd peer [--state-dir PATH] link SOURCE_SESSION SOURCE_STRAND TARGET_SESSION TARGET_STRAND --wake busy_only|may_wake\n       loomd peer [--state-dir PATH] unlink SOURCE_SESSION SOURCE_STRAND TARGET_SESSION TARGET_STRAND\n       loomd peer [--state-dir PATH] send SOURCE_SESSION SOURCE_STRAND TARGET_SESSION TARGET_STRAND --message-id ID --text TEXT\n\nLinks are directional. Grant the reverse direction separately. Both endpoints must be resident for link and send; inspect and unlink never open a saved session. Reuse a message ID only to retry the same target and text. A send receipt proves durable admission, not model consumption.\n\nExamples:\n  loomd peer inspect SESSION main\n  loomd peer link SOURCE main TARGET reviewer --wake busy_only\n  loomd peer unlink SOURCE main TARGET reviewer\n  loomd peer send SOURCE main TARGET reviewer --message-id review-1 --text 'Found a race'"

/// Runs a peer control command and prints one JSON object to stdout.
///
/// Exit 0 means an acknowledged complete response. Exit 2 means invalid
/// arguments, 3 means daemon refusal, 4 means an unknown or transport outcome,
/// and 5 means an outgoing link was removed but recipient revocation is pending.
///
/// ## Examples
///
/// ```gleam
/// // loomd peer inspect SESSION main
/// // loomd peer send SOURCE main TARGET reviewer --message-id review-1 --text finding
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case parse(arguments) {
    Error(reason) -> {
      io.println(json.to_string(error_json("usage", reason)))
      ffi_os.halt(2)
    }
    Ok(command) -> {
      case run(command) {
        Ok(value) -> {
          io.println(json.to_string(value))
          ffi_os.halt(case field(value, "partial") {
            Ok(json.Bool(True)) -> 5
            _ -> 0
          })
        }
        Error(reason) -> {
          io.println(json.to_string(failure(command, reason)))
          ffi_os.halt(case unknown_outcome(reason) {
            True -> 4
            False -> 3
          })
        }
      }
    }
  }
}

/// Parses exact endpoint coordinates and validates the resulting v2 frame.
///
/// ## Examples
///
/// ```gleam
/// // peer_cli.parse(["inspect", source_id, "main"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Command, String) {
  let #(directory, arguments) = case arguments {
    ["--state-dir", directory, ..rest] -> #(directory, rest)
    rest -> #("", rest)
  }
  let parsed = case arguments {
    ["inspect", source, strand] ->
      Ok(
        #("peers.inspect", source, strand, json.Null, json.Null, json.Null, []),
      )
    ["link", source, strand, target, to, "--wake", wake] ->
      Ok(
        #(
          "peers.link",
          source,
          strand,
          endpoint(target, to),
          json.String(wake),
          json.Null,
          [
            #("target_session", json.String(target)),
            #("target_strand", json.String(to)),
            #("wake", json.String(wake)),
          ],
        ),
      )
    ["unlink", source, strand, target, to] ->
      Ok(
        #(
          "peers.unlink",
          source,
          strand,
          endpoint(target, to),
          json.Null,
          json.Null,
          [
            #("target_session", json.String(target)),
            #("target_strand", json.String(to)),
          ],
        ),
      )
    ["send", source, strand, target, to, "--message-id", id, "--text", text] ->
      Ok(
        #(
          "peers.send",
          source,
          strand,
          endpoint(target, to),
          json.Null,
          json.String(id),
          [
            #("target_session", json.String(target)),
            #("target_strand", json.String(to)),
            #("message_id", json.String(id)),
            #("text", json.String(text)),
          ],
        ),
      )
    _ -> Error(usage)
  }
  use #(name, source, strand, target, wake, message_id, extra) <- result.try(
    parsed,
  )
  let fields = [
    #("source_session", json.String(source)),
    #("source_strand", json.String(strand)),
    ..extra
  ]
  use request <- result.try(admin.peer_request(directory, name, fields))
  Ok(Command(directory, request, name, source, strand, target, wake, message_id))
}

/// Executes through the local private endpoint, without starting a daemon.
///
/// ## Examples
///
/// ```gleam
/// // peer_cli.run(command)
/// ```
@internal
pub fn run(command: Command) -> Result(JsonValue, String) {
  use #(address, token, epoch) <- result.try(admin.peer_discover(
    command.directory,
  ))
  exchange(address, token, epoch, command)
}

/// Exchanges on a caller-supplied control listener for real wire tests.
///
/// ## Examples
///
/// ```gleam
/// // peer_cli.exchange(address, owner_token, epoch, command)
/// ```
@internal
pub fn exchange(
  address: String,
  token: String,
  epoch: String,
  command: Command,
) -> Result(JsonValue, String) {
  let reply = case command.name {
    "peers.inspect" -> inspect_pages(address, token, epoch, command)
    _ -> admin.exchange(address, token, epoch, command.request)
  }
  reply
  |> result.map(fn(reply) { success(command, reply) })
}

fn inspect_pages(
  address: String,
  token: String,
  epoch: String,
  command: Command,
) -> Result(JsonValue, String) {
  use first <- result.try(admin.exchange(address, token, epoch, command.request))
  use outgoing <- result.try(array_field(first, "outgoing"))
  use incoming <- result.try(array_field(first, "incoming"))
  use next <- result.try(cursor_field(first))
  follow_pages(
    address,
    token,
    epoch,
    command,
    first,
    next,
    list.reverse(outgoing),
    list.reverse(incoming),
  )
}

fn follow_pages(
  address: String,
  token: String,
  epoch: String,
  command: Command,
  first: JsonValue,
  next: JsonValue,
  outgoing: List(JsonValue),
  incoming: List(JsonValue),
) -> Result(JsonValue, String) {
  case next {
    json.Null ->
      case first {
        json.Object(fields) ->
          Ok(
            json.Object([
              #("outgoing", json.Array(list.reverse(outgoing))),
              #("incoming", json.Array(list.reverse(incoming))),
              #("next", json.Null),
              ..list.filter(fields, fn(field) {
                let #(key, _) = field
                key != "outgoing" && key != "incoming" && key != "next"
              })
            ]),
          )
        _ -> Error("invalid peer inspection response; outcome unknown")
      }
    json.String(cursor) -> {
      use request <- result.try(
        admin.peer_request(command.directory, "peers.inspect", [
          #("source_session", json.String(command.source_session)),
          #("source_strand", json.String(command.source_strand)),
          #("after", json.String(cursor)),
        ]),
      )
      use page <- result.try(admin.exchange(address, token, epoch, request))
      use page_outgoing <- result.try(array_field(page, "outgoing"))
      use page_incoming <- result.try(array_field(page, "incoming"))
      use page_next <- result.try(cursor_field(page))
      use Nil <- result.try(
        case field(page, "source_session"), field(page, "source_strand") {
          Ok(json.String(source)), Ok(json.String(strand))
            if source == command.source_session
            && strand == command.source_strand
          -> Ok(Nil)
          _, _ -> Error("invalid peer inspection coordinates; outcome unknown")
        },
      )
      use Nil <- result.try(case page_next {
        json.Null -> Ok(Nil)
        json.String(next_cursor) -> {
          let has_rows =
            list.is_empty(page_outgoing) == False
            || list.is_empty(page_incoming) == False
          case string.compare(next_cursor, cursor) == order.Gt && has_rows {
            True -> Ok(Nil)
            False -> Error("invalid peer inspection cursor; outcome unknown")
          }
        }
        _ -> Error("invalid peer inspection cursor; outcome unknown")
      })
      follow_pages(
        address,
        token,
        epoch,
        command,
        first,
        page_next,
        list.append(list.reverse(page_outgoing), outgoing),
        list.append(list.reverse(page_incoming), incoming),
      )
    }
    _ -> Error("invalid peer inspection cursor; outcome unknown")
  }
}

fn array_field(value, key) {
  case field(value, key) {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("invalid peer inspection rows; outcome unknown")
  }
}

fn cursor_field(value) {
  case field(value, "next") {
    Ok(json.Null) -> Ok(json.Null)
    Ok(json.String(cursor)) if cursor != "" -> Ok(json.String(cursor))
    _ -> Error("invalid peer inspection cursor; outcome unknown")
  }
}

fn endpoint(session, strand) {
  json.Object([
    #("session", json.String(session)),
    #("strand", json.String(strand)),
  ])
}

fn identity(command: Command) {
  [
    #("command", json.String(command.name)),
    #("source", endpoint(command.source_session, command.source_strand)),
    #("target", command.target),
    #("wake", command.wake),
    #("message_id", command.message_id),
  ]
}

fn success(command: Command, reply: JsonValue) {
  let partial = case command.name, field(reply, "recipient_grant") {
    "peers.unlink", Ok(json.String(_)) -> True
    _, _ -> False
  }
  json.Object([
    #("ok", json.Bool(True)),
    #("partial", json.Bool(partial)),
    #("result", reply),
    ..identity(command)
  ])
}

fn field(value, key) {
  case value {
    json.Object(fields) -> list.key_find(fields, key)
    _ -> Error(Nil)
  }
}

fn failure(command, reason) {
  json.Object([
    #("ok", json.Bool(False)),
    #(
      "code",
      json.String(case unknown_outcome(reason) {
        True -> "unknown_outcome"
        False -> "refused"
      }),
    ),
    #("error", json.String(reason)),
    ..identity(command)
  ])
}

fn error_json(code, reason) {
  json.Object([
    #("ok", json.Bool(False)),
    #("code", json.String(code)),
    #("error", json.String(reason)),
  ])
}

@internal
pub fn unknown_outcome(reason: String) -> Bool {
  string.contains(reason, "outcome unknown")
  || string.contains(reason, "request not sent")
  || string.contains(reason, "state directory")
  || string.contains(reason, "HOME is unset")
  || string.contains(reason, "no ready local daemon")
  || string.contains(reason, "published daemon has exited")
}
