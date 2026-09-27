//// Terminal event names over the shared host WebSocket transport.
////
//// The shared transport owns startup, socket custody, and reader monitoring.
//// Mapping events happens in that existing owner; this adapter adds no process.
//// The events themselves are data in `session_view/connection_event`, so the code
//// that reduces them never imports the transport.
////
//// A session socket also wakes the loop that reads it (`connect_waking`).
//// The terminal's loop sleeps in etui's input wait between ticks, and a
//// frame filed in its inbox does not end that wait by itself; only a
//// keypress or the poll timeout does. So after the socket actor files a
//// frame it sends etui's wake to the process that owns the inbox, which is
//// the loop, and the loop ticks and drains. The wakes are paced at the
//// sender to one per `wake_interval_ms`, the shortest gap between two
//// painted frames, and a frame filed inside that interval gets one wake
//// at its end (`websocket.WakeAfter`). A burst of frames therefore wakes
//// the loop about once a frame, each wake reaches the loop after the frames
//// it announces, and no frame waits longer than one interval for a wake.

import gleam/erlang/process.{type Subject}
import gleam/result
import host/websocket
import session_view/connection_event.{
  type Message, Closed, Connected, Incoming, NetworkFault,
}
import tui/internal/ffi_terminal

/// A shared socket handle with the original reader's lifetime.
pub type Connection =
  websocket.Connection

/// The shortest gap between two wakes a session socket sends its loop, in
/// milliseconds.
///
/// It is `pacing.frame_interval_ms`, the shortest gap between two painted
/// frames: waking the loop more often than it may paint would only run
/// ticks whose frame is deferred. The value is repeated rather than
/// imported because `tui/pacing` sits above this module in the import
/// graph, and `connection_test` holds the two equal.
pub const wake_interval_ms = 16

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
  // Stratus exposes a refused upgrade through this startup diagnostic, not
  // its HTTP response body. Translate only the known admission status; other
  // transport and authentication failures retain their original meaning.
  websocket.connect_mapped(address, token, inbox, terminal_event)
  |> result.map_error(admission_notice)
}

fn admission_notice(reason: String) -> String {
  case reason {
    "InitFailed(\"WebSocket handshake failed with status 503\")" ->
      "daemon connection admission unavailable (503). Retry, or close another terminal / raise [daemon] max_connections or max_reserved_message_bytes and restart."
    _ -> reason
  }
}

/// Opens a session socket whose frames also wake the loop that owns
/// `inbox`, as the module header describes.
///
/// Only a socket whose inbox the etui loop reads should wake: the wake is a
/// message for etui's input wait, and any other owner would never read it.
/// The daemon's control connection and the bootstrap probe use `connect`.
///
/// ## Examples
///
/// ```gleam
/// connection.connect_waking(address, token, frames)
/// ```
pub fn connect_waking(
  address: String,
  token: String,
  inbox: Subject(Message),
) -> Result(Connection, String) {
  use owner <- result.try(
    process.subject_owner(inbox)
    |> result.replace_error("the connection inbox has no owner"),
  )
  let wake =
    websocket.WakeAfter(
      notify: fn() { ffi_terminal.wake_loop(owner) },
      interval_ms: wake_interval_ms,
    )
  websocket.connect_waking(address, token, inbox, terminal_event, wake)
  |> result.map_error(admission_notice)
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

/// Receives one queued event from a raw inbox subject without blocking.
///
/// The terminal's step never calls this: it reads `Model.inbox` through
/// `tui/buffered`, whose held messages are older than anything this would
/// return. It is for a subject nothing has buffered, such as a test's
/// frames subject before a `Prepared` names it.
///
/// ## Examples
///
/// ```gleam
/// connection.receive(inbox)
/// ```
pub fn receive(inbox: Subject(Message)) -> Result(Message, Nil) {
  process.receive(inbox, 0)
}
