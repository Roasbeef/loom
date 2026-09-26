//// Daemon control: opening, creating, renaming, archiving and deleting
//// catalogue sessions, inspecting and mutating exact peer links, and
//// reattaching after a lost connection.
////
//// These requests go to the daemon's control socket rather than a session
//// channel, and each runs in a background worker so the terminal never
//// waits on the daemon. At most one catalogue request runs at a time; a
//// second is refused with a transcript line rather than queued. The
//// worker's result comes back as a `ControlEvent`, a `ReconnectEvent` or,
//// for an opened session, an attachment candidate event, and the tick
//// drains each. `accept_control_event` and `accept_reconnect_event` are
//// the entry points a test drives directly.

import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import tui/agents
import tui/attachment
import tui/attempt
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/inbound
import tui/model.{
  type ControlEvent, type Model, ActivityAsking, ActivityDue, ActivityResting,
  AgentInspector, ApprovalInspector, ControlRequest, DaemonSelector,
  GoalInspector, Model, ModelSelector, NoOverlay, PageLoaded,
  PeerInspectionLoaded, PeerLinkManager, PeerOperationCompleted,
  PeerSessionsLoaded, PeerWorkspaceLoaded, ReconnectAttempting, ReconnectIdle,
  ReconnectSpent, SessionArchived, SessionDeleted, SessionRenamed,
  SessionRestored, SessionSelector,
} as tui_model
import tui/peer_links
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

      // A new page of the same collection is the same view to the operator,
      // so it keeps their filter and the last activity answers. A switch of
      // collection starts over: the archive has no resident rows.
      let selector = session_selector.State(..selector, collection:)
      let selector = case model.overlay {
        DaemonSelector(previous) if previous.collection == collection ->
          session_selector.carry(previous, selector)
        _ -> selector
      }
      Model(
        ..model,
        overlay: DaemonSelector(selector),
        activity_poll: case model.activity_poll {
          ActivityAsking(..) -> model.activity_poll
          ActivityDue | ActivityResting(..) -> ActivityDue
        },
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
          | SessionSelector(_)
          | PeerLinkManager(_) -> model.overlay
        },
        notice: "renamed session to " <> row.name,
      )
      |> tui_model.invalidate_frame

    // The row is dropped from the page already on screen rather than by
    // re-listing: the reply proves this identity is gone, and a fresh page
    // would move every other row under the operator's cursor.
    Some(Ok(PeerWorkspaceLoaded(page, document))) ->
      finish_peer_workspace(model, page, document)
    Some(Ok(PeerSessionsLoaded(page))) -> finish_peer_sessions(model, page)
    Some(Ok(PeerInspectionLoaded(document, after))) ->
      finish_peer_inspection(model, document, after)
    Some(Ok(PeerOperationCompleted(document))) ->
      finish_peer_operation(model, document)
    Some(Ok(SessionDeleted(id))) ->
      catalogue_removed(model, id, "deleted session ")
    Some(Ok(SessionArchived(id))) ->
      catalogue_removed(model, id, "archived session ")
    Some(Ok(SessionRestored(id))) ->
      catalogue_removed(model, id, "restored session ")
    Some(Error(reason)) -> finish_control_failure(model, reason)
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
      | SessionSelector(_)
      | PeerLinkManager(_) -> model.overlay
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

/// Applies one peer-manager key without changing the attached conversation.
///
/// ## Examples
///
/// ```gleam
/// // session_control.update_peer_link_manager(key, model, state)
/// ```
pub fn update_peer_link_manager(key, model, state) {
  case peer_links.update(key, state) {
    peer_links.Continue(next) ->
      Model(..model, overlay: PeerLinkManager(next))
      |> tui_model.invalidate_frame
    peer_links.Close ->
      Model(
        ..model,
        overlay: case state.return_to {
          peer_links.Conversation -> NoOverlay
          peer_links.Agents(inspector) -> AgentInspector(inspector)
          peer_links.Sessions(selector) -> DaemonSelector(selector)
        },
        notice: "peer links closed; composer draft retained",
      )
      |> tui_model.invalidate_frame
    peer_links.Inspect(session, strand) ->
      begin_peer_inspection(model, session, strand, None)
    peer_links.NextPage(cursor) ->
      begin_peer_inspection(
        model,
        state.source_session,
        state.source_strand,
        Some(cursor),
      )
    peer_links.NextSessions(cursor, revision) ->
      begin_peer_sessions(model, cursor, revision)
    peer_links.Link(proposal) -> begin_peer_link(model, proposal)
    peer_links.Unlink(grant) -> begin_peer_unlink(model, grant)
  }
}

/// Opens peer management for the attached strand.
///
/// ## Examples
///
/// ```gleam
/// // session_control.begin_peer_workspace(model)
/// ```
pub fn begin_peer_workspace(model: Model) {
  begin_peer_workspace_state(
    model,
    peer_links.new(model.session, model.active_strand),
  )
}

/// Opens peer management from an agent inspection, retaining its selection.
///
/// ## Examples
///
/// ```gleam
/// // session_control.begin_peer_workspace_for(model, inspector)
/// ```
pub fn begin_peer_workspace_for(model: Model, inspector: agents.Inspector) {
  begin_peer_workspace_state(
    model,
    peer_links.from_agent(model.session, inspector),
  )
}

/// Opens the selected target session in the peer manager without attaching it.
///
/// ## Examples
///
/// ```gleam
/// // session_control.begin_peer_workspace_for_session(model, selector, row)
/// ```
pub fn begin_peer_workspace_for_session(
  model: Model,
  selector: session_selector.State,
  target: control_protocol.Session,
) {
  begin_peer_workspace_state(
    model,
    peer_links.from_session(
      model.session,
      model.active_strand,
      selector,
      target,
    ),
  )
}

fn begin_peer_workspace_state(model: Model, state: peer_links.State) {
  case model.session, model.daemon_host, model.control_request {
    "", _, _ ->
      tui_model.append_error(model, "peer links require an attached session")
    _, _, Some(_) ->
      tui_model.append_error(model, "another daemon control request is running")
    _session, Some(host), None -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use sessions_reply <- result.try(
              daemon.request(
                daemon_selection.control(host),
                control_protocol.ListSessions("", None),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            use page <- result.try(case sessions_reply {
              control_protocol.SessionsReply(page) -> Ok(page)
              _ -> Error("peer catalogue returned an unexpected reply")
            })
            use inspection_reply <- result.try(
              daemon.request(
                daemon_selection.control(host),
                control_protocol.InspectPeers(
                  state.source_session,
                  state.source_strand,
                  None,
                ),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            use document <- result.try(case inspection_reply {
              control_protocol.PeersInspectionReply(document) -> Ok(document)
              _ -> Error("peer inspection returned an unexpected reply")
            })
            Ok(PeerWorkspaceLoaded(page, document))
          },
        ])
        |> weft.deadline(15_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        overlay: PeerLinkManager(state),
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "loading owner-authorized peer grants",
      )
      |> tui_model.invalidate_frame
    }
    _, None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
  }
}

fn begin_peer_inspection(
  model: Model,
  session: String,
  strand: String,
  after: Option(String),
) {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
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
                control_protocol.InspectPeers(session, strand, after),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            case reply {
              control_protocol.PeersInspectionReply(document) ->
                Ok(PeerInspectionLoaded(document, after))
              _ -> Error("peer inspection returned an unexpected reply")
            }
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: case after {
          None -> "refreshing peer grants"
          Some(_) -> "loading next peer page"
        },
      )
    }
  }
}

// The chooser reads only metadata under the first page's catalogue revision.
fn begin_peer_sessions(model: Model, after: String, revision: Int) {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
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
                control_protocol.ListSessions(after, Some(revision)),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            case reply {
              control_protocol.SessionsReply(page) ->
                Ok(PeerSessionsLoaded(page))
              _ -> Error("peer catalogue returned an unexpected reply")
            }
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "loading more target sessions",
      )
    }
  }
}

fn begin_peer_link(model: Model, proposal: peer_links.Proposal) {
  run_peer_mutation(
    model,
    control_protocol.LinkPeers(
      proposal.source_session,
      proposal.source_strand,
      proposal.target_session,
      proposal.target_strand,
      proposal.wake,
    ),
  )
}

fn begin_peer_unlink(model: Model, grant: peer_links.Grant) {
  run_peer_mutation(
    model,
    control_protocol.UnlinkPeers(
      grant.source_session,
      grant.source_strand,
      grant.target_session,
      grant.target_strand,
    ),
  )
}

fn run_peer_mutation(model: Model, command: control_protocol.Command) {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use reply <- result.try(
              daemon.request(daemon_selection.control(host), command, 5000)
              |> result.map_error(daemon_selection.failure),
            )
            case reply {
              control_protocol.PeersMutationReply(document) ->
                Ok(PeerOperationCompleted(document))
              _ -> Error("peer mutation returned an unexpected reply")
            }
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "sending one directional peer operation",
      )
    }
  }
}

fn finish_peer_workspace(
  model: Model,
  page: control_protocol.Page,
  document: json.JsonValue,
) {
  case model.overlay {
    PeerLinkManager(state) ->
      case
        peer_links.decode_inspection_page(
          document,
          state.source_session,
          state.source_strand,
        )
      {
        Ok(inspection) ->
          Model(
            ..model,
            overlay: PeerLinkManager(peer_links.loaded(
              peer_links.catalogue(state, page),
              page.sessions,
              inspection.inspection,
              inspection.next,
            )),
          )
          |> tui_model.invalidate_frame
        Error(reason) ->
          Model(
            ..model,
            overlay: PeerLinkManager(peer_links.failed(state, reason)),
          )
          |> tui_model.invalidate_frame
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> model
  }
}

fn finish_peer_sessions(model: Model, page: control_protocol.Page) {
  case model.overlay {
    PeerLinkManager(state) ->
      Model(
        ..model,
        overlay: PeerLinkManager(case state.session_revision {
          Some(revision) if revision == page.revision ->
            peer_links.append_sessions(state, page)
          _ -> peer_links.failed(state, "target session catalogue changed")
        }),
      )
      |> tui_model.invalidate_frame
    _ -> model
  }
}

fn finish_peer_inspection(
  model: Model,
  document: json.JsonValue,
  after: Option(String),
) {
  case model.overlay {
    PeerLinkManager(state) ->
      case
        peer_links.decode_inspection_page(
          document,
          state.source_session,
          state.source_strand,
        )
      {
        Ok(page) ->
          Model(
            ..model,
            overlay: PeerLinkManager(case after {
              None ->
                peer_links.loaded(
                  state,
                  state.sessions,
                  page.inspection,
                  page.next,
                )
              Some(_) -> peer_links.append_page(state, page)
            }),
          )
          |> tui_model.invalidate_frame
        Error(reason) ->
          Model(
            ..model,
            overlay: PeerLinkManager(peer_links.failed(state, reason)),
          )
          |> tui_model.invalidate_frame
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> model
  }
}

fn finish_peer_operation(model: Model, document: json.JsonValue) {
  case model.overlay {
    PeerLinkManager(state) -> {
      let notice = peer_links.completed(state, document)
      begin_peer_inspection(
        Model(..model, overlay: PeerLinkManager(notice)),
        state.source_session,
        state.source_strand,
        None,
      )
    }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> model
  }
}

fn finish_control_failure(model: Model, reason: String) {
  case model.overlay {
    PeerLinkManager(state) ->
      Model(..model, overlay: PeerLinkManager(peer_links.failed(state, reason)))
      |> tui_model.invalidate_frame
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> tui_model.append_error(model, reason)
  }
}

/// How long the picker waits after one activity answer before asking again.
///
/// Three seconds is often enough that a session which just started or
/// finished work changes tab while the operator is looking, and rare enough
/// that an open picker costs the daemon one small request, and one
/// authenticated handshake, every few seconds.
const activity_interval_ms = 3000

/// Starts one activity request when the picker is open on resident rows and
/// the last answer has rested long enough.
///
/// Nothing is asked while the picker is closed, on the archive, or when its
/// page holds no resident row, so an idle terminal sends nothing. The request
/// runs on a control connection the worker opens and closes itself: the
/// terminal's borrowed control has one outstanding slot, which an operator's
/// page turn must never find occupied by a poll.
///
/// ## Examples
///
/// ```gleam
/// // session_control.service_activity(model)
/// ```
@internal
pub fn service_activity(model: Model) -> Model {
  case model.overlay, model.daemon_host {
    DaemonSelector(selector), Some(host) ->
      case activity_due(model), session_selector.resident_ids(selector) {
        True, [_, ..] as ids -> start_activity(model, host, ids)
        _, _ -> model
      }
    _, _ -> model
  }
}

fn activity_due(model: Model) -> Bool {
  case model.activity_poll {
    ActivityDue -> True
    ActivityResting(until_ms:) -> model.monotonic_time_ms() >= until_ms
    ActivityAsking(..) -> False
  }
}

fn start_activity(
  model: Model,
  host: daemon_selection.Host,
  ids: List(String),
) -> Model {
  let replies = process.new_subject()

  // Only the route and the identities cross into the worker, bound here for
  // the reason the catalogue job gives: a closure over a model field would
  // copy the whole presentation state into it.
  let _relay =
    weft.new([
      fn() {
        use owned <- result.try(daemon_selection.reconnect(host, process.self()))
        let control = daemon_selection.control(owned)
        let reply =
          daemon.request(control, control_protocol.SessionActivity(ids), 5000)
        daemon.close(control)
        use reply <- result.try(result.map_error(
          reply,
          daemon_selection.failure,
        ))
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
      },
    ])
    |> weft.deadline(9000)
    |> weft.start_relayed(replies)

  // Closing the picker does not stop this worker: its deadline and its
  // own connection bound what it can hold, and its answer is dropped by
  // `drain_activity` when no picker is open to take it.
  Model(..model, activity_poll: ActivityAsking(replies, ids))
}

/// Takes the activity worker's next relayed message, if one has arrived.
///
/// An answer is applied only to a picker that is still open, and `observe`
/// applies it only to rows still on its page, so an answer that outlived its
/// page or its picker changes nothing. A refusal or a lost worker is not an
/// operator error: the rows stay as they were, marked by whatever the last
/// answer said, and the poll rests before asking again. An older daemon that
/// does not know `sessions.activity` is therefore asked once per interval
/// while the picker is open and costs nothing more.
///
/// ## Examples
///
/// ```gleam
/// // session_control.drain_activity(model)
/// ```
@internal
pub fn drain_activity(model: Model) -> Model {
  case model.activity_poll {
    ActivityDue | ActivityResting(..) -> model
    ActivityAsking(replies:, asked:) ->
      case process.receive(replies, 0) {
        Error(Nil) -> model
        Ok(weft.PulledOutcome(weft.Completed(value:, ..))) ->
          observe_activity(model, asked, value)
        Ok(weft.AllDelivered) | Ok(weft.RunLost(_)) ->
          Model(
            ..model,
            activity_poll: ActivityResting(
              model.monotonic_time_ms() + activity_interval_ms,
            ),
          )
        Ok(weft.NotYet) | Ok(weft.PulledOutcome(_)) -> model
      }
  }
}

fn observe_activity(
  model: Model,
  asked: List(String),
  rows: List(control_protocol.Activity),
) -> Model {
  case model.overlay {
    DaemonSelector(selector) ->
      Model(
        ..model,
        overlay: DaemonSelector(session_selector.observe(selector, asked, rows)),
      )
      |> tui_model.invalidate_frame
    _ -> model
  }
}
