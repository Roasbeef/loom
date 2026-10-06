//// A terminal step decides its I/O and performs none of it.
////
//// `tui.step` returns the next model and the effects it decided on, and
//// `tui.update` is that step followed by `runtime.perform`. These tests drive
//// `step` directly and read the effects as values: a copy asks for one
//// clipboard write, a quit asks for every cancel and close, and a replayed
//// submission asks for no write at all. Where a stand-in
//// handle wraps a subject this process owns, the test also checks the
//// mailbox, so "performs nothing during the step" is observed rather than
//// assumed.

import etui/backend
import etui/widgets/textarea as text_area
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/model as session_model
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/step_effect
import session_view/transcript_line
import tui
import tui/attachment
import tui/connection
import tui/daemon/selection as daemon_selection
import tui/effect.{type Effect}
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/terminal_lane
import tui/view_set
import tui/workspace
import tui_test/pushed
import tui_test/stepping

// A copy asks the runtime for exactly one clipboard write, and only when the
// terminal has a clipboard to write to. The notice is set either way, which
// is what shows the copy path ran in both cases.
pub fn a_mouse_copy_queues_one_clipboard_write_test() {
  let #(copied, effects) = drag_and_release(tui_model.TerminalClipboard)
  assert string.contains(copied.shared.notice, "copied")
  let assert [effect.WriteClipboard(sequence)] =
    list.filter(effects, is_clipboard_write)
    as "a release over a selection queues one clipboard write"
  assert string.starts_with(sequence, "\u{001B}]52;c;")
    as "the queued write is an OSC 52 sequence"

  let #(copied, effects) = drag_and_release(tui_model.NoClipboard)
  assert string.contains(copied.shared.notice, "copied")
  assert list.filter(effects, is_clipboard_write) == []
    as "a terminal with no clipboard is sent no sequence"
}

// A quit with a live channel and every background job running decides one
// close or cancel per resource, in the order they were once performed, and
// performs none of them. The channel's close is queued first, ahead of the
// provisional attempt's cancel, so a recording notes the adopted lane's
// close before the attempt's, as it always has. Each job is cancelled by
// the key its slot held, the control job first, then the relaunch, then
// the activity poll, and each slot is cleared in the same step so nothing
// the cancelled jobs send afterwards is admitted. The provisional attempt's
// job is cancelled by its key just ahead of the attempt's own cleanup.
pub fn quit_with_a_channel_queues_every_close_and_cancel_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let host = host_on(owner)
  let #(channel, _subscribe) =
    session_channel.start(
      socket,
      snapshot.Expected("A", "epoch", "incarnation"),
      now: 0,
    )
    |> session_channel.take_outputs
  let #(model, request) = tui_model.allocate_job(quiet_model())
  let #(model, relaunch) = tui_model.allocate_job(model)
  let #(model, poll) = tui_model.allocate_job(model)
  let #(model, replacement) = tui_model.allocate_job(model)
  let attempt = attachment.opening(replacement, None)
  let model =
    tui_model.Model(
      shared: model.shared
        |> shared_set.peer(session_model.Attached)
        |> shared_set.channel(Some(channel)),
      view: model.view
        |> view_set.candidate(attempt)
        |> view_set.control_request(
          Some(tui_model.ControlRequest(
            job: job.awaiting(request),
            result: None,
          )),
        )
        |> view_set.reconnect(
          tui_model.ReconnectAttempting(job.awaiting(relaunch)),
        )
        |> view_set.activity_poll(
          tui_model.ActivityAsking(job.awaiting(poll), ["A"]),
        ),
    )
    |> runtime.adopt_control(host)
  let assert Some(daemon) = model.view.daemon_host

  let #(quit, effects) = stepping.step(backend.KeyPress("ctrl+c"), model)
  assert quit.shared.quit
  assert quit.view.outbox == []
  assert effects
    == [
      effect.Step(step_effect.Lane(session_channel.Shut(socket))),
      effect.CancelJob(replacement),
      effect.Attachment(attachment.Abandon(attempt)),
      effect.CancelJob(request),
      effect.CancelJob(relaunch),
      effect.CancelJob(poll),
      effect.CloseControl(daemon.control),
    ]
  assert quit.view.control_request == None
  assert quit.view.reconnect == tui_model.ReconnectSpent
  assert quit.view.activity_poll == tui_model.ActivityDue
  assert !attachment.busy(quit.view.candidate)
  assert process.receive(owner, 0) == Error(Nil)
    as "the step closed nothing itself"

  // Performing them is what reaches the handles: one socket close and one
  // control close, both addressed to the handles the step was given.
  let _running = runtime.perform(effects, quit.view.running)
  let assert Ok(_) = process.receive(owner, 100)
  let assert Ok(_) = process.receive(owner, 100)
  assert process.receive(owner, 0) == Error(Nil)
}

// A replay has no socket, so a prompt submitted during one does the local
// half of the live path and asks for no write of any kind.
pub fn a_replayed_prompt_queues_no_write_test() {
  let model = {
    let base = pushed.attached()
    tui_model.Model(
      shared: shared_set.active_strand(base.shared, "main"),
      view: view_set.input(base.view, text_area.state_from_string("hello")),
    )
  }

  let #(submitted, effects) = stepping.step(backend.KeyPress("enter"), model)
  assert string.contains(submitted.shared.notice, "prompt sent")
    as "premise: the submission took the live path's local half"

  // The notice alone would also be set on a path that went on to refuse the
  // prompt. A replaying peer marks the strand submitting and stops there,
  // the local half of the live path, while a refusal leaves it unset.
  assert submitted.shared.submitting == Some("main")
    as "premise: the prompt took the replay path rather than a refusal"
  assert list.filter(effects, is_write) == []
}

fn drag_and_release(
  clipboard: tui_model.Clipboard,
) -> #(tui_model.Model, List(Effect)) {
  let model = {
    let base = quiet_model()
    tui_model.Model(
      shared: shared_set.transcript(base.shared, [
        transcript_line.Line(transcript_line.System, "alpha beta"),
        transcript_line.Line(transcript_line.System, "gamma delta"),
      ]),
      view: tui_model.View(..base.view, clipboard:),
    )
  }

  // The transcript's text starts at row 2, column 1 on a 60x12 screen: one
  // header row, then the panel border.
  let #(model, _) = stepping.step(backend.Resize(60, 12), model)
  let #(model, _) =
    stepping.step(backend.MousePress(3, 2, backend.MouseLeft), model)
  let #(model, _) =
    stepping.step(backend.MouseDrag(5, 3, backend.MouseLeft), model)
  stepping.step(backend.MouseRelease(5, 3, backend.MouseLeft), model)
}

fn quiet_model() -> tui_model.Model {
  {
    let base =
      tui.new_model(
        connection.new_inbox(),
        workspace.Context(path: "/w/demo", branch: None),
      )
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.transcript([])
        |> shared_set.strands([])
        |> shared_set.notice("ready"),
    )
  }
}

// A closed lane is `Closed`, so nothing the rest of the step does to it can
// queue more traffic behind its close. Retiring it, which an adoption does
// to whatever lane it replaces, is the transition that used to queue a
// second close and report a failure for a lane that was already gone.
pub fn a_closed_lane_queues_nothing_after_its_close_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let closed =
    session_channel.start(socket, snapshot.Expected("s", "e", "i"), now: 0)
    |> session_channel.close
  let #(retired, updates) = session_channel.retire(closed, "replaced")
  let #(_, outputs) = session_channel.take_outputs(retired)

  assert list.map(outputs, output_kind) == ["transmit", "shut"]
    as "the subscribe and one close, and nothing after the close"
  assert updates == [] as "retiring a closed lane reports nothing"
}

fn output_kind(output: terminal_lane.Output) -> String {
  case output {
    session_channel.Transmit(..) -> "transmit"
    session_channel.Shut(..) -> "shut"
    session_channel.Note(..) -> "note"
  }
}

fn is_clipboard_write(requested: Effect) -> Bool {
  case requested {
    effect.WriteClipboard(_) -> True
    _ -> False
  }
}

fn is_write(requested: Effect) -> Bool {
  case requested {
    effect.Step(step_effect.Lane(session_channel.Transmit(..))) -> True
    effect.Attachment(attachment.FromChannel(session_channel.Transmit(..))) ->
      True
    _ -> False
  }
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host
