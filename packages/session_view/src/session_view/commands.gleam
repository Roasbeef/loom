//// The commands: what an operator does to a session, over the session
//// state alone.
////
//// An interrupt, a stop, a decision, a model change, a change of active
//// strand and a quit each decide what to send and what to write in the
//// session state, and none of those decisions reads what a host shows. So
//// each is a function that takes and returns `Shared` alone, and a second
//// host of the session, such as the web view, can run it with its own
//// handle bindings (`docs/design-notes/step-extraction.md`, section 3,
//// "S3e′: the commands").
////
//// A host decides when to run a command. The terminal reads a key or a
//// parsed slash command against its own surfaces first, and then calls the
//// function here for the session's half. Where a command used to write the
//// terminal's own state, it records a `SurfaceFact` instead, as the folds
//// do: `InterruptRequested` returns the composer to prompting and
//// `ReviewAnswered` closes the approval dialog. The terminal stores each
//// result through `tui_model.run_shared` and applies what it recorded with
//// `inbound.settle_surfaces`, at the point of the call.
////
//// `act` is the entry: it carries out one `msg.Command`. A submitted draft
//// that parsed as a `command.Session` command is dispatched here too
//// (`submit`), exhaustively over the session's commands; the host has
//// already acted on any `command.Surface` command itself. A draft that the
//// dispatch consumes at once records `DraftTaken`, saying whether it became
//// a prompt or a command, and the host decides what that means for its
//// editor, its input history and its submission mode. A draft locked behind
//// the lane is consumed when the lane sends it, as `drafts_sent` records.
////
//// A change of active strand is three units rather than one, because the
//// lane's cancellation of unsent frames produces updates, and under the
//// ruling on question 11 the host applies each update and its facts before
//// the next. The host cancels (`lane_fold.cancel_unsent` and its own loop),
//// then runs `focus`, which parks the departing workspace and makes the
//// strand active, and then `load_strand`, which shows the captured cut for
//// it or asks for its configuration. The host applies `focus`'s facts before
//// `load_strand` runs, so the cut sees the workspace the switch restored.

import core/message
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/approval
import session_view/command
import session_view/composer
import session_view/event_fold
import session_view/lane_fold
import session_view/model.{
  type DraftTaking, type Shared, Attached, ComposerSubmission, Disconnected,
  DraftTaken, Interrupt, InterruptRequested, LookupRequested, OverlaySubmission,
  Preview, Replaying, ReviewAnswered, Shared, TakenAsPrompt, TakenByCommand,
  TranscriptCleared,
} as session_model
import session_view/msg
import session_view/operator
import session_view/outbound
import session_view/pasted_image
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/surfaces
import session_view/text_hygiene
import session_view/transcript_line.{
  type Submission, Assistant, HeldPrompt, Interjection, Line, User,
}

/// Sends an interrupt for the active strand's running operation, once.
///
/// The interrupt is held in `Shared.interrupt` until the operation settles,
/// so input typed meanwhile is released with the input the daemon holds
/// rather than steered into the stopping turn. The `InterruptRequested`
/// fact tells a host that offers a steer to return its composer to
/// prompting.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.interrupt_active(shared)
/// ```
@internal
pub fn interrupt_active(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case
    session_model.active_strand_phase(shared),
    session_model.active_interrupt(shared)
  {
    None, _ -> shared_set.notice(shared, "nothing is running")
    Some(_), Some(_) -> shared_set.notice(shared, "interrupt already requested")
    Some(_), None ->
      // The interrupt is held until the operation settles, so it is recorded
      // only for an abort the lane will take. A refused one, on an observer's
      // attachment or a lane whose command slot is busy, would otherwise
      // leave "interrupt already requested" standing for a frame that was
      // never written.
      case outbound.mutation_refusal(shared, command.Abort) {
        Some(reason) -> session_model.append_error(shared, reason)
        None -> {
          let strand = shared.active_strand
          shared
          |> shared_set.interrupt(
            Some(Interrupt(
              strand:,
              operation: captured_operation(shared, strand),
              pending: None,
            )),
          )
          |> shared_set.notice(stopping_notice)
          |> session_model.record_surface(InterruptRequested)
          |> outbound.send_frame(protocol.abort(shared.next_id, strand))
        }
      }
  }
}

// The operation the last capture shows running on `strand`, which the held
// interrupt names so that its settlement can be recognized.
fn captured_operation(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Option(String) {
  case shared.captured {
    Some(#(_, view)) -> dict.get(view.operations, strand) |> option.from_result
    None -> None
  }
}

/// Stops one strand's running operation.
///
/// The active strand goes through `interrupt_active`, which also holds its
/// queued input and arms the composer to send it. Any other strand gets the
/// same `abort` command without that bookkeeping: its queue is its own, and
/// the operator's composer is still addressed to the strand on screen.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.stop_strand(shared, "sub:main/audit-1a2b")
/// ```
@internal
pub fn stop_strand(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  case
    strand == shared.active_strand,
    session_model.strand_running(shared, strand)
  {
    True, _ -> interrupt_active(shared)
    False, False -> shared_set.notice(shared, strand <> " is not running")
    False, True ->
      outbound.send_frame(
        shared_set.notice(shared, "stopping " <> strand),
        protocol.abort(shared.next_id, strand),
      )
  }
}

/// Encodes and sends a decision for the displayed approval `id`. A decision
/// that is not on screen is refused, so the operator only answers what they
/// have seen.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.decide(shared, "esc-1", operator.AllowOnce)
/// ```
@internal
pub fn decide(
  shared: Shared(socket, recorder, source, replay_source),
  id: String,
  choice: operator.Choice,
) -> Shared(socket, recorder, source, replay_source) {
  case list.find(shared.approvals, fn(record) { record.id == id }) {
    Error(Nil) ->
      session_model.append_error(
        shared,
        "decision is not displayed; load /approvals " <> id <> " first",
      )
    Ok(record) ->
      case operator.decision(shared.next_id, record, choice) {
        Error(reason) -> session_model.append_error(shared, reason)
        Ok(frame) -> outbound.send_frame(shared, frame)
      }
  }
}

/// Encodes and sends a decision for `record`, the review a host's dialog
/// captured.
///
/// The dialog's own record is decided rather than the one `Shared.approvals`
/// holds under the same ID now, because looking the ID up again would
/// replace the question on screen with a newer record the operator never
/// saw. A decision handed to the lane records `ReviewAnswered`, and the host
/// closes the dialog; a refused one leaves it open with the reason in the
/// transcript.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.decide_review(shared, record, operator.Deny)
/// ```
@internal
pub fn decide_review(
  shared: Shared(socket, recorder, source, replay_source),
  record: approval.Review,
  choice: operator.Choice,
) -> Shared(socket, recorder, source, replay_source) {
  case outbound.mutation_refusal(shared, command.Approve(record.id)) {
    Some(reason) -> session_model.append_error(shared, reason)
    None ->
      case operator.decision(shared.next_id, record, choice) {
        Error(reason) -> session_model.append_error(shared, reason)
        Ok(frame) ->
          session_model.record_surface(shared, ReviewAnswered)
          |> outbound.send_frame(frame)
      }
  }
}

/// Switches the active strand to the catalogue model `name`: the strand's
/// recorded model and cache watch change here, the `set_model` command goes
/// to the lane, and the transcript says so.
///
/// The recorded model changes before the reply, as it always has, so the
/// cache watch that `event_fold.select_model` forgets is not shown against
/// the new model while the command is in flight.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.select_model(shared, "claude-sonnet")
/// ```
@internal
pub fn select_model(
  shared: Shared(socket, recorder, source, replay_source),
  name: String,
) -> Shared(socket, recorder, source, replay_source) {
  event_fold.select_model(shared, name)
  |> outbound.send_frame(protocol.set_model(
    shared.next_id,
    shared.active_strand,
    name,
  ))
  |> session_model.append_system("active model changed to " <> name)
}

/// Makes `strand` the active strand of the current session: parks the
/// departing strand's history window, restores the arriving one's, and
/// forgets the echoes and the model that belonged to the departing strand.
///
/// This is the second of the three units of a change of strand. The host
/// has already cancelled the lane's unsent frames, so none of them can
/// reach the new target. The `WorkspaceSwitched` fact that
/// `event_fold.select_workspace` records is applied by the host before
/// `load_strand` runs.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.focus(shared, "worker")
/// ```
@internal
pub fn focus(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  let switched = event_fold.select_workspace(shared, shared.session, strand)
  Shared(
    ..switched,
    active_strand: strand,
    // The clock times the active strand's own generation. Another strand
    // that is mid-generation would otherwise lend its start to this one.
    generation_started_ms: None,
    queued: [],
    awaiting_outcome: None,
    current_model: "loading…",
    record_cache_valid: False,
    notice: "active strand: " <> strand,
  )
  |> session_model.invalidate_transcript
}

/// Shows the newly active `strand`: re-projects the captured cut for it, or
/// asks for its configuration when nothing is captured.
///
/// The third unit of a change of strand. `around` is what the host shows
/// once it has closed its overlays for the switch, which the cut's approval
/// decisions read (`lane_fold.Surroundings`).
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.load_strand(shared, "worker", around)
/// ```
@internal
pub fn load_strand(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  around: lane_fold.Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.captured {
    Some(#(cut, view)) -> lane_fold.apply_cut(shared, cut, view, around)
    None -> outbound.send_frame(shared, protocol.config(shared.next_id, strand))
  }
}

/// Closes the adopted lane and marks the session as ending.
///
/// Nothing is closed during the step: the lane's close is queued on the
/// shared outbox, and a host queues its own cancellations after it, so a
/// recording notes the lane's close before anything else the quit closes.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.quit(shared)
/// ```
@internal
pub fn quit(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let shared = case shared.channel {
    Some(channel) ->
      session_model.hold_channel(shared, session_channel.close(channel))
    None -> shared
  }
  shared_set.quit(shared, True)
}

/// Carries out one operator command over the session state.
///
/// This is the shared step's entry for a command: the host has decided from
/// its own controls what the operator meant, and every command here is one
/// call that reads and writes `Shared` alone. What a command did to a
/// host's own surfaces is recorded as a `SurfaceFact`, which the host
/// applies after the call.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.act(shared, msg.Interrupt)
/// ```
@internal
pub fn act(
  shared: Shared(socket, recorder, source, replay_source),
  command: msg.Command,
) -> Shared(socket, recorder, source, replay_source) {
  case command {
    msg.Submit(draft:, command:, delivery:) ->
      submit(shared, draft, command, delivery)
    msg.Control(command:) -> control(shared, command)
    msg.Interrupt -> interrupt_active(shared)
    msg.Stop(strand:) -> stop_strand(shared, strand)
    msg.Decide(review:, choice:) -> decide_review(shared, review, choice)
    msg.SelectModel(name:) -> select_model(shared, name)
    msg.Quit -> quit(shared)
  }
}

/// Runs a session command that a control chose, not a composer's draft.
///
/// A button on a host's page names a command directly (`/fork`, `/goal
/// pause`, `/goal clear`), so no draft belongs to it. The composer's text
/// is the operator's own, and a control that fired while they were typing
/// must leave it where it is. `submit` cannot promise that: it marks a
/// mutating command `ComposerSubmission`, so the lane counts the frame it
/// sends in `drafts_sent`, and a dispatch that consumes at once records
/// `DraftTaken`, and a host empties its editor on either. This entry marks
/// nothing, so the lane counts nothing, and it drops the `DraftTaken` the
/// dispatch would record, so the host reads neither.
///
/// Everything else is `submit`'s: the refusal for an attachment that cannot
/// mutate comes first, and the dispatch is the same exhaustive one, so a
/// control cannot do what the same words typed in the composer would not.
/// A control carries no prompt, since a prompt's text is a draft; the
/// hosts that call this build a fixed set of commands.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.control(shared, command.GoalPause)
/// ```
@internal
pub fn control(
  shared: Shared(socket, recorder, source, replay_source),
  command: command.Session,
) -> Shared(socket, recorder, source, replay_source) {
  case outbound.mutation_refusal(shared, command) {
    Some(reason) -> session_model.append_error(shared, reason)
    None -> {
      let ran = dispatch(shared, "", command, operator.Prompt)
      shared_set.surface_facts(
        ran,
        list.filter(ran.surface_facts, fn(fact) {
          case fact {
            DraftTaken(..) -> False
            _ -> True
          }
        }),
      )
    }
  }
}

/// Submits a draft that parsed as a session command.
///
/// A mutation the attachment cannot accept is refused before encoding, and
/// the draft is kept. Otherwise a mutation sent through a live lane is
/// marked `ComposerSubmission`, so the draft is consumed only when the lane
/// sends it (`drafts_sent`); any other command consumes it now, and records
/// `DraftTaken` for the host's editor. A draft whose frame is still queued
/// behind the lane stays locked; otherwise the marker is released.
///
/// ## Examples
///
/// ```gleam
/// let shared =
///   commands.submit(shared, "hello", command.Prompt("hello"), operator.Prompt)
/// ```
@internal
pub fn submit(
  shared: Shared(socket, recorder, source, replay_source),
  draft: String,
  command: command.Session,
  delivery: operator.Delivery,
) -> Shared(socket, recorder, source, replay_source) {
  case outbound.mutation_refusal(shared, command) {
    Some(reason) -> session_model.append_error(shared, reason)
    None -> {
      // The marker scopes the encoder call and, only if the frame is queued,
      // the later send. The draft itself stays where the host keeps it.
      let prepared = case
        outbound.mutating_submission(shared, command),
        shared.peer
      {
        True, Attached ->
          shared_set.pending_submission(shared, Some(ComposerSubmission))
        _, _ -> shared
      }
      case composer.has_images(prepared.attachments) {
        True -> submit_with_images(prepared, draft, command)
        False -> dispatch(prepared, draft, command, delivery)
      }
      |> release_submission
    }
  }
}

/// Releases the submission marker unless a frame is still queued behind the
/// lane, which keeps the draft locked until the lane sends or refuses it.
///
/// ## Examples
///
/// ```gleam
/// let shared = commands.release_submission(shared)
/// ```
@internal
pub fn release_submission(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel {
    Some(channel) ->
      case session_channel.has_unsent(channel) {
        True -> shared
        False -> shared_set.pending_submission(shared, None)
      }
    None -> shared_set.pending_submission(shared, None)
  }
}

// Consumes the draft now, unless the lane will consume it when it sends the
// frame. The host empties its editor when it applies the fact; a prompt
// also takes the attachments, which are the session's.
fn take_draft(
  shared: Shared(socket, recorder, source, replay_source),
  taking: DraftTaking,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.pending_submission, taking {
    Some(ComposerSubmission), _ -> shared
    Some(OverlaySubmission), TakenByCommand | None, TakenByCommand ->
      session_model.record_surface(shared, DraftTaken(TakenByCommand))
    Some(OverlaySubmission), TakenAsPrompt | None, TakenAsPrompt ->
      shared_set.attachments(shared, [])
      |> session_model.record_surface(DraftTaken(TakenAsPrompt))
  }
}

// One session command, dispatched. `shared` is the state the submission
// was admitted at; `cleared` has consumed the draft as a command and
// `prompt_cleared` as a prompt, and the arm decides which it continues from.
fn dispatch(
  shared: Shared(socket, recorder, source, replay_source),
  draft: String,
  command: command.Session,
  delivery: operator.Delivery,
) -> Shared(socket, recorder, source, replay_source) {
  let expanded = composer.expand(draft, shared.attachments)
  let cleared = take_draft(shared, TakenByCommand)
  let prompt_cleared = take_draft(shared, TakenAsPrompt)
  case command {
    command.Empty ->
      case shared.attachments {
        [] -> cleared
        _ -> send_prompt(prompt_cleared, expanded)
      }
    command.Clear ->
      Shared(
        ..cleared,
        transcript: [],
        records: [],
        record_cache_epoch: cleared.record_cache_epoch + 1,
        compact_call_cache: dict.new(),
        compact_entry_cache: dict.new(),
        pending_records: [],
        record_cache_valid: False,
        // `/clear` empties the local view, and an echo is part of that view
        // rather than something it is drawn over.
        queued: [],
        awaiting_outcome: None,
        notice: "local view cleared",
      )
      |> session_model.record_surface(TranscriptCleared)
      |> session_model.invalidate_transcript
    command.Model(name) -> select_model(cleared, name)
    command.Schedules ->
      outbound.send_frame(cleared, protocol.schedules(cleared.next_id))
    command.Unschedule(name:, target:) -> {
      // An absent target means the strand the operator is looking at,
      // which is the row the listing above the prompt just printed. A
      // schedule a parent set onto a subagent needs the second word.
      let target = option.unwrap(target, cleared.active_strand)
      session_model.append_system(
        cleared,
        "cancelling schedule " <> name <> " on " <> target,
      )
      |> outbound.send_frame(protocol.schedule_cancel(
        cleared.next_id,
        target,
        name,
      ))
    }
    command.Approvals(None) ->
      list.fold(
        lane_fold.approval_lines(cleared.approvals),
        cleared,
        fn(shared, line) { session_model.append_system(shared, line.text) },
      )

    // The host opens the record when the lookup answers, so it is told
    // which record was asked for.
    command.Approvals(Some(id)) ->
      session_model.record_surface(cleared, LookupRequested(id))
      |> lane_fold.request_decisions([id])
    command.AddDirectory(path, access) ->
      outbound.send_frame(
        cleared,
        protocol.add_directory(cleared.next_id, path, access),
      )
    command.Approve(id) -> decide(cleared, id, operator.AllowOnce)
    command.Deny(id) -> decide(cleared, id, operator.Deny)
    command.Fork(name) ->
      session_model.append_system(cleared, "fork queued: " <> name)
      |> outbound.send_frame(protocol.fork(
        cleared.next_id,
        cleared.active_strand,
        name,
      ))
    command.Effort(level) ->
      session_model.append_system(
        cleared,
        "reasoning level for " <> cleared.active_strand <> ": " <> level,
      )
      |> outbound.send_frame(protocol.set_thinking(
        cleared.next_id,
        cleared.active_strand,
        level,
      ))

    // Each mutation's confirmation waits for the board that commits it.
    // The server answers every goal mutation with the fresh board or with
    // a refusal, so the line belongs on the reply: printed on the way out
    // it claimed a goal was pinned and was then followed by the sentence
    // saying no advisor is routed.
    command.GoalSet(objective:, token_budget:) ->
      surfaces.confirming(
        cleared,
        "goal pinned · budget "
          <> int.to_string(token_budget)
          <> " tokens · /goal --budget N sets it",
      )
      |> outbound.send_frame(protocol.goal_set(
        cleared.next_id,
        objective,
        token_budget,
      ))

    // The confirmation names the command back, because an operator who
    // mistyped it should see what the harness will run before the reviewer
    // is shown its result.
    command.GoalCheck(command: Some(check)) ->
      surfaces.confirming(cleared, "the goal check is " <> check)
      |> outbound.send_frame(protocol.goal_check(cleared.next_id, Some(check)))
    command.GoalCheck(command: None) ->
      surfaces.confirming(cleared, "the goal check is cleared")
      |> outbound.send_frame(protocol.goal_check(cleared.next_id, None))
    command.GoalClear ->
      surfaces.confirming(cleared, "the session goal is cleared")
      |> outbound.send_frame(protocol.goal_clear(cleared.next_id))
    command.GoalPause -> surfaces.submit_goal_action(cleared, command.GoalPause)
    command.GoalResume ->
      surfaces.submit_goal_action(cleared, command.GoalResume)

    // The word is shown back because the operator has to see which of
    // their words was read as the budget, and a goal must never be pinned
    // to a spend nobody chose.
    command.GoalBudgetInvalid(word) ->
      session_model.append_error(
        cleared,
        "/goal --budget needs a positive token count, not \""
          <> word
          <> "\" · /goal <objective> pins the default budget instead",
      )

    // The count is shown for the reason the objective's is: the operator has
    // to know how much to cut, and the two bounds are different numbers.
    command.GoalCheckTooLong(count) ->
      session_model.append_error(
        cleared,
        "/goal check command is "
          <> int.to_string(count)
          <> " characters; the most a goal check may carry is "
          <> int.to_string(command.check_limit),
      )

    // The objective is not sent: the server refuses it on the same bound,
    // and a round trip to be told so is a round trip wasted.
    command.GoalObjectiveTooLong(count) ->
      session_model.append_error(
        cleared,
        "/goal objective is "
          <> int.to_string(count)
          <> " characters; the most a goal may carry is "
          <> int.to_string(command.objective_limit),
      )
    command.Compact ->
      session_model.append_system(
        cleared,
        "compaction queued for " <> cleared.active_strand,
      )
      |> outbound.send_frame(protocol.compact(
        cleared.next_id,
        cleared.active_strand,
      ))
    command.Abort ->
      session_model.append_system(
        cleared,
        "abort queued for " <> cleared.active_strand,
      )
      |> outbound.send_frame(protocol.abort(
        cleared.next_id,
        cleared.active_strand,
      ))
    command.Steer(text) ->
      send_explicit_steer(
        prompt_cleared,
        composer.expand(text, shared.attachments),
        shared,
      )
    command.Queue(text) ->
      send_follow_up(prompt_cleared, composer.expand(text, shared.attachments))
    command.Unknown(name) ->
      session_model.append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      session_model.append_error(cleared, "/" <> name <> " needs an argument")
    command.Prompt(_) ->
      send_user_text(prompt_cleared, expanded, shared, delivery)
  }
}

// Images are new prompt content, never live-turn steering, and
// `prompt_content` is the only frame that carries them. A session command
// therefore has nowhere to put an attachment; refusing before the draft is
// consumed preserves both the instruction and every local attachment.
// Liveness is not this client's question: `prompt` on a busy strand is held
// by the daemon and drained when the run settles, so an image prompt goes
// out and comes back `queued`.
fn submit_with_images(
  shared: Shared(socket, recorder, source, replay_source),
  draft: String,
  command: command.Session,
) -> Shared(socket, recorder, source, replay_source) {
  case command {
    command.Empty | command.Prompt(_) -> send_image_prompt(shared, draft)
    command.Model(_)
    | command.Schedules
    | command.Unschedule(..)
    | command.Approvals(_)
    | command.AddDirectory(..)
    | command.Approve(_)
    | command.Deny(_)
    | command.Fork(_)
    | command.Effort(_)
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
    | command.Unknown(_)
    | command.MissingArgument(_) ->
      session_model.append_error(
        shared,
        "image attachments can only accompany an ordinary prompt",
      )
  }
}

fn send_image_prompt(
  shared: Shared(socket, recorder, source, replay_source),
  draft: String,
) -> Shared(socket, recorder, source, replay_source) {
  let expanded = composer.expand(draft, shared.attachments)
  let images = composer.images(shared.attachments)
  let content = image_prompt_content(expanded, images)
  send_prompt_content(
    take_draft(shared, TakenAsPrompt),
    content,
    expanded,
    images,
  )
}

/// Builds one ordered user turn without exposing local image paths.
///
/// ## Examples
///
/// ```gleam
/// let content = commands.image_prompt_content("look", [image])
/// ```
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

// The image prompt's echo is expected before the frame goes out, so the
// entry that commits it retires the echo rather than drawing a second copy.
// Only a live lane sends; a replay stops where the live client's own work
// stopped, and the preview answers locally.
fn send_prompt_content(
  shared: Shared(socket, recorder, source, replay_source),
  content: List(message.UserBlock),
  text: String,
  images: List(pasted_image.Image),
) -> Shared(socket, recorder, source, replay_source) {
  let sent =
    Shared(
      ..event_fold.expect_own_turn(shared, HeldPrompt(text)),
      submitting: Some(shared.active_strand),
      notice: "image prompt sent to " <> shared.active_strand,
    )
  case shared.peer {
    Attached ->
      outbound.send_frame(
        sent,
        protocol.prompt_content(shared.next_id, shared.active_strand, content),
      )

    // A replay stops exactly where the live client's local work stopped.
    // The turn it produced is in the recording and arrives as an entry.
    Replaying -> sent
    Disconnected ->
      session_model.append_error(shared, "no conversation is attached")
    Preview ->
      shared
      |> shared_set.transcript(
        list.append(shared.transcript, [
          Line(
            User,
            image_prompt_preview(text, images, shared.details_expanded),
          ),
          Line(Assistant, "Design-preview echo received."),
        ]),
      )
      |> shared_set.record_cache_valid(False)
      |> shared_set.notice("image prompt accepted")
      |> session_model.invalidate_transcript
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

// An ordinary prompt: held and released after an interrupt, steered into a
// running strand when the host asked for a steer, and otherwise a prompt,
// which the daemon holds on a busy strand and runs when it settles.
fn send_user_text(
  cleared: Shared(socket, recorder, source, replay_source),
  text: String,
  before: Shared(socket, recorder, source, replay_source),
  delivery: operator.Delivery,
) -> Shared(socket, recorder, source, replay_source) {
  case session_model.active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None ->
      case session_model.active_strand_live(before), delivery {
        False, _ -> send_prompt(cleared, text)

        // A prompt aimed at a running strand is held by the daemon and run
        // when that strand settles, so this is the same frame as the idle
        // case and needs no command of its own. Only the local echo differs.
        True, operator.Prompt -> send_prompt(cleared, text)
        True, operator.Steer -> send_steer(cleared, text)
      }
  }
}

// `/steer` is an explicit instruction about ordering, so a pending interrupt
// does not quietly turn it into a prompt. The gateway holds a steer at its own
// priority and a release keeps that priority, which is what the operator asked
// for (`protocol-change/033`). Only a legacy host without a gateway queue falls
// back to the client-side hold.
fn send_explicit_steer(
  cleared: Shared(socket, recorder, source, replay_source),
  text: String,
  before: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  use <- bool.lazy_guard(before.channel != None, fn() {
    send_steer(cleared, text)
  })
  case session_model.active_interrupt(before) {
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
  cleared: Shared(socket, recorder, source, replay_source),
  before: Shared(socket, recorder, source, replay_source),
  strand: String,
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  use <- bool.lazy_guard(before.channel != None, fn() {
    event_fold.send_prompt_to(cleared, strand, text)
  })
  case session_model.active_strand_live(before) {
    False ->
      event_fold.send_prompt_to(
        shared_set.interrupt(cleared, None),
        strand,
        text,
      )
    True -> {
      let pending = case before.interrupt {
        Some(Interrupt(pending: Some(earlier), ..)) ->
          Some(earlier <> "\n\n" <> text)
        _ -> Some(text)
      }
      cleared
      |> shared_set.interrupt(
        Some(Interrupt(strand:, operation: None, pending:)),
      )
      |> shared_set.notice("steer captured; waiting for stop")
    }
  }
}

fn send_prompt(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  event_fold.send_prompt_to(shared, shared.active_strand, text)
}

// A steer draws no echo, but the entry it commits is indistinguishable from a
// drained prompt's, so it is recorded as an interjection: without that, a
// steer typed while a prompt is held retires the prompt's echo and the
// operator watches their own line disappear, which is the symptom the echo
// exists to prevent.
fn send_steer(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  let expected =
    event_fold.expect_own_turn(shared, steering_submission(shared, text))
  outbound.send_via(
    shared_set.notice(expected, "steered " <> shared.active_strand),
    fn(lane, now) {
      operator.submit(
        lane,
        shared.next_id,
        shared.active_strand,
        text,
        operator.Steer,
        now,
      )
    },
  )
}

// Both controls transfer input custody to the modern host queue. Older
// recordings still account for their original in-operation interjections.
fn send_follow_up(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  let expected =
    event_fold.expect_own_turn(shared, steering_submission(shared, text))
  outbound.send_frame(
    shared_set.notice(expected, "queued after " <> shared.active_strand),
    protocol.follow_up(shared.next_id, shared.active_strand, text),
  )
}

fn steering_submission(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Submission {
  case shared.channel {
    Some(_) -> HeldPrompt(text)
    None -> Interjection
  }
}

/// The notice an interrupt request leaves. A host that already says why
/// the held input waits, as the terminal's status band does, recognises it
/// by this constant and draws the one sentence rather than both.
pub const stopping_notice =
  "stopping; held input waits · enter sends it with your message"
