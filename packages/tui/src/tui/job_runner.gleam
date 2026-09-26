//// Starts, cancels and receives the terminal's background jobs.
////
//// A reducer asks for a job by queuing `effect.StartJob(key, spec)`, and
//// the runtime brings it here after the step. `start` creates the job's
//// reply subject and cancel signal in the calling process, which is the
//// process that created the model, starts a one-task weft run that relays
//// its outcome to that subject, and records both under the key. The
//// reducer never sees either: it names the job by its key, cancels it with
//// `effect.CancelJob(key)`, and reads its replies from the slot the runtime
//// admitted them into.
////
//// The table of running jobs, `Running`, lives on the model as
//// `Model.running` because the model is the only state the loop keeps
//// between two events. No reducer reads it. `runtime.perform` threads it
//// through the effects it performs and `runtime.settle` puts the result
//// back on the model, so every change to it happens after a step, in the
//// order the step decided.
////
//// `receive` reads every running job's subject before a step, and a job
//// stays in the table until its relay's last message has been read, even
//// after it was cancelled or its slot was cleared. That is what keeps a
//// job's messages from staying in the terminal's mailbox, where every
//// later selective receive would scan past them. A one-task run's relay
//// sends at most two messages, its outcome and then `AllDelivered` or
//// `RunLost`, so reading everything a job sent is bounded.
////
//// The worker bodies live here, not in the reducers that ask for them:
//// `session_control` decides which request to make and what to do with its
//// outcome, and this module is the only place the request is made.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/job.{type Arrival, type Key}
import weft

/// The jobs this terminal has started and not yet heard the end of, by key.
pub opaque type Running {
  Running(handles: Dict(Key, Handle))
}

// What the runtime holds for one job: the signal that cancels it, and a
// selector over its reply subject that tags each message with the job's
// key. The selector is data, built once at start, so receiving from the
// job needs nothing else.
type Handle {
  Handle(cancel: weft.Cancel, arrivals: Selector(Arrival))
}

/// A table with no jobs, for a new model.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.new()
/// ```
pub fn new() -> Running {
  Running(handles: dict.new())
}

// The bounded relaunch budget. It is the same ninety seconds the initial
// local launch is allowed, because the work is the same: a launch lock, a
// daemon start, and two authenticated probes.
const reconnect_timeout_ms = 90_000

// The activity poll's deadline covers one handshake and one request on a
// connection of its own.
const activity_timeout_ms = 9000

/// Starts the job `spec` describes under `key`.
///
/// Called by the runtime when it performs `effect.StartJob`, in the process
/// that created the model, so the reply subject belongs to the process
/// whose `receive` reads it.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.start(running, key, job.Reconnect(options))
/// ```
pub fn start(running: Running, key: Key, spec: job.Spec) -> Running {
  case spec {
    job.Control(host:, request:) ->
      start_task(
        running,
        key,
        control_work(host, request),
        control_deadline(request),
        job.ControlArrived,
      )

    // The relaunched daemon's control belongs to the terminal's process,
    // which is the caller here, so a terminal that exits mid-attempt still
    // closes it.
    job.Reconnect(options:) -> {
      let owner = process.self()
      start_task(
        running,
        key,
        fn() { daemon_selection.relaunch(options, owner, reconnect_timeout_ms) },
        reconnect_timeout_ms,
        job.ReconnectArrived,
      )
    }

    job.Activity(host:, ids:) ->
      start_task(
        running,
        key,
        fn() { activity(host, ids) },
        activity_timeout_ms,
        job.ActivityArrived,
      )
  }
}

/// Starts `work` as a one-task weft run bounded by `within_ms`, relaying
/// its outcome to a new subject whose messages arrive tagged by `tag`.
///
/// `start` is this with the worker a spec describes. It is exposed so a
/// test can stand a worker of its own in for the daemon.
///
/// ## Examples
///
/// ```gleam
/// job_runner.start_task(running, key, fn() { Error("refused") }, 100,
///   job.ReconnectArrived)
/// ```
@internal
pub fn start_task(
  running: Running,
  key: Key,
  work: fn() -> Result(a, e),
  within_ms: Int,
  tag: fn(Key, weft.Pulled(a, e)) -> Arrival,
) -> Running {
  let cancel = weft.cancel_signal()
  let replies = process.new_subject()
  let _relay =
    weft.new([work])
    |> weft.deadline(within_ms)
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(replies)
  let arrivals =
    process.new_selector()
    |> process.select_map(replies, fn(reply) { tag(key, reply) })
  Running(handles: dict.insert(running.handles, key, Handle(cancel, arrivals)))
}

/// Cancels the job named `key`, if it is still running.
///
/// The job stays in the table: its relay still sends the cancelled
/// outcome and its last message, and `receive` reads them so they do not
/// stay in the mailbox. The reducer that cancelled it has already cleared
/// the slot that named the key, so neither reaches a reducer.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.cancel(running, key)
/// ```
pub fn cancel(running: Running, key: Key) -> Running {
  case dict.get(running.handles, key) {
    Ok(handle) -> weft.cancel(handle.cancel)
    Error(Nil) -> Nil
  }
  running
}

/// Receives, without waiting, every message the running jobs have sent,
/// oldest first within each job.
///
/// `runtime.receive` calls this before every step and passes each arrival
/// to `runtime.hold`, which also removes a job from the table once its last
/// message has been read.
///
/// ## Examples
///
/// ```gleam
/// let arrivals = job_runner.receive(running)
/// ```
pub fn receive(running: Running) -> List(Arrival) {
  dict.fold(running.handles, [], fn(received, _key, handle) {
    drain(handle.arrivals, received)
  })
  |> list.reverse
}

// Everything one job has sent so far. A one-task relay sends at most two
// messages, so this ends quickly.
fn drain(
  arrivals: Selector(Arrival),
  received: List(Arrival),
) -> List(Arrival) {
  case process.selector_receive(arrivals, 0) {
    Ok(arrival) -> drain(arrivals, [arrival, ..received])
    Error(Nil) -> received
  }
}

/// Removes the job an arrival came from once that arrival is its last.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.observed(running, arrival)
/// ```
pub fn observed(running: Running, arrival: Arrival) -> Running {
  case job.is_last(arrival) {
    True ->
      Running(handles: dict.delete(running.handles, job.arrival_key(arrival)))
    False -> running
  }
}

/// A selector over every running job's replies.
///
/// A test driver hosted in an actor selects on this between scripts. An
/// actor discards a message its selector does not match, so a reply that
/// arrived while the driver waited would otherwise be lost. What it
/// selects goes to `runtime.hold`, as a received arrival does.
///
/// ## Examples
///
/// ```gleam
/// process.selector_receive(job_runner.selector(model.running), 1000)
/// ```
pub fn selector(running: Running) -> Selector(Arrival) {
  dict.fold(running.handles, process.new_selector(), fn(merged, _key, handle) {
    process.merge_selector(merged, handle.arrivals)
  })
}

/// How many jobs the table still holds.
///
/// ## Examples
///
/// ```gleam
/// assert job_runner.size(job_runner.new()) == 0
/// ```
@internal
pub fn size(running: Running) -> Int {
  dict.size(running.handles)
}

// ---------------------------------------------------------------------------
// The workers

fn control_deadline(request: job.ControlJob) -> Int {
  case request {
    job.Remove(..) -> 85_000
    job.LoadPeerWorkspace(..) -> 15_000
    job.LoadPage(..)
    | job.Rename(..)
    | job.InspectPeers(..)
    | job.LoadPeerSessions(..)
    | job.MutatePeers(..) -> 12_000
  }
}

// Each control request runs over the terminal's control route: the
// borrowed connection while it lives, or a replacement the worker owns
// for this one request (`daemon_selection.with_live_control`).
fn control_work(
  host: daemon_selection.Host,
  request: job.ControlJob,
) -> fn() -> Result(job.ControlOutcome, String) {
  fn() {
    use host <- daemon_selection.with_live_control(host)
    case request {
      job.LoadPage(command:, collection:, session:, workspace:) ->
        load_page(host, command, collection, session, workspace)
      job.Rename(session:, name:) -> rename(host, session, name)
      job.Remove(session:, removal:) -> remove(host, session, removal)
      job.LoadPeerWorkspace(source_session:, source_strand:) ->
        load_peer_workspace(host, source_session, source_strand)
      job.InspectPeers(session:, strand:, after:) ->
        inspect_peers(host, session, strand, after)
      job.LoadPeerSessions(after:, revision:) ->
        load_peer_sessions(host, after, revision)
      job.MutatePeers(command:) -> mutate_peers(host, command)
    }
  }
}

fn request(
  host: daemon_selection.Host,
  command: control_protocol.Command,
) -> Result(control_protocol.Reply, String) {
  daemon.request(daemon_selection.control(host), command, 5000)
  |> result.map_error(daemon_selection.failure)
}

fn load_page(host, command, collection, session, workspace) {
  use reply <- result.try(request(host, command))
  use page <- result.try(case reply {
    control_protocol.SessionsReply(page) -> Ok(page)
    control_protocol.StatusReply(_)
    | control_protocol.SessionReply(_)
    | control_protocol.LifecycleReply(_)
    | control_protocol.DeletedReply(_)
    | control_protocol.PeersInspectionReply(_)
    | control_protocol.PeersMutationReply(_)
    | control_protocol.ActivityReply(_)
    | control_protocol.ShutdownReply ->
      Error("catalogue returned an unexpected control reply")
  })
  let selected = case session {
    "" -> default_selection(host, workspace)
    id -> id
  }
  Ok(job.PageLoaded(page, selected, collection))
}

// The row a picker opened with no attached session highlights: the
// workspace's default session, or none when the daemon names none.
fn default_selection(host: daemon_selection.Host, workspace: String) -> String {
  case request(host, control_protocol.WorkspaceDefault(workspace)) {
    Ok(control_protocol.SessionReply(row)) -> row.session_id
    _ -> ""
  }
}

// The reply owns the displayed name. A timeout leaves the outcome unknown
// and never causes the metadata mutation to be sent a second time.
fn rename(host, session, name) {
  use reply <- result.try(request(
    host,
    control_protocol.RenameSession(session, name),
  ))
  case reply {
    control_protocol.SessionReply(row) if row.session_id == session ->
      Ok(job.SessionRenamed(row))
    _ -> Error("rename returned an unexpected control reply")
  }
}

fn remove(host, session, removal) {
  case removal {
    job.Archive ->
      result.map(daemon_selection.archive(host, session), job.SessionArchived)
    job.Restore ->
      result.map(daemon_selection.restore(host, session), job.SessionRestored)
    job.PermanentlyDelete ->
      result.map(daemon_selection.delete(host, session), job.SessionDeleted)
  }
}

fn load_peer_workspace(host, source_session, source_strand) {
  use sessions_reply <- result.try(request(
    host,
    control_protocol.ListSessions("", None),
  ))
  use page <- result.try(case sessions_reply {
    control_protocol.SessionsReply(page) -> Ok(page)
    _ -> Error("peer catalogue returned an unexpected reply")
  })
  use inspection_reply <- result.try(request(
    host,
    control_protocol.InspectPeers(source_session, source_strand, None),
  ))
  use document <- result.try(case inspection_reply {
    control_protocol.PeersInspectionReply(document) -> Ok(document)
    _ -> Error("peer inspection returned an unexpected reply")
  })
  Ok(job.PeerWorkspaceLoaded(page, document))
}

fn inspect_peers(host, session, strand, after) {
  use reply <- result.try(request(
    host,
    control_protocol.InspectPeers(session, strand, after),
  ))
  case reply {
    control_protocol.PeersInspectionReply(document) ->
      Ok(job.PeerInspectionLoaded(document, after))
    _ -> Error("peer inspection returned an unexpected reply")
  }
}

// The chooser reads only metadata under the first page's catalogue revision.
fn load_peer_sessions(host, after, revision) {
  use reply <- result.try(request(
    host,
    control_protocol.ListSessions(after, Some(revision)),
  ))
  case reply {
    control_protocol.SessionsReply(page) -> Ok(job.PeerSessionsLoaded(page))
    _ -> Error("peer catalogue returned an unexpected reply")
  }
}

fn mutate_peers(host, command) {
  use reply <- result.try(request(host, command))
  case reply {
    control_protocol.PeersMutationReply(document) ->
      Ok(job.PeerOperationCompleted(document))
    _ -> Error("peer mutation returned an unexpected reply")
  }
}

// The activity poll runs on a control connection of its own, which it
// closes before returning: the terminal's borrowed control has one
// outstanding slot, and an operator's page turn must never find a poll
// holding it.
fn activity(
  host: daemon_selection.Host,
  ids: List(String),
) -> Result(List(control_protocol.Activity), String) {
  use owned <- result.try(daemon_selection.reconnect(host, process.self()))
  let control = daemon_selection.control(owned)
  let reply =
    daemon.request(control, control_protocol.SessionActivity(ids), 5000)
  daemon.close(control)
  use reply <- result.try(result.map_error(reply, daemon_selection.failure))
  case reply {
    control_protocol.ActivityReply(rows) -> Ok(rows)
    control_protocol.StatusReply(_)
    | control_protocol.SessionsReply(_)
    | control_protocol.SessionReply(_)
    | control_protocol.LifecycleReply(_)
    | control_protocol.DeletedReply(_)
    | control_protocol.PeersInspectionReply(_)
    | control_protocol.PeersMutationReply(_)
    | control_protocol.ShutdownReply ->
      Error("activity returned an unexpected control reply")
  }
}
