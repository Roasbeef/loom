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
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/claim
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
    claim_address: ClaimAddress,
  )
}

// Where the printed `claim_command` points the invitee. An invitation or
// rotation that enrolls a digest, and every other command, prints none.
type ClaimAddress {
  NoClaim

  // The control address this command discovered, which is the daemon's
  // loopback listener and so works only on the daemon's host.
  DiscoveredAddress

  // An address from `--claim-addr`, already checked by `claim.remote_address`.
  GivenAddress(address: String)
}

/// The complete access-command usage, shared with the top-level dispatcher.
pub const usage =
  "usage: loomd access [--state-dir PATH] invite SESSION PRINCIPAL ROLE NAME [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | set-role SESSION PRINCIPAL ROLE | revoke SESSION PRINCIPAL | rotate PRINCIPAL [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | revoke-credentials PRINCIPAL | isolate SESSION --share-existing-transcript"

/// Runs one administration request. A claim token is printed only on
/// standard output, only on explicit success, and never with a bearer.
///
/// ## Examples
///
/// ```gleam
/// // loomd access invite SESSION alice observer Alice --claim-addr wss://host/v2/control
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
          case request.claim_address {
            DiscoveredAddress ->
              io.println_error(
                "claim_command names this daemon's loopback address, which "
                <> "works only on this host; pass --claim-addr wss://HOST/v2/control "
                <> "for an invitee elsewhere. Send the claim and the command "
                <> "outside Loom, never through a Loom session.",
              )
            NoClaim | GivenAddress(_) -> Nil
          }
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
      Ok(Request(
        directory,
        "sessions.isolate",
        session,
        [
          #("session_id", json.String(session)),
          #("transcript", json.String("share_existing")),
        ],
        NoClaim,
      ))
    ["invite", session, principal, role, name, ..options] -> {
      use #(fields, address) <- result.try(enrollment_options(options))
      Ok(Request(
        directory,
        "sessions.invite",
        principal,
        [
          #("session_id", json.String(session)),
          #("role", json.String(role)),
          #("name", json.String(name)),
          ..fields
        ],
        address,
      ))
    }
    ["set-role", session, principal, role] ->
      Ok(Request(
        directory,
        "sessions.set_role",
        principal,
        [
          #("session_id", json.String(session)),
          #("role", json.String(role)),
        ],
        NoClaim,
      ))
    ["revoke", session, principal] ->
      Ok(Request(
        directory,
        "sessions.revoke",
        principal,
        [#("session_id", json.String(session))],
        NoClaim,
      ))
    ["rotate", principal, ..options] -> {
      use #(fields, address) <- result.try(enrollment_options(options))
      Ok(Request(directory, "credentials.rotate", principal, fields, address))
    }
    ["revoke-credentials", principal] ->
      Ok(Request(directory, "credentials.revoke", principal, [], NoClaim))
    _other -> Error(usage)
  }
}

// The options an invitation or rotation takes, gathered whole before any
// field is built. `--credential-digest` enrolls the invitee's own credential
// and creates no claim, so it excludes both claim options: a lifetime or an
// address for a claim that will not exist names nothing.
type EnrollmentOptions {
  EnrollmentOptions(ttl: String, address: String, digest: String)
}

fn enrollment_options(
  options: List(String),
) -> Result(#(List(#(String, JsonValue)), ClaimAddress), String) {
  use found <- result.try(gather_options(options, EnrollmentOptions("", "", "")))
  case found {
    EnrollmentOptions(ttl: "", address: "", digest: "") ->
      Ok(#([], DiscoveredAddress))
    EnrollmentOptions(ttl:, address:, digest: "") -> {
      use ttl <- result.try(ttl_field(ttl))
      use address <- result.try(case address {
        "" -> Ok(DiscoveredAddress)
        given ->
          claim.remote_address(given)
          |> result.map(fn(_) { GivenAddress(given) })
          |> result.map_error(fn(reason) { "--claim-addr: " <> reason })
      })
      Ok(#(ttl, address))
    }
    EnrollmentOptions(ttl: "", address: "", digest:) ->
      Ok(#([#("credential_digest", json.String(digest))], NoClaim))
    EnrollmentOptions(..) ->
      Error("--credential-digest cannot be combined with --ttl or --claim-addr")
  }
}

fn gather_options(
  options: List(String),
  found: EnrollmentOptions,
) -> Result(EnrollmentOptions, String) {
  case options {
    [] -> Ok(found)
    ["--ttl", value, ..rest] if found.ttl == "" ->
      gather_options(rest, EnrollmentOptions(..found, ttl: value))
    ["--claim-addr", value, ..rest] if found.address == "" ->
      gather_options(rest, EnrollmentOptions(..found, address: value))
    ["--credential-digest", value, ..rest] if found.digest == "" ->
      gather_options(rest, EnrollmentOptions(..found, digest: value))
    _other -> Error(usage)
  }
}

// `--ttl` takes a count of minutes, hours or days. The daemon holds the
// range, 5 minutes to 7 days, and refuses anything outside it; the bound is
// repeated here only so the mistake is named before a connection is made.
fn ttl_field(text: String) -> Result(List(#(String, JsonValue)), String) {
  use <- bool.guard(when: text == "", return: Ok([]))
  let unit = string.slice(text, string.length(text) - 1, 1)
  use count <- result.try(
    int.parse(string.drop_end(text, 1))
    |> result.replace_error("--ttl takes a form such as 30m, 24h or 7d"),
  )
  use multiplier <- result.try(case unit {
    "m" -> Ok(60_000)
    "h" -> Ok(3_600_000)
    "d" -> Ok(86_400_000)
    _other -> Error("--ttl takes a form such as 30m, 24h or 7d")
  })
  let ttl = count * multiplier
  case ttl >= 300_000 && ttl <= 604_800_000 {
    True -> Ok([#("claim_ttl_ms", json.Int(ttl))])
    False -> Error("--ttl must be between 5 minutes and 7 days")
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

/// Builds a peer control request while sharing this client's private endpoint
/// discovery and authenticated WebSocket exchange.
///
/// ## Examples
///
/// ```gleam
/// // admin.peer_request("", "peers.inspect", fields)
/// ```
@internal
pub fn peer_request(
  directory: String,
  command: String,
  fields: List(#(String, JsonValue)),
) -> Result(Request, String) {
  use source <- result.try(
    list.key_find(fields, "source_session")
    |> result.replace_error("missing source session"),
  )
  use source <- result.try(case source {
    json.String(source) -> Ok(source)
    _ -> Error("invalid source session")
  })
  let request = Request(directory, command, source, fields, NoClaim)
  use _ <- result.try(
    protocol.decode(envelope(request, "validation-only"))
    |> result.replace_error("invalid or oversized peer request"),
  )
  Ok(request)
}

fn envelope(request: Request, epoch) {
  let identity = case request.command {
    "sessions.isolate" -> []
    "peers.inspect" | "peers.link" | "peers.unlink" | "peers.send" -> []
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

@internal
pub fn execute(request: Request) {
  use #(address, token, epoch) <- result.try(discover(request.directory))
  exchange(address, token, epoch, request)
}

/// Discovers the private owner control endpoint before any peer request is sent.
/// Local discovery failures are explicitly marked, so the CLI does not report
/// them as daemon refusals.
///
/// ## Examples
///
/// ```gleam
/// // admin.peer_discover("/private/loom")
/// ```
@internal
pub fn peer_discover(
  directory: String,
) -> Result(#(String, String, String), String) {
  discover(directory)
  |> result.map_error(fn(reason) { "request not sent: " <> reason })
}

fn discover(directory) {
  use directory <- result.try(case directory {
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
  Ok(#(address, token, epoch))
}

fn ready_record(record) {
  case record {
    None | Some(endpoint.Starting(_)) -> Error("no ready local daemon")
    Some(endpoint.Ready(fence, _, _, epoch, _) as record) -> {
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
  let outcome = transact(socket, inbox, address, epoch, request)
  websocket.close(socket)
  outcome
}

fn transact(socket, inbox, address, epoch, request: Request) {
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
    Ok(json.String("error")) -> {
      use body <- result.try(
        object_fields(body)
        |> result.replace_error("invalid refusal reply; outcome unknown"),
      )
      Error(refusal_code(body))
    }
    Ok(json.String(event)) if event == request.command -> {
      case request.command {
        "peers.inspect" | "peers.link" | "peers.unlink" | "peers.send" ->
          Ok(body)
        _ -> {
          use body <- result.try(
            object_fields(body)
            |> result.replace_error("invalid successful reply; outcome unknown"),
          )
          success(body, address, request)
          |> result.replace_error("invalid successful reply; outcome unknown")
        }
      }
    }
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
  use body <- result.try(
    list.key_find(fields, "body")
    |> result.replace_error("missing response body"),
  )
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

fn success(fields, address, request: Request) {
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
    _member_command -> member_success(fields, address, request)
  }
}

// A member reply is re-encoded from checked fields rather than echoed, so a
// daemon that answered with a `bearer` or any other extra field could not get
// it printed. A claim is printed only when this request asked for one.
fn member_success(fields, address, request: Request) {
  use Nil <- result.try(equal_field(
    fields,
    "principal_id",
    json.String(request.principal),
  ))
  use name <- result.try(case list.key_find(fields, "name") {
    Ok(json.String(name)) -> Ok(name)
    Ok(_) | Error(Nil) -> Error("missing successful member name")
  })
  let identity = [
    #("principal_id", json.String(request.principal)),
    #("name", json.String(name)),
  ]
  case request.command, request.claim_address {
    "sessions.invite", GivenAddress(given)
    | "credentials.rotate", GivenAddress(given)
    -> claimed(fields, identity, given)
    "sessions.invite", DiscoveredAddress
    | "credentials.rotate", DiscoveredAddress
    -> claimed(fields, identity, address)
    "sessions.invite", NoClaim
    | "credentials.rotate", NoClaim
    | "sessions.set_role", _
    | "sessions.revoke", _
    | "credentials.revoke", _
    -> Ok(json.Object(identity))
    _other, _ -> Error("unsupported administration reply")
  }
}

// `claim_command` names the address and never the token, so the invitee's
// shell history and argument vector hold no secret by default.
fn claimed(fields, identity, address: String) {
  use token <- result.try(case list.key_find(fields, "claim") {
    Ok(json.String(token)) -> Ok(token)
    Ok(_) | Error(Nil) -> Error("missing successful claim")
  })
  use Nil <- result.try(claim.validate_token(token))
  use expires_in_ms <- result.try(case list.key_find(fields, "expires_in_ms") {
    Ok(json.Int(value)) if value > 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error("missing claim lifetime")
  })
  Ok(
    json.Object(
      list.append(identity, [
        #("claim", json.String(token)),
        #("expires_in_ms", json.Int(expires_in_ms)),
        #("claim_command", json.String("loom claim --addr " <> address)),
      ]),
    ),
  )
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
    Ok(json.String(code)) -> code
    Ok(_) | Error(Nil) -> "administration refused"
  }
}
