//// The shell around the project board screen: opening it, keeping it current,
//// and filing the daemon's replies into it.
////
//// `tui/project_screen` is pure. This module is where the screen meets the
//// terminal's model: it starts the control jobs the screen asks for, takes the
//// outcome of each, and decides whether the frame needs repainting. It shares
//// the terminal's one control-job slot with the session picker and the access
//// overlay, so a read starts only when the slot is empty and an answer sent
//// while a read is in flight is refused with a line saying to try again,
//// keeping the person's draft.
////
//// ## Flow
////
//// `open` → `service` → `finish` → `act`
////
//// 1. `open` shows the screen for the working directory's project.
//// 2. `service` runs on every tick while the screen is open. It reads the
////    open ticket when its read is older than the board, and otherwise reads
////    the board when the poll's rest has passed.
//// 3. `finish` takes the outcome of a read or a change. A board whose
////    revision is the one already shown leaves the frame alone, so nothing is
////    repainted.
//// 4. `act` turns a key's `Action` into a job, a new state, or the worker's
////    session.

import gleam/option.{type Option, None, Some}
import session_view/project_board
import tui/job
import tui/model.{
  type Model, AccessManager, AgentInspector, ApprovalInspector, ControlRequest,
  DaemonSelector, EvolutionReview, GoalInspector, MemoryOverview, Model,
  ModelSelector, NoOverlay, PeerLinkManager, ProjectScreen, ProposalReview,
} as tui_model
import tui/project_screen
import tui/view_set

/// How long a read that failed rests before the next one, in milliseconds.
const failure_rest_ms = 10_000

/// Opens the screen for the project of the working directory and starts the
/// first read when the control slot is free. A terminal with no daemon
/// connection says so and opens nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_control.open(model)
/// ```
pub fn open(model: Model) -> Model {
  case model.view.daemon_host {
    None ->
      tui_model.append_error(
        model,
        "daemon control is unavailable; reconnect explicitly",
      )
    Some(_) ->
      shown(model, project_screen.new(model.view.workspace.path))
      |> service
  }
}

/// Starts the read the screen is due for, when the control slot is empty.
///
/// A ticket's page needs its own read first when the one it holds is older
/// than the board, and the board is polled when the rest after the last answer
/// has passed. Nothing is asked while another control request is running, and
/// a screen that is not open asks nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_control.service(model)
/// ```
pub fn service(model: Model) -> Model {
  // A read starts only for an open screen with a daemon connection and an empty
  // control slot. Any other combination leaves the model as it is, and the next
  // tick asks again.
  case open_screen(model), model.view.daemon_host, model.view.control_request {
    Some(state), Some(host), None -> {
      let now = model.shared.stamp.now_ms

      // The rest begins when the read does, so a slow answer is not followed
      // by a second request for the same board.
      case wanted(state, now) {
        Some(request) ->
          start(
            model,
            host,
            project_screen.rest(state, now + project_board.refresh_ms),
            request,
          )
        None -> model
      }
    }
    None, _, _ | Some(_), None, _ | Some(_), Some(_), Some(_) -> model
  }
}

/// Files the outcome of a project job into the open screen. An outcome that
/// arrives after the screen was closed changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_control.finish(model, job.ProjectBoardLoaded(document))
/// ```
pub fn finish(model: Model, outcome: job.ControlOutcome) -> Model {
  // An outcome for a screen that has been closed is dropped.
  case open_screen(model) {
    None -> model
    Some(state) -> {
      let next = filed(state, outcome, model.shared.stamp.now_ms)

      // Only the poll's rest differs when the board has the revision already
      // shown, and a frame that would look the same is not repainted.
      case project_screen.same_picture(state, next) {
        True -> held(model, next)
        False -> shown(model, next)
      }
    }
  }
}

/// Files a failed job: the notice says what happened and the poll rests, so a
/// daemon that cannot answer is asked once per rest and not once per tick.
///
/// ## Examples
///
/// ```gleam
/// // project_control.failed(model, "daemon control timed out")
/// ```
pub fn failed(model: Model, reason: String) -> Model {
  case open_screen(model) {
    None -> model
    Some(state) ->
      shown(
        model,
        state
          |> project_screen.failed(reason)
          |> project_screen.rest(model.shared.stamp.now_ms + failure_rest_ms),
      )
  }
}

/// Carries out what a key asked of the screen. `open_worker` opens a session
/// by id; it is passed in because the session controls import this module.
///
/// ## Examples
///
/// ```gleam
/// // project_control.act(project_screen.update(key, state), model, open_worker)
/// ```
pub fn act(
  action: project_screen.Action,
  model: Model,
  open_worker: fn(Model, String) -> Model,
) -> Model {
  case action {
    project_screen.Continue(state) -> shown(model, state)
    project_screen.Close ->
      Model(..model, view: view_set.overlay(model.view, NoOverlay))
      |> tui_model.invalidate_frame
    project_screen.Open(state, _) -> shown(model, state) |> service
    project_screen.Worker(session) -> open_worker(model, session)
    project_screen.Send(state, ticket, seq, text) ->
      change(model, state, answer(state, ticket, seq, text))
    project_screen.Accept(state, ticket) ->
      change(model, state, closing(state, ticket))
    project_screen.Retry(state, ticket) ->
      change(model, state, retry(state, ticket))
  }
}

// --- jobs --------------------------------------------------------------------

/// The open screen's state, if a project screen is the overlay.
fn open_screen(model: Model) -> Option(project_screen.State) {
  case model.view.overlay {
    ProjectScreen(state) -> Some(state)
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | AccessManager(_)
    | ApprovalInspector(_)
    | ProposalReview(_)
    | EvolutionReview(_)
    | MemoryOverview(_) -> None
  }
}

/// What the screen is due to read, if anything: the open ticket when its read
/// is missing or older than the board, and otherwise the board when its rest
/// has passed.
fn wanted(state: project_screen.State, now_ms: Int) -> Option(job.ControlJob) {
  case state.project, project_screen.open_ticket(state), state.board {
    Some(project), Some(ticket), Some(held) ->
      case stale(state, held) {
        True -> Some(job.ReadProjectTicket(project, ticket))
        False -> poll(state, now_ms)
      }
    Some(_), Some(_), None
    | Some(_), None, _
    | None, Some(_), _
    | None, None, _
    -> poll(state, now_ms)
  }
}

/// Whether the open ticket's read is missing or older than the board.
fn stale(state: project_screen.State, held: project_board.Board) -> Bool {
  case state.detail {
    None -> True
    Some(detail) -> detail.revision < held.revision
  }
}

/// The board read, when its rest has passed.
fn poll(state: project_screen.State, now_ms: Int) -> Option(job.ControlJob) {
  case project_screen.poll_due(state, now_ms) {
    False -> None
    True ->
      Some(
        job.ReadProjectBoard(case state.project {
          Some(id) -> job.ProjectId(id)
          None -> job.InWorkspace(state.workspace)
        }),
      )
  }
}

/// Starts a job in the control slot and shows the screen with its rest. The
/// screen is stored without a repaint, because starting a read changes nothing
/// a person can see.
fn start(
  model: Model,
  host: job.Daemon,
  state: project_screen.State,
  request: job.ControlJob,
) -> Model {
  let #(started, key) =
    tui_model.start_job(model, job.Control(host.control, request))

  Model(
    ..started,
    view: view_set.control_request(
      view_set.overlay(started.view, ProjectScreen(state)),
      Some(ControlRequest(job.awaiting(key), None)),
    ),
  )
}

/// Sends a change when the control slot is free. A busy slot keeps the draft
/// and says to try again, because dropping an answer silently would lose the
/// person's text.
fn change(
  model: Model,
  state: project_screen.State,
  request: Option(job.ProjectChange),
) -> Model {
  case model.view.control_request, model.view.daemon_host, request {
    Some(_), _, _ ->
      shown(
        model,
        project_screen.failed(
          state,
          "Another daemon request is running. Try again in a moment.",
        ),
      )
    None, Some(host), Some(sent) ->
      start(model, host, state, job.ChangeProject(sent))
    None, None, _ | None, Some(_), None -> shown(model, state)
  }
}

/// The answer a key sent, in the daemon's terms, when the screen knows the
/// project.
fn answer(
  state: project_screen.State,
  ticket: String,
  seq: Int,
  text: String,
) -> Option(job.ProjectChange) {
  option.map(state.project, fn(project) {
    job.AnswerTicket(project:, ticket:, seq:, text:)
  })
}

/// The close a key sent, when the screen knows the project.
fn closing(
  state: project_screen.State,
  ticket: String,
) -> Option(job.ProjectChange) {
  option.map(state.project, fn(project) { job.CloseTicket(project:, ticket:) })
}

/// The retry a key sent, when the screen knows the project.
fn retry(
  state: project_screen.State,
  ticket: String,
) -> Option(job.ProjectChange) {
  option.map(state.project, fn(project) { job.RetryTicket(project:, ticket:) })
}

// --- replies -----------------------------------------------------------------

/// The state after an outcome. An outcome of another kind of job cannot reach
/// an open project screen, and leaves it as it was.
fn filed(
  state: project_screen.State,
  outcome: job.ControlOutcome,
  now_ms: Int,
) -> project_screen.State {
  case outcome {
    job.ProjectBoardLoaded(document) ->
      case project_board.decode_board(document) {
        Ok(fresh) -> project_screen.observe(state, fresh, now_ms)
        Error(reason) -> project_screen.failed(state, reason)
      }
    job.ProjectTicketLoaded(document) ->
      case project_board.decode_detail(document) {
        Ok(detail) -> project_screen.observed_ticket(state, detail)
        Error(reason) -> project_screen.failed(state, reason)
      }
    job.ProjectChanged(job.AnswerTicket(..), None) ->
      project_screen.answered(state)
    job.ProjectChanged(job.AnswerTicket(..), Some(code)) ->
      project_screen.answer_refused(state, code)
    job.ProjectChanged(job.CloseTicket(..), None) ->
      project_screen.failed(state, "Ticket closed.")
    job.ProjectChanged(job.CloseTicket(..), Some(code)) ->
      project_screen.failed(
        state,
        "The daemon refused the close (" <> code <> ").",
      )
    job.ProjectChanged(job.RetryTicket(..), None) ->
      project_screen.failed(state, "Retry requested.")
    job.ProjectChanged(job.RetryTicket(..), Some(code)) ->
      project_screen.failed(
        state,
        "The daemon refused the retry (" <> code <> ").",
      )
    job.PageLoaded(..)
    | job.SessionDeleted(..)
    | job.SessionArchived(..)
    | job.SessionRestored(..)
    | job.SessionRenamed(..)
    | job.PeerWorkspaceLoaded(..)
    | job.PeerSessionsLoaded(..)
    | job.PeerInspectionLoaded(..)
    | job.PeerOperationCompleted(..)
    | job.AccessListed(..)
    | job.MembershipsListed(..)
    | job.AccessChanged(..) -> state
  }
}

/// Shows the screen and repaints.
fn shown(model: Model, state: project_screen.State) -> Model {
  Model(..model, view: view_set.overlay(model.view, ProjectScreen(state)))
  |> tui_model.invalidate_frame
}

/// Keeps the screen as the poll left it, without a repaint: only its rest
/// changed.
fn held(model: Model, state: project_screen.State) -> Model {
  Model(..model, view: view_set.overlay(model.view, ProjectScreen(state)))
}
