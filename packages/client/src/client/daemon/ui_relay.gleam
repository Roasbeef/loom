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
//// ## The page's role
////
//// The page acts with the smallest of the principal's membership role, the
//// ceiling its link was minted with, and Operator (`capped`;
//// protocol-change/051, the operator addendum). The binding the relay
//// attaches with carries that role, and its `check` answers with the same
//// minimum of the current record, so the gateway's equality check closes the
//// attachment the moment the capped role changes. An observer's page is
//// therefore an observer's attachment, refused every mutation by the
//// gateway; no page ever carries `Owner`.
////
//// ## Opening without blocking
////
//// The relay is started from inside the component's own start, which Lustre
//// bounds at one second, and the gateway's attach can take longer. So
//// `start` returns as soon as the relay's process exists, and the attach runs
//// as the relay's first message: the outcome is sent to the `opened` subject
//// the component selects, `Ok` with the relay's handle or `Error` with why the
//// gateway refused it.
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
//// The reason it reports is one of `web_view/ending`'s fixed strings, so the
//// component draws a closed reason class and the page's socket picks the
//// close code from it. The gateway does not say why it closed an attachment,
//// so the relay asks the attachment's own check once more: a UI session that
//// is gone is `PageEnded` (its eight
//// hours ran out), and any other refusal, or a role that changed, is
//// `AccessRevoked`. The gateway exiting, or closing while the check still
//// passes unchanged, is `SessionStopped`. A refused attach is reported the same way,
//// as `NotOpen` unless the check named the page's end, and it also tells the
//// page's socket, which closes with a code the client retries.
////
//// Backpressure is the terminal socket's: this mailbox and the component's
//// are unbounded, and what bounds a slow browser is the page socket's TCP
//// writes.

import client/daemon/upgrade_log
import client/gateway
import gleam/erlang/process.{type Pid, type Subject}
import gleam/result
import session_view/connection_event
import storage/access
import web_view/ending.{type Ending}
import weft/actor

/// What the relay needs to attach: the gateway, the binding, the page's
/// ceiling, and the capabilities the gateway calls back into.
pub type Attach {
  Attach(
    /// The session's gateway, resolved from the resident instance.
    hub: gateway.Gateway,
    /// The attachment's identity, with the membership authority the page
    /// was admitted under. The relay caps it with `ceiling`.
    binding: gateway.Binding,
    /// Re-authorizes the attachment against the membership record. The
    /// relay caps its answer with `ceiling`.
    check: fn() -> Result(#(access.Principal, access.Authority), String),
    /// The most the page may do, from its UI session.
    ceiling: access.Role,
    /// Asks the registry to stop an incarnation whose reader failed.
    failed_reader: fn() -> Nil,
  )
}

/// A running relay.
pub opaque type Relay {
  Relay(subject: Subject(Message))
}

type Message {
  // The relay's first message: attach to the gateway now, in the relay's own
  // process, so the gateway monitors the relay as the attachment's socket.
  Attaching

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

// Before the attach, the relay holds what it needs to attach and to answer
// the component; after it, the attachment it carries frames over.
type State {
  Waiting(
    attach: Attach,
    self: Subject(Message),
    component: process.Monitor,
    inbox: Subject(connection_event.Message),
    opened: Subject(Result(Relay, String)),
    ended: fn(Ending) -> Nil,
  )
  State(
    connection: gateway.ConnectionHandle,
    inbox: Subject(connection_event.Message),
    ended: fn(Ending) -> Nil,
    check: fn() -> Result(#(access.Principal, access.Authority), String),
    // The authority the attach was made with, already capped, and the cap.
    // A close whose re-check still passes is a role change only if the
    // capped authority now differs from this one.
    held: access.Authority,
    ceiling: access.Role,
  )
}

/// The authority a page acts with: the smallest of the membership
/// `authority`, the page's `ceiling`, and Operator.
///
/// The ceiling caps and never grants, so an observer asking for an
/// operator's page gets an observer's; and no page carries `Owner`, whose
/// one power in a session beyond an operator's is the gateway's worktree read.
/// A page does not go through the gateway for it: the Changes tab is handed a
/// daemon-run observation under an admission of its own
/// (`ui_socket.worktree_answer`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_relay.capped(access.Owner, access.Operator)
///   == access.Participant(access.Operator)
/// ```
pub fn capped(
  authority: access.Authority,
  ceiling: access.Role,
) -> access.Authority {
  case authority, ceiling {
    _, access.Observer -> access.Participant(access.Observer)
    access.Participant(access.Observer), access.Operator ->
      access.Participant(access.Observer)
    access.Owner, access.Operator
    | access.Participant(access.Operator), access.Operator
    -> access.Participant(access.Operator)
  }
}

/// A page's authorization: `check`, refused once `open` says the page's UI
/// session has ended.
///
/// The gateway calls the result at every request and every push, so a UI
/// session that expires or is replaced while the page is open ends the
/// attachment at the next frame, through the same `close` a revocation
/// takes.
///
/// ## Examples
///
/// ```gleam
/// // ui_relay.while_open(authorize, ui_sessions.still_open(tables, cookie, grant))
/// ```
pub fn while_open(
  check: fn() -> Result(answer, String),
  open: fn() -> Result(Nil, Nil),
) -> fn() -> Result(answer, String) {
  fn() {
    case open() {
      Ok(Nil) -> check()
      Error(Nil) -> Error(ending.reason(ending.PageEnded))
    }
  }
}

/// Starts a relay for the page's `component` and returns at once. Every
/// frame goes to `inbox`; the attach's outcome goes to `opened`, once: the
/// relay's handle, or why the gateway refused it. `ended` is called when
/// the gateway ends the attachment, so the page's socket can close.
///
/// ## Examples
///
/// ```gleam
/// // ui_relay.start(attach, inbox, process.self(), opened, close_page)
/// ```
pub fn start(
  attach: Attach,
  inbox: Subject(connection_event.Message),
  component: Pid,
  opened: Subject(Result(Relay, String)),
  ended: fn(Ending) -> Nil,
) -> Nil {
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      let watch = process.monitor(component)

      // The attach is the first message, so it runs after this initialiser
      // has returned and the component's start is not held by it.
      process.send(subject, Attaching)
      actor.initialised(Waiting(attach, subject, watch, inbox, opened, ended))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_specific_monitor(watch, ComponentDown),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  case started {
    Ok(_) -> Nil

    // No relay means no attach, which is the daemon's failure and not the
    // person's: the socket closes with a code the client retries.
    Error(_) -> {
      process.send(opened, Error("the page's relay did not start"))
      ended(ending.DaemonNotReady)
    }
  }
}

// Attaches in the relay's own process, so the pid the gateway monitors as
// the attachment's socket is the relay's. The binding and every later check
// carry the capped role.
fn attached(state: State) -> actor.Next(State, Message) {
  case state {
    State(..) -> actor.continue(state)
    Waiting(attach:, self:, component:, inbox:, opened:, ended:) -> {
      let authority = capped(attach.binding.authority, attach.ceiling)
      let connection =
        gateway.attach_authenticated_flushing(
          attach.hub,
          gateway.Binding(..attach.binding, authority:),
          fn() {
            attach.check()
            |> result.map(fn(answer) {
              #(answer.0, capped(answer.1, attach.ceiling))
            })
          },
          fn(frame) { process.send(self, Push(frame)) },
          fn() { process.send(self, Closed) },
          attach.failed_reader,
          fn(reply) { process.send(self, Flush(reply)) },
          process.self(),
        )
      case connection {
        // The gateway refused the attach. The page is told the ending, not
        // the gateway's words, both through `opened`, which the component
        // draws, and through `ended`, which closes the page's socket with
        // the code that ending calls for.
        Error(reason) -> {
          upgrade_log.refused(upgrade_log.Page, "attach", reason)
          let why = ending.from_reason(reason, otherwise: ending.NotOpen)
          process.send(opened, Error(ending.reason(why)))
          ended(why)
          actor.stop()
        }
        Ok(connection) -> {
          let gateway_watch =
            process.monitor(gateway.connection_pid(connection))
          process.send(opened, Ok(Relay(self)))
          actor.continue(State(
            connection:,
            inbox:,
            ended:,
            check: attach.check,
            held: authority,
            ceiling: attach.ceiling,
          ))
          |> actor.with_selector(
            process.new_selector()
            |> process.select(self)
            |> process.select_specific_monitor(component, ComponentDown)
            |> process.select_specific_monitor(gateway_watch, GatewayDown),
          )
        }
      }
    }
  }
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
  case state, message {
    _, Attaching -> attached(state)

    // Nothing but the component's end or its own shut can reach a relay that
    // has not attached: the component holds no handle until `opened` says
    // the attach succeeded, and the gateway knows no relay before it.
    Waiting(..), Shut | Waiting(..), ComponentDown(_) -> actor.stop()
    Waiting(..), Transmit(_)
    | Waiting(..), Push(_)
    | Waiting(..), Flush(_)
    | Waiting(..), Closed
    | Waiting(..), GatewayDown(_)
    -> actor.continue(state)

    // One request at a time, as a terminal socket admits them. A missing
    // reply is an unknown outcome, so the relay ends rather than retrying.
    State(connection:, inbox:, ..), Transmit(frame:) ->
      case gateway.connection_request(connection, frame) {
        Ok(reply) -> {
          process.send(inbox, connection_event.Incoming(reply))
          actor.continue(state)
        }
        Error(_) ->
          end(state, diagnosed(state, unchanged: ending.ConnectionFailed))
      }

    State(inbox:, ..), Push(frame:) -> {
      process.send(inbox, connection_event.Incoming(frame))
      actor.continue(state)
    }

    State(..), Flush(reply:) -> {
      process.send(reply, Nil)
      actor.continue(state)
    }

    // The two ends that come from the page's side: the lane closed, or the
    // component is gone. Nothing needs telling; the relay detaches and
    // exits.
    State(connection:, ..), Shut | State(connection:, ..), ComponentDown(_) -> {
      gateway.connection_detach(connection)
      actor.stop()
    }

    // The two ends that come from the gateway's side. The page's socket is
    // told, so it closes and shuts the component down.
    State(..), GatewayDown(_) -> end(state, ending.SessionStopped)
    State(..), Closed ->
      end(state, diagnosed(state, unchanged: ending.SessionStopped))
  }
}

// Why the gateway ended the attachment. It ended it because the attachment's
// `check` refused, and the gateway does not say what the check said, so the
// relay asks again. A UI session that is gone answers with the page's own
// ending, and any other refusal (a credential that no longer authenticates,
// a membership that is gone) is a revoked access. A check that still passes
// with a different capped authority is a role change, also revoked access.
// One that passes with the authority the attach held means the gateway closed
// for a reason of its own (its snapshot reader failed and the incarnation is
// stopping), or the request failed for another reason, and `unchanged` says
// which the caller saw. The check reads the page's authorization and changes
// nothing, and this runs once, as the relay ends.
fn diagnosed(state: State, unchanged unchanged: Ending) -> Ending {
  case state {
    Waiting(..) -> unchanged
    State(check:, held:, ceiling:, ..) ->
      case check() {
        Error(reason) ->
          ending.from_reason(reason, otherwise: ending.AccessRevoked)
        Ok(#(_, current)) ->
          case capped(current, ceiling) == held {
            True -> unchanged
            False -> ending.AccessRevoked
          }
      }
  }
}

// The relay's last message to the page, in the reason string the session
// engine carries and the page's component reads back as the same ending.
fn end(state: State, why: Ending) -> actor.Next(State, Message) {
  case state {
    Waiting(..) -> actor.stop()
    State(connection:, inbox:, ended:, ..) -> {
      process.send(inbox, connection_event.Closed(ending.reason(why)))
      ended(why)
      gateway.connection_detach(connection)
      actor.stop()
    }
  }
}
