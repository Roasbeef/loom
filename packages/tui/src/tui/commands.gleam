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
//// A change of active strand is three units rather than one, because the
//// lane's cancellation of unsent frames produces updates, and under the
//// ruling on question 11 the host applies each update and its facts before
//// the next. The host cancels (`lane_fold.cancel_unsent` and its own loop),
//// then runs `focus`, which parks the departing workspace and makes the
//// strand active, and then `load_strand`, which shows the captured cut for
//// it or asks for its configuration. The host applies `focus`'s facts before
//// `load_strand` runs, so the cut sees the workspace the switch restored.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/approval
import session_view/command
import session_view/operator
import session_view/protocol
import session_view/session_channel
import tui/event_fold
import tui/lane_fold
import tui/outbound
import tui/session_model.{
  type Shared, Interrupt, InterruptRequested, ReviewAnswered, Shared,
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
    None, _ -> Shared(..shared, notice: "nothing is running")
    Some(_), Some(_) -> Shared(..shared, notice: "interrupt already requested")
    Some(_), None -> {
      let strand = shared.active_strand
      Shared(
        ..shared,
        interrupt: Some(Interrupt(
          strand:,
          operation: captured_operation(shared, strand),
          pending: None,
        )),
        notice: "stopping; held input waits · enter sends it with your message",
      )
      |> session_model.record_surface(InterruptRequested)
      |> outbound.send_frame(protocol.abort(shared.next_id, strand))
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
    False, False -> Shared(..shared, notice: strand <> " is not running")
    False, True ->
      outbound.send_frame(
        Shared(..shared, notice: "stopping " <> strand),
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
  Shared(..shared, quit: True)
}
