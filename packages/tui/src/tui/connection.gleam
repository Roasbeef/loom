//// Terminal event names over the shared host WebSocket transport.
////
//// The shared transport owns startup, socket custody, and reader monitoring.
//// Mapping events happens in that existing owner; this adapter adds no process.

import gleam/erlang/process.{type Subject}
import host/websocket

/// A shared socket handle with the original reader's lifetime.
pub type Connection =
  websocket.Connection

/// One connection lifecycle message for the terminal process.
pub type Message {
  /// The socket actor completed its handshake and can accept commands.
  Connected

  /// A text frame arrived from the gateway.
  Incoming(
    /// The undecoded wire payload.
    text: String,
  )

  /// The peer or local actor closed the websocket.
  Closed(
    /// The backend's diagnostic close reason.
    reason: String,
  )

  /// The transport reported an I/O violation.
  NetworkFault(
    /// The backend's diagnostic failure reason.
    reason: String,
  )
}

/// Creates the inbox owned by the calling terminal.
///
/// ## Examples
///
/// ```gleam
/// let inbox = connection.new_inbox()
/// ```
pub fn new_inbox() -> Subject(Message) {
  process.new_subject()
}

/// Opens the shared transport with terminal-specific event names.
///
/// ## Examples
///
/// ```gleam
/// connection.connect("ws://127.0.0.1:8080/v2/control", token, inbox)
/// ```
pub fn connect(
  address: String,
  token: String,
  inbox: Subject(Message),
) -> Result(Connection, String) {
  websocket.connect_mapped(address, token, inbox, terminal_event)
}

fn terminal_event(event: websocket.Message) -> Message {
  case event {
    websocket.Connected -> Connected
    websocket.Incoming(text) -> Incoming(text)
    websocket.Closed(reason) -> Closed(reason)
    websocket.NetworkFault(reason) -> NetworkFault(reason)
  }
}

/// Runs guarded startup without linking failures to the terminal.
///
/// ## Examples
///
/// ```gleam
/// connection.start_safely(start)
/// ```
@internal
pub fn start_safely(start: fn() -> Result(a, String)) -> Result(a, String) {
  websocket.start_safely(start)
}

/// Runs guarded startup with an explicit test deadline.
///
/// ## Examples
///
/// ```gleam
/// connection.start_safely_within(start, 100)
/// ```
@internal
pub fn start_safely_within(
  start: fn() -> Result(a, String),
  within_ms: Int,
) -> Result(a, String) {
  websocket.start_safely_within(start, within_ms)
}

/// Sends one frame through the existing socket owner.
///
/// ## Examples
///
/// ```gleam
/// connection.send(socket, text)
/// ```
pub fn send(connection: Connection, text: String) -> Nil {
  websocket.send(connection, text)
}

/// Requests graceful closure through the existing owner.
///
/// ## Examples
///
/// ```gleam
/// connection.close(socket)
/// ```
pub fn close(connection: Connection) -> Nil {
  websocket.close(connection)
}

/// Checks a replacement handle before terminal adoption.
///
/// ## Examples
///
/// ```gleam
/// connection.adopt(socket)
/// ```
pub fn adopt(connection: Connection) -> Result(Nil, String) {
  websocket.adopt(connection)
}

/// Returns the original socket PID for lifecycle assertions.
///
/// ## Examples
///
/// ```gleam
/// connection.owner(socket)
/// ```
@internal
pub fn owner(connection: Connection) -> Result(process.Pid, Nil) {
  websocket.owner(connection)
}

/// Receives one queued event without blocking the terminal.
///
/// ## Examples
///
/// ```gleam
/// connection.receive(inbox)
/// ```
pub fn receive(inbox: Subject(Message)) -> Result(Message, Nil) {
  process.receive(inbox, 0)
}
