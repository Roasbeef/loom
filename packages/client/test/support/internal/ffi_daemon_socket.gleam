//// Stock OTP socket connection used only by daemon wire tests.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import support/internal/ffi_ws.{type Socket, type SocketOption}

/// Opens a passive test connection with an explicit deadline.
///
/// ## Examples
///
/// ```gleam
/// // connect(#(127, 0, 0, 1), port, options, 1000)
/// ```
@external(erlang, "gen_tcp", "connect")
pub fn connect(
  host: #(Int, Int, Int, Int),
  port: Int,
  options: List(SocketOption),
  timeout: Int,
) -> Result(Socket, Dynamic)

/// Sends already-framed test bytes.
///
/// ## Examples
///
/// ```gleam
/// // send(socket, bytes)
/// ```
@external(erlang, "gen_tcp", "send")
fn do_send(socket: Socket, bytes: BitArray) -> Dynamic

/// Converts OTP's bare success atom into a Gleam result.
///
/// ## Examples
///
/// ```gleam
/// // send(socket, bytes)
/// ```
pub fn send(socket: Socket, bytes: BitArray) -> Result(Nil, Dynamic) {
  let outcome = do_send(socket, bytes)
  case outcome == atom.to_dynamic(atom.create("ok")) {
    True -> Ok(Nil)
    False -> Error(outcome)
  }
}
