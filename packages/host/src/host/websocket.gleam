//// Shared WebSocket ownership for terminal and command-line clients.
////
//// Stratus owns the socket; the caller owns its inbox. The existing Weft
//// startup scope and guardian preserve reader and attempt lifetime separately.
//// Event mapping runs in the existing socket actor, never a forwarding process.

import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/result
import gleam/string
import stratus
import weft
import weft/actor

/// A command for the socket actor, carried as a Stratus user message.
///
/// These never reach the caller's inbox: they travel the other way, from a
/// caller that must not block on socket I/O into the process that owns it.
type Outbound {
  /// Write one text frame; an I/O failure becomes a `NetworkFault` notice.
  SendText(String)

  /// Close the websocket gracefully and stop the socket actor.
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
/// let inbox = websocket.new_inbox()
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
/// let inbox = websocket.new_inbox()
/// let result = websocket.connect("ws://127.0.0.1:8080/v2/control", "token", inbox)
/// ```
pub fn connect(
  address: String,
  token: String,
  inbox: Subject(Message),
) -> Result(Connection, String) {
  connect_mapped(address, token, inbox, fn(event) { event })
}

/// Maps shared lifecycle events into a caller-owned inbox without a new process.
///
/// ## Examples
///
/// ```gleam
/// // websocket.connect_mapped(address, token, inbox, terminal_event)
/// ```
pub fn connect_mapped(
  address: String,
  token: String,
  inbox: Subject(event),
  map: fn(Message) -> event,
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

  // `Connected` is minted inside the socket actor's own initialiser, which
  // Stratus runs after the upgrade and before the actor's first loop pass.
  // Sending it from here instead would let a gateway that pushes a snapshot
  // on connect, or a peer that closes at once, land an `Incoming` or `Closed`
  // in the inbox first: `stratus.start` returns only after the handshake, so
  // the socket actor is already delivering by the time this function resumes.
  let builder =
    stratus.new_with_initialiser(websocket_request, fn() {
      process.send(inbox, map(Connected))
      Ok(stratus.initialised(inbox))
    })
    |> stratus.on_message(fn(inbox, message, socket) {
      case message {
        stratus.Text(text) -> {
          process.send(inbox, map(Incoming(text)))
          stratus.continue(inbox)
        }
        stratus.Binary(_) -> {
          process.send(
            inbox,
            map(NetworkFault("the gateway sent a binary frame")),
          )
          stratus.continue(inbox)
        }
        stratus.User(SendText(text)) -> {
          let _ = case stratus.send_text_message(socket, text) {
            Ok(Nil) -> Nil
            Error(reason) ->
              process.send(inbox, map(NetworkFault(string.inspect(reason))))
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
      process.send(inbox, map(Closed(string.inspect(reason))))
    })
  use started <- result.try(
    start_safely(fn() { start_owned_socket(builder, inbox, caller, map) }),
  )
  use owner <- result.try(
    process.subject_owner(started)
    |> result.replace_error("the websocket actor exited during startup"),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error("the websocket actor exited during startup")
  })
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

/// Starts the socket and hands its custody to a guardian without a gap.
///
/// This is the function the module exists for. Three processes are involved:
/// this startup worker `W`, the Stratus socket `S`, and the guardian `G`.
/// `stratus.start` links `S` to `W`; `G` starts linked to `W` and links `S`
/// in its own initialiser; only then does `W` unlink `S`. At every instant
/// between those steps at least one live owner holds a link to `S`, so a
/// cancelled or crashed startup can never leave a socket with a TCP
/// connection and nobody to close it.
///
/// The one exit that used to break that invariant is the guardian failing to
/// start: `W` then returns an error and exits *normally*, and a normal exit
/// over a link is ignored by the non-trapping socket. That path now kills the
/// socket explicitly.
fn start_owned_socket(
  builder: stratus.Builder(Subject(event), Outbound),
  inbox: Subject(event),
  caller: process.Pid,
  map: fn(Message) -> event,
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
          socket_exit(socket, pid, reason, inbox, map)
      }
    })
    |> actor.on_shutdown(fn(socket, _reason) { process.kill(socket) })
    |> actor.start
    |> result.map_error(fn(reason) {
      // The socket outlives this worker's normal exit by design, which is
      // what makes a successful start safe and this failure a leak. Kill it
      // here so the only exit that leaves `S` running is the successful one.
      process.kill(socket.pid)
      string.inspect(reason)
    }),
  )
  process.unlink(socket.pid)
  Ok(socket.data)
}

/// Decides which linked exit ends the socket's custody.
///
/// The guardian traps exits and holds links to two different things, so this
/// is where their meanings are separated. An exit from the socket itself ends
/// the guardian either way, and an abnormal one is also the caller's close
/// notice. An exit from anything else is the startup worker: its normal exit
/// is the successful handoff and must be ignored, while cancellation or a
/// crash arrives abnormally and must still take a half-started socket down.
fn socket_exit(
  socket: process.Pid,
  exited: process.Pid,
  reason: process.ExitReason,
  inbox: Subject(event),
  map: fn(Message) -> event,
) -> actor.Next(process.Pid, LifetimeMessage) {
  case exited == socket, reason {
    True, process.Normal -> actor.stop()
    True, reason -> {
      process.send(inbox, map(Closed(string.inspect(reason))))
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
///
/// ## Examples
///
/// ```gleam
/// // websocket.start_safely(fn() { start_owned_socket(builder, inbox, caller, map) })
/// ```
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
///
/// ## Examples
///
/// ```gleam
/// // websocket.start_safely_within(fn() { Error("no") }, 50)
/// ```
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
/// websocket.send(socket, text)
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
/// websocket.close(socket)
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
/// websocket.adopt(socket)
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
/// let assert Ok(pid) = websocket.owner(socket)
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
/// let next = websocket.receive(inbox)
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
