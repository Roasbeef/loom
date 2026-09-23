//// Raw OTP port operations for the trusted Codex subscription helper.
////
//// The actor above this boundary owns framing, request correlation, and
//// cancellation. OTP alone can open an executable with a binary stdin/stdout
//// port and receive its untyped port messages, so those mechanics live here.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Subject}

/// The two port messages the actor can act on; all other shapes are invalid.
pub type PortEvent {
  /// Raw stdout bytes at an arbitrary pipe boundary.
  PortBytes(BitArray)

  /// The child exited with its native status.
  PortClosed(Int)

  /// A matched but unknown port message.
  PortInvalid
}

/// Opens the fixed helper executable with one profile argument. OTP's
/// `open_port/2` is required for a persistent binary child process.
@external(erlang, "client_codex_bridge_ffi", "open_stdio")
pub fn open_stdio(executable: String, profile: String) -> Result(Port, String)

/// Writes a complete JSON command as one bounded length-prefixed frame.
/// OTP's `port_command/2` is required to write to the child stdin.
@external(erlang, "client_codex_bridge_ffi", "port_send")
pub fn port_send(port: Port, json: String) -> Result(Nil, Nil)

/// Normalizes an OTP port mailbox message to a typed event.
@external(erlang, "client_codex_bridge_ffi", "port_event")
pub fn port_event(message: Dynamic) -> PortEvent

/// Claims the one live bridge actor for a profile without making atoms from
/// profile text. OTP ETS is required for a VM-wide compare-and-insert.
@external(erlang, "client_codex_bridge_ffi", "claim")
pub fn claim(profile: String, subject: Subject(message)) -> Result(Nil, String)

/// Looks up the live profile actor. Dead entries are removed by the shim.
@external(erlang, "client_codex_bridge_ffi", "lookup")
pub fn lookup(profile: String) -> Result(Subject(message), String)
