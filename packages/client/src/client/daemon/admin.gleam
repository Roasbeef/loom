//// `loomd access`: one-shot owner administration over the daemon's own
//// control listener, and the seam the peer commands share.
////
//// The grammar, the exchange and the lines printed live in `host/access`,
//// which `loom access` calls too, so the two binaries answer the same command
//// with the same bytes (protocol-change/053). This module adds what only the
//// daemon's package can: a check of each request against the daemon's own
//// decoder before any connection is made, and the process exit.
////
//// Discovery never starts a daemon or opens a conversation. The caller keeps
//// its chosen principal ID before sending a mutation; a lost response remains
//// an unknown outcome and can be recovered only by explicit rotation.

import client/daemon/protocol
import client/internal/ffi_os
import core/json.{type JsonValue}
import gleam/list
import gleam/result
import host/access

/// A parsed command with no bearer or inferred target identity.
@internal
pub type Request =
  access.Request

/// The complete access-command usage, shared with the top-level dispatcher.
pub const usage =
  "usage: loomd access [--state-dir PATH] list [--after PRINCIPAL] | show PRINCIPAL [--after SESSION] | invite SESSION PRINCIPAL ROLE NAME [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | set-role SESSION PRINCIPAL ROLE | revoke SESSION PRINCIPAL | rotate PRINCIPAL [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | revoke-credentials PRINCIPAL | isolate SESSION --share-existing-transcript"

/// Runs one administration request and exits with its status. A claim token is
/// printed only on standard output, only on explicit success, and never with
/// a bearer.
///
/// ## Examples
///
/// ```gleam
/// // loomd access invite SESSION alice observer Alice --claim-addr wss://host/v2/control
/// // loomd access rotate alice
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case access.run(arguments, access.Loomd, decodes) {
    access.Succeeded -> ffi_os.halt(0)
    access.Failed -> ffi_os.halt(1)
  }
}

// The daemon's decoder is the authority on what it will accept, so a request
// it would refuse is refused here, before it is sent.
fn decodes(envelope: String) -> Result(Nil, String) {
  protocol.decode(envelope)
  |> result.replace(Nil)
  |> result.replace_error("invalid or oversized administration argument")
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
  use request <- result.try(access.parse(arguments, access.Loomd))
  use Nil <- result.try(decodes(access.envelope(request, "validation-only")))
  Ok(request)
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
  let request = access.raw_request(directory, command, source, fields)
  use _ <- result.try(
    protocol.decode(access.envelope(request, "validation-only"))
    |> result.replace_error("invalid or oversized peer request"),
  )
  Ok(request)
}

/// Runs a parsed request against the local daemon, answering its reply as one
/// value.
///
/// ## Examples
///
/// ```gleam
/// // admin.execute(request)
/// ```
@internal
pub fn execute(request: Request) -> Result(JsonValue, String) {
  access.execute(request) |> result.map(single)
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
  access.discover(directory)
  |> result.map_error(fn(reason) { "request not sent: " <> reason })
}

/// Exchanges one request with an already discovered listener.
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
  access.exchange(address, token, epoch, request) |> result.map(single)
}

// A mutation and a peer command answer one value. A listing answers one line
// per row, which a caller of this seam reads as an array.
fn single(lines: List(JsonValue)) -> JsonValue {
  case lines {
    [only] -> only
    many -> json.Array(many)
  }
}
