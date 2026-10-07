//// Daemon control: opening, creating, renaming, archiving and deleting
//// catalogue sessions, inspecting and mutating exact peer links, and
//// reattaching after a lost connection.
////
//// These requests go to the daemon's control socket rather than a session
//// channel, and each runs in a background job so the terminal never
//// waits on the daemon. At most one catalogue request runs at a time; a
//// second is refused with a transcript line rather than queued.
////
//// This module decides which request to make and what its outcome means.
//// It describes each request as a `job.Spec` and queues its start with a
//// key (`tui_model.start_job`); `tui/job_runner` runs it after the step.
//// The runtime admits each reply into the slot that names its key, and
//// the tick takes it from there through `drain_control`, `drain_reconnect`,
//// `drain_activity` and `drain_configuration`, which are also what a test
//// drives directly after handing the slot a reply with `runtime.hold`. An
//// opened session comes back as an attachment candidate instead, through
//// `tui/attachment`.
////
//// ## Flow
////
//// `load_catalogue` → `start_control` → `drain_control` → `apply_control_reply` → `staged` → `finish_control`
////
//// 1. An operator action calls a `begin_*` or `load_*` function (`load_catalogue`,
////    `begin_rename`, `begin_removal`, `begin_peer_link`, `begin_access_request`).
////    It refuses a second request while the one control slot is busy, then
////    `start_control` queues a `job.Control` with `tui_model.start_job` and
////    parks a `ControlRequest` on the view.
//// 2. The runtime puts the reply in that slot, and the tick calls `drain_control`,
////    which takes it with `job.take`.
//// 3. `apply_control_reply` maps every weft outcome (completed, failed, crashed,
////    abandoned, relay lost) to either a stored result or an error line;
////    `staged` keeps the result on the slot until the relay reports it is done.
//// 4. On `weft.AllDelivered`, `finish_control` applies the outcome: a catalogue
////    page opens the selector, a rename or removal updates the catalogue
////    (`catalogue_removed`), peer and access replies go to `finish_peer_workspace`,
////    `finish_peer_inspection`, `finish_access_listing` and `finish_access_change`.
//// 5. `begin_open` is the other half: it starts an attach job and an attachment
////    candidate, and `tui/attachment` finishes it.
//// 6. Three more slots follow the same shape: `drain_reconnect` (after a lost
////    connection), `drain_configuration` (`create_session`) and `drain_activity`
////    (`service_activity`).

import core/json
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/attempt
import session_view/shared_set
import tui/access_overlay
import tui/agents
import tui/attachment
import tui/daemon/protocol as control_protocol
import tui/inbound
import tui/job.{
  AccessChanged, AccessListed, MembershipsListed, PageLoaded,
  PeerInspectionLoaded, PeerOperationCompleted, PeerSessionsLoaded,
  PeerWorkspaceLoaded, SessionArchived, SessionDeleted, SessionRenamed,
  SessionRestored,
}
import tui/model.{
  type Model, AccessManager, ActivityAsking, ActivityDue, ActivityResting,
  AgentInspector, ApprovalInspector, ControlRequest, DaemonSelector,
  GoalInspector, Model, ModelSelector, NoOverlay, PeerLinkManager,
  ReconnectAttempting, ReconnectIdle, ReconnectSpent, View,
} as tui_model
import tui/peer_links
import tui/recording
import tui/session_selector
import tui/view_set
import tui/workspace
import weft

/// Takes the relaunch's next reply, if the runtime has admitted one, and
/// applies it.
///
/// A success reattaches the same session through the shipped open path, which
/// is what gives the operator a working channel again; the transcript it
/// already had is merged rather than replaced. A failure is terminal: the
/// attempt is marked spent and the reason is written to the transcript, so a
/// relaunch that cannot succeed is reported once instead of being retried.
/// Every `weft.Pulled` variant is named rather than swept up, because each is a
/// different fact about the attempt and a catch-all would hide a new one.
///
/// Only replies to the attempt in the slot reach it: the runtime admits a
/// reply only when its key is the slot's, so this compares nothing.
///
/// ## Examples
///
/// ```gleam
/// // session_control.drain_reconnect(runtime.hold(model, arrival))
/// ```
@internal
pub fn drain_reconnect(model: Model) -> Model {
  case model.view.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(job: awaiting) ->
      case job.take(awaiting) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) ->
          apply_reconnect_reply(
            Model(
              ..model,
              view: view_set.reconnect(
                model.view,
                ReconnectAttempting(awaiting),
              ),
            ),
            reply,
          )
      }
  }
}

// Once the attempt has an outcome the slot is spent, so the relay's
// `AllDelivered` that follows finds no slot naming its key and the runtime
// drops it.
fn apply_reconnect_reply(
  model: Model,
  reply: job.ReconnectReply(job.Daemon),
) -> Model {
  case reply {
    weft.NotYet -> model

    // The connection of the daemon that died stays in the runtime's table,
    // as it stayed unclosed on the model before control keys. It is one
    // entry per daemon death, and the reconnect is offered once per death.
    weft.PulledOutcome(weft.Completed(value: host, ..)) -> {
      let model =
        Model(..model, view: view_set.reconnect(model.view, ReconnectSpent))
      let model = tui_model.adopt_daemon(model, host)
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
      reconnect_failed(model, "the daemon relaunch ended without an outcome")
  }
}

// Reattaches the session the terminal was already showing. The identity comes
// from the model, so the operator's transcript and the daemon's registration
// are the same session; `begin_open` is the shipped path that resolves the
// current epoch and incarnation through control and adopts the new socket.
fn reattach_after_reconnect(model: Model) -> Model {
  case model.shared.session {
    "" ->
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "daemon reconnected; no session was attached",
        ),
      )
    session ->
      tui_model.append_system(
        begin_open(
          Model(
            ..model,
            shared: shared_set.notice(
              model.shared,
              "reattaching to " <> session,
            ),
          ),
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
    Model(..model, view: view_set.reconnect(model.view, ReconnectSpent)),
    "reconnect failed: " <> reason <> "; press /sessions to reconnect",
  )
}

// One deadline covers the whole attachment: the control open or create, the
// socket handshake and the initial cut.
const attach_timeout_ms = 90_000

/// Opens a catalogue session through daemon control as a recorded
/// attachment candidate, after cancelling any unsent frame for the old target.
@internal
pub fn begin_open(model: Model, session: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.shared.session)
  case attachment.busy(model.view.candidate), model.view.daemon_host {
    True, _ ->
      tui_model.append_error(model, "a session switch is already in progress")
    False, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    False, Some(host) -> {
      let #(model, key) =
        tui_model.start_job(
          model,
          job.Attach(job.OpenSession(host.control, session), attach_timeout_ms),
        )
      Model(
        shared: shared_set.notice(model.shared, "opening session " <> session),
        view: model.view
          |> view_set.overlay(NoOverlay)
          |> view_set.next_attempt(model.view.next_attempt + 1)
          |> view_set.candidate(attachment.opening(
            key,
            recording.trace(
              model.shared.recorder,
              attempt.Id(model.view.next_attempt),
            ),
          )),
      )
    }
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
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue page is already loading")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let model =
        start_control(
          model,
          host,
          job.LoadPage(
            command,
            collection,
            model.shared.session,
            model.view.workspace.path,
          ),
        )
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "loading authorized session metadata",
        ),
      )
    }
  }
}

// Starts one control job in the picker's slot. Every caller has already
// checked that the slot is free and that control is connected, so the job
// replaces nothing.
fn start_control(
  model: Model,
  host: job.Daemon,
  request: job.ControlJob,
) -> Model {
  let #(model, key) =
    tui_model.start_job(model, job.Control(host.control, request))
  Model(
    ..model,
    view: view_set.control_request(
      model.view,
      Some(ControlRequest(job.awaiting(key), None)),
    ),
  )
}

/// A rename shares the picker's one control job slot with paging, so a
/// rename while a page is in flight is refused rather than queued behind it.
/// The reply owns the displayed name. A timeout leaves the outcome unknown
/// and never causes the metadata mutation to be sent a second time.
@internal
pub fn begin_rename(model: Model, session: String, name: String) -> Model {
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue action is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let model = start_control(model, host, job.Rename(session, name))
      Model(
        ..model,
        shared: shared_set.notice(model.shared, "renaming session"),
      )
    }
  }
}

/// Permanently deletes a catalogue session through daemon control.
@internal
pub fn begin_delete(model: Model, session: String) -> Model {
  begin_removal(model, session, job.PermanentlyDelete)
}

/// Starts one archive or delete request against daemon control. Only one
/// catalogue request runs at a time; a second is refused with a transcript
/// error rather than queued.
@internal
pub fn begin_removal(
  model: Model,
  session: String,
  removal: job.Removal,
) -> Model {
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue request is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let model = start_control(model, host, job.Remove(session, removal))
      Model(
        ..model,
        shared: shared_set.notice(model.shared, case removal {
          job.Archive -> "stopping and archiving session " <> session
          job.Restore -> "restoring session " <> session
          job.PermanentlyDelete ->
            "stopping and permanently deleting session " <> session
        }),
      )
    }
  }
}

/// Takes the control job's next reply, if the runtime has admitted one,
/// and applies it.
///
/// The outcome is staged on the slot and applied only at the relay's
/// `AllDelivered`, which is what proves the worker is gone. Only replies to
/// the job in the slot reach it: the runtime admits a reply only when its
/// key is the slot's, so this compares nothing.
///
/// ## Examples
///
/// ```gleam
/// // session_control.drain_control(runtime.hold(model, arrival))
/// ```
@internal
pub fn drain_control(model: Model) -> Model {
  case model.view.control_request {
    None -> model
    Some(run) ->
      case job.take(run.job) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) ->
          apply_control_reply(
            model,
            ControlRequest(..run, job: awaiting),
            reply,
          )
      }
  }
}

fn apply_control_reply(
  model: Model,
  run: tui_model.ControlRequest,
  reply: job.ControlReply,
) -> Model {
  case reply {
    weft.NotYet ->
      Model(..model, view: view_set.control_request(model.view, Some(run)))
    weft.PulledOutcome(weft.Completed(value:, ..)) ->
      staged(model, run, Ok(value))
    weft.PulledOutcome(weft.Failed(error:, ..)) ->
      staged(model, run, Error(error))
    weft.PulledOutcome(weft.Crashed(reason:, ..))
    | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
      staged(model, run, Error(string.inspect(reason)))
    weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      staged(model, run, Error("control request did not complete"))
    weft.RunLost(reason) ->
      tui_model.append_error(
        Model(..model, view: view_set.control_request(model.view, None)),
        string.inspect(reason),
      )
    weft.AllDelivered ->
      finish_control(
        Model(..model, view: view_set.control_request(model.view, None)),
        run.result,
      )
  }
}

// Keeps an outcome on the slot until the relay reports that it is done.
fn staged(
  model: Model,
  run: tui_model.ControlRequest,
  result: Result(job.ControlOutcome, String),
) -> Model {
  Model(
    ..model,
    view: view_set.control_request(
      model.view,
      Some(ControlRequest(..run, result: Some(result))),
    ),
  )
}

fn finish_control(model: Model, result) {
  case result {
    Some(Ok(PageLoaded(page, selected, collection))) -> {
      let selector =
        session_selector.new(
          session_selector.prioritize(page, model.view.workspace.path),
          selected,
        )

      // A new page of the same collection is the same view to the operator,
      // so it keeps their filter and the last activity answers. A switch of
      // collection starts over: the archive has no resident rows.
      let selector = session_selector.State(..selector, collection:)
      let selector = case model.view.overlay {
        DaemonSelector(previous) if previous.collection == collection ->
          session_selector.carry(previous, selector)
        _ -> selector
      }
      Model(
        shared: shared_set.notice(model.shared, case collection {
          session_selector.Active ->
            "Enter opens · d archives · a shows archived sessions"
          session_selector.Archived ->
            "Enter restores · d permanently deletes · a shows active sessions"
        }),
        view: model.view
          |> view_set.overlay(DaemonSelector(selector))
          |> view_set.activity_poll(case model.view.activity_poll {
            ActivityAsking(..) -> model.view.activity_poll
            ActivityDue | ActivityResting(..) -> ActivityDue
          }),
      )
      |> tui_model.invalidate_frame
    }

    Some(Ok(SessionRenamed(row))) ->
      Model(
        shared: model.shared
          |> shared_set.session_label(
            case row.session_id == model.shared.session {
              True -> Some(#(row.session_id, row.name))
              False -> model.shared.session_label
            },
          )
          |> shared_set.notice("renamed session to " <> row.name),
        view: view_set.overlay(model.view, case model.view.overlay {
          DaemonSelector(selector) ->
            DaemonSelector(session_selector.renamed(selector, row))
          NoOverlay
          | ModelSelector(_)
          | AgentInspector(_)
          | GoalInspector(_)
          | ApprovalInspector(_)
          | PeerLinkManager(_)
          | AccessManager(_) -> model.view.overlay
        }),
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
    Some(Ok(AccessListed(document, after))) ->
      finish_access_listing(model, document, after)
    Some(Ok(MembershipsListed(document, principal, after))) ->
      finish_memberships(model, document, principal, after)
    Some(Ok(AccessChanged(document))) -> finish_access_change(model, document)
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
    shared: shared_set.notice(model.shared, description <> id),
    view: view_set.overlay(model.view, case model.view.overlay {
      DaemonSelector(selector) ->
        DaemonSelector(session_selector.without(selector, id))
      NoOverlay
      | ModelSelector(_)
      | AgentInspector(_)
      | GoalInspector(_)
      | ApprovalInspector(_)
      | PeerLinkManager(_)
      | AccessManager(_) -> model.view.overlay
    }),
  )
  |> tui_model.invalidate_frame
}

/// Creates a new daemon session from the local launch options, resolving
/// the session configuration before any creation key is retained.
///
/// Resolving the configuration reads the file system, so a terminal with
/// local launch options starts a `job.Configure` job and continues in
/// `drain_configuration` when the tick takes its reply. A terminal with no
/// local options has nothing to resolve and creates at once with no
/// configuration, as it always did.
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
  case model.view.local_options, model.view.configuring {
    None, _ -> create_session_configured(model, "")

    // A second press while the first resolution runs adds nothing: the
    // first creation continues when its configuration arrives.
    Some(_), Some(_) -> model
    Some(options), None -> {
      let #(model, key) = tui_model.start_job(model, job.Configure(options))
      Model(
        ..model,
        view: view_set.configuring(model.view, Some(job.awaiting(key))),
      )
    }
  }
}

/// Takes the configuration job's reply, if the runtime has admitted one,
/// and continues the session creation that asked for it.
///
/// A resolved configuration goes on to `create_session_configured`, which
/// makes every check and change the creation made when it resolved the
/// configuration inside the step: it cancels the pending submission,
/// refuses while a creation key is retained, control is disconnected or
/// another attachment is starting, and otherwise retains the key and starts
/// the attachment. A failure is written to the transcript, as it was, and
/// nothing else changes. The slot is cleared by the first outcome, so the
/// relay's `AllDelivered` that follows finds no slot naming its key and the
/// runtime drops it.
///
/// ## Examples
///
/// ```gleam
/// // session_control.drain_configuration(runtime.hold(model, arrival))
/// ```
@internal
pub fn drain_configuration(model: Model) -> Model {
  case model.view.configuring {
    None -> model
    Some(awaiting) ->
      case job.take(awaiting) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) ->
          apply_configuration_reply(
            Model(
              ..model,
              view: view_set.configuring(model.view, Some(awaiting)),
            ),
            reply,
          )
      }
  }
}

fn apply_configuration_reply(
  model: Model,
  reply: job.ConfigurationReply,
) -> Model {
  let finished = Model(..model, view: view_set.configuring(model.view, None))
  case reply {
    weft.NotYet -> model

    // The key press that asked for this painted the picker still open, and
    // the tick repaints only when the frame revision moves, so the closed
    // picker and the creation notice need an invalidation of their own. The
    // failure arms below get theirs from `append_error`.
    weft.PulledOutcome(weft.Completed(value: config, ..)) ->
      create_session_configured(finished, config)
      |> tui_model.invalidate_frame
    weft.PulledOutcome(weft.Failed(error:, ..)) ->
      tui_model.append_error(finished, error)
    weft.PulledOutcome(weft.Crashed(reason:, ..))
    | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
      tui_model.append_error(finished, string.inspect(reason))
    weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      tui_model.append_error(
        finished,
        "resolving the session configuration did not complete",
      )
    weft.RunLost(reason) ->
      tui_model.append_error(finished, string.inspect(reason))
    weft.AllDelivered ->
      tui_model.append_error(
        finished,
        "the configuration job ended without an outcome",
      )
  }
}

// The model profile the launch asked for, which only a local launch has:
// `--model-profile` is one of its options, and a terminal attached to a remote
// session has none. Empty means the configuration's default roles.
fn chosen_profile(model: Model) -> String {
  case model.view.local_options {
    Some(options) -> options.profile
    None -> ""
  }
}

fn create_session_configured(model: Model, config: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.shared.session)
  case
    model.view.creation_key,
    model.view.daemon_host,
    attachment.busy(model.view.candidate)
  {
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
      // The terminal's identity and the wall-clock reading make the key
      // unique across terminals and restarts, and `next_id` across
      // attempts within one terminal. Both are read before the step, so
      // building the key reads no clock and no process identity.
      let key =
        "tui-"
        <> model.view.terminal
        <> "-"
        <> int.to_string(model.view.wall_ms)
        <> "-"
        <> int.to_string(model.shared.next_id)

      let route =
        job.CreateSession(
          host.control,
          key,
          model.view.workspace.path,
          workspace.session_name(model.view.workspace),
          config,
          chosen_profile(model),
        )
      let #(model, job_key) =
        tui_model.start_job(model, job.Attach(route, attach_timeout_ms))
      Model(
        shared: model.shared
          |> shared_set.next_id(model.shared.next_id + 1)
          |> shared_set.notice("creating a new session"),
        view: View(
          ..{
            model.view
            |> view_set.overlay(NoOverlay)
            |> view_set.next_attempt(model.view.next_attempt + 1)
            |> view_set.candidate(attachment.opening(
              job_key,
              recording.trace(
                model.shared.recorder,
                attempt.Id(model.view.next_attempt),
              ),
            ))
          },
          creation_key: Some(key),
        ),
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
      Model(..model, view: view_set.overlay(model.view, PeerLinkManager(next)))
      |> tui_model.invalidate_frame
    peer_links.Close ->
      Model(
        shared: shared_set.notice(
          model.shared,
          "peer links closed; composer draft retained",
        ),
        view: view_set.overlay(model.view, case state.return_to {
          peer_links.Conversation -> NoOverlay
          peer_links.Agents(inspector) -> AgentInspector(inspector)
          peer_links.Sessions(selector) -> DaemonSelector(selector)
        }),
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
    peer_links.new(model.shared.session, model.shared.active_strand),
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
    peer_links.from_agent(model.shared.session, inspector),
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
      model.shared.session,
      model.shared.active_strand,
      selector,
      target,
    ),
  )
}

fn begin_peer_workspace_state(model: Model, state: peer_links.State) {
  case
    model.shared.session,
    model.view.daemon_host,
    model.view.control_request
  {
    "", _, _ ->
      tui_model.append_error(model, "peer links require an attached session")
    _, _, Some(_) ->
      tui_model.append_error(model, "another daemon control request is running")
    _session, Some(host), None -> {
      let model =
        start_control(
          model,
          host,
          job.LoadPeerWorkspace(state.source_session, state.source_strand),
        )
      Model(
        shared: shared_set.notice(
          model.shared,
          "loading owner-authorized peer grants",
        ),
        view: view_set.overlay(model.view, PeerLinkManager(state)),
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
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
    None, Some(host) -> {
      let model =
        start_control(model, host, job.InspectPeers(session, strand, after))
      Model(
        ..model,
        shared: shared_set.notice(model.shared, case after {
          None -> "refreshing peer grants"
          Some(_) -> "loading next peer page"
        }),
      )
    }
  }
}

// The chooser reads only metadata under the first page's catalogue revision.
fn begin_peer_sessions(model: Model, after: String, revision: Int) {
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
    None, Some(host) -> {
      let model =
        start_control(model, host, job.LoadPeerSessions(after, revision))
      Model(
        ..model,
        shared: shared_set.notice(model.shared, "loading more target sessions"),
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
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
    None, Some(host) -> {
      let model = start_control(model, host, job.MutatePeers(command))
      Model(
        ..model,
        shared: shared_set.notice(
          model.shared,
          "sending one directional peer operation",
        ),
      )
    }
  }
}

fn finish_peer_workspace(
  model: Model,
  page: control_protocol.Page,
  document: json.JsonValue,
) {
  case model.view.overlay {
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
            view: view_set.overlay(
              model.view,
              PeerLinkManager(peer_links.loaded(
                peer_links.catalogue(state, page),
                page.sessions,
                inspection.inspection,
                inspection.next,
              )),
            ),
          )
          |> tui_model.invalidate_frame
        Error(reason) ->
          Model(
            ..model,
            view: view_set.overlay(
              model.view,
              PeerLinkManager(peer_links.failed(state, reason)),
            ),
          )
          |> tui_model.invalidate_frame
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_)
    | AccessManager(_) -> model
  }
}

fn finish_peer_sessions(model: Model, page: control_protocol.Page) {
  case model.view.overlay {
    PeerLinkManager(state) ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          PeerLinkManager(case state.session_revision {
            Some(revision) if revision == page.revision ->
              peer_links.append_sessions(state, page)
            _ -> peer_links.failed(state, "target session catalogue changed")
          }),
        ),
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
  case model.view.overlay {
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
            view: view_set.overlay(
              model.view,
              PeerLinkManager(case after {
                None ->
                  peer_links.loaded(
                    state,
                    state.sessions,
                    page.inspection,
                    page.next,
                  )
                Some(_) -> peer_links.append_page(state, page)
              }),
            ),
          )
          |> tui_model.invalidate_frame
        Error(reason) ->
          Model(
            ..model,
            view: view_set.overlay(
              model.view,
              PeerLinkManager(peer_links.failed(state, reason)),
            ),
          )
          |> tui_model.invalidate_frame
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_)
    | AccessManager(_) -> model
  }
}

fn finish_peer_operation(model: Model, document: json.JsonValue) {
  case model.view.overlay {
    PeerLinkManager(state) -> {
      let notice = peer_links.completed(state, document)
      begin_peer_inspection(
        Model(
          ..model,
          view: view_set.overlay(model.view, PeerLinkManager(notice)),
        ),
        state.source_session,
        state.source_strand,
        None,
      )
    }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_)
    | AccessManager(_) -> model
  }
}

fn finish_control_failure(model: Model, reason: String) {
  case model.view.overlay {
    PeerLinkManager(state) ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          PeerLinkManager(peer_links.failed(state, reason)),
        ),
      )
      |> tui_model.invalidate_frame
    AccessManager(state) ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AccessManager(access_overlay.failed(state, reason)),
        ),
      )
      |> tui_model.invalidate_frame
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> tui_model.append_error(model, reason)
  }
}

/// Opens the owner's `/access` overlay and reads its first page.
///
/// The overlay does not need an attached session, only the daemon's control
/// connection. Whether that connection is the owner's is the daemon's
/// judgment: a member is refused `forbidden` and the overlay says so.
///
/// ## Examples
///
/// ```gleam
/// // session_control.begin_access(model)
/// ```
pub fn begin_access(model: Model) -> Model {
  case model.view.daemon_host, model.view.control_request {
    _, Some(_) ->
      tui_model.append_error(model, "another daemon control request is running")
    None, None ->
      tui_model.append_error(model, "daemon owner control is unavailable")
    Some(host), None -> {
      let model =
        start_control(
          model,
          host,
          job.ReadAccess(control_protocol.ListPrincipals(None)),
        )
      Model(
        ..model,
        view: view_set.overlay(model.view, AccessManager(access_overlay.new())),
      )
      |> tui_model.invalidate_frame
    }
  }
}

/// Applies one key to the access overlay and starts the request it asks for.
///
/// ## Examples
///
/// ```gleam
/// // session_control.update_access_overlay(key, model, state)
/// ```
pub fn update_access_overlay(key, model: Model, state: access_overlay.State) {
  case access_overlay.update(key, state) {
    access_overlay.Continue(next) -> show_access(model, next)
    access_overlay.Close ->
      Model(
        shared: shared_set.notice(model.shared, "access overlay closed"),
        view: view_set.overlay(model.view, NoOverlay),
      )
      |> tui_model.invalidate_frame
    access_overlay.ReadPrincipals(next, after) ->
      begin_access_request(
        model,
        next,
        job.ReadAccess(control_protocol.ListPrincipals(after)),
      )
    access_overlay.ReadMemberships(next, principal, after) ->
      begin_access_request(
        model,
        next,
        job.ReadAccess(control_protocol.PrincipalMemberships(principal, after)),
      )
    access_overlay.Apply(next, change) ->
      begin_access_request(
        model,
        next,
        job.ChangeAccess(access_command(change)),
      )
  }
}

// The control command for one reviewed change. The epoch is added where the
// command is encoded, from the hello of the connection that sends it.
fn access_command(change: access_overlay.Change) -> control_protocol.Command {
  case change {
    access_overlay.SetRole(session_id:, principal_id:, role:, ..) ->
      control_protocol.SetMemberRole(session_id, principal_id, role)
    access_overlay.RevokeMembership(session_id:, principal_id:, ..) ->
      control_protocol.RevokeMembership(session_id, principal_id)
    access_overlay.RevokeCredentials(principal_id:, ..) ->
      control_protocol.RevokeCredentials(principal_id)
  }
}

fn show_access(model: Model, state: access_overlay.State) -> Model {
  Model(..model, view: view_set.overlay(model.view, AccessManager(state)))
  |> tui_model.invalidate_frame
}

// One control request at a time. When another is running, nothing is sent and
// the overlay says so on its own notice line; a reviewed change that meets a
// busy slot returns to browsing unsent, so the operator can repeat it.
fn begin_access_request(
  model: Model,
  state: access_overlay.State,
  request: job.ControlJob,
) -> Model {
  case model.view.control_request, model.view.daemon_host {
    Some(_), _ ->
      show_access(
        model,
        access_overlay.failed(
          state,
          "another daemon control request is running",
        ),
      )
    None, None ->
      show_access(
        model,
        access_overlay.failed(state, "daemon owner control is unavailable"),
      )
    None, Some(host) -> show_access(start_control(model, host, request), state)
  }
}

fn finish_access_listing(
  model: Model,
  document: json.JsonValue,
  after: Option(String),
) -> Model {
  case model.view.overlay {
    AccessManager(state) ->
      case access_overlay.decode_principals(document) {
        Ok(page) ->
          show_access(model, access_overlay.listed(state, page, after))
        Error(reason) ->
          show_access(model, access_overlay.failed(state, reason))
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | ApprovalInspector(_) -> model
  }
}

fn finish_memberships(
  model: Model,
  document: json.JsonValue,
  principal: String,
  after: Option(String),
) -> Model {
  case model.view.overlay {
    AccessManager(state) ->
      case access_overlay.decode_memberships(document, principal) {
        Ok(page) ->
          show_access(
            model,
            access_overlay.memberships_listed(state, principal, page, after),
          )
        Error(reason) ->
          show_access(model, access_overlay.failed(state, reason))
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | ApprovalInspector(_) -> model
  }
}

// An acknowledged change is followed by the read that shows its effect. The
// acknowledgement itself is drawn by the overlay from what was reviewed. A
// change acknowledged after the overlay closed leaves one transcript line.
fn finish_access_change(model: Model, document: json.JsonValue) -> Model {
  case model.view.overlay {
    AccessManager(state) ->
      case access_overlay.changed(state, document) {
        access_overlay.ReadPrincipals(next, after) ->
          begin_access_request(
            model,
            next,
            job.ReadAccess(control_protocol.ListPrincipals(after)),
          )
        access_overlay.ReadMemberships(next, principal, after) ->
          begin_access_request(
            model,
            next,
            job.ReadAccess(control_protocol.PrincipalMemberships(
              principal,
              after,
            )),
          )
        access_overlay.Continue(next) -> show_access(model, next)
        access_overlay.Close | access_overlay.Apply(..) -> model
      }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | ApprovalInspector(_) ->
      tui_model.append_system(model, "access change acknowledged")
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
  case model.view.overlay, model.view.daemon_host {
    DaemonSelector(selector), Some(host) ->
      case activity_due(model), session_selector.resident_ids(selector) {
        True, [_, ..] as ids -> start_activity(model, host, ids)
        _, _ -> model
      }
    _, _ -> model
  }
}

fn activity_due(model: Model) -> Bool {
  case model.view.activity_poll {
    ActivityDue -> True
    ActivityResting(until_ms:) -> model.shared.stamp.now_ms >= until_ms
    ActivityAsking(..) -> False
  }
}

fn start_activity(model: Model, host: job.Daemon, ids: List(String)) -> Model {
  let #(model, key) =
    tui_model.start_job(model, job.Activity(host.control, ids))

  // Closing the picker does not cancel this job: its deadline and its own
  // connection bound what it can hold, and its answer is dropped by
  // `drain_activity` when no picker is open to take it. A quit cancels it.
  Model(
    ..model,
    view: view_set.activity_poll(
      model.view,
      ActivityAsking(job.awaiting(key), ids),
    ),
  )
}

/// Takes the activity job's next reply, if the runtime has admitted one.
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
  case model.view.activity_poll {
    ActivityDue | ActivityResting(..) -> model
    ActivityAsking(job: awaiting, asked:) ->
      case job.take(awaiting) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) ->
          apply_activity_reply(
            Model(
              ..model,
              view: view_set.activity_poll(
                model.view,
                ActivityAsking(awaiting, asked),
              ),
            ),
            asked,
            reply,
          )
      }
  }
}

fn apply_activity_reply(
  model: Model,
  asked: List(String),
  reply: job.ActivityReply,
) -> Model {
  case reply {
    weft.PulledOutcome(weft.Completed(value:, ..)) ->
      observe_activity(model, asked, value)
    weft.AllDelivered | weft.RunLost(_) ->
      Model(
        ..model,
        view: view_set.activity_poll(
          model.view,
          ActivityResting(model.shared.stamp.now_ms + activity_interval_ms),
        ),
      )
    weft.NotYet | weft.PulledOutcome(_) -> model
  }
}

fn observe_activity(
  model: Model,
  asked: List(String),
  rows: List(control_protocol.Activity),
) -> Model {
  case model.view.overlay {
    DaemonSelector(selector) ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          DaemonSelector(session_selector.observe(selector, asked, rows)),
        ),
      )
      |> tui_model.invalidate_frame
    _ -> model
  }
}
