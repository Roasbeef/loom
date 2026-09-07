//// The websocket transport for the ClientGateway: a thin `mist` server
//// that upgrades `/v1/ws`, authenticates the upgrade, and pipes frames
//// between the socket and a `client/gateway` hub.
////
//// It is package-internal. An upgrade here proves possession of one shared
//// bearer token and nothing more, so it attaches with `gateway.attach` and
//// the resulting connection carries no principal and no role: a trusted
//// host fixture rather than a session member. Production serving is the
//// daemon's authenticated route (`client/daemon/server` and
//// `client/daemon/session_socket`), which resolves an identity before the
//// socket exists and hands the hub a `Binding`. The constructor is
//// `@internal` so that difference is enforced rather than described.
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
/// Internal to this package. This listener attaches with `gateway.attach` —
/// one shared bearer token, no principal, no role — which is a trusted-host
/// fixture rather than a network identity, and protocol-015 leaves no v1
/// adapter or legacy server mode for it to be. The daemon's own listener
/// (`client/daemon/server`) is the production route. Keeping the constructor
/// out of the package's public surface is what makes an unauthenticated
/// gateway attachment unreachable from outside rather than merely unused;
/// `gateway.attach`'s doc already said so, and this is the type system
/// saying it.
@internal
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
/// Internal to this package, for the reason `serve` is.
@internal
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
/// Internal to this package: it mints the credential only this listener
/// checks, so it travels with `serve`.
@internal
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

// The per-socket state. Attachment is a handler turn rather than an
// initializer step, for the reason given at the self-send below, so a socket
// exists for one turn before it has a gateway id.
type SocketState {
  // Nothing is attached yet. The subject is the one the initializer selected
  // on; the sink built at attach time sends into it.
  Pending(outbound: Subject(SocketEvent))

  // Attached, carrying the connection id the gateway issued. The websocket
  // process owns the socket write.
  Attached(connection: Int)
}

type SocketEvent {
  // The self-addressed message that runs attachment. `on_init` queues it and
  // nothing else ever sends it.
  Admit

  Outbound(frame: String)
}

fn upgrade(
  request: Request(Connection),
  gateway: Gateway,
) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: fn(_websocket) {
      let outbound = process.new_subject()

      // Attachment is a `process.call` into the hub with a five second budget,
      // and mist gives this initializer 500 ms it does not expose
      // (`actor.new_with_initialiser(500, ...)` in its internal websocket
      // module). An initializer that overruns is killed along with its socket,
      // so a hub that is merely busy would reach the peer as a dropped
      // connection rather than a refusal. Hence this self-send: the call is
      // paid for in the first handler turn instead.
      //
      // The ordering is what makes that safe. mist transfers TCP ownership and
      // calls `set_active` only after the initializer returns
      // (`mist.websocket_upgrade`), so `Admit` is queued before the socket can
      // deliver a byte and is the first message the handler sees. A refusal is
      // therefore an ordinary `mist.stop()` from that turn, which is why the
      // out-of-band refusal this function used to carry is gone.
      process.send(outbound, Admit)
      let selector =
        process.new_selector()
        |> process.select(outbound)
      #(Pending(outbound), Some(selector))
    },
    handler: fn(state: SocketState, message, websocket) {
      case state, message {
        Pending(outbound), mist.Custom(Admit) ->
          case
            gateway.attach(gateway, fn(frame) {
              process.send(outbound, Outbound(frame))
            })
          {
            Ok(connection) -> mist.continue(Attached(connection))
            Error(Nil) -> mist.stop()
          }

        // Unreachable, for the ordering reason above: nothing reaches a
        // pending socket before its own `Admit`. Spelled out rather than
        // folded into a catch-all so a change in mist's start sequence fails
        // closed instead of silently serving an unattached socket.
        Pending(_), mist.Text(_)
        | Pending(_), mist.Binary(_)
        | Pending(_), mist.Closed
        | Pending(_), mist.Shutdown
        | Pending(_), mist.Custom(Outbound(_))
        -> mist.stop()

        Attached(connection), mist.Text(frame) -> {
          gateway.handle_text(gateway, connection, frame)
          mist.continue(state)
        }

        // The protocol is text-frame JSON; a binary frame is answered
        // with nothing and ignored.
        Attached(_), mist.Binary(_) -> mist.continue(state)

        Attached(_), mist.Custom(Outbound(frame)) ->
          case mist.send_text_frame(websocket, frame) {
            Ok(Nil) -> mist.continue(state)
            Error(_) -> mist.stop()
          }

        Attached(_), mist.Custom(Admit)
        | Attached(_), mist.Closed
        | Attached(_), mist.Shutdown
        -> mist.stop()
      }
    },
    on_close: fn(state: SocketState) {
      case state {
        Attached(connection) -> gateway.detach(gateway, connection)
        Pending(_) -> Nil
      }
    },
  )
}
