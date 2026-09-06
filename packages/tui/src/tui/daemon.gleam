//// An authenticated control connection with one bounded outstanding request.
////
//// The state machine owns the inbox from socket startup through hello and all
//// later replies. The existing connection guardian therefore follows the same
//// owner throughout handshake; no worker-owned inbox escapes into the terminal.
//// A separate monitor closes this owner when its terminal exits, even normally.
//// Requests are never retried here. Losing a mutation reply leaves its outcome
//// unknown, not cancelled. Callers reconcile metadata or explicitly retry a
//// create with its original durable key before deciding what to do next.
//// An in-flight deadline retires this control owner, so a blocked socket writer
//// cannot accumulate another request after each caller timeout.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap
import tui/connection
import tui/daemon/protocol
import weft/state_machine as sm

/// A control owner and the authenticated identity established by its hello.
pub opaque type Connection {
  Connection(
    /// The state machine's bounded request interface.
    commands: Subject(Message),
    /// The original control owner, retained for monitoring.
    pid: process.Pid,
    /// Verified before returning this handle.
    hello: protocol.Hello,
  )
}

/// Failures distinguish known non-admission from an uncertain mutation result.
pub type Failure {
  /// Input was rejected locally, before a socket write was requested.
  Invalid(
    /// Fixed local diagnostic without supplied credentials or request bodies.
    reason: String,
  )

  /// The peer did not establish an authenticated hello within the budget.
  HandshakeFailed

  /// Another request already owns this connection's single response slot.
  Busy

  /// A read did not complete within its deadline.
  TimedOut

  /// The peer or control owner disappeared before a read completed.
  Disconnected

  /// The authenticated peer refused the correlated request.
  Refused(
    /// Stable server refusal category.
    code: String,
    /// Bounded peer diagnostic, not terminal-safe presentation text.
    message: String,
  )

  /// A mutation may have been admitted; only its command name is retained.
  UnknownOutcome(
    /// Command name only, never its secret or filesystem arguments.
    command: String,
  )
}

type Phase {
  AwaitHello
  Idle
  Waiting
}

type Pending {
  Pending(
    id: Int,
    command: protocol.Command,
    reply: Subject(Result(protocol.Reply, Failure)),
  )
}

type Data {
  Data(
    socket: connection.Connection,
    hello_reply: Subject(Result(protocol.Hello, Failure)),
    hello: Option(protocol.Hello),
    next_id: Int,
    pending: Option(Pending),
    handshake_ms: Int,
  )
}

type Message {
  Wire(connection.Message)
  Request(
    protocol.Command,
    deadline: Int,
    reply: Subject(Result(protocol.Reply, Failure)),
  )
  Deadline
  OwnerGone
  Close
}

/// Opens control and verifies hello without opening any session.
///
/// `owner` is the terminal lifetime, not a short-lived bootstrap worker. This
/// function may run in that worker while the returned connection remains owned
/// by the terminal. The budget includes socket startup and authenticated hello.
///
/// ## Examples
///
/// ```gleam
/// let control = daemon.connect(address, token, process.self(), 5000)
/// ```
pub fn connect(
  address: String,
  token: String,
  owner: process.Pid,
  within_ms: Int,
) -> Result(Connection, Failure) {
  use Nil <- result.try(valid_budget(within_ms))
  use Nil <- result.try(valid_address(address))
  let deadline = bootstrap.monotonic_time_ms() + within_ms
  let hello_reply = process.new_subject()
  use started <- result.try(
    sm.new_with_initialiser(within_ms, fn(subject) {
      let inbox = connection.new_inbox()
      let owner_watch = process.monitor(owner)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(inbox, Wire)
        |> process.select_specific_monitor(owner_watch, fn(_) { OwnerGone })
      use socket <- result.try(connection.connect(address, token, inbox))
      let data = Data(socket, hello_reply, None, 1, None, remaining(deadline))
      sm.initialised(AwaitHello, data)
      |> sm.selecting(selector)
      |> sm.returning(subject)
      |> Ok
    })
    |> sm.on_enter(fn(_, phase, data) {
      case phase {
        AwaitHello ->
          sm.keep(data)
          |> sm.with_state_timeout(after: data.handshake_ms, sending: Deadline)
        Idle | Waiting -> sm.keep(data)
      }
    })
    |> sm.on_event(handle)
    |> sm.unlinked
    |> sm.start
    |> result.replace_error(HandshakeFailed),
  )
  let response = process.receive(hello_reply, remaining(deadline) + 100)
  case response {
    Ok(Ok(hello)) -> Ok(Connection(started.data, started.pid, hello))
    Ok(Error(failure)) -> Error(failure)
    Error(Nil) -> {
      sm.send(started.data, Close)
      Error(HandshakeFailed)
    }
  }
}

/// Returns the verified daemon epoch, principal, and control limit.
///
/// ## Examples
///
/// ```gleam
/// let epoch = daemon.hello(control).epoch
/// ```
pub fn hello(control: Connection) -> protocol.Hello {
  control.hello
}

/// Sends exactly once and awaits the correlated response within a deadline.
///
/// A second simultaneous request receives Busy without entering a hidden queue.
/// An in-flight timeout closes this control owner. An explicit replacement has
/// a new inbox, so an old reply cannot reach it even if request IDs coincide.
/// Lifecycle commands take their epoch from the authenticated hello.
///
/// ## Examples
///
/// ```gleam
/// let status = daemon.request(control, protocol.Status, 1000)
/// ```
pub fn request(
  control: Connection,
  command: protocol.Command,
  within_ms: Int,
) -> Result(protocol.Reply, Failure) {
  use Nil <- result.try(valid_budget(within_ms))
  let replies = process.new_subject()
  let watch = process.monitor(control.pid)
  sm.send(
    control.commands,
    Request(command, bootstrap.monotonic_time_ms() + within_ms, replies),
  )
  let selector =
    process.new_selector()
    |> process.select_map(replies, fn(reply) { reply })
    |> process.select_specific_monitor(watch, fn(_) {
      Error(lost(command, Disconnected))
    })
  let answer = process.selector_receive(selector, within_ms + 100)
  process.demonitor_process(watch)
  case answer {
    Ok(reply) -> reply
    Error(Nil) -> Error(lost(command, TimedOut))
  }
}

/// Closes this control owner; it does not stop the daemon or any session.
///
/// ## Examples
///
/// ```gleam
/// daemon.close(control)
/// ```
pub fn close(control: Connection) -> Nil {
  sm.send(control.commands, Close)
}

/// Exposes only the owner PID for lifecycle integration assertions.
///
/// ## Examples
///
/// ```gleam
/// let watch = process.monitor(daemon.owner(control))
/// ```
@internal
pub fn owner(control: Connection) -> process.Pid {
  control.pid
}

fn handle(
  phase: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Message) {
  case message {
    OwnerGone | Close -> finish(phase, data, Disconnected)
    Wire(connection.Closed(_)) | Wire(connection.NetworkFault(_)) ->
      finish(phase, data, Disconnected)
    Wire(connection.Connected) -> sm.keep(data)
    Wire(connection.Incoming(text)) -> receive(phase, data, text)
    Deadline ->
      case phase {
        AwaitHello -> finish(phase, data, HandshakeFailed)
        Waiting -> finish(phase, data, TimedOut)
        Idle -> sm.keep(data)
      }
    Request(command, deadline, reply) ->
      case phase {
        AwaitHello | Waiting -> {
          process.send(reply, Error(Busy))
          sm.keep(data)
        }
        Idle -> begin(data, command, deadline, reply)
      }
  }
}

fn begin(data: Data, command: protocol.Command, deadline: Int, reply) {
  let prepared = {
    use hello <- result.try(case data.hello {
      Some(hello) -> Ok(hello)
      None -> Error("missing hello")
    })
    use text <- result.try(protocol.encode(data.next_id, command, hello.epoch))
    case string.byte_size(text) <= hello.control_bytes {
      True -> Ok(text)
      False -> Error("request exceeds advertised control limit")
    }
  }
  case prepared, remaining(deadline) {
    Error(reason), _ -> {
      process.send(reply, Error(Invalid(reason)))
      sm.keep(data)
    }
    Ok(_), 0 -> {
      process.send(reply, Error(TimedOut))
      sm.keep(data)
    }
    Ok(text), budget -> {
      connection.send(data.socket, text)
      sm.transition(
        Waiting,
        Data(
          ..data,
          next_id: data.next_id + 1,
          pending: Some(Pending(data.next_id, command, reply)),
        ),
      )
      |> sm.with_state_timeout(after: budget, sending: Deadline)
    }
  }
}

fn receive(phase: Phase, data: Data, text: String) {
  case protocol.decode(text) {
    Error(_) -> finish(phase, data, Disconnected)
    Ok(protocol.Greeting(hello)) ->
      case phase {
        AwaitHello -> {
          process.send(data.hello_reply, Ok(hello))
          sm.transition(Idle, Data(..data, hello: Some(hello)))
        }
        Idle | Waiting -> finish(phase, data, Disconnected)
      }
    Ok(event) ->
      case phase {
        AwaitHello -> finish(phase, data, HandshakeFailed)
        Idle -> sm.keep(data)
        Waiting -> answer(data, event)
      }
  }
}

fn answer(data: Data, event: protocol.Event) {
  case data.pending, event {
    Some(pending), protocol.Answer(id, name, reply) if id == pending.id -> {
      case name == protocol.name(pending.command) && same_epoch(data, reply) {
        True -> {
          process.send(pending.reply, Ok(reply))
          sm.transition(Idle, Data(..data, pending: None))
        }
        False -> finish(Waiting, data, Disconnected)
      }
    }
    Some(pending), protocol.Refused(Some(id), code, message)
      if id == pending.id
    -> {
      process.send(pending.reply, Error(Refused(code, message)))
      sm.transition(Idle, Data(..data, pending: None))
    }

    // A duplicate or unrelated reply never owns the current request's slot.
    Some(_), protocol.Answer(..)
    | Some(_), protocol.Refused(..)
    | Some(_), protocol.Greeting(_)
    | None, _
    -> sm.keep(data)
  }
}

fn finish(phase: Phase, data: Data, failure: Failure) {
  case phase {
    AwaitHello -> process.send(data.hello_reply, Error(HandshakeFailed))
    Waiting -> reply_lost(data, failure)
    Idle -> Nil
  }
  connection.close(data.socket)
  sm.stop()
}

fn reply_lost(data: Data, failure: Failure) {
  case data.pending {
    Some(pending) ->
      process.send(pending.reply, Error(lost(pending.command, failure)))
    None -> Nil
  }
}

// A status reply cannot silently replace the authenticated hello's lifetime.
// Reconnecting constructs a new control owner and exposes a new Hello instead.
fn same_epoch(data: Data, reply: protocol.Reply) {
  case reply, data.hello {
    protocol.StatusReply(summary), Some(hello) -> summary.epoch == hello.epoch
    protocol.StatusReply(_), None -> False
    protocol.SessionsReply(_), _
    | protocol.SessionReply(_), _
    | protocol.LifecycleReply(_), _
    | protocol.ShutdownReply, _
    -> True
  }
}

fn lost(command: protocol.Command, failure: Failure) {
  case protocol.mutates(command) {
    True -> UnknownOutcome(protocol.name(command))
    False -> failure
  }
}

fn valid_budget(within_ms: Int) {
  case within_ms > 0 && within_ms <= 90_000 {
    True -> Ok(Nil)
    False -> Error(Invalid("deadline must be between 1 and 90000 milliseconds"))
  }
}

fn remaining(deadline: Int) {
  int.max(0, deadline - bootstrap.monotonic_time_ms())
}

/// Accepts a control address only when its credentials stay off the network.
///
/// Credentials may cross cleartext TCP only to literal loopback addresses.
/// Validation precedes the existing transport's authorization-header creation.
/// It is exposed to the suite because the decision is a pure string judgement
/// that would otherwise only be observable behind a real socket connect.
///
/// ## Examples
///
/// ```gleam
/// // daemon.valid_address("ws://[::1]:8080/v2/control") -> Ok(Nil)
/// ```
@internal
pub fn valid_address(address: String) {
  use endpoint <- result.try(
    uri.parse(address)
    |> result.replace_error(Invalid("invalid control address")),
  )
  use Nil <- result.try(case endpoint {
    uri.Uri(
      path: "/v2/control",
      userinfo: None,
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error(Invalid("expected an unqualified /v2/control endpoint"))
  })

  // `uri.parse` keeps an IPv6 literal's brackets in `host`, so the bracketed
  // form is the one a parsed `ws://[::1]:PORT/v2/control` actually presents.
  // The bare form is matched as well because a caller may hand this function
  // a host it assembled itself rather than one it parsed back out of a URI.
  case endpoint.scheme, endpoint.host {
    Some("wss"), Some(host) if host != "" -> Ok(Nil)
    Some("ws"), Some("127.0.0.1")
    | Some("ws"), Some("[::1]")
    | Some("ws"), Some("::1")
    -> Ok(Nil)
    _, _ -> Error(Invalid("remote control requires TLS"))
  }
}
