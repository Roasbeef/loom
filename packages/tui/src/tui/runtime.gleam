//// Performs the effects a terminal step decided on.
////
//// The reducer appends `Effect` values to the model's outbox, which is the
//// step's one queue. A channel queues its own writes, closes and recording
//// notes, but the reducer that transitions it moves them into the outbox
//// before it stores the channel (`tui_model.hold_channel`), and a
//// provisional attachment hands its channel's outputs back with the rest of
//// what it decided. `take` empties the outbox at the end of a step;
//// `perform` then carries the effects out. `tui.step` returns what `take`
//// collected, and `tui.update`, which etui and the virtual backend call, is
//// `step` followed by `perform`.
////
//// The effects come out in the order the step decided them. For the
//// sockets that is the order that matters: frames on one socket leave in
//// the order the protocol lane issued them, and a closed lane is in its
//// `Closed` phase and queues nothing further, so no channel writes after
//// its own close. For the recording it is the order ADR-009 requires: the
//// input's line is queued before the reducer runs, and every note after it
//// is queued where its cause was decided.
////
//// It also reads the clocks the step is applied at. `stamp` runs before
//// the step and writes one `Stamp` onto the model, so the reducers read the
//// time from the model instead of calling a clock, and every reducer in a
//// step sees the same instant.
////
//// It also receives the step's traffic. `receive` runs before the step and
//// tops up every inbox the model holds from its mailbox, each to the most
//// the step can consume from it, and the reducers take from those buffers
//// instead of reading a mailbox. What arrives during the step waits for
//// the next one.
////
//// This module is the only impure half of the step. Nothing in the reducer
//// imports it.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap as host_bootstrap
import tui/attachment
import tui/buffered
import tui/connection
import tui/daemon
import tui/effect.{type Effect}
import tui/herdr
import tui/model.{type Model, type Stamp, Model, Stamp} as tui_model
import tui/recording
import tui/session_channel
import tui/sessions
import weft

/// Reads the clocks for one event and writes them onto the model.
///
/// `tui.update` calls this once per event, before the step. A caller that
/// drives a reducer outside `update`, such as a test driver handing a
/// selected socket message to `inbound.accept_connection_message`, stamps
/// first, or the reducer runs at the time of the previous event.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.stamp(model)
/// ```
pub fn stamp(model: Model) -> Model {
  Model(
    ..model,
    stamp: read_stamp(model.monotonic_time_ms, model.transport_time_ms),
  )
}

/// Receives the traffic for one event, before the step, into the inboxes
/// the model holds.
///
/// Each inbox is topped up to what the step can take from it: the
/// connection inbox to `connection_batch`, the drain a tick or a key runs;
/// the replay inbox to one event, which is all a tick applies; and the
/// provisional attachment's inboxes through `attachment.top_up`. An inbox
/// the step did not drain keeps what it holds and receives nothing more, so
/// no buffer grows past its bound.
///
/// `tui.update` calls this once per event, after `stamp`. A caller that
/// runs `tui.step` itself and expects it to see traffic calls it first.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.receive(runtime.stamp(model))
/// ```
pub fn receive(model: Model) -> Model {
  Model(
    ..model,
    inbox: buffered.top_up(model.inbox, up_to: tui_model.connection_batch),
    replay_inbox: buffered.top_up(model.replay_inbox, up_to: 1),
    candidate: attachment.top_up(model.candidate),
  )
}

/// Reads the presentation and transport clocks it is given and the host's
/// wall clock, once each.
///
/// ## Examples
///
/// ```gleam
/// let stamp =
///   runtime.read_stamp(
///     host_bootstrap.monotonic_time_ms,
///     host_bootstrap.monotonic_time_ms,
///   )
/// ```
pub fn read_stamp(presentation: fn() -> Int, transport: fn() -> Int) -> Stamp {
  Stamp(
    now_ms: presentation(),
    transport_ms: transport(),
    wall_ms: host_bootstrap.system_time_ms(),
  )
}

/// Names this terminal for a session creation key: the OS process and the
/// calling BEAM process. It is read once, when the model is created, since
/// neither changes while the terminal runs.
///
/// ## Examples
///
/// ```gleam
/// let terminal = runtime.terminal_identity()
/// ```
pub fn terminal_identity() -> String {
  int.to_string(host_bootstrap.current_process_id())
  <> "-"
  <> string.inspect(process.self())
}

/// Takes every effect a step queued, oldest first, and empties the outbox.
///
/// The outbox is the only queue: every reducer that transitions a channel
/// has already moved that channel's outputs into it, so there is nothing to
/// collect from the channels and no order across queues to choose.
///
/// ## Examples
///
/// ```gleam
/// let #(model, effects) = runtime.take(model)
/// ```
pub fn take(model: Model) -> #(Model, List(Effect)) {
  #(Model(..model, outbox: []), list.reverse(model.outbox))
}

/// Performs effects in order.
///
/// ## Examples
///
/// ```gleam
/// runtime.perform(effects)
/// ```
pub fn perform(effects: List(Effect)) -> Nil {
  list.each(effects, perform_one)
}

/// Takes and performs everything a model has queued.
///
/// For a caller that drives reducers outside `tui.update`, such as a test
/// driver that hands a selected socket message to
/// `inbound.accept_connection_message`: whatever that call decided is
/// performed here rather than waiting for the next step to collect it.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.flush(inbound.accept_connection_message(model, message))
/// ```
pub fn flush(model: Model) -> Model {
  let #(model, effects) = take(model)
  perform(effects)
  model
}

fn perform_one(requested: Effect) -> Nil {
  case requested {
    effect.Channel(output) -> session_channel.perform(output)
    effect.Attachment(output) -> attachment.perform(output)
    effect.Send(socket, frame) -> connection.send(socket, frame)
    effect.CloseSocket(socket) -> connection.close(socket)
    effect.CloseControl(control) -> daemon.close(control)
    effect.CancelTask(signal) -> weft.cancel(signal)
    effect.CancelSessionSwitch(status) -> sessions.cancel(status)
    effect.Discard(inbox) -> sessions.discard(inbox)
    effect.Record(recorder, event) -> recording.append(recorder, event)

    // Etui draws its frames with `io:put_chars`, so a sequence printed the
    // same way lands on the terminal in order with them.
    effect.WriteClipboard(sequence) -> io.print(sequence)
    effect.AnnounceHerdr(reporter, session) ->
      herdr.announce(Some(reporter), session)
    effect.ReportHerdr(reporter, state, session, message) ->
      herdr.report(Some(reporter), state, session, message)
  }
}
