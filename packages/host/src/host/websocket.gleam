//// Shared WebSocket ownership for terminal and command-line clients.
////
//// Stratus owns the socket; the caller owns its inbox. The existing Weft
//// startup scope and guardian preserve reader and attempt lifetime separately.
//// Event mapping runs in the existing socket actor, never a forwarding process.
////
//// A reader that sleeps between polls can also ask to be woken. With a
//// `WakeAfter`, the socket actor calls the reader's `notify` after it files
//// a message in the inbox, so the reader need not poll on a short timeout
//// to notice traffic. The wake is sent by the same process that sent the
//// message, after it, so the reader never sees a wake ahead of the message
//// it announces: messages between one pair of processes arrive in the order
//// they were sent. Wakes are paced to one per interval. A delivery inside
//// the interval is not dropped: one wake is scheduled for the interval's
//// end, so every delivered message is followed by a wake within one
//// interval. That bound is the whole contract, and it holds without the
//// reader telling the socket anything back.

import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/result
import gleam/string
import host/bootstrap
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

  /// The pacing interval that held back a wake has ended. Sent by the
  /// actor's own timer, never by a caller.
  WakeDue
}

/// What the socket actor does for its reader after it files a message.
pub type Wake {
  /// Nothing: the reader reads its inbox on its own schedule.
  NoWake

  /// Call `notify` after a message is filed, at most once every
  /// `interval_ms`. A message filed inside the interval is followed by one
  /// call at the interval's end, so none waits longer than `interval_ms`
  /// for its wake. `notify` runs in the socket actor, after the message was
  /// sent, and must not block.
  WakeAfter(notify: fn() -> Nil, interval_ms: Int)
}

/// Where the actor's wake schedule stands.
///
/// There is at most one scheduled wake, so a burst of deliveries costs one
/// timer however long it runs, and the timer is never cancelled, so it can
/// never fire stale: when it fires, a wake is owed.
@internal
pub type Pacing {
  /// No wake is scheduled, and the next may be sent at once from `open_at`.
  Open(open_at: Int)

  /// A delivery landed inside the interval and its wake is scheduled for the
  /// interval's end.
  Scheduled
}

/// What one delivery asks of the wake schedule.
@internal
pub type Pace {
  /// Wake the reader now.
  WakeNow

  /// Schedule one wake this many milliseconds from now.
  WakeIn(delay_ms: Int)

  /// A wake is already scheduled after this delivery; it covers this one.
  Covered
}

// The socket actor's state: the reader's inbox, what to do after a
// delivery, the pacing of the wakes, and the subject its own timer fires on.
type Delivery(event) {
  Delivery(
    inbox: Subject(event),
    wake: Wake,
    pacing: Pacing,
    timer: Subject(Outbound),
  )
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
  connect_waking(address, token, inbox, map, NoWake)
}

/// Maps lifecycle events into a caller-owned inbox, as `connect_mapped`
/// does, and wakes the reader after each message it files as `wake` says.
///
/// ## Examples
///
/// ```gleam
/// // websocket.connect_waking(address, token, inbox, map,
/// //   websocket.WakeAfter(notify: wake_loop, interval_ms: 16))
/// ```
pub fn connect_waking(
  address: String,
  token: String,
  inbox: Subject(event),
  map: fn(Message) -> event,
  wake: Wake,
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
  //
  // The wake timer's subject is created here too, so the actor owns it and
  // Stratus merges it into the selector the actor reads.
  let builder =
    stratus.new_with_initialiser(websocket_request, fn() {
      let timer = process.new_subject()
      let pacing = start_pacing(bootstrap.monotonic_time_ms())
      let delivery = Delivery(inbox:, wake:, pacing:, timer:)
      stratus.initialised(deliver(delivery, map(Connected)))
      |> stratus.selecting(process.new_selector() |> process.select(timer))
      |> Ok
    })
    |> stratus.on_message(fn(delivery, message, socket) {
      case message {
        stratus.Text(text) ->
          stratus.continue(deliver(delivery, map(Incoming(text))))
        stratus.Binary(_) ->
          deliver(
            delivery,
            map(NetworkFault("the gateway sent a binary frame")),
          )
          |> stratus.continue
        stratus.User(SendText(text)) ->
          case stratus.send_text_message(socket, text) {
            Ok(Nil) -> stratus.continue(delivery)
            Error(reason) ->
              deliver(delivery, map(NetworkFault(string.inspect(reason))))
              |> stratus.continue
          }
        stratus.User(Stop) -> {
          let _ = stratus.close(socket, stratus.GoingAway(<<>>))
          stratus.stop()
        }

        // The pacing interval ended with a delivery still unannounced.
        stratus.User(WakeDue) -> stratus.continue(woken(delivery))
      }
    })
    // The actor is ending, so no timer it arms would ever fire: the close
    // is announced at once, whatever the pacing says.
    |> stratus.on_close(fn(delivery, reason) {
      process.send(delivery.inbox, map(Closed(string.inspect(reason))))
      notify(delivery.wake)
    })
  use started <- result.try(
    start_safely(fn() { start_owned_socket(builder, inbox, caller, map, wake) }),
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

// Files one message in the reader's inbox and then, if the reader asked to
// be woken, wakes it or schedules the wake the pacing allows. The send comes
// first: a wake must never reach the reader ahead of what it announces.
fn deliver(delivery: Delivery(event), message: event) -> Delivery(event) {
  process.send(delivery.inbox, message)
  case delivery.wake {
    NoWake -> delivery
    WakeAfter(interval_ms:, ..) ->
      case pace(delivery.pacing, bootstrap.monotonic_time_ms(), interval_ms) {
        #(pacing, WakeNow) -> {
          notify(delivery.wake)
          Delivery(..delivery, pacing:)
        }
        #(pacing, WakeIn(delay_ms:)) -> {
          process.send_after(delivery.timer, delay_ms, WakeDue)
          Delivery(..delivery, pacing:)
        }
        #(pacing, Covered) -> Delivery(..delivery, pacing:)
      }
  }
}

// The scheduled wake: it announces every delivery since the last one, and
// opens the next interval from now.
fn woken(delivery: Delivery(event)) -> Delivery(event) {
  case delivery.wake {
    NoWake -> delivery
    WakeAfter(interval_ms:, ..) -> {
      notify(delivery.wake)
      let open_at = bootstrap.monotonic_time_ms() + interval_ms
      Delivery(..delivery, pacing: Open(open_at))
    }
  }
}

fn notify(wake: Wake) -> Nil {
  case wake {
    NoWake -> Nil
    WakeAfter(notify:, ..) -> notify()
  }
}

/// The wake schedule of a socket that has sent no wake yet, at the monotonic
/// reading `now`: its first delivery wakes the reader at once.
///
/// The schedule opens at the actor's own first reading rather than at zero,
/// because the BEAM's monotonic clock starts at an arbitrary offset that is
/// negative on this platform. A schedule that opened at zero would hold the
/// first wake for as long as that offset, which is days, and cover every
/// delivery after it.
///
/// ## Examples
///
/// ```gleam
/// assert websocket.start_pacing(-5000) == websocket.Open(-5000)
/// ```
@internal
pub fn start_pacing(now: Int) -> Pacing {
  Open(open_at: now)
}

/// Decides what one delivery at `now` does to the wake schedule.
///
/// Outside the interval the reader is woken at once and the next interval
/// opens `interval_ms` later. Inside it, the first delivery schedules one
/// wake for the interval's end and later ones are covered by it. Every
/// delivery is therefore followed by a wake no later than `interval_ms`
/// after it, and no two wakes are closer than `interval_ms`.
///
/// ## Examples
///
/// ```gleam
/// assert websocket.pace(websocket.Open(0), 100, 16)
///   == #(websocket.Open(116), websocket.WakeNow)
/// assert websocket.pace(websocket.Open(116), 105, 16)
///   == #(websocket.Scheduled, websocket.WakeIn(11))
/// assert websocket.pace(websocket.Scheduled, 110, 16)
///   == #(websocket.Scheduled, websocket.Covered)
/// ```
@internal
pub fn pace(pacing: Pacing, now: Int, interval_ms: Int) -> #(Pacing, Pace) {
  case pacing {
    Open(open_at:) if now >= open_at -> #(Open(now + interval_ms), WakeNow)
    Open(open_at:) -> #(Scheduled, WakeIn(open_at - now))
    Scheduled -> #(Scheduled, Covered)
  }
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
  builder: stratus.Builder(Delivery(event), Outbound),
  inbox: Subject(event),
  caller: process.Pid,
  map: fn(Message) -> event,
  wake: Wake,
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
          socket_exit(socket, pid, reason, inbox, map, wake)
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
  wake: Wake,
) -> actor.Next(process.Pid, LifetimeMessage) {
  case exited == socket, reason {
    True, process.Normal -> actor.stop()

    // The guardian is a second sender, so its close carries its own wake,
    // sent after it. The socket that paced the other wakes is gone.
    True, reason -> {
      process.send(inbox, map(Closed(string.inspect(reason))))
      notify(wake)
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
