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
import weft/actor

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
  let caller = process.self()
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
    start_safely(fn() { start_owned_socket(builder, inbox, caller) }),
  )
  use owner <- result.try(
    process.subject_owner(started)
    |> result.replace_error("the websocket actor exited during startup"),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error("the websocket actor exited during startup")
  })
  process.send(inbox, Connected)
  Ok(Connection(started))
}

// The socket may fail abnormally on an ordinary TCP disconnect. Its link
// ends here, not at the terminal. Monitoring the inbox owner also closes the
// socket if the terminal exits normally, which an ordinary link would ignore.
type LifetimeMessage {
  ReaderGone

  AttemptGone(process.Down)

  LinkedExit(process.ExitMessage)
}

fn start_owned_socket(
  builder: stratus.Builder(Subject(Message), Outbound),
  inbox: Subject(Message),
  caller: process.Pid,
) -> Result(Subject(stratus.InternalMessage(Outbound)), String) {
  use reader <- result.try(
    process.subject_owner(inbox)
    |> result.replace_error("the connection inbox has no owner"),
  )

  // Keep blocking network startup in the untrapped worker. Its deadline
  // kills the socket immediately instead of queuing cancellation behind a
  // guardian initializer that is still waiting for the handshake.
  use socket <- result.try(
    stratus.start(builder)
    |> result.map_error(string.inspect),
  )
  use _guardian <- result.try(
    actor.new_with_initialiser(1000, fn(_subject) {
      let reader_monitor = process.monitor(reader)
      let attempt_monitor = process.monitor(caller)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(reader_monitor, fn(_) { ReaderGone })
        |> process.select_specific_monitor(attempt_monitor, AttemptGone)
        |> process.select_trapped_exits(LinkedExit)

      // Both owners retain links until the guardian acknowledges this start.
      // There is no interval in which cancellation leaves the socket unowned.
      use Nil <- result.try(case process.link(socket.pid) {
        True -> Ok(Nil)
        False -> Error("the websocket exited before guardian adoption")
      })
      actor.initialised(socket.pid)
      |> actor.selecting(selector)
      |> actor.returning(socket.data)
      |> Ok
    })
    |> actor.trapping_exits(True)
    |> actor.on_message(fn(socket, message) {
      case message {
        ReaderGone -> actor.stop()
        AttemptGone(process.ProcessDown(reason: process.Normal, ..)) ->
          actor.continue(socket)
        AttemptGone(_) -> actor.stop()
        LinkedExit(process.ExitMessage(pid:, reason:)) ->
          socket_exit(socket, pid, reason, inbox)
      }
    })
    |> actor.on_shutdown(fn(socket, _reason) { process.kill(socket) })
    |> actor.start
    |> result.map_error(string.inspect),
  )
  process.unlink(socket.pid)
  Ok(socket.data)
}

fn socket_exit(
  socket: process.Pid,
  exited: process.Pid,
  reason: process.ExitReason,
  inbox: Subject(Message),
) -> actor.Next(process.Pid, LifetimeMessage) {
  case exited == socket, reason {
    True, process.Normal -> actor.stop()
    True, reason -> {
      process.send(inbox, Closed(string.inspect(reason)))
      actor.stop()
    }

    // The guarded startup worker exits normally after returning the handle.
    // Cancellation is abnormal and must still close a half-started socket.
    False, process.Normal -> actor.continue(socket)
    False, process.Killed | False, process.Abnormal(_) -> actor.stop()
  }
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

    // Only a managed task can lose or leave unconfirmed a drain proof,
    // and this run carries none; the arms are exhaustiveness, not cases.
    [weft.DrainProofLost(..)] | [weft.CancellationUnconfirmed(..)] ->
      Error("websocket startup produced no account")
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

/// Checks that a replacement websocket actor is still available.
///
/// Session resolution opens replacement sockets in an unlinked worker. The
/// terminal checks the successful actor before replacing the active socket.
/// Its guardian already monitors the terminal-owned inbox, so no direct
/// socket link or unowned handoff window is needed.
///
/// ## Examples
///
/// ```gleam
/// connection.adopt(socket)
/// ```
pub fn adopt(connection: Connection) -> Result(Nil, String) {
  let Connection(subject) = connection
  use owner <- result.try(
    process.subject_owner(subject)
    |> result.replace_error("the websocket actor exited before adoption"),
  )
  case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error("the websocket actor exited before adoption")
  }
}

/// Names the process that owns a websocket, for lifecycle assertions.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(pid) = connection.owner(socket)
/// ```
@internal
pub fn owner(connection: Connection) -> Result(process.Pid, Nil) {
  let Connection(subject) = connection
  process.subject_owner(subject)
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
