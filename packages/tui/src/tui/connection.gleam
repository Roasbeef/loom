//// A websocket actor for the terminal client.
////
//// The actor owns the socket. The terminal process owns an inbox and drains
//// it on etui ticks, so network traffic never blocks keyboard polling and
//// the view remains a pure function of the current model.

import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/result
import gleam/string
import stratus
import weft

type Outbound {
  SendText(String)
  Stop
}

/// A connected websocket actor.
pub opaque type Connection {
  Connection(Subject(stratus.InternalMessage(Outbound)))
}

/// One connection lifecycle message for the terminal process.
pub type Message {
  /// The socket actor completed its handshake and can accept commands.
  Connected

  /// A text frame arrived from the ClientGateway.
  Incoming(
    /// The undecoded wire payload.
    text: String,
  )

  /// The peer or local actor closed the websocket.
  Closed(
    /// The backend's diagnostic close reason.
    reason: String,
  )

  /// The socket remained alive long enough to report an I/O violation.
  NetworkFault(
    /// The backend's diagnostic failure reason.
    reason: String,
  )
}

/// Creates the inbox the terminal process will own.
///
/// ## Examples
///
/// ```gleam
/// let inbox = connection.new_inbox()
/// ```
pub fn new_inbox() -> Subject(Message) {
  process.new_subject()
}

/// Opens a websocket and starts its socket-owning actor.
///
/// The returned handle never exposes the socket itself. All reads cross the
/// terminal-owned inbox, and all writes cross the actor mailbox, preserving
/// one owner for websocket lifecycle state.
///
/// ## Examples
///
/// ```gleam
/// let inbox = connection.new_inbox()
/// let result = connection.connect("ws://127.0.0.1:8080/v1/ws", "token", inbox)
/// ```
pub fn connect(
  address: String,
  token: String,
  inbox: Subject(Message),
) -> Result(Connection, String) {
  use websocket_request <- result.try(
    request.to(http_address(address))
    |> result.replace_error("the websocket address is invalid"),
  )
  let websocket_request = case token {
    "" -> websocket_request
    value ->
      request.set_header(websocket_request, "authorization", "Bearer " <> value)
  }
  let builder =
    stratus.new(websocket_request, inbox)
    |> stratus.on_message(fn(inbox, message, socket) {
      case message {
        stratus.Text(text) -> {
          process.send(inbox, Incoming(text))
          stratus.continue(inbox)
        }
        stratus.Binary(_) -> {
          process.send(inbox, NetworkFault("the gateway sent a binary frame"))
          stratus.continue(inbox)
        }
        stratus.User(SendText(text)) -> {
          let _ = case stratus.send_text_message(socket, text) {
            Ok(Nil) -> Nil
            Error(reason) ->
              process.send(inbox, NetworkFault(string.inspect(reason)))
          }
          stratus.continue(inbox)
        }
        stratus.User(Stop) -> {
          let _ = stratus.close(socket, stratus.GoingAway(<<>>))
          stratus.stop()
        }
      }
    })
    |> stratus.on_close(fn(inbox, reason) {
      process.send(inbox, Closed(string.inspect(reason)))
    })
  use started <- result.try(
    start_safely(fn() {
      stratus.start(builder)
      |> result.map_error(fn(error) { string.inspect(error) })
    }),
  )
  use owner <- result.try(
    process.subject_owner(started.data)
    |> result.replace_error("the websocket actor exited during startup"),
  )
  use Nil <- result.try(case process.link(owner) {
    True -> Ok(Nil)
    False -> Error("the websocket actor exited during startup")
  })
  process.send(inbox, Connected)
  Ok(Connection(started.data))
}

/// Runs connection startup outside the terminal process.
///
/// A websocket dependency is allowed to return an ordinary error, but a bug
/// in its actor initialiser must not take the interactive terminal down. The
/// child is unlinked and monitored so both outcomes become typed data.
@internal
pub fn start_safely(start: fn() -> Result(a, String)) -> Result(a, String) {
  start_safely_within(start, 5000)
}

/// Runs guarded startup with an explicit deadline for deterministic tests.
///
/// The spawn/monitor/kill scaffolding this once hand-rolled is weft's whole
/// job: the worker links to weft's scope rather than to this process, so an
/// initialiser crash still cannot reach the terminal, and the deadline both
/// answers the caller and reaps the worker. The websocket actor the closure
/// starts survives its worker's normal exit exactly as before — a normal
/// exit signal does not propagate over its link — and a timed-out worker's
/// kill still takes the half-started actor down with it.
@internal
pub fn start_safely_within(
  start: fn() -> Result(a, String),
  within_ms: Int,
) -> Result(a, String) {
  let outcomes =
    weft.new([start])
    |> weft.deadline(within_ms)
    |> weft.start

  // A one-task run yields exactly one outcome; the impossible shapes are
  // still answered rather than asserted away, because a wrong account from
  // the engine should refuse the connection, not take the terminal down.
  case outcomes {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(reason:, ..)] ->
      Error("websocket startup crashed: " <> string.inspect(reason))
    [weft.Abandoned(..)] -> Error("websocket startup timed out")
    [weft.NeverStarted(..)] -> Error("websocket startup timed out")
    [] | [_, _, ..] -> Error("websocket startup produced no account")
  }
}

/// Sends one text frame without blocking the terminal process on socket I/O.
///
/// ## Examples
///
/// ```gleam
/// connection.send(socket, "{\"v\":1}")
/// ```
pub fn send(connection: Connection, text: String) -> Nil {
  let Connection(subject) = connection
  process.send(subject, stratus.to_user_message(SendText(text)))
}

/// Requests a graceful websocket close.
///
/// ## Examples
///
/// ```gleam
/// connection.close(socket)
/// ```
pub fn close(connection: Connection) -> Nil {
  let Connection(subject) = connection
  process.send(subject, stratus.to_user_message(Stop))
}

/// Receives one queued connection message, if one is ready.
///
/// ## Examples
///
/// ```gleam
/// let next = connection.receive(inbox)
/// ```
pub fn receive(inbox: Subject(Message)) -> Result(Message, Nil) {
  process.receive(inbox, 0)
}

fn http_address(address: String) -> String {
  case address {
    "ws://" <> rest -> "http://" <> rest
    "wss://" <> rest -> "https://" <> rest
    other -> other
  }
}
