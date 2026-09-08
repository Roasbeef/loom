//// Explicit lifecycle selection over an already authenticated daemon control.
////
//// Listing never calls this module's open path. An operator action sends open
//// once, then observes only the returned operation within the same epoch.
//// Losing admission's reply is reported as an unknown outcome, never retried.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import tui/attachment
import tui/daemon
import tui/daemon/protocol
import tui/snapshot
import tui/workspace
import weft/poll

/// One control connection and its conversation routing authority.
pub opaque type Host {
  Host(control: daemon.Connection, address: uri.Uri, token: String)
}

/// Retains the authenticated control and canonical route, not a session socket.
///
/// ## Examples
///
/// ```gleam
/// // selection.host(control, "ws://127.0.0.1:8080/v2/control", token)
/// ```
pub fn host(
  control: daemon.Connection,
  address: String,
  token: String,
) -> Result(Host, String) {
  use address <- result.try(
    uri.parse(address) |> result.replace_error("invalid daemon address"),
  )
  Ok(Host(control, address, token))
}

/// Returns the control owner for metadata requests and terminal shutdown.
///
/// ## Examples
///
/// ```gleam
/// // daemon.close(selection.control(host))
/// ```
pub fn control(host: Host) -> daemon.Connection {
  host.control
}

/// Builds a second control owner on this host's own route and credential.
///
/// A control request that times out retires its owner: `daemon.finish` closes
/// the socket and stops the machine so a stalled writer cannot accumulate
/// requests, and a late reply is delivered to an inbox nobody reads. That
/// ruling is what makes a lost reply safe. What it leaves behind is a route
/// whose owner is gone, and the route is the durable half — so it, not the
/// connection, is what the terminal keeps and what mints the replacement. The
/// new owner is a new state machine with a new inbox, so a reply owed to the
/// retired owner can never be mistaken for an answer to a later request.
///
/// This is not automatic reconnection: the caller decides when a control
/// action is worth a new connection, and pays the handshake for it there.
///
/// ## Examples
///
/// ```gleam
/// // selection.reconnect(host, process.self())
/// ```
pub fn reconnect(host: Host, owner: process.Pid) -> Result(Host, String) {
  use control <- result.map(
    daemon.connect(uri.to_string(host.address), host.token, owner, 5000)
    |> result.map_error(failure),
  )
  Host(..host, control:)
}

/// Borrows live control or owns a replacement for one explicit worker action.
///
/// Call this inside the action's managed worker, never from the frame loop.
/// A replacement monitors that worker, so cancellation closes even a socket
/// still waiting for hello. Normal completion closes it here. The terminal
/// retains the route, not this temporary owner, and no failed action is retried.
///
/// ## Examples
///
/// ```gleam
/// // selection.with_live_control(host, fn(host) { selection.open(host, id) })
/// ```
pub fn with_live_control(
  host: Host,
  action: fn(Host) -> Result(a, String),
) -> Result(a, String) {
  case process.is_alive(daemon.owner(host.control)) {
    True -> action(host)
    False -> {
      use replacement <- result.try(reconnect(host, process.self()))
      let outcome = action(replacement)
      daemon.close(replacement.control)
      outcome
    }
  }
}

/// Sends one explicit open and waits only on its returned operation.
///
/// The caller supplies a surrounding Weft deadline covering this request and
/// the later initial snapshot. This function never reconnects control.
///
/// ## Examples
///
/// ```gleam
/// // selection.open(host, selected_id)
/// ```
pub fn open(host: Host, session: String) -> Result(attachment.Target, String) {
  use selected <- result.try(
    daemon.request(host.control, protocol.GetSession(session), 5000)
    |> result.map_error(failure)
    |> result.try(selected_row),
  )
  case selected.status {
    // An observer may attach to an already resident session without asking
    // for execution authority. Saved sessions still require explicit open.
    protocol.Resident(_) ->
      target(host, session, selected.workspace, None, selected.status)

    // No database was ever established under this identity, so asking the
    // daemon to open it can only earn a `not_initialized` refusal. Say what
    // the row is instead of relaying that code back to the operator.
    protocol.Reserved ->
      Error(
        "this session was reserved but never initialized; "
        <> "retry its creation instead of opening it",
      )

    protocol.Saved
    | protocol.Opening(_)
    | protocol.Stopping(_)
    | protocol.RecoveryBlocked -> open_selected(host, selected)
  }
}

fn open_selected(host: Host, selected: protocol.Session) {
  use reply <- result.try(
    daemon.request(
      host.control,
      protocol.OpenSession(selected.session_id),
      10_000,
    )
    |> result.map_error(failure),
  )
  use status <- result.try(case reply {
    protocol.LifecycleReply(status) -> Ok(status)
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.SessionReply(_)
    | protocol.ShutdownReply ->
      Error("open returned an unexpected control reply")
  })
  target(host, selected.session_id, selected.workspace, None, status)
}

/// Creates with a name derived from the terminal's cached workspace context.
///
/// Naming is metadata supplied with the original admission, not a later
/// rename or an inference request. A lost reply retains the same creation key.
///
/// ## Examples
///
/// ```gleam
/// // selection.create_named(host, key, project.path, workspace.session_name(project), config)
/// ```
pub fn create_named(
  host: Host,
  key: String,
  workspace: String,
  name: String,
  configuration: String,
) -> Result(attachment.Target, String) {
  use reply <- result.try(
    daemon.request(
      host.control,
      protocol.CreateSession(key, workspace, name, configuration),
      10_000,
    )
    |> result.map_error(failure),
  )
  case reply {
    protocol.SessionReply(row) ->
      target(host, row.session_id, row.workspace, Some(key), row.status)
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.LifecycleReply(_)
    | protocol.ShutdownReply ->
      Error("create returned an unexpected control reply")
  }
}

fn target(host: Host, session, workspace, creation_key, status) {
  use incarnation <- result.try(case status {
    protocol.Resident(incarnation) -> Ok(incarnation)
    protocol.Opening(operation) -> await(host, session, operation)
    protocol.Reserved
    | protocol.Saved
    | protocol.Stopping(_)
    | protocol.RecoveryBlocked ->
      Error("selected session is not available for attachment")
  })
  let epoch = daemon.hello(host.control).epoch.value
  let address =
    uri.Uri(
      ..host.address,
      path: "/v2/sessions/" <> session <> "/ws",
      query: None,
      fragment: None,
    )
  Ok(attachment.Target(
    uri.to_string(address),
    host.token,
    snapshot.Expected(session, epoch, incarnation),
    workspace.Context(..workspace.discover_from(workspace), path: workspace),
    creation_key,
  ))
}

fn selected_row(reply) {
  case reply {
    protocol.SessionReply(row) -> Ok(row)
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.LifecycleReply(_)
    | protocol.ShutdownReply ->
      Error("selection returned an unexpected control reply")
  }
}

fn await(host: Host, session, operation) {
  let epoch = daemon.hello(host.control).epoch
  case
    poll.until(within: 60_000, every: 50, attempt: fn() {
      case
        daemon.request(
          host.control,
          protocol.GetOperation(session, operation, epoch),
          2000,
        )
      {
        Error(reason) -> poll.Fail(failure(reason))
        Ok(protocol.SessionReply(row)) ->
          case row.status {
            protocol.Resident(incarnation) -> poll.Done(incarnation)
            protocol.Opening(_) -> poll.Retry
            protocol.Reserved
            | protocol.Saved
            | protocol.Stopping(_)
            | protocol.RecoveryBlocked ->
              poll.Fail(
                "session startup did not produce an attachable incarnation",
              )
          }
        Ok(protocol.StatusReply(_))
        | Ok(protocol.SessionsReply(_))
        | Ok(protocol.LifecycleReply(_))
        | Ok(protocol.ShutdownReply) ->
          poll.Fail("operation returned an unexpected control reply")
      }
    })
  {
    poll.Answered(incarnation) -> Ok(incarnation)
    poll.Failed(reason) -> Error(reason)
    poll.Expired ->
      Error("session startup remains incomplete; no open was retried")
  }
}

/// Formats bounded control failures without credentials or request bodies.
///
/// ## Examples
///
/// ```gleam
/// assert selection.failure(daemon.Busy) == "daemon control is busy"
/// ```
pub fn failure(reason: daemon.Failure) -> String {
  case reason {
    daemon.Invalid(reason) -> reason
    daemon.HandshakeFailed -> "daemon authentication did not complete"
    daemon.Busy -> "daemon control is busy"
    daemon.TimedOut -> "daemon control timed out; reconnect explicitly"
    daemon.Disconnected -> "daemon control disconnected; reconnect explicitly"

    // The daemon admitted this open and its builder then failed. The cause is
    // classified into the daemon log rather than sent here, because it can
    // name the session's own path; the terminal says where to read it.
    daemon.Refused("start_failed", _) ->
      "session startup failed; the daemon log records the cause under "
      <> "daemon.session_start_failed"

    daemon.Refused(code, message) -> code <> ": " <> message
    daemon.UnknownOutcome(command) ->
      "unknown outcome for " <> command <> "; request was not retried"
  }
}

/// Builds the sole control route for an explicit remote launch.
///
/// ## Examples
///
/// ```gleam
/// assert selection.control_address("ws://localhost:8080/v2/sessions/id/ws")
///   == Ok("ws://localhost:8080/v2/control")
/// ```
pub fn control_address(address: String) -> Result(String, String) {
  use parsed <- result.try(
    uri.parse(address) |> result.replace_error("invalid daemon address"),
  )
  case parsed.path {
    "/v1/ws" -> Error("gateway v1 is not supported; use the daemon v2 endpoint")
    _ ->
      Ok(uri.to_string(
        uri.Uri(..parsed, path: "/v2/control", query: None, fragment: None),
      ))
  }
}
