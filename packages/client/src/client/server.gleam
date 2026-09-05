//// The websocket transport for the ClientGateway: a thin `mist` server
//// that upgrades `/v1/ws`, authenticates the upgrade, and pipes frames
//// between the socket and a `client/gateway` hub.
////
//// ## Why mist
////
//// Gleam ships no websocket server in its core libraries. `mist` is the
//// ecosystem's maintained pure-Gleam HTTP/websocket server (it sits on
//// `glisten`, the ecosystem's TCP layer, both actively maintained on
//// Hex) and its version constraints resolve cleanly against this tree,
//// so the framed-TCP fallback the work package sketched was not needed.
//// The websocket specifics stay confined to this module: the gateway
//// speaks sinks and text frames, so a different transport is a new
//// module, not a gateway change.
////
//// ## Auth (WP-L, protocol.md open question 1 — answered with what
//// this module ships)
////
//// mist listens on TCP interfaces only — it has no unix-socket
//// listener — so unix-socket peer credentials are not implementable
//// here today. The **local story shipped instead**: bind `127.0.0.1`
//// and require a bearer token minted at startup and written to a
//// `0600` token file next to the session (`LocalAuth`). A local client
//// reads the file — readable only by the same user, which is the
//// peer-credential check moved into the filesystem — and sends
//// `Authorization: Bearer <token>` on the upgrade, exactly like a
//// remote client (`BearerAuth`), so the TUI's TCP-only dial path works
//// unchanged. If mist grows unix listeners, `ws+unix` + `SO_PEERCRED`
//// can replace the token file without touching the protocol.
////
//// Every upgrade without the exact token is answered `401` before any
//// websocket state exists.

import client/gateway.{type Gateway}
import client/internal/ffi_crypto
import client/internal/ffi_file
import client/internal/ffi_os

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import simplifile

/// How upgrades authenticate.
pub type Auth {
  /// Local serving: loopback bind plus a startup-minted bearer token
  /// written to `token_path` with `0600` permissions. Invariant:
  /// `token_path` is an absolute path in a directory the serving user
  /// owns.
  LocalAuth(token_path: String)

  /// Remote serving: the caller-supplied bearer token checked on every
  /// upgrade. Invariant: non-empty.
  BearerAuth(token: String)
}

/// Server configuration.
///
/// Constructor invariants: `bind` is an interface `mist` accepts
/// (`"localhost"`, an IPv4, or an IPv6 address) — keep it loopback for
/// `LocalAuth`; `port` may be `0` to take an ephemeral port; `entropy`
/// supplies seeds for token minting (never used for anything else).
pub type Config {
  Config(
    gateway: Gateway,
    bind: String,
    port: Int,
    auth: Auth,
    entropy: fn() -> Int,
  )
}

/// A running server: the mist supervisor, the bound port, and the
/// bearer token upgrades must present.
pub type Server {
  Server(supervisor: process.Pid, port: Int, token: String)
}

/// Why the server failed to start.
pub type ServeError {
  /// The token file could not be written or restricted to `0600`.
  TokenFileFailed(reason: simplifile.FileError)

  /// The listener failed to start.
  ListenFailed(error: actor.StartError)
}

/// Starts the websocket server. For `LocalAuth` a fresh token is minted
/// and written to the token file (`0600`) before the listener opens;
/// for `BearerAuth` the supplied token is used as-is.
///
/// ## Examples
///
/// ```gleam
/// // server.serve(server.Config(gateway:, bind: "127.0.0.1", port: 0,
/// //   auth: server.LocalAuth("/tmp/session.token"), entropy:))
/// ```
///
pub fn serve(config: Config) -> Result(Server, ServeError) {
  use token <- result.try(case config.auth {
    BearerAuth(token:) -> Ok(token)
    LocalAuth(token_path:) -> {
      let token = mint_token(config.entropy)
      case write_token_file(token_path, token) {
        Ok(Nil) -> Ok(token)
        Error(reason) -> Error(TokenFileFailed(reason:))
      }
    }
  })

  // The listener reports its bound port (which matters for port 0)
  // through `after_start`; the subject hands it back to this caller.
  let ports = process.new_subject()
  let handler = fn(request) { route(request, config.gateway, token) }
  let started =
    mist.new(handler)
    |> mist.bind(config.bind)
    |> mist.port(config.port)
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(ports, port)
    })
    |> mist.start
  case started {
    Error(error) -> Error(ListenFailed(error:))
    Ok(actor.Started(pid:, ..)) -> {
      // The caller owns the server through the returned record, not
      // through the start link: unlinking lets `stop` kill the listener
      // without taking the owner down with it (the same pattern the
      // runtime supervisor uses).
      process.unlink(pid)
      case process.receive(ports, within: 5000) {
        Ok(port) -> Ok(Server(supervisor: pid, port:, token:))
        Error(Nil) ->
          Error(
            ListenFailed(error: actor.InitFailed(
              "the listener never reported its port",
            )),
          )
      }
    }
  }
}

/// Stops a running server.
///
/// ## Examples
///
/// ```gleam
/// // server.stop(server)
/// ```
///
pub fn stop(server: Server) -> Nil {
  process.kill(server.supervisor)
}

/// Mints a 128-bit hex bearer token from the injected entropy source.
///
/// ## Examples
///
/// ```gleam
/// // server.mint_token(entropy)
/// ```
///
pub fn mint_token(entropy: fn() -> Int) -> String {
  [entropy(), entropy(), entropy(), entropy()]
  |> take_hex([])
  |> string.concat
}

fn take_hex(seeds: List(Int), accumulator: List(String)) -> List(String) {
  case seeds {
    [] -> accumulator
    [seed, ..rest] -> {
      let word = int.absolute_value(seed) % 4_294_967_296
      let hex =
        word
        |> int.to_base16
        |> string.lowercase
        |> string.pad_start(to: 8, with: "0")
      take_hex(rest, [hex, ..accumulator])
    }
  }
}

// Writes `token` to `path` with no window in which anything at `path`
// is readable by more than its owner (GW-token-perms): the bytes are
// created at an unpredictable temp name in the same directory,
// exclusively and already at mode 0600 (`ffi_file`), then moved onto
// `path` with a single atomic rename. A rename replaces whatever is at
// the destination -- file, or a pre-planted symlink -- without ever
// reading through it, so a symlink race on the well-known token path is
// refused the same way a plain TOCTOU is: the destination's contents
// never influence what gets written.
fn write_token_file(
  path: String,
  token: String,
) -> Result(Nil, simplifile.FileError) {
  let temp_path =
    path <> ".tmp-" <> int.to_string(ffi_os.unique_positive_integer())
  case
    ffi_file.create_exclusive_private_file(
      temp_path,
      bit_array.from_string(token),
    )
  {
    Error(Nil) ->
      Error(simplifile.Unknown(
        "failed to create the token file exclusively at " <> temp_path,
      ))
    Ok(Nil) ->
      case simplifile.rename(at: temp_path, to: path) {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> {
          // The rename failed; the temp file is not the token file
          // anyone reads, so leaving it behind would only leak the
          // token to a second local user under a name nobody is
          // watching for -- clean it up on a best-effort basis.
          let _ = simplifile.delete_file(temp_path)
          Error(reason)
        }
      }
  }
}

// --- routing ---------------------------------------------------------------

fn route(
  request: Request(Connection),
  gateway: Gateway,
  token: String,
) -> Response(ResponseData) {
  case request.path_segments(request) {
    ["v1", "ws"] ->
      case authorized(request, token) {
        False -> plain(401, "unauthorized")
        True -> upgrade(request, gateway)
      }
    ["healthz"] -> plain(200, "ok")
    _ -> plain(404, "not found")
  }
}

const bearer_prefix = "Bearer "

// GW-token-timing: the presented bytes are compared to the expected
// token in constant time (`ffi_crypto.constant_time_equal`, the same
// `crypto:hash_equals` primitive `broker/token` checks capability
// tokens with) rather than with `==`, which short-circuits at the first
// differing byte and turns response latency into an oracle on the
// secret. The `starts_with` check ahead of it only branches on the
// scheme name, which is public, never on the token.
fn authorized(request: Request(Connection), token: String) -> Bool {
  case request.get_header(request, "authorization") {
    Error(Nil) -> False
    Ok(header) ->
      case string.starts_with(header, bearer_prefix) {
        False -> False
        True -> {
          let presented =
            string.drop_start(header, string.length(bearer_prefix))
          ffi_crypto.constant_time_equal(
            bit_array.from_string(presented),
            bit_array.from_string(token),
          )
        }
      }
  }
}

fn plain(status: Int, text: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

// The per-socket state: this connection's gateway id plus the subject
// outbound frames arrive on (the gateway's sink sends into it; the
// websocket process owns the socket write).
type SocketState {
  SocketState(connection: Result(Int, Nil), outbound: Subject(SocketEvent))
}

// A failed attachment closes the socket even if its peer sends nothing.
type SocketEvent {
  Outbound(frame: String)
  GatewayUnavailable
}

fn upgrade(
  request: Request(Connection),
  gateway: Gateway,
) -> Response(ResponseData) {
  let refused = process.new_subject()
  let response =
    mist.websocket(
      request:,
      on_init: fn(_websocket) {
        let outbound = process.new_subject()
        let connection =
          gateway.attach(gateway, fn(frame) {
            process.send(outbound, Outbound(frame))
          })
        case connection {
          Ok(_) -> Nil
          Error(Nil) -> process.send(refused, outbound)
        }
        let selector =
          process.new_selector()
          |> process.select(outbound)
        #(SocketState(connection:, outbound:), Some(selector))
      },
      handler: fn(state: SocketState, message, websocket) {
        case state.connection, message {
          Error(Nil), _ -> mist.stop()
          Ok(connection), mist.Text(frame) -> {
            gateway.handle_text(gateway, connection, frame)
            mist.continue(state)
          }

          // The protocol is text-frame JSON; a binary frame is answered
          // with nothing and ignored.
          Ok(_), mist.Binary(_) -> mist.continue(state)
          Ok(_), mist.Custom(Outbound(frame)) ->
            case mist.send_text_frame(websocket, frame) {
              Ok(Nil) -> mist.continue(state)
              Error(_) -> mist.stop()
            }
          Ok(_), mist.Custom(GatewayUnavailable)
          | Ok(_), mist.Closed
          | Ok(_), mist.Shutdown
          -> mist.stop()
        }
      },
      on_close: fn(state: SocketState) {
        case state.connection {
          Ok(connection) -> gateway.detach(gateway, connection)
          Error(Nil) -> Nil
        }
      },
    )

  // Mist transfers TCP ownership only after on_init returns. A self-message
  // from on_init could stop the new actor before that transfer and crash the
  // HTTP handler. The request process releases a refusal after websocket has
  // completed the transfer; on_init already queued it before acknowledging
  // startup, so this receive does not wait for work or depend on a timer.
  case process.receive(refused, within: 0) {
    Ok(outbound) -> process.send(outbound, GatewayUnavailable)
    Error(Nil) -> Nil
  }
  response
}
