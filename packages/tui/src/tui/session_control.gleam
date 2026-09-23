//// Daemon control: opening, creating, renaming, archiving and deleting
//// catalogue sessions, and reattaching after a lost connection.
////
//// These requests go to the daemon's control socket rather than a session
//// channel, and each runs in a background worker so the terminal never
//// waits on the daemon. At most one catalogue request runs at a time; a
//// second is refused with a transcript line rather than queued. The
//// worker's result comes back as a `ControlEvent`, a `ReconnectEvent` or,
//// for an opened session, an attachment candidate event, and the tick
//// drains each. `accept_control_event` and `accept_reconnect_event` are
//// the entry points a test drives directly.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import tui/attachment
import tui/attempt
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/inbound
import tui/model.{
  type ControlEvent, type Model, AgentInspector, ApprovalInspector,
  ControlRequest, DaemonSelector, GoalInspector, Model, ModelSelector, NoOverlay,
  PageLoaded, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
  SessionArchived, SessionDeleted, SessionRenamed, SessionRestored,
  SessionSelector,
} as tui_model
import tui/recording
import tui/session_selector
import tui/workspace
import weft

/// One relayed relaunch outcome, selected by the terminal and its driver.
@internal
pub type ReconnectEvent {
  ReconnectEvent(
    source: Subject(weft.Pulled(daemon_selection.Host, String)),
    reply: weft.Pulled(daemon_selection.Host, String),
  )
}

/// Applies one relaunch outcome, bounded to the attempt which produced it.
///
/// A success reattaches the same session through the shipped open path, which
/// is what gives the operator a working channel again; the transcript it
/// already had is merged rather than replaced. A failure is terminal: the
/// attempt is marked spent and the reason is written to the transcript, so a
/// relaunch that cannot succeed is reported once instead of being retried.
/// Every `weft.Pulled` variant is named rather than swept up, because each is a
/// different fact about the attempt and a catch-all would hide a new one.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_reconnect_event(model, event)
/// ```
@internal
pub fn accept_reconnect_event(model: Model, event: ReconnectEvent) -> Model {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(replies: source, ..) if source != event.source -> model
    ReconnectAttempting(..) ->
      case event.reply {
        weft.NotYet -> model
        weft.PulledOutcome(weft.Completed(value: host, ..)) -> {
          let model = Model(..model, reconnect: ReconnectSpent)
          let model = Model(..model, daemon_host: Some(host))
          reattach_after_reconnect(model)
        }
        weft.PulledOutcome(weft.Failed(error:, ..)) ->
          reconnect_failed(model, error)
        weft.PulledOutcome(weft.Crashed(reason:, ..))
        | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
          reconnect_failed(model, string.inspect(reason))
        weft.PulledOutcome(weft.Abandoned(..))
        | weft.PulledOutcome(weft.NeverStarted(..))
        | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
          reconnect_failed(model, "the daemon relaunch did not complete")
        weft.RunLost(reason) -> reconnect_failed(model, string.inspect(reason))
        weft.AllDelivered ->
          reconnect_failed(
            model,
            "the daemon relaunch ended without an outcome",
          )
      }
  }
}

// Reattaches the session the terminal was already showing. The identity comes
// from the model, so the operator's transcript and the daemon's registration
// are the same session; `begin_open` is the shipped path that resolves the
// current epoch and incarnation through control and adopts the new socket.
fn reattach_after_reconnect(model: Model) -> Model {
  case model.session {
    "" -> Model(..model, notice: "daemon reconnected; no session was attached")
    session ->
      tui_model.append_system(
        begin_open(
          Model(..model, notice: "reattaching to " <> session),
          session,
        ),
        "daemon restarted; reattaching to " <> session,
      )
  }
}

// The terminal failure of one reconnect. The attempt is spent either way, so
// the operator gets the reason and the standing Disconnected advice rather
// than a loop; `/sessions` remains the explicit way back.
fn reconnect_failed(model: Model, reason: String) -> Model {
  tui_model.append_error(
    Model(..model, reconnect: ReconnectSpent),
    "reconnect failed: " <> reason <> "; press /sessions to reconnect",
  )
}

/// Opens a catalogue session through daemon control as a recorded
/// attachment candidate, after cancelling any unsent frame for the old target.
@internal
pub fn begin_open(model: Model, session: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.session)
  case attachment.busy(model.candidate), model.daemon_host {
    True, _ ->
      tui_model.append_error(model, "a session switch is already in progress")
    False, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    False, Some(host) ->
      Model(
        ..model,
        overlay: NoOverlay,
        next_attempt: model.next_attempt + 1,
        candidate: attachment.start_recorded(
          fn() {
            use host <- daemon_selection.with_live_control(host)
            daemon_selection.open(host, session)
          },
          90_000,
          recording.trace(model.recorder, attempt.Id(model.next_attempt)),
        ),
        notice: "opening session " <> session,
      )
  }
}

/// Paging observes only authorized metadata in the requested revision.
@internal
pub fn load_catalogue(
  model: Model,
  after: String,
  revision: Option(Int),
) -> Model {
  load_catalogue_collection(model, after, revision, session_selector.Active)
}

/// Collection belongs to the request, so a late page cannot be relabelled by
/// a key pressed while its one bounded control job is still outstanding.
@internal
pub fn load_catalogue_collection(
  model: Model,
  after: String,
  revision: Option(Int),
  collection: session_selector.Collection,
) -> Model {
  let command = case collection {
    session_selector.Active -> control_protocol.ListSessions(after, revision)
    session_selector.Archived ->
      control_protocol.ListArchivedSessions(after, revision)
  }
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue page is already loading")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()

      // The two scalars the worker needs are bound here rather than read off
      // `model` inside the closure. A closure over a field captures the whole
      // record, and weft copies a fun's environment into the worker: that
      // would send the transcript, the row caches and the cached frame — an
      // 8 MiB retained window at its bound — to a process that wants a
      // session id and a path.
      let session = model.session
      let workspace = model.workspace.path
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use reply <- result.try(
              daemon.request(daemon_selection.control(host), command, 5000)
              |> result.map_error(daemon_selection.failure),
            )
            use page <- result.try(case reply {
              control_protocol.SessionsReply(page) -> Ok(page)
              control_protocol.StatusReply(_)
              | control_protocol.SessionReply(_)
              | control_protocol.LifecycleReply(_)
              | control_protocol.DeletedReply(_)
              | control_protocol.ShutdownReply ->
                Error("catalogue returned an unexpected control reply")
            })
            let selected = case session {
              "" -> default_selection(host, workspace)
              id -> id
            }
            Ok(PageLoaded(page, selected, collection))
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "loading authorized session metadata",
      )
    }
  }
}

/// Deletion shares the picker's one control job slot with paging, so a delete
/// while a page is in flight is refused rather than queued behind it. The
/// identity is bound outside the closure for the same reason the page job
/// binds its two scalars: weft copies the fun's environment, and a reference
/// to a model field would copy the whole presentation state with it.
/// The reply owns the displayed name. A timeout leaves the outcome unknown
/// and never causes the metadata mutation to be sent a second time.
@internal
pub fn begin_rename(model: Model, session: String, name: String) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue action is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use reply <- result.try(
              daemon.request(
                daemon_selection.control(host),
                control_protocol.RenameSession(session, name),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            case reply {
              control_protocol.SessionReply(row) if row.session_id == session ->
                Ok(SessionRenamed(row))
              _ -> Error("rename returned an unexpected control reply")
            }
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "renaming session",
      )
    }
  }
}

/// Permanently deletes a catalogue session through daemon control.
@internal
pub fn begin_delete(model: Model, session: String) -> Model {
  begin_removal(model, session, PermanentlyDelete)
}

/// The ADT keeps a confirmed permanent deletion distinct from reversible
/// archive and restore requests while they share one bounded job slot.
@internal
pub type Removal {
  Archive
  Restore
  PermanentlyDelete
}

/// Starts one archive or delete request against daemon control. Only one
/// catalogue request runs at a time; a second is refused with a transcript
/// error rather than queued.
@internal
pub fn begin_removal(model: Model, session: String, removal: Removal) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue request is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            case removal {
              Archive ->
                result.map(
                  daemon_selection.archive(host, session),
                  SessionArchived,
                )
              Restore ->
                result.map(
                  daemon_selection.restore(host, session),
                  SessionRestored,
                )
              PermanentlyDelete ->
                result.map(
                  daemon_selection.delete(host, session),
                  SessionDeleted,
                )
            }
          },
        ])
        |> weft.deadline(85_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: case removal {
          Archive -> "stopping and archiving session " <> session
          Restore -> "restoring session " <> session
          PermanentlyDelete ->
            "stopping and permanently deleting session " <> session
        },
      )
    }
  }
}

fn default_selection(host, workspace) {
  case
    daemon.request(
      daemon_selection.control(host),
      control_protocol.WorkspaceDefault(workspace),
      5000,
    )
  {
    Ok(control_protocol.SessionReply(row)) -> row.session_id
    _ -> ""
  }
}

/// Applies a selected control job response before later terminal messages.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_control_event(model, event)
/// ```
@internal
pub fn accept_control_event(model: Model, event: ControlEvent) -> Model {
  case model.control_request {
    None -> model
    Some(run) if run.replies != event.source -> model
    Some(run) ->
      case event.reply {
        weft.NotYet -> model
        weft.PulledOutcome(weft.Completed(value:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Ok(value))),
            ),
          )
        weft.PulledOutcome(weft.Failed(error:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Error(error))),
            ),
          )
        weft.PulledOutcome(weft.Crashed(reason:, ..))
        | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Error(string.inspect(reason)))),
            ),
          )
        weft.PulledOutcome(weft.Abandoned(..))
        | weft.PulledOutcome(weft.NeverStarted(..))
        | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(
                ..run,
                result: Some(Error("control request did not complete")),
              ),
            ),
          )
        weft.RunLost(reason) ->
          tui_model.append_error(
            Model(..model, control_request: None),
            string.inspect(reason),
          )
        weft.AllDelivered ->
          finish_control(Model(..model, control_request: None), run.result)
      }
  }
}

fn finish_control(model: Model, result) {
  case result {
    Some(Ok(PageLoaded(page, selected, collection))) -> {
      let selector =
        session_selector.new(
          session_selector.prioritize(page, model.workspace.path),
          selected,
        )
      Model(
        ..model,
        overlay: DaemonSelector(session_selector.State(..selector, collection:)),
        notice: case collection {
          session_selector.Active ->
            "Enter opens · d archives · a shows archived sessions"
          session_selector.Archived ->
            "Enter restores · d permanently deletes · a shows active sessions"
        },
      )
      |> tui_model.invalidate_frame
    }

    Some(Ok(SessionRenamed(row))) ->
      Model(
        ..model,
        session_label: case row.session_id == model.session {
          True -> Some(#(row.session_id, row.name))
          False -> model.session_label
        },
        overlay: case model.overlay {
          DaemonSelector(selector) ->
            DaemonSelector(session_selector.renamed(selector, row))
          NoOverlay
          | ModelSelector(_)
          | AgentInspector(_)
          | GoalInspector(_)
          | ApprovalInspector(_)
          | SessionSelector(_) -> model.overlay
        },
        notice: "renamed session to " <> row.name,
      )
      |> tui_model.invalidate_frame

    // The row is dropped from the page already on screen rather than by
    // re-listing: the reply proves this identity is gone, and a fresh page
    // would move every other row under the operator's cursor.
    Some(Ok(SessionDeleted(id))) ->
      catalogue_removed(model, id, "deleted session ")
    Some(Ok(SessionArchived(id))) ->
      catalogue_removed(model, id, "archived session ")
    Some(Ok(SessionRestored(id))) ->
      catalogue_removed(model, id, "restored session ")
    Some(Error(reason)) -> tui_model.append_error(model, reason)
    None ->
      tui_model.append_error(model, "control job ended without an outcome")
  }
}

// Acknowledgements update only the collection already on screen. Restoring a
// row never opens it, and no metadata acknowledgement retargets attachment.
fn catalogue_removed(model: Model, id: String, description: String) -> Model {
  Model(
    ..model,
    overlay: case model.overlay {
      DaemonSelector(selector) ->
        DaemonSelector(session_selector.without(selector, id))
      NoOverlay
      | ModelSelector(_)
      | AgentInspector(_)
      | GoalInspector(_)
      | ApprovalInspector(_)
      | SessionSelector(_) -> model.overlay
    },
    notice: description <> id,
  )
  |> tui_model.invalidate_frame
}

/// Creates a new daemon session from the local launch options, resolving
/// the session configuration before any creation key is retained.
@internal
pub fn create_session(model: Model) -> Model {
  // Resolve local paths before retaining a creation key: a local failure sent
  // nothing and must leave the operator free to correct the invocation.
  //
  // Resolution runs per attempt, so a retained key retried after a lost reply
  // carries whatever `<state-root>/loom.toml` says at that moment, and
  // `reserve_creation` answers `Conflict` if the answer changed. That is
  // accepted rather than cached: the file would have to appear inside a single
  // lost-reply window, and the operator sees a named conflict, not a session
  // created under a catalogue they did not ask for.
  let configuration = case model.local_options {
    Some(options) -> bootstrap.session_configuration(options)
    None -> Ok("")
  }
  case configuration {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(config) -> create_session_configured(model, config)
  }
}

fn create_session_configured(model: Model, config: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.session)
  case model.creation_key, model.daemon_host, attachment.busy(model.candidate) {
    Some(key), _, _ ->
      tui_model.append_error(
        model,
        "reconcile prior creation key before creating again: " <> key,
      )
    None, None, _ ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(_), True ->
      tui_model.append_error(model, "a session switch is already in progress")
    None, Some(host), False -> {
      let key =
        "tui-"
        <> int.to_string(host_bootstrap.current_process_id())
        <> "-"
        <> string.inspect(process.self())
        <> "-"
        <> int.to_string(host_bootstrap.system_time_ms())
        <> "-"
        <> int.to_string(model.next_id)

      // Bound outside the closure for the same reason the catalogue job binds
      // its two: a reference to `model.workspace` would put the whole
      // presentation state, cached frame included, in the worker's copied
      // environment.
      let workspace = model.workspace.path
      let name = workspace.session_name(model.workspace)
      Model(
        ..model,
        creation_key: Some(key),
        overlay: NoOverlay,
        next_id: model.next_id + 1,
        next_attempt: model.next_attempt + 1,
        candidate: attachment.start_recorded(
          fn() {
            use host <- daemon_selection.with_live_control(host)
            daemon_selection.create_named(host, key, workspace, name, config)
          },
          90_000,
          recording.trace(model.recorder, attempt.Id(model.next_attempt)),
        ),
        notice: "creating a new session",
      )
    }
  }
}

/// Returns the value that follows `flag` in a launch argument list.
@internal
pub fn flag_value(
  arguments: List(String),
  flag: String,
) -> Result(String, Nil) {
  case arguments {
    [] | [_] -> Error(Nil)
    [name, value, ..rest] ->
      case name == flag {
        True -> Ok(value)
        False -> flag_value([value, ..rest], flag)
      }
  }
}
