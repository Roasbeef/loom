//// `cap/net` — outbound network access, **deny-by-default**.
////
//// The design's story is meant literally: a program cannot open a socket
//// unless it imports `cap/net`, and even then the call only succeeds
//// under an approved network policy. Network is off by default
//// (design §5.2), so on a default policy every function here returns
//// `NetDenied` carrying the broker's reason — the module exists, imports
//// resolve, the capability is named in the vetting closure, and the
//// effect surface still refuses. An operator who approves an egress
//// allowlist for a host (the escalation flow, design §5.3) turns the
//// same calls into real requests through the harness-owned proxy; no
//// direct sockets ever exist.
////
//// ## Deny-by-default is a broker property, not a property of this module
////
//// Say it plainly: nothing here refuses anything. Every function marshals
//// its arguments and calls `dispatch`, exactly as `cap/fs.read` does; the
//// refusal is composed and returned by the broker, and `map_error` only
//// *labels* it as a `NetError`. There is no local policy check, and — the
//// point of the design — no policy field for a program to flip, so a
//// program cannot widen its own network access. The other side of that
//// coin is that this module contributes no defence in depth: if the broker
//// ever admitted `net.request` under a default policy, `cap/net` would not
//// catch it. Deny-by-default is a property of the broker (M4 triage C-F4).

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// An HTTP request to make through the egress proxy.
pub type Request {
  Request(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

/// A response from an approved request.
pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

/// Why a network call did not return a response. `NetDenied` is the
/// default outcome: no policy grants the host.
pub type NetError {
  /// Network is off, or the host is not in the approved allowlist.
  NetDenied(message: String)
  /// The request was allowed but failed (DNS, connection, timeout).
  NetFailed(code: String, message: String)
  /// The capability channel could not carry the call.
  NetUnavailable(reason: String)
}

/// Fetches a URL with a GET request.
///
/// Capability: `net.request`. Denied by default; see the module docs.
pub fn fetch(url: String) -> Result(Response, NetError) {
  request(Request(method: "GET", url:, headers: [], body: <<>>))
}

/// Makes an arbitrary HTTP request.
///
/// Capability: `net.request`. Denied by default; see the module docs.
pub fn request(request: Request) -> Result(Response, NetError) {
  let args =
    wire.args([
      #("method", wire.string(request.method)),
      #("url", wire.string(request.url)),
      #("headers", encode_headers(request.headers)),
      #("body", wire.binary(request.body)),
    ])
  use value <- result.try(
    dispatch.call("net.request", args) |> result.map_error(map_error),
  )
  decode_response(value)
  |> result.map_error(fn(reason) {
    NetUnavailable("bad net.request result: " <> reason)
  })
}

fn encode_headers(headers: List(#(String, String))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(headers, fn(pair) {
      #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
    }),
  )
}

fn decode_response(value: MsgPackValue) -> Result(Response, String) {
  use status <- result.try(wire.int_field(value, "status"))
  use body <- result.try(wire.binary_field(value, "body"))
  let headers = case wire.field(value, "headers") {
    Ok(msgpack.MapValue(entries:)) -> decode_headers(entries)
    _ -> []
  }
  Ok(Response(status:, headers:, body:))
}

fn decode_headers(
  entries: List(#(MsgPackValue, MsgPackValue)),
) -> List(#(String, String)) {
  list.filter_map(entries, fn(entry) {
    case entry {
      #(msgpack.StringValue(name), msgpack.StringValue(text)) ->
        Ok(#(name, text))
      _ -> Error(Nil)
    }
  })
}

fn map_error(error: CallError) -> NetError {
  case error {
    Unreachable(reason:) -> NetUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "denied" | "network_off" | "policy" | "not_allowed" ->
          NetDenied(message:)
        _ -> NetFailed(code:, message:)
      }
  }
}
