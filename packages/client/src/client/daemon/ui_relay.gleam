//// The web view's stand-in for a session socket: one process per page that
//// attaches to the session's gateway and carries the lane's frames
//// (protocol-change/051, "The relay").
////
//// A terminal reaches the gateway through `session_socket`, a mist process
//// that writes the gateway's replies and pushes to a TCP socket. A page's
//// lane runs inside a Lustre component in this same VM, so there is no
//// socket to write to. The relay does the socket process's other job:
//// it holds the authenticated attachment, turns each frame the lane
//// transmits into one bounded `gateway.connection_request`, and hands the
//// reply to the component as `connection_event.Incoming`. A frame the
//// gateway pushes arrives on the attachment's sink and goes to the component
//// the same way. One mailbox serializes both, so a reply and a push never
//// interleave, as in `session_socket`.
////
//// The relay attaches with its own pid as the attachment's `socket`, so the
//// gateway monitors the relay: when the relay exits, however it exits, the
//// gateway drops the attachment and its presence.
////
//// ## Read-only by role
////
//// Whatever the principal's membership says, the relay's binding carries
//// `Participant(Observer)`, and its `check` caps every answer to the same.
//// The gateway refuses every command outside its read-only list for an
//// observer, so a mutation frame from this relay is refused by the daemon
//// however the frame was produced. When a later phase lets an operator act
//// from the page, it removes the cap wholesale, so the membership record
//// stays the only source of a person's role.
////
//// ## How it ends
////
//// Four ways, each leaving no process and no presence:
////
//// - `shut`: the lane closed its socket. The relay detaches and exits.
//// - The component exits (the browser went away and the page's socket shut
////   it down). The relay monitors it, detaches and exits.
//// - The gateway exits (the session stopped or the daemon is shutting
////   down). The relay monitors the gateway's pid, reports the end so the
////   page's socket closes, and exits.
//// - The gateway closes the attachment (a check refused it, for example on
////   revocation). The attachment's `close` reaches the relay, which reports
////   the end so the page's socket closes, and exits.
////
//// Backpressure is the terminal socket's: this mailbox and the component's
//// are unbounded, and what bounds a slow browser is the page socket's TCP
//// writes.

import client/gateway
import gleam/erlang/process.{type Subject}
import gleam/otp/actor as otp_actor
import gleam/result
import session_view/connection_event
import storage/access
import weft/actor

/// What the relay needs to attach: the gateway, the binding, and the
/// capabilities the gateway calls back into.
pub type Attach {
  Attach(
    /// The session's gateway, resolved from the resident instance.
    hub: gateway.Gateway,
    /// The attachment's identity. Its authority is replaced by observer.
    binding: gateway.Binding,
    /// Re-authorizes the attachment. The relay caps its answer to observer.
    check: fn() -> Result(#(access.Principal, access.Authority), String),
    /// Asks the registry to stop an incarnation whose reader failed.
    failed_reader: fn() -> Nil,
  )
}

/// A running relay.
pub opaque type Relay {
  Relay(subject: Subject(Message))
}

type Message {
  // One frame the lane transmitted.
  Transmit(frame: String)

  // The lane closed its socket.
  Shut

  // One frame the gateway pushed; the sink runs on the hub process and only
  // hands it over, because the sink must not block.
  Push(frame: String)

  // The gateway's flush marker, acknowledged once earlier pushes are out.
  Flush(reply: Subject(Nil))

  // The gateway closed the attachment.
  Closed

  GatewayDown(process.Down)
  ComponentDown(process.Down)
}

type State {
  State(
    connection: gateway.ConnectionHandle,
    inbox: Subject(connection_event.Message),
    ended: fn(String) -> Nil,
  )
}

/// Starts a relay for the calling process, which it monitors as the
/// component, delivering every frame to `inbox`. `ended` is called when the
/// gateway ends the attachment, so the page's socket can close.
///
/// ## Examples
///
/// ```gleam
/// // ui_relay.start(attach, inbox, fn(reason) { close_page(reason) })
/// ```
pub fn start(
  attach: Attach,
  inbox: Subject(connection_event.Message),
  ended: fn(String) -> Nil,
) -> Result(Relay, String) {
  let component = process.self()
  actor.new_with_initialiser(7000, fn(subject) {
    // The attach runs here, in the relay's own process, so the pid the
    // gateway monitors as the attachment's socket is the relay's.
    let observer = access.Participant(access.Observer)
    use connection <- result.try(gateway.attach_authenticated_flushing(
      attach.hub,
      gateway.Binding(..attach.binding, authority: observer),
      fn() {
        attach.check()
        |> result.map(fn(answer) { #(answer.0, observer) })
      },
      fn(frame) { process.send(subject, Push(frame)) },
      fn() { process.send(subject, Closed) },
      attach.failed_reader,
      fn(reply) { process.send(subject, Flush(reply)) },
      process.self(),
    ))
    let component_watch = process.monitor(component)
    let gateway_watch = process.monitor(gateway.connection_pid(connection))
    actor.initialised(State(connection:, inbox:, ended:))
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(component_watch, ComponentDown)
      |> process.select_specific_monitor(gateway_watch, GatewayDown),
    )
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Relay(started.data) })
  |> result.map_error(fn(error) {
    case error {
      otp_actor.InitFailed(reason) -> reason
      otp_actor.InitTimeout | otp_actor.InitExited(_) ->
        "the session's gateway did not admit the page"
    }
  })
}

/// Writes one frame for the lane.
///
/// ## Examples
///
/// ```gleam
/// // ui_relay.transmit(relay, frame)
/// ```
pub fn transmit(relay: Relay, frame: String) -> Nil {
  process.send(relay.subject, Transmit(frame))
}

/// Closes the lane's socket: the relay detaches and exits.
///
/// ## Examples
///
/// ```gleam
/// // ui_relay.shut(relay)
/// ```
pub fn shut(relay: Relay) -> Nil {
  process.send(relay.subject, Shut)
}

/// The relay's pid, for a test that watches it exit.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(ui_relay.pid(relay))
/// ```
@internal
pub fn pid(relay: Relay) -> Result(process.Pid, Nil) {
  process.subject_owner(relay.subject)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    // One request at a time, as a terminal socket admits them. A missing
    // reply is an unknown outcome, so the relay ends rather than retrying.
    Transmit(frame:) ->
      case gateway.connection_request(state.connection, frame) {
        Ok(reply) -> {
          process.send(state.inbox, connection_event.Incoming(reply))
          actor.continue(state)
        }
        Error(reason) -> end(state, reason)
      }

    Push(frame:) -> {
      process.send(state.inbox, connection_event.Incoming(frame))
      actor.continue(state)
    }

    Flush(reply:) -> {
      process.send(reply, Nil)
      actor.continue(state)
    }

    // The two ends that come from the page's side: the lane closed, or the
    // component is gone. Nothing needs telling; the relay detaches and
    // exits.
    Shut | ComponentDown(_) -> {
      gateway.connection_detach(state.connection)
      actor.stop()
    }

    // The two ends that come from the gateway's side. The page's socket is
    // told, so it closes and shuts the component down.
    GatewayDown(_) -> end(state, "the session ended")
    Closed -> end(state, "access was revoked")
  }
}

fn end(state: State, reason: String) -> actor.Next(State, Message) {
  process.send(state.inbox, connection_event.Closed(reason))
  state.ended(reason)
  gateway.connection_detach(state.connection)
  actor.stop()
}
