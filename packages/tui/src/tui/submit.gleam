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
import session_view/worktree_view
import tui/agents
import tui/attachment
import tui/effect
import tui/inbound
import tui/job
import tui/layout
import tui/model.{
  type Model, ActivityAsking, ActivityDue, ActivityResting, AgentInspector,
  DiffHidden, DiffVisible, Model, ModelSelector, NoOverlay, PromptNext,
  ReconnectAttempting, ReconnectIdle, ReconnectSpent, SteerNow, View,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/queue_editor
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

/// Shows or hides the agent rail.
@internal
pub fn toggle_agent_rail(model: Model) -> Model {
  let visible = !model.view.agent_rail_visible
  Model(
    shared: Shared(..model.shared, notice: case visible {
      True -> "agent rail shown"
      False -> "agent rail hidden"
    }),
    view: View(
      ..model.view,
      agent_rail_visible: visible,
      repaint_phase: !model.view.repaint_phase,
    ),
  )
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
