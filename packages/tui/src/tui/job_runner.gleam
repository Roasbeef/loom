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
//// The daemon control connections live in the same table, under keys the
//// runtime allocates (`job.ControlKey`). The step names a connection by its
//// key, in a job's spec and in `effect.CloseControl`, and this module is
//// the only place a key is turned back into the connection. A key is never
//// reused, so it names at perform time the connection it named when the
//// reducer decided. A connection enters the table at launch
//// (`adopt_control`) or when a relaunch hands one back (`file`), and leaves
//// it when the step closes it.
////
//// The worker bodies live here, not in the reducers that ask for them:
//// `session_control` decides which request to make and what to do with its
//// outcome, and this module is the only place the request is made.
////
//// An attachment job is the one that hands the terminal a socket. Its
//// worker publishes a `job.Prepared` on a second subject, and the runtime
//// creates the frames subject the socket delivers to and passes it to the
//// worker, which names it in the `Prepared`. Whatever drops a `Prepared`
//// owns its socket at that moment: `runtime.hold` queues its close, and
//// `cancel` closes any `Prepared` it finds still waiting in the mailbox
//// through `dropped`. Neither close is what finally guarantees the socket
//// goes down. A worker that exits without an acknowledgement has either
//// closed the socket itself, when its wait ran out, or been killed, and
//// then the socket's guardian closes it (`host/websocket`). The runner
//// forgets an attachment job at the relay's last message, and nothing
//// orders that message against the worker's `Prepared`, which comes from
//// another process; if the `Prepared` arrives after the job is forgotten,
//// the cost is one message left in the mailbox, not an open socket.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import session_view/connection_event
import tui/bootstrap
import tui/buffered
import tui/connection
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/image_open
import tui/job.{type Arrival, type ControlKey, type Key}
import tui/view_link
import weft

/// The jobs this terminal has started and not yet heard the end of, by
/// key, and the daemon control connections the step names by key.
pub opaque type Running {
  Running(
    handles: Dict(Key, Handle),
    controls: Dict(ControlKey, daemon_selection.Host),
    next_control: Int,
  )
}

// What the runtime holds for one job: the signal that cancels it, a
// selector over its subjects that tags each message with the job's key,
// and, for an attachment job, the frames subject its socket delivers to.
// The selector is data, built once at start, so receiving from the job
// needs nothing else.
type Handle {
  Handle(
    cancel: weft.Cancel,
    arrivals: Selector(Arrival(daemon_selection.Host)),
    frames: Option(Subject(connection_event.Message)),
  )
}

/// A table with no jobs, for a new model.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.new()
/// ```
pub fn new() -> Running {
  Running(handles: dict.new(), controls: dict.new(), next_control: 0)
}

/// Adds a daemon control connection to the table and returns the step's
/// name for it.
///
/// ## Examples
///
/// ```gleam
/// let #(running, daemon) = job_runner.adopt_control(running, host)
/// ```
pub fn adopt_control(
  running: Running,
  host: daemon_selection.Host,
) -> #(Running, job.Daemon) {
  let key = job.control_key(running.next_control)
  let build = daemon.hello(daemon_selection.control(host)).build
  #(
    Running(
      ..running,
      controls: dict.insert(running.controls, key, host),
      next_control: running.next_control + 1,
    ),
    job.Daemon(control: key, build:),
  )
}

/// The control connection a key names, while the table holds it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(host) = job_runner.control(running, daemon.control)
/// ```
pub fn control(
  running: Running,
  key: ControlKey,
) -> Result(daemon_selection.Host, Nil) {
  dict.get(running.controls, key)
}

/// Closes the control connection a key names and forgets it. A key the
/// table no longer holds was closed already.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.close_control(running, daemon.control)
/// ```
pub fn close_control(running: Running, key: ControlKey) -> Running {
  case dict.get(running.controls, key) {
    Error(Nil) -> running
    Ok(host) -> {
      daemon.close(daemon_selection.control(host))
      Running(..running, controls: dict.delete(running.controls, key))
    }
  }
}

/// Files one received arrival for the step: a relaunch's control
/// connection enters the table and the arrival carries its key instead.
/// Every other arrival carries no connection and passes unchanged.
///
/// ## Examples
///
/// ```gleam
/// let #(running, arrival) = job_runner.file(running, arrival)
/// ```
pub fn file(
  running: Running,
  arrival: Arrival(daemon_selection.Host),
) -> #(Running, Arrival(job.Daemon)) {
  case arrival {
    job.ReconnectArrived(key:, reply:) -> {
      let #(running, reply) = file_relaunch(running, reply)
      #(running, job.ReconnectArrived(key:, reply:))
    }
    job.ControlArrived(key:, reply:) -> #(
      running,
      job.ControlArrived(key:, reply:),
    )
    job.ActivityArrived(key:, reply:) -> #(
      running,
      job.ActivityArrived(key:, reply:),
    )
    job.AttachArrived(key:, reply:) -> #(
      running,
      job.AttachArrived(key:, reply:),
    )
    job.ConfigurationArrived(key:, reply:) -> #(
      running,
      job.ConfigurationArrived(key:, reply:),
    )
    job.ImageArrived(key:, reply:) -> #(running, job.ImageArrived(key:, reply:))
  }
}

// The relaunch's outcome is the one reply that carries a connection. Every
// other variant is rebuilt as it was, because its type names the connection
// it does not carry.
fn file_relaunch(
  running: Running,
  reply: job.ReconnectReply(daemon_selection.Host),
) -> #(Running, job.ReconnectReply(job.Daemon)) {
  case reply {
    weft.PulledOutcome(weft.Completed(index:, value: host)) -> {
      let #(running, daemon) = adopt_control(running, host)
      #(running, weft.PulledOutcome(weft.Completed(index:, value: daemon)))
    }
    weft.PulledOutcome(weft.Failed(index:, error:)) -> #(
      running,
      weft.PulledOutcome(weft.Failed(index:, error:)),
    )
    weft.PulledOutcome(weft.Crashed(index:, reason:)) -> #(
      running,
      weft.PulledOutcome(weft.Crashed(index:, reason:)),
    )
    weft.PulledOutcome(weft.Abandoned(index:)) -> #(
      running,
      weft.PulledOutcome(weft.Abandoned(index:)),
    )
    weft.PulledOutcome(weft.NeverStarted(index:)) -> #(
      running,
      weft.PulledOutcome(weft.NeverStarted(index:)),
    )
    weft.PulledOutcome(weft.DrainProofLost(index:, reason:)) -> #(
      running,
      weft.PulledOutcome(weft.DrainProofLost(index:, reason:)),
    )
    weft.PulledOutcome(weft.CancellationUnconfirmed(index:)) -> #(
      running,
      weft.PulledOutcome(weft.CancellationUnconfirmed(index:)),
    )
    weft.AllDelivered -> #(running, weft.AllDelivered)
    weft.NotYet -> #(running, weft.NotYet)
    weft.RunLost(reason:) -> #(running, weft.RunLost(reason:))
  }
}

// The bounded relaunch budget. It is the same ninety seconds the initial
// local launch is allowed, because the work is the same: a launch lock, a
// daemon start, and two authenticated probes.
const reconnect_timeout_ms = 90_000

// The activity poll's deadline covers one handshake and one request on a
// connection of its own.
const activity_timeout_ms = 9000

// Resolving a configuration reads an environment variable and asks the file
// system about at most two paths. It needs no network, so a resolution still
// running after five seconds is stuck on its file system and is reported as
// a failure rather than left to hold the creation.
const configuration_timeout_ms = 5000

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
    job.Control(control:, request:) ->
      start_task(
        running,
        key,
        with_control(running, control, control_work(_, request)),
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

    job.Activity(control:, ids:) ->
      start_task(
        running,
        key,
        with_control(running, control, fn(host) { fn() { activity(host, ids) } }),
        activity_timeout_ms,
        job.ActivityArrived,
      )

    job.Attach(route:, within_ms:) ->
      start_attach(running, key, resolve(running, route), within_ms)

    job.Configure(options:) ->
      start_task(
        running,
        key,
        fn() { bootstrap.session_configuration(options) },
        configuration_timeout_ms,
        job.ConfigurationArrived,
      )

    // The opener is waited on for at most `view_link.opener_wait_ms`, and
    // writing the file reads no network, so the job's deadline is that wait
    // and a little for the write.
    job.OpenImage(mime_type:, data:) ->
      start_task(
        running,
        key,
        fn() { image_open.open(mime_type, data, view_link.quiet_opener()) },
        view_link.opener_wait_ms + 2000,
        job.ImageArrived,
      )
  }
}

/// Starts an attachment job whose route resolves through `resolve`.
///
/// `start` is this with the resolution a route describes. The runtime
/// creates the frames subject here, in the terminal's process, and the
/// worker connects its socket to it, publishes the socket as a
/// `job.Prepared` naming that subject, and waits up to `within_ms` for the
/// terminal to acknowledge the initial cut. A test stands in a resolution
/// of its own that fails, or names a fixture server.
///
/// ## Examples
///
/// ```gleam
/// job_runner.start_attach(running, key, fn() { Error("refused") }, 5000)
/// ```
@internal
pub fn start_attach(
  running: Running,
  key: Key,
  resolve: fn() -> Result(daemon_selection.Target, String),
  within_ms: Int,
) -> Running {
  let frames = connection.new_inbox()
  let prepared = process.new_subject()
  let cancel = weft.cancel_signal()
  let replies = process.new_subject()
  let _relay =
    weft.new([fn() { attach(resolve, within_ms, frames, prepared) }])
    |> weft.deadline(within_ms)
    |> weft.cancel_with(cancel)
    |> weft.start_relayed(replies)
  let arrivals =
    process.new_selector()
    |> process.select_map(prepared, fn(published) {
      job.AttachArrived(key, job.Published(published))
    })
    |> process.select_map(replies, fn(reply) {
      job.AttachArrived(key, job.Settled(reply))
    })
  insert(running, key, Handle(cancel, arrivals, Some(frames)))
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
  tag: fn(Key, weft.Pulled(a, e)) -> Arrival(daemon_selection.Host),
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
  insert(running, key, Handle(cancel, arrivals, None))
}

fn insert(running: Running, key: Key, handle: Handle) -> Running {
  Running(..running, handles: dict.insert(running.handles, key, handle))
}

// The work a job does through the control connection `key` names. A key the
// table no longer holds names a connection the step already closed, and the
// job fails with that reason rather than reaching for another connection.
fn with_control(
  running: Running,
  key: ControlKey,
  work: fn(daemon_selection.Host) -> fn() -> Result(a, String),
) -> fn() -> Result(a, String) {
  case control(running, key) {
    Ok(host) -> work(host)
    Error(Nil) -> fn() { Error("daemon control is closed") }
  }
}

/// Cancels the job named `key`, if it is still running.
///
/// The reducer that cancelled it has already cleared the slot that named
/// the key, so nothing the job sends afterwards reaches a reducer. An
/// attachment job is then drained at once, without waiting: a `Prepared`
/// already in the mailbox is dropped, closing its socket, and the frames
/// subject is emptied. That is the attempt's bounded drain at quit. It
/// closes only what has already arrived; `weft.cancel` kills the worker
/// asynchronously, and a socket the worker publishes after the drain is
/// closed by its guardian when the killed worker exits. The job stays in
/// the table until its relay's
/// last message is read: the relay still sends the cancelled outcome and
/// that last message, and `receive` reads them so they do not stay in the
/// mailbox.
///
/// ## Examples
///
/// ```gleam
/// let running = job_runner.cancel(running, key)
/// ```
pub fn cancel(running: Running, key: Key) -> Running {
  case dict.get(running.handles, key) {
    Error(Nil) -> running
    Ok(Handle(frames: None, ..) as handle) -> {
      weft.cancel(handle.cancel)
      running
    }
    Ok(Handle(frames: Some(frames), ..) as handle) -> {
      weft.cancel(handle.cancel)
      let drained = drain(handle.arrivals, []) |> list.reverse
      list.each(drained, dropped)
      buffered.discard(frames)
      list.fold(drained, running, observed)
    }
  }
}

/// Performs what dropping an arrival requires: a `Prepared` carries an open
/// socket the terminal will not adopt, so the socket is closed and the
/// frames subject it delivers to is emptied, and a relaunch's `Completed`
/// carries a control connection, which is closed. Every other arrival is
/// only forgotten.
///
/// `cancel` calls this for what it drains, at perform time. `runtime.hold`
/// queues the same releases as effects instead, since it runs before the
/// step.
///
/// ## Examples
///
/// ```gleam
/// job_runner.dropped(job.AttachArrived(key, job.Published(prepared)))
/// ```
pub fn dropped(arrival: Arrival(daemon_selection.Host)) -> Nil {
  case arrival {
    job.AttachArrived(reply: job.Published(prepared), ..) -> {
      connection.close(prepared.socket)
      buffered.discard(prepared.frames)
    }
    job.ReconnectArrived(
      reply: weft.PulledOutcome(weft.Completed(value: host, ..)),
      ..,
    ) -> daemon.close(daemon_selection.control(host))
    job.AttachArrived(reply: job.Settled(_), ..)
    | job.AttachArrived(reply: job.Finished(_), ..)
    | job.ControlArrived(..)
    | job.ReconnectArrived(..)
    | job.ActivityArrived(..)
    | job.ConfigurationArrived(..)
    | job.ImageArrived(..) -> Nil
  }
}

/// Receives, without waiting, every message the running jobs have sent,
/// oldest first.
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
pub fn receive(running: Running) -> List(Arrival(daemon_selection.Host)) {
  // One pass over the mailbox for every job, rather than one per job. A
  // selective receive that matches nothing scans the whole mailbox, and this
  // runs before every event, so under a socket backlog each extra pass
  // costs one scan of the backlog per keypress (ADR-013, the addendum on
  // one mailbox scan). An empty table reads nothing, since a receive on a
  // selector with no handlers would scan the backlog to find nothing.
  //
  // The merged selector returns the jobs' messages in mailbox order, where
  // one selector per job returned them grouped by job. That changes nothing
  // a reducer sees. Restricted to one job, mailbox order is the order the
  // per-job receive produced, so each job's own messages keep their order:
  // a job's relay is one sender, and an attachment's `Prepared` and its
  // relay's messages were already read in mailbox order by its own
  // selector. Across jobs the order carries no meaning, because each
  // arrival is tagged with its own key by the handler of the subject it came
  // from, and `runtime.hold` admits it only into the slot that names that
  // key, or releases what it holds; no job's arrival reads or writes
  // another job's slot or table entry. The reducers then take from the
  // slots in the tick's fixed drain order, not in arrival order.
  case dict.is_empty(running.handles) {
    True -> []
    False -> drain(selector(running), []) |> list.reverse
  }
}

// Everything the selected jobs have sent so far. A one-task relay sends at
// most two messages and an attachment's worker one more, so this ends after
// at most three messages per job.
fn drain(
  arrivals: Selector(Arrival(daemon_selection.Host)),
  received: List(Arrival(daemon_selection.Host)),
) -> List(Arrival(daemon_selection.Host)) {
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
pub fn observed(running: Running, arrival: Arrival(control)) -> Running {
  case job.is_last(arrival) {
    True ->
      Running(
        ..running,
        handles: dict.delete(running.handles, job.arrival_key(arrival)),
      )
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
pub fn selector(running: Running) -> Selector(Arrival(daemon_selection.Host)) {
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

// The attachment worker. The acknowledgement subject is the worker's own,
// created here, because the worker is the process that waits on it. A wait
// that runs out closes the socket the worker opened, since no terminal will
// take it.
fn attach(
  resolve: fn() -> Result(daemon_selection.Target, String),
  within_ms: Int,
  frames: Subject(connection_event.Message),
  prepared: Subject(job.Prepared),
) -> Result(Nil, String) {
  use target <- result.try(resolve())

  // The frames inbox belongs to the terminal's loop, which `start_attach`
  // runs in, so the socket wakes that loop when a frame arrives rather than
  // leaving it for the next poll timeout (`connection.connect_waking`).
  use socket <- result.try(connection.connect_waking(
    target.address,
    target.token,
    frames,
  ))
  let acknowledged = process.new_subject()
  process.send(
    prepared,
    job.Prepared(
      socket:,
      expected: target.expected,
      workspace: target.workspace,
      session_name: target.session_name,
      creation_key: target.creation_key,
      acknowledgement: acknowledged,
      frames:,
    ),
  )
  case process.receive(acknowledged, within_ms) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      connection.close(socket)
      Error("initial conversation capture was not acknowledged")
    }
  }
}

// An attachment resolves through the terminal's control route, borrowed
// while it lives or replaced for this one request.
fn resolve(
  running: Running,
  route: job.AttachRoute,
) -> fn() -> Result(daemon_selection.Target, String) {
  case route {
    job.OpenSession(control:, session:) ->
      with_control(running, control, fn(host) {
        fn() {
          use host <- daemon_selection.with_live_control(host)
          daemon_selection.open(host, session)
        }
      })
    job.CreateSession(
      control:,
      key:,
      workspace:,
      name:,
      config:,
      profile:,
      executor:,
      pool:,
    ) ->
      with_control(running, control, fn(host) {
        fn() {
          use host <- daemon_selection.with_live_control(host)
          daemon_selection.create_named(
            host,
            key,
            workspace,
            name,
            config,
            profile,
            executor,
            pool,
          )
        }
      })
  }
}

fn control_deadline(request: job.ControlJob) -> Int {
  case request {
    job.Remove(..) -> 85_000
    job.LoadPeerWorkspace(..) -> 15_000
    job.LoadPage(..)
    | job.Rename(..)
    | job.InspectPeers(..)
    | job.LoadPeerSessions(..)
    | job.MutatePeers(..)
    | job.ReadAccess(..)
    | job.ChangeAccess(..) -> 12_000
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
      job.ReadAccess(command:) -> read_access(host, command)
      job.ChangeAccess(command:) -> change_access(host, command)
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
    | control_protocol.MovedReply(..)
    | control_protocol.PeersInspectionReply(_)
    | control_protocol.PeersMutationReply(_)
    | control_protocol.AccessListingReply(_)
    | control_protocol.AccessChangeReply(_)
    | control_protocol.ActivityReply(_)
    | control_protocol.UiLinkReply(..)
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

// The owner's access reads. The reply is handed on unread: `host/access`
// checks it where the overlay draws it, so the terminal accepts exactly the
// rows `loom access` would print.
fn read_access(host, command) {
  use reply <- result.try(request(host, command))
  case reply, command {
    control_protocol.AccessListingReply(document),
      control_protocol.ListPrincipals(after)
    -> Ok(job.AccessListed(document, after))
    control_protocol.AccessListingReply(document),
      control_protocol.PrincipalMemberships(principal, after)
    -> Ok(job.MembershipsListed(document, principal, after))
    _, _ -> Error("access listing returned an unexpected reply")
  }
}

// One access change. A reply lost after the request was sent surfaces as an
// unknown outcome and is never resent.
fn change_access(host, command) {
  use reply <- result.try(request(host, command))
  case reply {
    control_protocol.AccessChangeReply(document) ->
      Ok(job.AccessChanged(document))
    _ -> Error("access change returned an unexpected reply")
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
    | control_protocol.MovedReply(..)
    | control_protocol.PeersInspectionReply(_)
    | control_protocol.PeersMutationReply(_)
    | control_protocol.AccessListingReply(_)
    | control_protocol.AccessChangeReply(_)
    | control_protocol.UiLinkReply(..)
    | control_protocol.ShutdownReply ->
      Error("activity returned an unexpected control reply")
  }
}
