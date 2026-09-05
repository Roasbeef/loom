//// Test-side FFI (spec §0.2 confinement, mirroring the conformance
//// package's test support): the minimal websocket probe the boot smoke
//// test uses to witness a real upgrade and a real frame round trip.

import gleam/dynamic.{type Dynamic}

/// An OTP TCP socket, owned by the process that opened or accepted it.
pub type Socket

/// Native gen_tcp options. Active must retain OTP's boolean tuple shape.
pub type SocketOption {
  /// Receive bytes rather than Erlang integer lists.
  Binary

  /// False selects passive reads through tcp_receive.
  Active(Bool)
}

/// Opens a test listener. Use port zero for an isolated ephemeral port.
///
/// ## Examples
///
/// ```gleam
/// let listener = tcp_listen(0, [Binary, Active(False)])
/// ```
@external(erlang, "gen_tcp", "listen")
pub fn tcp_listen(
  port: Int,
  options: List(SocketOption),
) -> Result(Socket, Dynamic)

/// Reads the bound port of a listener.
///
/// ## Examples
///
/// ```gleam
/// let port = tcp_port(listener)
/// ```
@external(erlang, "inet", "port")
pub fn tcp_port(socket: Socket) -> Result(Int, Dynamic)

/// Accepts one connection within a bounded test deadline.
///
/// ## Examples
///
/// ```gleam
/// let peer = tcp_accept(listener, 1000)
/// ```
@external(erlang, "gen_tcp", "accept")
pub fn tcp_accept(socket: Socket, timeout_ms: Int) -> Result(Socket, Dynamic)

/// Reads passive TCP bytes, retaining the native error for total decoding.
///
/// ## Examples
///
/// ```gleam
/// let received = tcp_receive(peer, 0, 1000)
/// ```
@external(erlang, "gen_tcp", "recv")
pub fn tcp_receive(
  socket: Socket,
  length: Int,
  timeout_ms: Int,
) -> Result(BitArray, Dynamic)

/// Closes a test socket.
///
/// ## Examples
///
/// ```gleam
/// tcp_close(listener)
/// ```
@external(erlang, "gen_tcp", "close")
pub fn tcp_close(socket: Socket) -> Dynamic

/// Dials `host:port`, upgrades `/v1/ws` with the bearer token, sends
/// one text frame, and returns the first text frame the server sends
/// back. Erlang `gen_tcp`/`crypto` in `client_test_ffi` — a socket
/// probe has no pure alternative, and using a client library would
/// hide the handshake the test exists to witness.
@external(erlang, "client_test_ffi", "ws_roundtrip")
pub fn ws_roundtrip(
  host: String,
  port: Int,
  token: String,
  text: String,
) -> Result(String, String)
