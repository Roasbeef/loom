//// Composer submission and the commands that change the conversation's
//// target.
////
//// `submit` turns the composer's text into a prompt, a steer, a follow-up
//// or a slash command, and sends it through `tui/outbound`. It also owns
//// the input history, image prompts, interrupts, and the switches of
//// strand and session that must cancel unsent frames first so a queued
//// frame cannot reach the wrong target.

import core/message
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/command
import session_view/composer
import session_view/context_view
import session_view/operator
import session_view/pasted_image
import session_view/protocol
import session_view/session_channel
import session_view/text_hygiene
import session_view/transcript_line.{
  type Submission, Assistant, HeldPrompt, Interjection, Line, User,
}
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
import tui/outbound
import tui/queue_editor
import tui/session_control
import tui/session_model.{
  Attached, ComposerSubmission, Disconnected, Interrupt, OverlaySubmission,
  Preview, Replaying, Shared,
}
import tui/surfaces

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

/// Submits the composer's text. A mutation the attachment cannot accept is
/// refused before encoding, and the draft is kept.
@internal
pub fn submit(model: Model) -> Model {
  case
    outbound.mutation_refusal(
      model,
      command.parse_with_skills(
        text_area.value(model.view.input),
        model.shared.skills,
      ),
    )
  {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      // This marker scopes the synchronous encoder call and, only if queued,
      // the later send. The draft itself never leaves its existing fields.
      let prepared = case
        outbound.mutating_submission(
          model,
          command.parse_with_skills(
            text_area.value(model.view.input),
            model.shared.skills,
          ),
        ),
        model.shared.peer
      {
        True, Attached ->
          Model(
            ..model,
            shared: Shared(
              ..model.shared,
              pending_submission: Some(ComposerSubmission),
            ),
          )
        _, _ -> model
      }
      let after = submit_admitted(prepared)
      case after.shared.channel {
        Some(channel) ->
          case session_channel.has_unsent(channel) {
            True -> after
            False ->
              Model(
                ..after,
                shared: Shared(..after.shared, pending_submission: None),
              )
          }
        None ->
          Model(
            ..after,
            shared: Shared(..after.shared, pending_submission: None),
          )
      }
    }
  }
}

fn submit_admitted(model: Model) -> Model {
  case composer.has_images(model.shared.attachments) {
    True -> submit_with_images(model)
    False -> submit_text(model)
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

fn submit_text(model: Model) -> Model {
  let input = text_area.value(model.view.input)
  let expanded = composer.expand(input, model.shared.attachments)
  let cleared = case model.shared.pending_submission {
    Some(ComposerSubmission) -> model
    Some(OverlaySubmission) | None -> outbound.clear_composer_text(model)
  }
  let prompt_cleared = case model.shared.pending_submission {
    Some(ComposerSubmission) -> cleared
    Some(OverlaySubmission) | None ->
      Model(
        shared: Shared(..cleared.shared, attachments: []),
        view: View(..cleared.view, submission_mode: PromptNext),
      )
  }
  case command.parse_with_skills(input, model.shared.skills) {
    command.Empty ->
      case model.shared.attachments {
        [] -> cleared
        _ -> send_prompt(prompt_cleared, expanded)
      }
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
    command.Clear ->
      Model(
        shared: Shared(
          ..cleared.shared,
          transcript: [],
          records: [],
          record_cache_epoch: cleared.shared.record_cache_epoch + 1,
          compact_call_cache: dict.new(),
          compact_entry_cache: dict.new(),
          pending_records: [],
          record_cache_valid: False,
          // `/clear` empties the local view, and an echo is part of that view
          // rather than something it is drawn over.
          queued: [],
          awaiting_outcome: None,
          notice: "local view cleared",
        ),
        view: View(..cleared.view, record_gutters: []),
      )
      |> tui_model.invalidate_transcript
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
      outbound.send_frame(opened, protocol.models(opened.shared.next_id))
    }
    command.Model(name) -> {
      let switched =
        inbound.select_model(cleared, name)
        |> outbound.send_frame(protocol.set_model(
          cleared.shared.next_id,
          cleared.shared.active_strand,
          name,
        ))
      tui_model.append_system(switched, "active model changed to " <> name)
    }
    command.Strands | command.Agents -> open_agents(cleared)
    command.PeerLinks -> session_control.begin_peer_workspace(cleared)
    command.Schedules ->
      outbound.send_frame(cleared, protocol.schedules(cleared.shared.next_id))
    command.Unschedule(name:, target:) -> {
      // An absent target means the strand the operator is looking at,
      // which is the row the listing above the prompt just printed. A
      // schedule a parent set onto a subagent needs the second word.
      let target = option.unwrap(target, cleared.shared.active_strand)
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "cancelling schedule " <> name <> " on " <> target,
        ),
        protocol.schedule_cancel(cleared.shared.next_id, target, name),
      )
    }
    command.Sessions -> open_session_selector(cleared)
    command.Rename(name) ->
      case cleared.shared.session {
        "" -> tui_model.append_error(cleared, "no session is attached")
        id -> session_control.begin_rename(cleared, id, name)
      }
    command.Approvals(None) ->
      list.fold(
        inbound.approval_lines(cleared.shared.approvals),
        cleared,
        fn(model, line) { tui_model.append_system(model, line.text) },
      )
    command.Approvals(Some(id)) ->
      inbound.request_decisions(
        Model(
          ..cleared,
          view: View(..cleared.view, inspecting_approval: Some(id)),
        ),
        [id],
      )
    command.AddDirectory(path, access) ->
      outbound.send_frame(
        cleared,
        protocol.add_directory(cleared.shared.next_id, path, access),
      )
    command.Approve(id) -> inbound.decide(cleared, id, operator.AllowOnce)
    command.Deny(id) -> inbound.decide(cleared, id, operator.Deny)
    command.Notes ->
      surfaces.refresh_notes(Model(
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
    command.Summary -> surfaces.open_summary(cleared)
    command.Context -> surfaces.open_context(cleared, context_view.Overview)
    command.ContextAll -> surfaces.open_context(cleared, context_view.All)
    command.Diff -> open_diff(cleared)
    command.Details -> toggle_details(cleared)
    command.Strand(name) ->
      case session_model.is_known_strand(cleared.shared.strands, name) {
        True ->
          tui_model.append_system(
            switch_active_strand(cleared, name),
            "active strand: " <> name,
          )
        False -> tui_model.append_error(cleared, "unknown strand: " <> name)
      }
    command.Fork(name) ->
      outbound.send_frame(
        tui_model.append_system(cleared, "fork queued: " <> name),
        protocol.fork(
          cleared.shared.next_id,
          cleared.shared.active_strand,
          name,
        ),
      )
    command.Effort(level) ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "reasoning level for "
            <> cleared.shared.active_strand
            <> ": "
            <> level,
        ),
        protocol.set_thinking(
          cleared.shared.next_id,
          cleared.shared.active_strand,
          level,
        ),
      )
    command.GoalStatus -> surfaces.request_goal_status(cleared)

    // Each mutation's confirmation waits for the board that commits it.
    // The server answers every goal mutation with the fresh board or with
    // a refusal, so the line belongs on the reply: printed on the way out
    // it claimed a goal was pinned and was then followed by the sentence
    // saying no advisor is routed.
    command.GoalSet(objective:, token_budget:) ->
      outbound.send_frame(
        surfaces.confirming(
          cleared,
          "goal pinned · budget "
            <> int.to_string(token_budget)
            <> " tokens · /goal --budget N sets it",
        ),
        protocol.goal_set(cleared.shared.next_id, objective, token_budget),
      )

    // The confirmation names the command back, because an operator who
    // mistyped it should see what the harness will run before the reviewer
    // is shown its result.
    command.GoalCheck(command: Some(check)) ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the goal check is " <> check),
        protocol.goal_check(cleared.shared.next_id, Some(check)),
      )
    command.GoalCheck(command: None) ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the goal check is cleared"),
        protocol.goal_check(cleared.shared.next_id, None),
      )
    command.GoalClear ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the session goal is cleared"),
        protocol.goal_clear(cleared.shared.next_id),
      )
    command.GoalPause -> surfaces.submit_goal_action(cleared, command.GoalPause)
    command.GoalResume ->
      surfaces.submit_goal_action(cleared, command.GoalResume)

    // The word is shown back because the operator has to see which of
    // their words was read as the budget, and a goal must never be pinned
    // to a spend nobody chose.
    command.GoalBudgetInvalid(word) ->
      tui_model.append_error(
        cleared,
        "/goal --budget needs a positive token count, not \""
          <> word
          <> "\" · /goal <objective> pins the default budget instead",
      )

    // The count is shown because the operator has to know how much to cut,
    // and the objective is not sent: the server refuses it on the same
    // bound, and a round trip to be told so is a round trip wasted.
    // The count is shown for the reason the objective's is: the operator has
    // to know how much to cut, and the two bounds are different numbers.
    command.GoalCheckTooLong(count) ->
      tui_model.append_error(
        cleared,
        "/goal check command is "
          <> int.to_string(count)
          <> " characters; the most a goal check may carry is "
          <> int.to_string(command.check_limit),
      )
    command.GoalObjectiveTooLong(count) ->
      tui_model.append_error(
        cleared,
        "/goal objective is "
          <> int.to_string(count)
          <> " characters; the most a goal may carry is "
          <> int.to_string(command.objective_limit),
      )
    command.Compact ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "compaction queued for " <> cleared.shared.active_strand,
        ),
        protocol.compact(cleared.shared.next_id, cleared.shared.active_strand),
      )
    command.Abort ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "abort queued for " <> cleared.shared.active_strand,
        ),
        protocol.abort(cleared.shared.next_id, cleared.shared.active_strand),
      )
    command.Steer(text) ->
      send_explicit_steer(
        prompt_cleared,
        composer.expand(text, model.shared.attachments),
        model,
      )
    command.Queue(text) ->
      send_follow_up(
        prompt_cleared,
        composer.expand(text, model.shared.attachments),
      )
    command.Unknown(name) ->
      tui_model.append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      tui_model.append_error(cleared, "/" <> name <> " needs an argument")
    command.Prompt(_) -> send_user_text(prompt_cleared, expanded, model)
  }
}

// Images are new prompt content, never live-turn steering, and `prompt_content`
// is the only frame that carries them. A slash command therefore has nowhere to
// put an attachment; refusing before the editor is cleared preserves both the
// instruction and every local attachment. Liveness is not this client's
// question: `prompt` on a busy strand is held by the daemon and drained when
// the run settles, so an image prompt goes out and comes back `queued`.
fn submit_with_images(model: Model) -> Model {
  let input = text_area.value(model.view.input)
  case command.parse_with_skills(input, model.shared.skills) {
    command.Empty | command.Prompt(_) -> send_image_prompt(model, input)
    command.QueueInspect
    | command.Diff
    | command.Summary
    | command.Context
    | command.ContextAll -> submit_text(model)
    command.Help
    | command.Models
    | command.Model(_)
    | command.Strands
    | command.Schedules
    | command.PeerLinks
    | command.Unschedule(..)
    | command.Agents
    | command.Sessions
    | command.Rename(_)
    | command.Approvals(_)
    | command.AddDirectory(..)
    | command.Approve(_)
    | command.Deny(_)
    | command.Notes
    | command.Details
    | command.Strand(_)
    | command.Fork(_)
    | command.Effort(_)
    | command.GoalStatus
    | command.GoalSet(..)
    | command.GoalCheck(..)
    | command.GoalClear
    | command.GoalPause
    | command.GoalResume
    | command.GoalBudgetInvalid(_)
    | command.GoalObjectiveTooLong(_)
    | command.GoalCheckTooLong(_)
    | command.Compact
    | command.Abort
    | command.Steer(_)
    | command.Queue(_)
    | command.Clear
    | command.Quit
    | command.Unknown(_)
    | command.MissingArgument(_) ->
      tui_model.append_error(
        model,
        "image attachments can only accompany an ordinary prompt",
      )
  }
}

fn send_image_prompt(model: Model, input: String) -> Model {
  let expanded = composer.expand(input, model.shared.attachments)
  let images = composer.images(model.shared.attachments)
  let content = image_prompt_content(expanded, images)
  let cleared = case model.shared.pending_submission {
    Some(ComposerSubmission) -> model
    Some(OverlaySubmission) | None -> outbound.clear_composer(model)
  }
  send_prompt_content(cleared, content, expanded, images)
}

/// Builds one ordered user turn without exposing local image paths.
@internal
pub fn image_prompt_content(
  text: String,
  images: List(pasted_image.Image),
) -> List(message.UserBlock) {
  let text_blocks = case text {
    "" -> []
    _ -> [message.UserText(text, None)]
  }
  let image_blocks =
    list.map(images, fn(image) {
      let pasted_image.Image(data:, mime_type:, ..) = image
      message.UserImage(data, mime_type)
    })
  list.append(text_blocks, image_blocks)
}

fn send_prompt_content(
  model: Model,
  content: List(message.UserBlock),
  text: String,
  images: List(pasted_image.Image),
) -> Model {
  let sent = {
    let expected = inbound.expect_own_turn(model, HeldPrompt(text))
    Model(
      ..expected,
      shared: Shared(
        ..expected.shared,
        submitting: Some(model.shared.active_strand),
        notice: "image prompt sent to " <> model.shared.active_strand,
      ),
    )
  }
  case model.shared.peer {
    Attached ->
      outbound.send_frame(
        sent,
        protocol.prompt_content(
          model.shared.next_id,
          model.shared.active_strand,
          content,
        ),
      )

    // A replay stops exactly where the live client's local work stopped.
    // The turn it produced is in the recording and arrives as an entry.
    Replaying -> sent
    Disconnected -> tui_model.append_error(model, "no conversation is attached")
    Preview ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          transcript: list.append(model.shared.transcript, [
            Line(
              User,
              image_prompt_preview(text, images, model.shared.details_expanded),
            ),
            Line(Assistant, "Design-preview echo received."),
          ]),
          record_cache_valid: False,
          notice: "image prompt accepted",
        ),
      )
      |> tui_model.invalidate_transcript
  }
}

fn image_prompt_preview(
  text: String,
  images: List(pasted_image.Image),
  details_expanded: Bool,
) -> String {
  let text = case text {
    "" -> []
    _ -> [composer.transcript_text(text, details_expanded)]
  }
  let image_labels =
    list.map(images, fn(image) {
      let pasted_image.Image(filename:, mime_type:, byte_size:, ..) = image
      "[image: "
      <> text_hygiene.single_line(filename)
      <> " · "
      <> mime_type
      <> " · "
      <> int.to_string(byte_size)
      <> " B]"
    })
  list.append(text, image_labels) |> string.join("\n")
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

fn send_user_text(cleared: Model, text: String, before: Model) -> Model {
  case session_model.active_interrupt(before.shared) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None ->
      case
        session_model.active_strand_live(before.shared),
        before.view.submission_mode
      {
        False, _ -> send_prompt(cleared, text)

        // A prompt aimed at a running strand is held by the daemon and run
        // when that strand settles, so this is the same frame as the idle
        // case and needs no command of its own. Only the local echo differs.
        True, PromptNext -> send_prompt(cleared, text)
        True, SteerNow -> send_steer(cleared, text)
      }
  }
}

// `/steer` is an explicit instruction about ordering, so a pending interrupt
// does not quietly turn it into a prompt. The gateway holds a steer at its own
// priority and a release keeps that priority, which is what the operator asked
// for (`protocol-change/033`). Only a legacy host without a gateway queue falls
// back to the client-side hold.
fn send_explicit_steer(cleared: Model, text: String, before: Model) -> Model {
  use <- bool.lazy_guard(before.shared.channel != None, fn() {
    send_steer(cleared, text)
  })
  case session_model.active_interrupt(before.shared) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None -> send_steer(cleared, text)
  }
}

// After an Escape the daemon halts everything it holds for the strand and
// waits for the operator (`protocol-change/033`). What the operator types
// next is an ordinary prompt: the gateway appends it to the halted queue and
// releases the whole batch, so it runs after the held input rather than
// ahead of it as a steer would. A legacy host without a gateway queue keeps
// the older client-side hold until the terminal transition.
fn hold_or_send_interrupt(
  cleared: Model,
  before: Model,
  strand: String,
  text: String,
) -> Model {
  use <- bool.lazy_guard(before.shared.channel != None, fn() {
    inbound.send_prompt_to(cleared, strand, text)
  })
  case session_model.active_strand_live(before.shared) {
    False ->
      inbound.send_prompt_to(
        Model(..cleared, shared: Shared(..cleared.shared, interrupt: None)),
        strand,
        text,
      )
    True -> {
      let pending = case before.shared.interrupt {
        Some(Interrupt(pending: Some(earlier), ..)) ->
          Some(earlier <> "\n\n" <> text)
        _ -> Some(text)
      }
      Model(
        ..cleared,
        shared: Shared(
          ..cleared.shared,
          interrupt: Some(Interrupt(strand:, operation: None, pending:)),
          notice: "steer captured; waiting for stop",
        ),
      )
    }
  }
}

fn send_prompt(model: Model, text: String) -> Model {
  inbound.send_prompt_to(model, model.shared.active_strand, text)
}

// A steer draws no echo, but the entry it commits is indistinguishable from a
// drained prompt's, so it is recorded as an interjection: without that, a
// steer typed while a prompt is held retires the prompt's echo and the
// operator watches their own line disappear, which is the symptom the echo
// exists to prevent.
fn send_steer(model: Model, text: String) -> Model {
  let expected =
    inbound.expect_own_turn(model, steering_submission(model, text))
  outbound.send_via(
    Model(
      ..expected,
      shared: Shared(
        ..expected.shared,
        notice: "steered " <> model.shared.active_strand,
      ),
    ),
    fn(lane, now) {
      operator.submit(
        lane,
        model.shared.next_id,
        model.shared.active_strand,
        text,
        operator.Steer,
        now,
      )
    },
  )
}

// Both controls transfer input custody to the modern host queue. Older
// recordings still account for their original in-operation interjections.
fn send_follow_up(model: Model, text: String) -> Model {
  let expected =
    inbound.expect_own_turn(model, steering_submission(model, text))
  outbound.send_frame(
    Model(
      ..expected,
      shared: Shared(
        ..expected.shared,
        notice: "queued after " <> model.shared.active_strand,
      ),
    ),
    protocol.follow_up(model.shared.next_id, model.shared.active_strand, text),
  )
}

fn steering_submission(model: Model, text: String) -> Submission {
  case model.shared.channel {
    Some(_) -> HeldPrompt(text)
    None -> Interjection
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
          notice: "interrupt steer is already armed",
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
@internal
pub fn interrupt_active(model: Model) -> Model {
  case
    session_model.active_strand_phase(model.shared),
    session_model.active_interrupt(model.shared)
  {
    None, _ ->
      Model(
        ..model,
        shared: Shared(..model.shared, notice: "nothing is running"),
      )
    Some(_), Some(_) ->
      Model(
        ..model,
        shared: Shared(..model.shared, notice: "interrupt already requested"),
      )
    Some(_), None -> {
      let strand = model.shared.active_strand
      outbound.send_frame(
        Model(
          shared: Shared(
            ..model.shared,
            interrupt: Some(Interrupt(
              strand:,
              operation: captured_operation(model, strand),
              pending: None,
            )),
            notice: "stopping; held input waits · enter sends it with your message",
          ),
          view: View(..model.view, submission_mode: PromptNext),
        ),
        protocol.abort(model.shared.next_id, strand),
      )
    }
  }
}

/// Stops one strand's running operation from the agent strip.
///
/// The active strand goes through `interrupt_active`, which also holds its
/// queued input and arms the composer to send it. Any other strand gets the
/// same `abort` command without that bookkeeping: its queue is its own, and
/// the operator's composer is still addressed to the strand on screen.
///
/// ## Examples
///
/// ```gleam
/// // submit.stop_strand(model, "sub:main/audit-1a2b")
/// ```
@internal
pub fn stop_strand(model: Model, strand: String) -> Model {
  case
    strand == model.shared.active_strand,
    layout.strand_running(model, strand)
  {
    True, _ -> interrupt_active(model)
    False, False ->
      Model(
        ..model,
        shared: Shared(..model.shared, notice: strand <> " is not running"),
      )
    False, True ->
      outbound.send_frame(
        Model(
          ..model,
          shared: Shared(..model.shared, notice: "stopping " <> strand),
        ),
        protocol.abort(model.shared.next_id, strand),
      )
  }
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

fn captured_operation(model: Model, strand: String) -> Option(String) {
  case model.shared.captured {
    Some(#(_, view)) -> dict.get(view.operations, strand) |> option.from_result
    None -> None
  }
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

/// Queues the cancellation of every background worker and request and the
/// close of the attachment, and marks the model as quitting.
///
/// Nothing is cancelled or closed during the step. The adopted lane's close
/// is queued first and the cancels after it, in the order they were once
/// performed. The runtime runs all of them after the step, before the loop
/// sees `quit` and exits.
@internal
pub fn quit(model: Model) -> Model {
  // The adopted lane closes ahead of the provisional attempt. A recording
  // has always noted the adopted lane's close before the attempt's, whose
  // close the `Abandon` below decides only when the runtime performs it.
  let model = case model.shared.channel {
    Some(channel) ->
      tui_model.hold_channel(model, session_channel.close(channel))
    None -> model
  }

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
  Model(..model, shared: Shared(..model.shared, quit: True))
}

/// Makes `strand` the active strand, cancelling unsent frames for the old
/// one and re-projecting the captured cut, or asking for the strand's
/// configuration when nothing is captured.
@internal
pub fn switch_active_strand(model: Model, strand: String) -> Model {
  let model =
    inbound.cancel_pending(model, "target change from " <> model.shared.session)
  let model = inbound.select_workspace(model, model.shared.session, strand)
  let selected =
    Model(
      shared: Shared(
        ..model.shared,
        active_strand: strand,
        queued: [],
        awaiting_outcome: None,
        current_model: "loading…",
        record_cache_valid: False,
        notice: "active strand: " <> strand,
      ),
      view: View(
        ..model.view,
        overlay: NoOverlay,
        cache_outlook: "",
        repaint_phase: !model.view.repaint_phase,
      ),
    )
    |> tui_model.invalidate_transcript
  case model.shared.captured {
    Some(#(cut, view)) -> inbound.apply_cut(selected, cut, view)
    None ->
      outbound.send_frame(
        selected,
        protocol.config(model.shared.next_id, strand),
      )
  }
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
