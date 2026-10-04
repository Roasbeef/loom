//// Composer submission and the commands that change the conversation's
//// target.
////
//// `submit` parses the composer's text and routes it: a session command,
//// a prompt, a steer or a follow-up goes to the shared step as a
//// `msg.Submit` (`commands.submit`), and a surface command, which opens a
//// terminal panel or reaches the daemon's control connection, is carried
//// out here. The module also owns the input history, the terminal forms of
//// the interrupt, the stop and the quit, and the switch of strand, which
//// must cancel unsent frames first so a queued frame cannot reach the
//// wrong target.
////
//// ## Flow
////
//// `submit` parses input and separates shared session commands from
//// terminal surface commands handled by `submit_surface`.
//// `delivery` selects the prompt or steer mode for shared submission.
//// `toggle_submission_mode` refuses steering while an interrupt is active.
//// `interrupt_active` delegates to the shared command reducer.
//// `switch_active_strand` cancels unsent intent before changing its target.

import etui/widgets/textarea as text_area
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/command
import session_view/commands
import session_view/composer
import session_view/context_view
import session_view/model.{ComposerSubmission, OverlaySubmission, Shared} as session_model
import session_view/msg
import session_view/operator
import session_view/protocol
import session_view/surfaces
import session_view/worktree_view
import tui/agent_strip
import tui/agents
import tui/attachment
import tui/effect
import tui/inbound
import tui/job
import tui/layout
import tui/layout_memory
import tui/model.{
  type Model, ActivityAsking, ActivityDue, ActivityResting, AgentInspector,
  DiffHidden, DiffVisible, Model, ModelSelector, NoOverlay, PromptNext,
  ReconnectAttempting, ReconnectIdle, ReconnectSpent, SteerNow, View,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/queue_editor
import tui/rail
import tui/session_control
import tui/side_surfaces

/// Opens the agent workspace on the active strand.
@internal
pub fn open_agents(model: Model) -> Model {
  Model(
    shared: Shared(..model.shared, notice: "agent workspace"),
    view: View(
      ..model.view,
      overlay: AgentInspector(agents.inspect(model.shared.active_strand)),
      repaint_phase: !model.view.repaint_phase,
    ),
  )
}

/// Submits the composer's text.
///
/// The draft is parsed here, and the parse decides who acts on it. A
/// session command goes to the shared step as `msg.Submit`
/// (`commands.submit`), which refuses a mutation the attachment cannot
/// accept, keeps the draft, and otherwise dispatches it; what that did to
/// the draft comes back as a `DraftTaken` fact or a move of `drafts_sent`,
/// and the terminal empties its own editor from those. A surface command is
/// the terminal's, and is carried out here (`submit_surface`).
///
/// ## Examples
///
/// ```gleam
/// let model = submit.submit(model)
/// ```
@internal
pub fn submit(model: Model) -> Model {
  let draft = text_area.value(model.view.input)
  case command.parse_with_skills(draft, model.shared.skills) {
    command.Session(session) ->
      inbound.run_settled(model, commands.act(
        _,
        msg.Submit(
          draft:,
          command: session,
          delivery: delivery(model.view.submission_mode),
        ),
      ))

    // No surface command mutates the session, so none is refused before
    // encoding or marks the draft; each releases a marker left by a frame
    // that is no longer queued, as every submission does.
    command.Surface(surface) ->
      submit_surface(model, surface)
      |> tui_model.run_shared(commands.release_submission)
  }
}

// The composer's mode, in the session's terms.
fn delivery(mode: tui_model.SubmissionMode) -> operator.Delivery {
  case mode {
    PromptNext -> operator.Prompt
    SteerNow -> operator.Steer
  }
}

// A surface command with images attached is carried out only when it opens
// a panel that leaves the draft alone; any other would consume the draft
// and lose the images with it, so it is refused and the draft kept.
fn submit_surface(model: Model, surface: command.Surface) -> Model {
  case composer.has_images(model.shared.attachments), surface {
    False, _
    | True, command.QueueInspect
    | True, command.Diff
    | True, command.Trace
    | True, command.Summary
    | True, command.Context
    | True, command.ContextAll
    -> surface_command(model, surface)
    True, command.Help
    | True, command.Models
    | True, command.Strands
    | True, command.Agents
    | True, command.PeerLinks
    | True, command.Access
    | True, command.Sessions
    | True, command.Rename(_)
    | True, command.Notes
    | True, command.Details
    | True, command.Strand(_)
    | True, command.GoalStatus
    | True, command.Quit
    ->
      tui_model.append_error(
        model,
        "image attachments can only accompany an ordinary prompt",
      )
  }
}

/// Opens the session picker, as `/sessions` does, without touching the draft.
///
/// ## Examples
///
/// ```gleam
/// // submit.open_session_selector(model)
/// ```
@internal
pub fn open_session_selector(model: Model) -> Model {
  case model.view.daemon_host {
    Some(_) -> session_control.load_catalogue(model, "", None)
    None ->
      tui_model.append_error(
        model,
        "daemon control is unavailable; reconnect explicitly",
      )
  }
}

// One surface command. The draft is consumed first, text into the input
// history, unless a submission still locked behind the lane owns it.
fn surface_command(model: Model, surface: command.Surface) -> Model {
  let cleared = case model.shared.pending_submission {
    Some(ComposerSubmission) -> model
    Some(OverlaySubmission) | None -> tui_model.clear_composer_text(model)
  }
  case surface {
    command.Quit -> quit(cleared)
    command.Help ->
      Model(
        shared: Shared(
          ..cleared.shared,
          note_board: None,
          notes_requested: None,
          notice: "/help",
        ),
        view: View(
          ..cleared.view,
          help_open: True,
          notes_open: False,
          note_selected: None,
          scroll_offset: 0,
          repaint_phase: !cleared.view.repaint_phase,
        ),
      )

    // The selector opens on what the session already lists, and a `models`
    // read refreshes it when the daemon answers.
    command.Models -> {
      let opened =
        Model(
          shared: Shared(..cleared.shared, notice: "model selector"),
          view: View(
            ..cleared.view,
            overlay: ModelSelector(model_selector.new(
              model.shared.models,
              model.shared.current_model,
            )),
            repaint_phase: !cleared.view.repaint_phase,
          ),
        )
      tui_model.send_frame(opened, protocol.models(opened.shared.next_id))
    }
    command.Strands | command.Agents -> open_agents(cleared)
    command.PeerLinks -> session_control.begin_peer_workspace(cleared)
    command.Access -> session_control.begin_access(cleared)
    command.Sessions -> open_session_selector(cleared)
    command.Rename(name) ->
      case cleared.shared.session {
        "" -> tui_model.append_error(cleared, "no session is attached")
        id -> session_control.begin_rename(cleared, id, name)
      }
    command.Notes ->
      side_surfaces.refresh_notes(Model(
        shared: Shared(
          ..cleared.shared,
          worktree: worktree_view.State(
            ..cleared.shared.worktree,
            focus: worktree_view.Composer,
          ),
          notice: "agent notes",
        ),
        view: View(
          ..cleared.view,
          help_open: False,
          diff_view: DiffHidden,
          notes_open: True,
          note_mode: note_panel.Readable,
          note_scroll: 0,
          scroll_offset: 0,
          repaint_phase: !cleared.view.repaint_phase,
        ),
      ))
    command.QueueInspect -> open_queue(cleared)
    command.Summary -> side_surfaces.open_summary(cleared)
    command.Trace -> open_trace_tab(cleared)
    command.Context ->
      side_surfaces.open_context(cleared, context_view.Overview)
    command.ContextAll -> side_surfaces.open_context(cleared, context_view.All)
    command.Diff -> open_diff(cleared)
    command.Details -> toggle_details(cleared)

    // A change of strand is the terminal's to drive: the lane's cancelled
    // frames are applied one update at a time, with the terminal's writes
    // between them (`switch_active_strand`).
    command.Strand(name) ->
      case session_model.is_known_strand(cleared.shared.strands, name) {
        True ->
          tui_model.append_system(
            switch_active_strand(cleared, name),
            "active strand: " <> name,
          )
        False -> tui_model.append_error(cleared, "unknown strand: " <> name)
      }
    command.GoalStatus -> side_surfaces.request_goal_status(cleared)
  }
}

/// The draft is captured exactly once when navigation leaves the live editor.
/// Returning past the newest history item restores those unsent bytes rather
/// than replacing them with an empty prompt.
@internal
pub fn navigate_history(model: Model, older: Bool) -> Model {
  let #(history_index, history_draft, value) =
    history_selection(
      model.view.history,
      model.view.history_index,
      model.view.history_draft,
      text_area.value(model.view.input),
      older,
    )
  Model(
    ..model,
    view: View(
      ..model.view,
      input: text_area.state_from_string(value),
      history_index:,
      history_draft:,
    ),
  )
}

/// Selects the next prompt-history value without owning terminal state.
///
/// ## Examples
///
/// ```gleam
/// assert tui.history_selection(["new", "old"], 0, "", "draft", True)
///   == #(1, "draft", "new")
/// assert tui.history_selection(["new"], 1, "draft", "new", False)
///   == #(0, "draft", "draft")
/// ```
@internal
pub fn history_selection(
  history: List(String),
  index: Int,
  draft: String,
  current: String,
  older: Bool,
) -> #(Int, String, String) {
  let saved_draft = case index == 0, older {
    True, True -> current
    _, _ -> draft
  }
  let target = case older {
    True -> int.min(list.length(history), index + 1)
    False -> int.max(0, index - 1)
  }
  case target {
    0 -> #(0, saved_draft, saved_draft)
    _ ->
      case history_item(history, target - 1) {
        Some(value) -> #(target, saved_draft, value)
        None -> #(index, saved_draft, current)
      }
  }
}

fn history_item(history: List(String), index: Int) -> Option(String) {
  case history, index {
    [item, ..], 0 -> Some(item)
    [_, ..rest], index -> history_item(rest, index - 1)
    [], _ -> None
  }
}

/// Switches the composer between prompting next and steering the running
/// turn. Steering is offered only while the active strand is live.
/// Held input resumes with an ordinary prompt, not by arming another steer.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.toggle_submission_mode(model)
/// ```
@internal
pub fn toggle_submission_mode(model: Model) -> Model {
  case
    session_model.active_interrupt(model.shared),
    session_model.active_strand_live(model.shared),
    model.view.submission_mode
  {
    Some(_), _, _ ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          notice: "stopped · enter sends held input with your message",
        ),
      )
    None, False, _ ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          notice: "steering is available while an agent runs",
        ),
      )
    None, True, PromptNext ->
      Model(
        shared: Shared(..model.shared, notice: "steer now"),
        view: View(..model.view, submission_mode: SteerNow),
      )
    None, True, SteerNow ->
      Model(
        shared: Shared(..model.shared, notice: "queue for next turn"),
        view: View(..model.view, submission_mode: PromptNext),
      )
  }
}

/// Sends an interrupt for the active strand's running operation, once.
///
/// The terminal's form of `commands.interrupt_active`. The composer returns
/// to prompting when the interrupt is sent (`InterruptRequested`).
///
/// ## Examples
///
/// ```gleam
/// let model = submit.interrupt_active(model)
/// ```
@internal
pub fn interrupt_active(model: Model) -> Model {
  inbound.run_settled(model, commands.act(_, msg.Interrupt))
}

/// Stops one strand's running operation from the agent strip.
///
/// The terminal's form of `commands.stop_strand`: the active strand is
/// interrupted, as Escape interrupts it, and any other strand is sent a bare
/// `abort`.
///
/// ## Examples
///
/// ```gleam
/// // submit.stop_strand(model, "sub:main/audit-1a2b")
/// ```
@internal
pub fn stop_strand(model: Model, strand: String) -> Model {
  inbound.run_settled(model, commands.act(_, msg.Stop(strand)))
}

/// Terminals encode Alt+character as Escape followed by that character. If a
/// user begins typing immediately after Escape, the backend cannot distinguish
/// the two intentions before its disambiguation timeout. The client reserves no
/// Alt shortcuts, so preserving both actions here avoids dropping the first
/// byte of a replacement steer.
@internal
pub fn interrupt_and_insert(model: Model, character: String) -> Model {
  let interrupted = interrupt_active(model)
  let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
  Model(
    ..interrupted,
    view: View(
      ..interrupted.view,
      input: text_area.insert_char(editor, interrupted.view.input, character),
    ),
  )
}

/// Docks or hides the rail, and records the choice.
///
/// The choice is what the layout memory keeps. On a terminal too narrow to
/// dock the rail the same key opens and closes the sheet instead, which is
/// not a choice and is not recorded: it is the rail's form for a terminal that
/// cannot spare a column. While the changes are open the rail is on Changes
/// and cannot be hidden, so the same key closes them.
@internal
pub fn toggle_agent_rail(model: Model) -> Model {
  case layout.diff_shown(model) && layout.rail_present(model) {
    True ->
      Model(
        shared: Shared(..model.shared, notice: "changes closed"),
        view: View(
          ..model.view,
          diff_view: DiffHidden,
          repaint_phase: !model.view.repaint_phase,
        ),
      )
    False ->
      case model.view.width >= rail.narrowest {
        False ->
          case layout.sheet_shown(model) {
            True -> close_sheet(model)
            False -> open_sheet(model)
          }
        True -> {
          let docked = layout.rail_columns(model) > 0
          let choice = case docked {
            True -> layout_memory.RailHidden
            False -> layout_memory.RailShown
          }
          Model(
            shared: Shared(..model.shared, notice: case docked {
              True -> "rail hidden"
              False -> "rail docked"
            }),
            view: View(
              ..model.view,
              rail: Some(choice),
              repaint_phase: !model.view.repaint_phase,
            ),
          )
        }
      }
  }
}

/// Expands or collapses transcript details such as reasoning and tool
/// output.
@internal
pub fn toggle_details(model: Model) -> Model {
  let expanded = !model.shared.details_expanded
  Model(
    shared: Shared(
      ..model.shared,
      details_expanded: expanded,
      notice: case expanded {
        True -> "details expanded"
        False -> "details collapsed"
      },
    ),
    view: View(..model.view, repaint_phase: !model.view.repaint_phase),
  )
}

/// Queues the cancellation of every background worker and request, the
/// close of the attachment, and the Herdr pane's release, and marks the
/// model as quitting.
///
/// Nothing is cancelled or closed during the step. The adopted lane's close
/// is queued first and the cancels after it, in the order they were once
/// performed. The runtime runs all of them after the step, before the loop
/// sees `quit` and exits, and the release is what that ordering is for:
/// the pane is clear of this terminal before the process that cleared it
/// is gone.
@internal
pub fn quit(model: Model) -> Model {
  // The adopted lane closes ahead of the provisional attempt, in the
  // session's half of the quit. A recording has always noted the adopted
  // lane's close before the attempt's, whose close the `Abandon` below
  // decides only when the runtime performs it.
  let model = tui_model.run_shared(model, commands.act(_, msg.Quit))

  // The attempt moves into its cancel effect, which closes what it opened.
  let model =
    Model(..model, view: View(..model.view, candidate: attachment.idle()))
    |> tui_model.emit_attachment(attachment.Abandon(model.view.candidate))

  // Every running job is cancelled by its key, and its slot is cleared in
  // the same step, so nothing a cancelled job sends afterwards is admitted
  // into a slot. The control job goes first and the relaunch after it, in
  // the order they were once cancelled; the activity poll, which used to
  // run on to its own deadline, follows them, and a session creation's
  // configuration job, which did not exist while the step resolved the
  // configuration itself, is cancelled last.
  let model = case model.view.control_request {
    None -> model
    Some(run) ->
      Model(..model, view: View(..model.view, control_request: None))
      |> tui_model.emit(effect.CancelJob(job.key(run.job)))
  }

  // A relaunch may be mid-start when the operator quits. Cancelling it stops
  // spawning a daemon nobody will talk to, and the close below covers the
  // control owner it may already have minted.
  let model = case model.view.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(job: awaiting) ->
      Model(..model, view: View(..model.view, reconnect: ReconnectSpent))
      |> tui_model.release_reconnect(awaiting)
      |> tui_model.emit(effect.CancelJob(job.key(awaiting)))
  }
  let model = case model.view.activity_poll {
    ActivityDue | ActivityResting(..) -> model
    ActivityAsking(job: awaiting, ..) ->
      Model(..model, view: View(..model.view, activity_poll: ActivityDue))
      |> tui_model.emit(effect.CancelJob(job.key(awaiting)))
  }
  let model = case model.view.configuring {
    None -> model
    Some(awaiting) ->
      Model(..model, view: View(..model.view, configuring: None))
      |> tui_model.emit(effect.CancelJob(job.key(awaiting)))
  }
  let model = case model.view.daemon_host {
    None -> model
    Some(host) -> tui_model.emit(model, effect.CloseControl(host.control))
  }

  // The Herdr release is queued last, after every close, at the last point
  // the model still owns everything it reported: a pane the terminal no
  // longer holds should not spend its safety-net second showing an agent
  // that has already gone. The exchange itself is bounded, so a dead socket
  // delays the runtime's final drain by at most the release deadline pair.
  case model.view.herdr_reporter {
    None -> model
    Some(reporter) -> tui_model.emit(model, effect.ReleaseHerdr(reporter))
  }
}

/// Makes `strand` the active strand, cancelling unsent frames for the old
/// one and re-projecting the captured cut, or asking for the strand's
/// configuration when nothing is captured.
///
/// The session's half is three units, each applied with its facts before
/// the next: the lane's cancellation (`cancel_pending`), `commands.focus`,
/// and `commands.load_strand`. Between the last two the terminal closes its
/// overlay and forgets the footer's outlook, so the cut's approval decisions
/// read a terminal with no dialog open, as they always have.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.switch_active_strand(model, "worker")
/// ```
@internal
pub fn switch_active_strand(model: Model, strand: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.shared.session)
  let focused = inbound.run_settled(model, commands.focus(_, strand))
  let selected =
    Model(
      ..focused,
      view: View(
        ..focused.view,
        overlay: NoOverlay,
        cache_outlook: "",
        repaint_phase: !focused.view.repaint_phase,
      ),
    )
  let around = inbound.surroundings(selected)
  inbound.run_settled(selected, commands.load_strand(_, strand, around))
}

/// Shows `tab` on the rail, docking the rail if it can be and is not.
///
/// This is what the digit keys and the `/diff`, `/trace` and `/summary`
/// commands do. Changes opens the changes, which is the changes setting's.
/// Any other tab closes them if they were open, is remembered as the
/// operator's tab, and starts at its top. Strands gives the keyboard back to
/// the composer, and Session asks for a fresh read of the live jobs, which
/// its jobs row reports.
///
/// A terminal too narrow to dock the rail has nowhere to show a tab, so it is
/// left as it is. The caller says so in a notice.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.select_rail_tab(model, rail.Trace)
/// ```
@internal
pub fn select_rail_tab(model: Model, tab: rail.Tab) -> Model {
  let chosen = choose_rail_tab(model, tab)

  // The sheet is a place the keyboard goes to, so choosing a tab in it
  // leaves the keyboard there; the docked rail leaves it where it was.
  case layout.sheet_shown(chosen) {
    True -> focus_sheet(chosen)
    False -> chosen
  }
}

fn choose_rail_tab(model: Model, tab: rail.Tab) -> Model {
  case tab {
    rail.Changes ->
      case layout.diff_shown(model) {
        True -> model
        False -> open_diff(model)
      }
    rail.Strands | rail.Trace | rail.Session -> {
      let closed = case layout.diff_shown(model) {
        True -> open_diff(model)
        False -> model
      }
      let chosen =
        Model(
          ..closed,
          view: View(
            ..closed.view,
            rail_tab: rail.remembered(tab),
            rail_scroll: 0,
            rail_focus: tui_model.FocusComposer,
            sheet: sheet_for(closed),
            rail: docked_choice(closed),
          ),
        )
      let left =
        tui_model.store_strip(
          chosen,
          agent_strip.leave(tui_model.strip(chosen)),
        )
      let read = case tab {
        rail.Session ->
          Model(
            ..left,
            shared: Shared(..left.shared, jobs_refresh: worktree_view.Requested),
          )
          |> tui_model.run_shared(surfaces.service_jobs_read)
        rail.Strands | rail.Changes | rail.Trace -> left
      }
      read
      |> tui_model.invalidate_transcript
      |> tui_model.invalidate_frame
    }
  }
}

// The rail's choice after something asks for it to be shown: shown, when the
// terminal is wide enough to dock it and the rail is not already docked, and
// what it was otherwise. A rail docked by default at 160 columns is not a
// choice, so choosing a tab on it must not make it dock at 120 next launch.
fn docked_choice(model: Model) -> Option(layout_memory.Rail) {
  case model.view.width >= rail.narrowest, layout.rail_columns(model) {
    True, 0 -> Some(layout_memory.RailShown)
    True, _ | False, _ -> model.view.rail
  }
}

// Whether choosing a tab on this terminal opens the sheet: it does where the
// rail cannot dock, and means nothing where it can.
fn sheet_for(model: Model) -> tui_model.Sheet {
  case model.view.width < rail.narrowest {
    True -> tui_model.SheetOpen
    False -> model.view.sheet
  }
}

/// Opens the sheet on the tab the operator left the rail on, and gives it
/// the keyboard.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.open_sheet(model)
/// ```
@internal
pub fn open_sheet(model: Model) -> Model {
  Model(..model, view: View(..model.view, sheet: tui_model.SheetOpen))
  |> focus_sheet
  |> tui_model.invalidate_transcript
  |> tui_model.invalidate_frame
}

/// Closes the sheet and gives the keyboard back to the composer.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.close_sheet(model)
/// ```
@internal
pub fn close_sheet(model: Model) -> Model {
  let closed =
    Model(
      ..model,
      view: View(
        ..model.view,
        sheet: tui_model.SheetClosed,
        rail_focus: tui_model.FocusComposer,
      ),
    )
  tui_model.store_strip(closed, agent_strip.leave(tui_model.strip(closed)))
  |> tui_model.invalidate_transcript
  |> tui_model.invalidate_frame
}

// The keyboard goes to the sheet. On Strands, with agents to choose among,
// that is the list's cursor; otherwise, and on every other tab but Changes,
// which has its own focus, it is the tab itself.
fn focus_sheet(model: Model) -> Model {
  case layout.rail_tab(model) {
    rail.Changes -> model
    rail.Strands ->
      case layout.strands_listed(model) {
        True ->
          tui_model.store_strip(
            model,
            agent_strip.enter(
              tui_model.strip(model),
              layout.strip_lines(model),
              model.shared.active_strand,
            ),
          )
        False ->
          Model(
            ..model,
            view: View(..model.view, rail_focus: tui_model.FocusTab),
          )
      }
    rail.Trace | rail.Session ->
      Model(..model, view: View(..model.view, rail_focus: tui_model.FocusTab))
  }
}

/// Hands the sheet off to the rail when a resize makes the terminal wide
/// enough to dock one: the sheet is closed, so it does not come back if the
/// terminal narrows again. The other direction is not followed: narrowing a
/// terminal that had the rail docked leaves the sheet closed, because opening
/// it would cover the transcript the person was reading.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.hand_off_sheet(model)
/// ```
@internal
pub fn hand_off_sheet(model: Model) -> Model {
  case model.view.sheet, model.view.width >= rail.narrowest {
    tui_model.SheetOpen, True ->
      Model(
        ..model,
        view: View(
          ..model.view,
          sheet: tui_model.SheetClosed,
          rail_focus: tui_model.FocusComposer,
        ),
      )
    tui_model.SheetOpen, False | tui_model.SheetClosed, _ -> model
  }
}

/// `/trace`: the Trace tab, on the docked rail where there is one and on the
/// sheet where there is not.
///
/// ## Examples
///
/// ```gleam
/// let model = submit.open_trace_tab(model)
/// ```
@internal
pub fn open_trace_tab(model: Model) -> Model {
  select_rail_tab(model, rail.Trace)
}

/// Opens held-input inspection without touching composer text or attachments.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_queue(model)
/// ```
@internal
pub fn open_queue(model: Model) -> Model {
  Model(
    ..model,
    view: View(
      ..model.view,
      queue_editor: queue_editor.open(model.view.queue_editor),
    ),
  )
  |> tui_model.invalidate_frame
}

/// Opens current worktree inspection without changing composer ownership.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_diff(model)
/// ```
@internal
pub fn open_diff(model: Model) -> Model {
  case layout.diff_shown(model) {
    True -> Model(..model, view: View(..model.view, diff_view: DiffHidden))
    False ->
      inbound.refresh_worktree(
        Model(
          ..model,
          view: View(
            ..model.view,
            diff_view: DiffVisible,
            diff_scroll_offset: 0,
            help_open: False,
            notes_open: False,
          ),
        ),
      )
  }
  |> tui_model.invalidate_transcript
  |> tui_model.invalidate_frame
}
