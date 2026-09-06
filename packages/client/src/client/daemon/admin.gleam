//// One-shot owner administration over the existing local control listener.
////
//// Discovery never starts a daemon or opens a conversation. The caller keeps
//// its chosen principal ID before sending a mutation; a lost response remains
//// an unknown outcome and can be recovered only by explicit rotation. Socket
//// ownership is the shared host transport's original reader lifetime.

import client/daemon/protocol
import client/internal/ffi_os
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/endpoint
import host/websocket

/// A parsed mutation with no bearer or inferred target identity.
@internal
pub opaque type Request {
  Request(
    directory: String,
    command: String,
    principal: String,
    body: List(#(String, JsonValue)),
  )
}

const usage = "usage: loomd access [--state-dir PATH] invite SESSION PRINCIPAL ROLE NAME | set-role SESSION PRINCIPAL ROLE | revoke SESSION PRINCIPAL | rotate PRINCIPAL | revoke-credentials PRINCIPAL | isolate SESSION --share-existing-transcript"

/// Runs one administration request and prints a bearer only on explicit success.
///
/// ## Examples
///
/// ```gleam
/// // loomd access invite SESSION alice observer Alice
/// // loomd access rotate alice
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case parse(arguments) {
    Error(reason) -> {
      io.println_error(reason)
      ffi_os.halt(1)
    }
    Ok(request) -> {
      let label = case request.command {
        "sessions.isolate" -> "session ID: "
        _member_command -> "principal recovery ID: "
      }
      io.println_error(label <> request.principal)
      case execute(request) {
        Ok(value) -> {
          io.println(json.to_string(value))
          ffi_os.halt(0)
        }
        Error(reason) -> {
          io.println_error(
            "access: "
            <> reason
            <> "; do not retry an unknown mutation automatically",
          )
          ffi_os.halt(1)
        }
      }
    }
  }
}

/// Parses the bounded positional command without touching daemon state.
///
/// ## Examples
///
/// ```gleam
/// // admin.parse(["rotate", "alice"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Request, String) {
  let #(directory, rest) = case arguments {
    ["--state-dir", path, ..rest] -> #(path, rest)
    rest -> #("", rest)
  }
  use request <- result.try(parse_command(directory, rest))
  use Nil <- result.try(valid_principal(request.principal))
  use _ <- result.try(
    protocol.decode(envelope(request, "validation-only"))
    |> result.replace_error("invalid or oversized administration argument"),
  )
  Ok(request)
}

fn parse_command(directory, arguments) {
  case arguments {
    ["isolate", session, "--share-existing-transcript"] ->
      Ok(
        Request(directory, "sessions.isolate", session, [
          #("session_id", json.String(session)),
          #("transcript", json.String("share_existing")),
        ]),
      )
    ["invite", session, principal, role, name] ->
      Ok(
        Request(directory, "sessions.invite", principal, [
          #("session_id", json.String(session)),
          #("role", json.String(role)),
          #("name", json.String(name)),
        ]),
      )
    ["set-role", session, principal, role] ->
      Ok(
        Request(directory, "sessions.set_role", principal, [
          #("session_id", json.String(session)),
          #("role", json.String(role)),
        ]),
      )
    ["revoke", session, principal] ->
      Ok(
        Request(directory, "sessions.revoke", principal, [
          #("session_id", json.String(session)),
        ]),
      )
    ["rotate", principal] ->
      Ok(Request(directory, "credentials.rotate", principal, []))
    ["revoke-credentials", principal] ->
      Ok(Request(directory, "credentials.revoke", principal, []))
    _other -> Error(usage)
  }
}

fn valid_principal(id) {
  case
    string.byte_size(id) > 0
    && string.byte_size(id) <= 128
    && list.all(string.to_graphemes(id), fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
        char,
      )
    })
  {
    True -> Ok(Nil)
    False -> Error("principal ID must be 1-128 ASCII identifier bytes")
  }
}

fn envelope(request: Request, epoch) {
  let identity = case request.command {
    "sessions.isolate" -> []
    _member_command -> [#("principal_id", json.String(request.principal))]
  }
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("id", json.Int(1)),
      #("cmd", json.String(request.command)),
      #(
        "body",
        json.Object(
          list.append(identity, [#("epoch", json.String(epoch)), ..request.body]),
        ),
      ),
    ]),
  )
}

fn execute(request: Request) {
  use directory <- result.try(case request.directory {
    "" ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.loom" })
      |> result.replace_error("HOME is unset; pass --state-dir")
    path -> Ok(path)
  })

  // Requiring an existing directory precedes paths(), which also serves launchers.
  use directory <- result.try(
    bootstrap.canonical_directory(directory)
    |> result.replace_error("the daemon state directory does not exist"),
  )
  use paths <- result.try(endpoint.paths(directory))
  use record <- result.try(endpoint.load(paths))
  use #(record, epoch) <- result.try(ready_record(record))
  use address <- result.try(endpoint.address(record))
  use token <- result.try(bootstrap.read_private_bounded(paths.token, 64))
  use token <- result.try(
    bit_array.to_string(token)
    |> result.replace_error("invalid private credential"),
  )
  use Nil <- result.try(hex_credential(token))
  exchange(address, token, epoch, request)
}

fn ready_record(record) {
  case record {
    None | Some(endpoint.Starting(_)) -> Error("no ready local daemon")
    Some(endpoint.Ready(fence, _, _, epoch) as record) -> {
      use present <- result.try(endpoint.is_present(fence))
      case present {
        True -> Ok(#(record, epoch))
        False -> Error("the published daemon has exited")
      }
    }
  }
}

/// Exchanges one mutation with an already discovered listener.
///
/// This host/test seam does not discover or start a daemon. The normal CLI
/// passes only the validated loopback address from its private endpoint.
/// The original reader must outlive this call; close is requested on every
/// returned outcome, and reader death independently closes the socket.
///
/// ## Examples
///
/// ```gleam
/// // admin.exchange(address, owner_token, epoch, request)
/// ```
@internal
pub fn exchange(
  address: String,
  token: String,
  epoch: String,
  request: Request,
) -> Result(JsonValue, String) {
  let inbox = websocket.new_inbox()
  use socket <- result.try(
    websocket.connect(address, token, inbox)
    |> result.replace_error("control connection failed; request not sent"),
  )
  let outcome = transact(socket, inbox, epoch, request)
  websocket.close(socket)
  outcome
}

fn transact(socket, inbox, epoch, request: Request) {
  use Nil <- result.try(
    verify_hello(inbox, epoch)
    |> result.replace_error("control handshake failed; request not sent"),
  )
  websocket.send(socket, envelope(request, epoch))

  // Only failures after this one send have an unknown mutation outcome.
  use #(fields, body) <- result.try(
    receive_reply(inbox)
    |> result.replace_error(
      "control response missing or invalid; outcome unknown",
    ),
  )
  case list.key_find(fields, "event") {
    Ok(json.String("error")) -> Error(refusal_code(body))
    Ok(json.String(event)) if event == request.command ->
      success(body, request)
      |> result.replace_error("invalid successful reply; outcome unknown")
    Ok(_) | Error(Nil) ->
      Error("unexpected administration reply; outcome unknown")
  }
}

fn verify_hello(inbox, epoch) {
  use hello <- result.try(next_frame(inbox))
  use fields <- result.try(event_fields(hello))
  use Nil <- result.try(equal_field(fields, "event", json.String("hello")))
  use body <- result.try(body_fields(fields))
  use Nil <- result.try(equal_field(body, "epoch", json.String(epoch)))
  equal_field(body, "protocol", json.Int(2))
}

fn receive_reply(inbox) {
  use reply <- result.try(next_frame(inbox))
  use fields <- result.try(event_fields(reply))
  use Nil <- result.try(equal_field(fields, "reply_to", json.Int(1)))
  use body <- result.try(body_fields(fields))
  Ok(#(fields, body))
}

fn next_frame(inbox) {
  use message <- result.try(
    process.receive(inbox, 5000)
    |> result.replace_error("control response timed out"),
  )
  case message {
    websocket.Connected ->
      process.receive(inbox, 5000)
      |> result.replace_error("control response timed out")
      |> result.try(text_frame)
    websocket.Incoming(_) as incoming -> text_frame(incoming)
    websocket.Closed(_) as closed -> text_frame(closed)
    websocket.NetworkFault(_) as fault -> text_frame(fault)
  }
}

fn text_frame(message) {
  case message {
    websocket.Incoming(text) -> Ok(text)
    websocket.Connected | websocket.Closed(_) | websocket.NetworkFault(_) ->
      Error("control connection ended")
  }
}

fn event_fields(text) {
  use Nil <- result.try(case string.byte_size(text) <= protocol.max_bytes {
    True -> Ok(Nil)
    False -> Error("oversized control response")
  })
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid control response"),
  )
  use fields <- result.try(object_fields(value))
  use Nil <- result.try(equal_field(fields, "v", json.Int(2)))
  Ok(fields)
}

fn body_fields(fields) {
  use body <- result.try(
    list.key_find(fields, "body")
    |> result.replace_error("missing response body"),
  )
  object_fields(body)
}

fn object_fields(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _other -> Error("invalid response object")
  }
}

fn equal_field(fields, key, expected) {
  case list.key_find(fields, key) == Ok(expected) {
    True -> Ok(Nil)
    False -> Error("response identity or epoch mismatch")
  }
}

fn success(fields, request: Request) {
  case request.command {
    "sessions.isolate" -> {
      use Nil <- result.try(equal_field(
        fields,
        "session_id",
        json.String(request.principal),
      ))
      use Nil <- result.try(equal_field(
        fields,
        "domain_scope",
        json.String("session_only"),
      ))
      Ok(
        json.Object([
          #("session_id", json.String(request.principal)),
          #("domain_scope", json.String("session_only")),
        ]),
      )
    }
    _member_command -> member_success(fields, request)
  }
}

fn member_success(fields, request: Request) {
  use Nil <- result.try(equal_field(
    fields,
    "principal_id",
    json.String(request.principal),
  ))
  let identity = [#("principal_id", json.String(request.principal))]
  case request.command {
    "sessions.invite" | "credentials.rotate" -> {
      use value <- result.try(
        list.key_find(fields, "bearer")
        |> result.replace_error("missing successful credential"),
      )
      use token <- result.try(case value {
        json.String(token) -> Ok(token)
        _other -> Error("invalid successful credential")
      })
      use Nil <- result.try(hex_credential(token))
      Ok(json.Object([#("bearer", json.String(token)), ..identity]))
    }
    "sessions.set_role" | "sessions.revoke" | "credentials.revoke" ->
      Ok(json.Object(identity))
    _other -> Error("unsupported administration reply")
  }
}

fn hex_credential(token) {
  case
    string.byte_size(token) == 64
    && list.all(string.to_graphemes(token), fn(char) {
      string.contains("0123456789abcdef", char)
    })
  {
    True -> Ok(Nil)
    False -> Error("invalid private credential")
  }
}

fn refusal_code(fields) {
  case list.key_find(fields, "code") {
    Ok(json.String("forbidden")) -> "forbidden"
    Ok(json.String("conflict")) -> "conflict"
    Ok(json.String("not_found")) -> "not_found"
    Ok(json.String("stale_epoch")) -> "stale_epoch"
    Ok(json.String("bad_request")) -> "bad_request"
    Ok(json.String("isolation_required")) ->
      "isolation_required: stop the session and explicitly isolate its existing transcript before sharing"
    Ok(_) | Error(Nil) -> "administration refused"
  }
}
