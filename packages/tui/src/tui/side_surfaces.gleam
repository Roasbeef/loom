//// The terminal's half of the side surfaces: which notes the notes surface
//// shows, whether it is on screen, and what opening or moving one of the
//// terminal's panels asks of the session.
////
//// The side surfaces' reads, replies and edges are session work and live in
//// `session_view/surfaces`, over the shared record alone. What is here
//// reads the terminal's overlay and panels before it decides, so it takes
//// the whole model: the notes target and the notes surface are the agent
//// inspector's tab or the standalone `/notes` panel, a note's selection is
//// the panel's cursor, and opening the summary, the goal inspector or a
//// context surface writes the terminal's own panel state beside the
//// session's request. Each stores a shared read through
//// `tui_model.run_shared`, as it did when both halves were one module.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import session_view/context_view
import session_view/model.{
  Attached, Disconnected, HoldGoalReport, Preview, Replaying, ReportGoal,
}
import session_view/shared_set
import session_view/surfaces
import session_view/worktree_view
import tui/agents
import tui/focused_goal_panel
import tui/model.{
  type Model, AccessManager, AgentInspector, ApprovalInspector, DaemonSelector,
  GoalInspector, Model, ModelSelector, NoOverlay, PeerLinkManager,
} as tui_model
import tui/queue_editor
import tui/render
import tui/summary_panel
import tui/view_set

/// Inspection has its own target. Reading a worker's notes never changes the
/// active strand, its parked draft, or the next submitted message.
@internal
pub fn notes_target(model: Model) -> String {
  case model.view.overlay {
    AgentInspector(agents.Inspector(detail: agents.Notes, selected:, ..)) ->
      selected
    _ -> model.shared.active_strand
  }
}

/// Whether a notes surface is on screen: standalone `/notes`, or the
/// agent inspector's Notes tab.
@internal
pub fn notes_surface(model: Model) -> Bool {
  case model.view.notes_open, model.view.overlay {
    True, _
    | False, AgentInspector(agents.Inspector(detail: agents.Notes, ..))
    -> True
    False, NoOverlay
    | False, ModelSelector(_)
    | False, GoalInspector(_)
    | False, DaemonSelector(_)
    | False, PeerLinkManager(_)
    | False, AccessManager(_)
    | False, AgentInspector(_)
    | False, ApprovalInspector(_)
    -> False
  }
}

/// Asks for a fresh read of the notes board for the strand the notes
/// surface is showing. The target is the terminal's, so this takes the
/// whole model.
@internal
pub fn refresh_notes(model: Model) -> Model {
  Model(
    ..model,
    shared: model.shared
      |> shared_set.notes_requested(Some(notes_target(model)))
      |> shared_set.notice("refreshing notes for " <> notes_target(model)),
  )
  |> tui_model.run_shared(surfaces.service_notes_read)
}

/// Moves the note selection by `direction`, clamped to the board.
@internal
pub fn select_note(model: Model, direction: Int) -> Model {
  let target = notes_target(model)
  case model.shared.note_board {
    Some(board) if board.strand == target -> {
      let index =
        list.index_map(board.notes, fn(note, position) {
          #(Some(note.key), position)
        })
        |> list.key_find(render.selected_note(model, board))
        |> result.unwrap(0)
      let next =
        int.clamp(
          index + direction,
          0,
          int.max(0, list.length(board.notes) - 1),
        )
      let selected =
        list.drop(board.notes, next)
        |> list.first
        |> result.map(fn(note) { note.key })
        |> option.from_result

      // Note navigation moves only the surface that owns this key. The
      // transcript beneath an inspector retains its independent anchor.
      Model(
        ..model,
        view: model.view
          |> view_set.note_selected(selected)
          |> view_set.note_scroll(0),
      )
      |> tui_model.invalidate_transcript
    }
    _ -> model
  }
}

/// Opens detailed completion evidence while preserving the ordinary composer.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_summary(model)
/// ```
@internal
pub fn open_summary(model: Model) -> Model {
  Model(
    shared: shared_set.jobs_refresh(model.shared, worktree_view.Requested),
    view: model.view
      |> view_set.summary_surface(queue_editor.Inspector)
      |> view_set.summary_scroll(0)
      |> view_set.summary_tab(summary_panel.Completion)
      |> view_set.summary_job_selected(0),
  )
  |> tui_model.run_shared(surfaces.service_jobs_read)
  |> tui_model.invalidate_frame
}

/// Opens the goal inspector and asks for a fresh goal board. The preview
/// mode shows an illustrative observation instead.
@internal
pub fn request_goal_status(model: Model) -> Model {
  let panel = case model.view.overlay {
    GoalInspector(state) -> state
    _ -> focused_goal_panel.new(model.shared.goal, goal_observation(model))
  }
  case model.shared.peer {
    Preview ->
      Model(
        shared: model.shared
          |> shared_set.goal_report(HoldGoalReport)
          |> shared_set.notice("goal inspector · illustrative observation"),
        view: model.view
          |> view_set.overlay(GoalInspector(panel))
          |> view_set.toggle_repaint,
      )
    Attached | Disconnected | Replaying ->
      Model(
        shared: model.shared
          |> shared_set.goal_refresh(worktree_view.Requested)
          |> shared_set.goal_report(ReportGoal),
        view: model.view
          |> view_set.overlay(GoalInspector(panel))
          |> view_set.toggle_repaint,
      )
  }
}

fn goal_observation(model: Model) -> String {
  case model.shared.goal, model.shared.peer {
    Some(_), Attached -> "Last server observation · refreshing"
    Some(_), Disconnected -> "Last server observation · disconnected"
    Some(_), Preview | Some(_), Replaying -> "Illustrative observation"
    None, Attached -> "Reading current goal"
    None, Disconnected -> "Goal unavailable · disconnected"
    None, Preview | None, Replaying -> "Goal unavailable in this preview"
  }
}

/// Opens context inspection while retaining the composer's draft and selection.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_context(model, context_view.Overview)
/// ```
@internal
pub fn open_context(model: Model, surface: context_view.Surface) -> Model {
  Model(
    ..model,
    shared: shared_set.context(
      model.shared,
      context_view.State(
        ..context_view.invalidate(model.shared.context),
        surface:,
        scroll: 0,
      ),
    ),
  )
  |> tui_model.run_shared(surfaces.service_context_read)
}
