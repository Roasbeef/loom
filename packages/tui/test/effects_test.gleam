//// A terminal step decides its I/O and performs none of it.
////
//// `tui.step` returns the next model and the effects it decided on, and
//// `tui.update` is that step followed by `runtime.perform`. These tests drive
//// `step` directly and read the effects as values: a copy asks for one
//// clipboard write, a quit asks for every cancel and close, and a submission
//// asks for a frame only when there is a socket to take it. Where a stand-in
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
import tui
import tui/agents
import tui/attachment
import tui/connection
import tui/daemon/selection as daemon_selection
import tui/effect.{type Effect}
import tui/model as tui_model
import tui/protocol
import tui/runtime
import tui/session_channel
import tui/sessions
import tui/snapshot
import tui/workspace
import tui_test/pushed
import weft

// A copy asks the runtime for exactly one clipboard write, and only when the
// terminal has a clipboard to write to. The notice is set either way, which
// is what shows the copy path ran in both cases.
pub fn a_mouse_copy_queues_one_clipboard_write_test() {
  let #(copied, effects) = drag_and_release(tui_model.TerminalClipboard)
  assert string.contains(copied.notice, "copied")
  let assert [effect.WriteClipboard(sequence)] =
    list.filter(effects, is_clipboard_write)
    as "a release over a selection queues one clipboard write"
  assert string.starts_with(sequence, "\u{001B}]52;c;")
    as "the queued write is an OSC 52 sequence"

  let #(copied, effects) = drag_and_release(tui_model.NoClipboard)
  assert string.contains(copied.notice, "copied")
  assert list.filter(effects, is_clipboard_write) == []
    as "a terminal with no clipboard is sent no sequence"
}

// A quit with a live channel and every background job running decides one
// close or cancel per resource, in the order they were once performed, and
// performs none of them. The channel's close leaves first, because the
// runtime collects the adopted channel's outputs before the outbox.
pub fn quit_with_a_channel_queues_every_close_and_cancel_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let host = host_on(owner)
  let request = weft.cancel_signal()
  let relaunch = weft.cancel_signal()
  let #(channel, _subscribe) =
    session_channel.start(
      socket,
      snapshot.Expected("A", "epoch", "incarnation"),
      now: 0,
    )
    |> session_channel.take_outputs
  let model =
    tui_model.Model(
      ..quiet_model(),
      peer: tui_model.Attached(socket),
      channel: Some(channel),
      daemon_host: Some(host),
      control_request: Some(tui_model.ControlRequest(
        cancel: request,
        replies: process.new_subject(),
        result: None,
      )),
      reconnect: tui_model.ReconnectAttempting(
        cancel: relaunch,
        replies: process.new_subject(),
      ),
    )

  let #(quit, effects) = tui.step(backend.KeyPress("ctrl+c"), model)
  assert quit.quit
  assert quit.outbox == []
  assert effects
    == [
      effect.Channel(session_channel.Shut(socket)),
      effect.CancelSessionSwitch(sessions.Idle),
      effect.Attachment(attachment.Abandon(attachment.idle())),
      effect.CancelTask(request),
      effect.CancelTask(relaunch),
      effect.CloseControl(daemon_selection.control(host)),
    ]
  assert process.receive(owner, 0) == Error(Nil)
    as "the step closed nothing itself"

  // Performing them is what reaches the handles: one socket close and one
  // control close, both addressed to the handles the step was given.
  runtime.perform(effects)
  let assert Ok(_) = process.receive(owner, 100)
  let assert Ok(_) = process.receive(owner, 100)
  assert process.receive(owner, 0) == Error(Nil)
}

// Without a channel, the preview peer's socket is closed directly, and the
// close is still only queued.
pub fn quit_without_a_channel_queues_the_peer_close_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let model = tui_model.Model(..quiet_model(), peer: tui_model.Attached(socket))

  let #(quit, effects) = tui.step(backend.KeyPress("ctrl+c"), model)
  assert quit.quit
  assert effects
    == [
      effect.CancelSessionSwitch(sessions.Idle),
      effect.Attachment(attachment.Abandon(attachment.idle())),
      effect.CloseSocket(socket),
    ]
  assert process.receive(owner, 0) == Error(Nil)
    as "the step closed nothing itself"
}

// A replay has no socket, so a prompt submitted during one does the local
// half of the live path and asks for no write of any kind.
pub fn a_replayed_prompt_queues_no_write_test() {
  let model =
    tui_model.Model(
      ..pushed.attached(),
      active_strand: "main",
      input: text_area.state_from_string("hello"),
    )

  let #(submitted, effects) = tui.step(backend.KeyPress("enter"), model)
  assert string.contains(submitted.notice, "prompt sent")
    as "premise: the submission took the live path's local half"

  // The notice alone would also be set on a path that went on to refuse the
  // prompt. A replaying peer marks the strand submitting and stops there,
  // the local half of the live path, while a refusal leaves it unset.
  assert submitted.submitting == Some("main")
    as "premise: the prompt took the replay path rather than a refusal"
  assert list.filter(effects, is_write) == []
}

// A socket with no channel yet takes a read as one direct write, queued
// rather than sent. A prompt is not the probe here: a mutation waits for a
// channel that has synchronized, so it would be refused before any write.
pub fn a_channelless_socket_queues_one_direct_write_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let model =
    tui_model.Model(
      ..quiet_model(),
      peer: tui_model.Attached(socket),
      input: text_area.state_from_string("/models"),
    )

  let #(_, effects) = tui.step(backend.KeyPress("enter"), model)
  assert list.filter(effects, is_write)
    == [effect.Send(socket, protocol.models(model.next_id))]
  assert process.receive(owner, 0) == Error(Nil)
    as "the step wrote nothing itself"

  runtime.perform(effects)
  let assert Ok(_) = process.receive(owner, 100)
    as "performing the effect is what reaches the socket"
}

fn drag_and_release(
  clipboard: tui_model.Clipboard,
) -> #(tui_model.Model, List(Effect)) {
  let model =
    tui_model.Model(..quiet_model(), clipboard:, transcript: [
      tui_model.Line(tui_model.System, "alpha beta"),
      tui_model.Line(tui_model.System, "gamma delta"),
    ])

  // The transcript's text starts at row 2, column 1 on a 60x12 screen: one
  // header row, then the panel border.
  let #(model, _) = tui.step(backend.Resize(60, 12), model)
  let #(model, _) = tui.step(backend.MousePress(3, 2, backend.MouseLeft), model)
  let #(model, _) = tui.step(backend.MouseDrag(5, 3, backend.MouseLeft), model)
  tui.step(backend.MouseRelease(5, 3, backend.MouseLeft), model)
}

fn quiet_model() -> tui_model.Model {
  tui_model.Model(
    ..tui.new_model(
      connection.new_inbox(),
      workspace.Context(path: "/w/demo", branch: None),
    ),
    transcript: [],
    strands: [],
    agent_summary: agents.summary([]),
    notice: "ready",
  )
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

fn output_kind(output: session_channel.Out) -> String {
  case output {
    session_channel.Transmit(..) -> "transmit"
    session_channel.Shut(..) -> "shut"
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
    effect.Send(..) -> True
    effect.Channel(session_channel.Transmit(..)) -> True
    effect.Attachment(attachment.FromChannel(session_channel.Transmit(..))) ->
      True
    _ -> False
  }
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host
