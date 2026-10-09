//// Explicit lifecycle selection over an already authenticated daemon control.
////
//// Listing never calls this module's open path. An operator action sends open
//// once, then observes only the returned operation within the same epoch.
//// Losing admission's reply is reported as an unknown outcome, never retried.

import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap as host_bootstrap
import host/endpoint as daemon_endpoint
import session_view/snapshot
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/workspace
import weft/poll

/// One control connection and its conversation routing authority.
pub opaque type Host {
  Host(control: daemon.Connection, address: uri.Uri, token: String)
}

/// Authenticated selection resolved by explicit control open, never by
/// listing. The attachment job's worker connects to it and publishes the
/// socket, with the identity the terminal checks before adoption.
pub type Target {
  Target(
    /// V2 conversation route for exactly the selected session.
    address: String,
    /// Bearer credential, never included in diagnostics.
    token: String,
    /// Expected session, daemon epoch and runtime incarnation.
    expected: snapshot.Expected,
    /// Canonical workspace returned by the authorized catalogue record.
    workspace: workspace.Context,
    /// Display name from the authorized catalogue, adopted with this identity.
    session_name: String,
    /// Only successful adoption of this creation may clear its retained key.
    creation_key: Option(String),
  )
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

/// Re-resolves the shared daemon and authenticates one control owner on its
/// new route.
///
/// This is what `reconnect` cannot do. That function mints a replacement owner
/// for a route the terminal already holds, which is right for a control request
/// whose own connection retired and useless when the daemon itself is gone: the
/// recorded route answers nothing, and no amount of reconnecting revives it.
/// Resolving again is what starts whichever daemon binary is now installed — the
/// installed launcher selects a fresh immutable tree at the same public
/// path — and the fresh endpoint record names the port and fence that new VM
/// actually published.
///
/// The resolved control belongs to the terminal PID, so a terminal that exits
/// during the attempt still closes it, and one attempt starts at most one
/// daemon because resolution holds the launch lock.
///
/// ## Examples
///
/// ```gleam
/// // selection.relaunch(options, process.self(), 90_000)
/// ```
pub fn relaunch(
  options: bootstrap.Options,
  owner: process.Pid,
  within_ms: Int,
) -> Result(Host, String) {
  use connected <- result.try(bootstrap.reconnect_daemon(
    options,
    owner,
    within_ms,
  ))
  use address <- result.try(daemon_endpoint.address(connected.record))
  use token <- result.try(
    host_bootstrap.read_private_bounded(connected.paths.token, 65)
    |> result.map_error(fn(reason) { "owner credential: " <> reason }),
  )
  use token <- result.try(
    bit_array.to_string(token)
    |> result.replace_error("invalid owner credential encoding"),
  )
  host(connected.control, address, string.trim(token))
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
pub fn open(host: Host, session: String) -> Result(Target, String) {
  use selected <- result.try(
    daemon.request(host.control, protocol.GetSession(session), 5000)
    |> result.map_error(failure_for(session, _))
    |> result.try(selected_row),
  )
  case selected.status {
    // An observer may attach to an already resident session without asking
    // for execution authority. Saved sessions still require explicit open.
    protocol.Resident(_) ->
      target(
        host,
        session,
        selected.workspace,
        selected.executor,
        selected.name,
        None,
        selected.status,
      )

    // No database was ever established under this identity, so asking the
    // daemon to open it can only earn a `not_initialized` refusal. Say what
    // the row is instead of relaying that code back to the operator.
    protocol.Reserved ->
      Error(
        "this session was reserved but never initialized; "
        <> "retry its creation or delete it instead of opening it",
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
    | protocol.DeletedReply(_)
    | protocol.MovedReply(..)
    | protocol.ShutdownReply
    | protocol.PeersInspectionReply(_)
    | protocol.PeersMutationReply(_)
    | protocol.AccessListingReply(_)
    | protocol.AccessChangeReply(_)
    | protocol.ActivityReply(_)
    | protocol.UiLinkReply(..) ->
      Error("open returned an unexpected control reply")
  })
  target(
    host,
    selected.session_id,
    selected.workspace,
    selected.executor,
    selected.name,
    None,
    status,
  )
}

/// Creates with a name derived from the terminal's cached workspace context.
///
/// Naming is metadata supplied with the original admission, not a later
/// rename or an inference request. A lost reply retains the same creation key.
///
/// ## Examples
///
/// ```gleam
/// // selection.create_named(host, key, project.path, workspace.session_name(project), config, "", "", "")
/// ```
pub fn create_named(
  host: Host,
  key: String,
  workspace: String,
  name: String,
  configuration: String,
  profile: String,
  executor: String,
  pool: String,
) -> Result(Target, String) {
  use reply <- result.try(
    daemon.request(
      host.control,
      protocol.CreateSession(
        key,
        workspace,
        name,
        configuration,
        profile,
        executor,
        pool,
      ),
      10_000,
    )
    |> result.map_error(failure),
  )
  case reply {
    protocol.SessionReply(row) ->
      target(
        host,
        row.session_id,
        row.workspace,
        row.executor,
        row.name,
        Some(key),
        row.status,
      )
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.LifecycleReply(_)
    | protocol.DeletedReply(_)
    | protocol.MovedReply(..)
    | protocol.ShutdownReply
    | protocol.PeersInspectionReply(_)
    | protocol.PeersMutationReply(_)
    | protocol.AccessListingReply(_)
    | protocol.AccessChangeReply(_)
    | protocol.ActivityReply(_)
    | protocol.UiLinkReply(..) ->
      Error("create returned an unexpected control reply")
  }
}

/// Stops one selected session, waits for retirement, then removes its files.
///
/// The picker has already confirmed this exact identity. Stop and delete are
/// each sent once. A lost reply, unproven drain, or concurrent reopen keeps the
/// registration rather than retrying a destructive command.
///
/// ## Examples
///
/// ```gleam
/// // selection.delete(host, selected_id)
/// ```
pub fn delete(host: Host, session: String) -> Result(String, String) {
  delete_using(session, fn(command, within) {
    daemon.request(host.control, command, within) |> result.map_error(failure)
  })
}

/// Runs the confirmed lifecycle through the same bounded request seam in tests.
///
/// ## Examples
///
/// ```gleam
/// // selection.delete_using(selected_id, request)
/// ```
@internal
pub fn delete_using(
  session: String,
  request: fn(protocol.Command, Int) -> Result(protocol.Reply, String),
) -> Result(String, String) {
  remove_using(session, EraseHistory, request)
}

// The mutation is selected before stopping. A timeout never changes an archive
// into a delete or resends either mutation after an unknown outcome.
type Removal {
  KeepHistory
  EraseHistory
}

/// Stops and archives one session while retaining all conversation files.
///
/// ## Examples
///
/// ```gleam
/// // selection.archive(host, selected_id)
/// ```
pub fn archive(host: Host, session: String) -> Result(String, String) {
  archive_using(session, fn(command, within) {
    daemon.request(host.control, command, within) |> result.map_error(failure)
  })
}

/// Exercises the archive lifecycle through the production bounded request seam.
///
/// ## Examples
///
/// ```gleam
/// // selection.archive_using(selected_id, request)
/// ```
@internal
pub fn archive_using(
  session: String,
  request: fn(protocol.Command, Int) -> Result(protocol.Reply, String),
) -> Result(String, String) {
  remove_using(session, KeepHistory, request)
}

/// Hands a session to another orchestrator and answers once the daemon has
/// accepted the move (protocol-change/078, phase 5). The daemon carries it to its
/// end, so the answer is the move's identity and destination, not its outcome.
/// Asking again for the same destination answers the same identity.
///
/// ## Examples
///
/// ```gleam
/// // selection.move(host, selected_id, "laptop")
/// ```
pub fn move(
  host: Host,
  session: String,
  to: String,
) -> Result(#(String, String), String) {
  use reply <- result.try(
    daemon.request(host.control, protocol.MoveSession(session, to), 10_000)
    |> result.map_error(failure_for(session, _)),
  )
  case reply {
    protocol.MovedReply(session_id, op, destination) if session_id == session ->
      Ok(#(op, destination))
    _ -> Error("move returned an unexpected control reply")
  }
}

/// Restores metadata without opening or selecting the session as a default.
///
/// ## Examples
///
/// ```gleam
/// // selection.restore(host, selected_id)
/// ```
pub fn restore(host: Host, session: String) -> Result(String, String) {
  use reply <- result.try(
    daemon.request(host.control, protocol.RestoreSession(session), 10_000)
    |> result.map_error(failure),
  )
  case reply {
    protocol.SessionReply(row) if row.session_id == session -> Ok(session)
    _ -> Error("restore returned an unexpected control reply")
  }
}

fn remove_using(
  session: String,
  removal: Removal,
  request: fn(protocol.Command, Int) -> Result(protocol.Reply, String),
) -> Result(String, String) {
  use stopped <- result.try(request(protocol.StopSession(session), 10_000))
  use status <- result.try(case stopped {
    protocol.LifecycleReply(status) -> Ok(status)
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.SessionReply(_)
    | protocol.DeletedReply(_)
    | protocol.MovedReply(..)
    | protocol.ShutdownReply
    | protocol.PeersInspectionReply(_)
    | protocol.PeersMutationReply(_)
    | protocol.AccessListingReply(_)
    | protocol.AccessChangeReply(_)
    | protocol.ActivityReply(_)
    | protocol.UiLinkReply(..) ->
      Error("stop returned an unexpected control reply; session kept")
  })
  use _ <- result.try(case status {
    protocol.Saved | protocol.Reserved -> Ok(Nil)
    protocol.Stopping(operation) ->
      await_retirement(session, operation, request)
    protocol.RecoveryBlocked -> Error("cleanup is not confirmed; session kept")
    protocol.Resident(_) | protocol.Opening(_) ->
      Error("session did not enter stopping; session kept")
  })
  let command = case removal {
    KeepHistory -> protocol.ArchiveSession(session)
    EraseHistory -> protocol.DeleteSession(session)
  }
  use reply <- result.try(request(command, 10_000))
  case removal, reply {
    KeepHistory, protocol.SessionReply(row) if row.session_id == session ->
      Ok(session)
    EraseHistory, protocol.DeletedReply(id) if id == session -> Ok(id)
    _, _ ->
      Error(case removal {
        KeepHistory -> "archive returned an unexpected control reply"
        EraseHistory -> "delete returned an unexpected control reply"
      })
  }
}

// How long a stop may take to retire before the removal is abandoned.
const retirement_wait_ms = 60_000

// The answer when the retirement wait runs out, between reads or during one.
const still_stopping = "session is still stopping; delete was not sent"

// Each read is given what is left of the retirement wait, as `await` does for
// an open and for the same reason: one slow reply from a loaded daemon must
// not end a wait that still has most of its time left.
fn await_retirement(session, operation, request) {
  let deadline = host_bootstrap.monotonic_time_ms() + retirement_wait_ms

  // GetOperation retires with its slot. GetSession's Saved status is the
  // daemon's positive proof that ordered cleanup released that slot.
  case
    poll.until(within: retirement_wait_ms, every: 50, attempt: fn() {
      let remaining = deadline - host_bootstrap.monotonic_time_ms()
      use <- bool.guard(remaining <= 0, poll.Retry)
      case request(protocol.GetSession(session), remaining) {
        // The seam's errors are already worded, so a read that failed because
        // it used up the wait is told apart by the clock: past the deadline,
        // the failure is the wait running out.
        Error(reason) ->
          case deadline - host_bootstrap.monotonic_time_ms() <= 0 {
            True -> poll.Fail(still_stopping)
            False -> poll.Fail(reason)
          }
        Ok(protocol.SessionReply(row)) if row.session_id == session -> {
          case row.status {
            protocol.Saved | protocol.Reserved -> poll.Done(Nil)
            protocol.Stopping(current) if current == operation -> poll.Retry
            protocol.RecoveryBlocked ->
              poll.Fail("cleanup is not confirmed; session kept")
            protocol.Stopping(_) | protocol.Resident(_) | protocol.Opening(_) ->
              poll.Fail(
                "session lifecycle changed while stopping; session kept",
              )
          }
        }
        Ok(protocol.StatusReply(_))
        | Ok(protocol.SessionsReply(_))
        | Ok(protocol.SessionReply(_))
        | Ok(protocol.LifecycleReply(_))
        | Ok(protocol.DeletedReply(_))
        | Ok(protocol.MovedReply(..))
        | Ok(protocol.ShutdownReply)
        | Ok(protocol.PeersInspectionReply(_))
        | Ok(protocol.PeersMutationReply(_))
        | Ok(protocol.AccessListingReply(_))
        | Ok(protocol.AccessChangeReply(_))
        | Ok(protocol.ActivityReply(_))
        | Ok(protocol.UiLinkReply(..)) ->
          poll.Fail(
            "stop observation returned an unexpected reply; session kept",
          )
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(still_stopping)
  }
}

/// Reads one bounded authorized page for a caller with no terminal open.
///
/// The command-line listing needs exactly this and nothing the picker keeps,
/// so it shares the control host rather than the presentation state.
///
/// ## Examples
///
/// ```gleam
/// // selection.list(host, "")
/// ```
pub fn list(host: Host, after: String) -> Result(protocol.Page, String) {
  use reply <- result.try(
    daemon.request(host.control, protocol.ListSessions(after, None), 5000)
    |> result.map_error(failure),
  )
  case reply {
    protocol.SessionsReply(page) -> Ok(page)
    protocol.StatusReply(_)
    | protocol.SessionReply(_)
    | protocol.LifecycleReply(_)
    | protocol.DeletedReply(_)
    | protocol.MovedReply(..)
    | protocol.ShutdownReply
    | protocol.PeersInspectionReply(_)
    | protocol.PeersMutationReply(_)
    | protocol.AccessListingReply(_)
    | protocol.AccessChangeReply(_)
    | protocol.ActivityReply(_)
    | protocol.UiLinkReply(..) ->
      Error("listing returned an unexpected control reply")
  }
}

// A session on an executor has a registered name where a local one has a path.
// The name is never probed for a repository: `discover_from` would read it
// relative to the terminal's own working directory and could show a branch of
// an unrelated local folder that happens to share the name.
fn target(
  host: Host,
  session,
  workspace,
  executor: Option(String),
  name,
  creation_key,
  status,
) {
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
  Ok(Target(
    uri.to_string(address),
    host.token,
    snapshot.Expected(session, epoch, incarnation),
    case executor {
      Some(_) -> workspace.Context(path: workspace, branch: None)
      None ->
        workspace.Context(..workspace.discover_from(workspace), path: workspace)
    },
    name,
    creation_key,
  ))
}

fn selected_row(reply) {
  case reply {
    protocol.SessionReply(row) -> Ok(row)
    protocol.StatusReply(_)
    | protocol.SessionsReply(_)
    | protocol.LifecycleReply(_)
    | protocol.DeletedReply(_)
    | protocol.MovedReply(..)
    | protocol.ShutdownReply
    | protocol.PeersInspectionReply(_)
    | protocol.PeersMutationReply(_)
    | protocol.AccessListingReply(_)
    | protocol.AccessChangeReply(_)
    | protocol.ActivityReply(_)
    | protocol.UiLinkReply(..) ->
      Error("selection returned an unexpected control reply")
  }
}

// How long an open may take to become attachable. It bounds the whole wait,
// every `GetOperation` read inside it included.
const startup_wait_ms = 60_000

// The answer when the startup wait runs out, whether between reads or during
// one. A read that outlives the wait is the wait running out, not a fault of
// the control connection, so it is reported as this rather than as a timeout
// that asks the operator to reconnect.
const startup_incomplete =
  "session startup remains incomplete; no open was retried"

// Each read is given what is left of the startup wait rather than a fixed
// budget of its own. A daemon under load can take longer than a couple of
// seconds to answer one read while the open itself is progressing: a
// catalogue read on the registry once took 2.6 s in the containerised
// signoff. With a fixed two-second budget that one slow reply ended the whole
// open, and because a timed-out request retires its control connection, the
// wait could not continue even though most of its minute was left. Tying the
// read to the wait's own deadline means the only timeout that can end the
// open is the one the operator was promised.
fn await(host: Host, session, operation) {
  let epoch = daemon.hello(host.control).epoch
  let deadline = host_bootstrap.monotonic_time_ms() + startup_wait_ms
  case
    poll.until(within: startup_wait_ms, every: 50, attempt: fn() {
      let remaining = deadline - host_bootstrap.monotonic_time_ms()

      // The poll makes one last attempt at the deadline itself. There is no
      // time left to give a read, so that attempt ends the wait as expired.
      use <- bool.guard(remaining <= 0, poll.Retry)
      case
        daemon.request(
          host.control,
          protocol.GetOperation(session, operation, epoch),
          remaining,
        )
      {
        Error(daemon.TimedOut) -> poll.Fail(startup_incomplete)
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
        | Ok(protocol.DeletedReply(_))
        | Ok(protocol.MovedReply(..))
        | Ok(protocol.ShutdownReply)
        | Ok(protocol.PeersInspectionReply(_))
        | Ok(protocol.PeersMutationReply(_))
        | Ok(protocol.AccessListingReply(_))
        | Ok(protocol.AccessChangeReply(_))
        | Ok(protocol.ActivityReply(_))
        | Ok(protocol.UiLinkReply(..)) ->
          poll.Fail("operation returned an unexpected control reply")
      }
    })
  {
    poll.Answered(incarnation) -> Ok(incarnation)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(startup_incomplete)
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
  failure_for("<session-id>", reason)
}

/// `failure` for a request that names `session`, so that a redirect to another
/// orchestrator can print the launch line that reaches it.
///
/// ## Examples
///
/// ```gleam
/// assert selection.failure_for("0198c0de-0000-7000-8000-000000000001", daemon.Busy)
///   == "daemon control is busy"
/// ```
pub fn failure_for(session: String, reason: daemon.Failure) -> String {
  case reason {
    daemon.Invalid(reason) -> reason
    daemon.HandshakeFailed -> "daemon authentication did not complete"
    daemon.Busy -> "daemon control is busy"
    daemon.TimedOut -> "daemon control timed out; reconnect explicitly"
    daemon.Disconnected -> "daemon control disconnected; reconnect explicitly"

    // The existing error envelope carries the authorized operation's bounded
    // startup reason after its owner has retired. A creation refused because
    // its configuration cannot load is the same cause one step earlier, before
    // any session was reserved, so it is worded the same way.
    //
    // A session on an executor can fail before it has a workspace: the daemon
    // is not configured for distribution, the executor is not a pinned peer, or
    // it refused the attach. The daemon leads that reason with
    // `executor_unavailable:`, which is the cause rather than a detail, so it is
    // moved into the sentence and the daemon's reason follows it.
    daemon.Refused("start_failed", "executor_unavailable:" <> reason) ->
      "session startup failed (executor_unavailable):" <> reason
    daemon.Refused("start_failed", message)
    | daemon.Refused("unusable_configuration", message) ->
      "session startup failed: " <> message

    // The daemon's refusal does not repeat the name it was sent, so the words
    // of the launch flag complete the sentence.
    daemon.Refused("executor_unknown", message) ->
      "executor_unknown: "
      <> message
      <> "; --executor must be an [executors.<name>] key of the daemon's configuration"

    daemon.Refused("pool_unknown", message) ->
      "pool_unknown: "
      <> message
      <> "; --pool must be a [pools.<name>] key of the daemon's configuration"

    daemon.Refused(code, message) -> code <> ": " <> message

    // The daemon does not hold the session and says who does. It never
    // forwards the terminal, and this terminal holds no credential for another
    // daemon, so the words are the launch that reaches the owner, on the
    // machine whose owner token it needs.
    daemon.Redirected(redirect) -> redirect_words(session, redirect)
    daemon.UnknownOutcome(command) ->
      "unknown outcome for " <> command <> "; request was not retried"
  }
}

// What the terminal tells the operator when the daemon points elsewhere.
fn redirect_words(session: String, redirect: protocol.Redirect) -> String {
  let launch = fn(address: String) {
    "loom --addr "
    <> address
    <> " --session "
    <> session
    <> " --token-file <owner token file on that host>"
  }
  case redirect {
    protocol.NotOwner(orchestrator, Some(address)) ->
      "session "
      <> session
      <> " is owned by orchestrator "
      <> orchestrator
      <> "; connect to it with: "
      <> launch(address)
    protocol.NotOwner(orchestrator, None) ->
      "session "
      <> session
      <> " is owned by orchestrator "
      <> orchestrator
      <> ", which has no address in this daemon's configuration; connect to it with: "
      <> launch("<its control address>")
    protocol.OwnerUnreachable(orchestrators) ->
      "session "
      <> session
      <> " is not on this daemon, and the orchestrators that may own it did "
      <> "not answer: "
      <> string.join(orchestrators, ", ")
      <> "; retry, or connect to one of them directly"
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
