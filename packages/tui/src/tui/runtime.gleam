//// Performs the effects a terminal step decided on.
////
//// The reducer appends `Effect` values to the model's outbox, and the two
//// channels it may hold, the adopted one and a provisional attachment's,
//// queue their own writes and closes. `take` collects all three at the end
//// of a step and leaves every queue empty; `perform` then carries them out.
//// `tui.step` returns what `take` collected, and `tui.update`, which etui
//// and the virtual backend call, is `step` followed by `perform`.
////
//// The collection order is the channels' outputs first, then the model's
//// outbox. Each channel's own outputs keep the order they were decided in,
//// which is the order that matters: frames on one socket must leave in the
//// order the protocol lane issued them. Across queues the order is
//// immaterial for correctness. A closed channel is in its `Closed` phase and
//// queues nothing further, so no channel writes after its own close. The
//// outputs `tui_model.release_channel` moves into the outbox belong to a
//// channel the step has already let go of, so they cannot interleave with
//// a live channel's writes to the same socket.
////
//// It also reads the clocks the step is applied at. `stamp` runs before
//// the step and writes one `Stamp` onto the model, so the reducers read the
//// time from the model instead of calling a clock, and every reducer in a
//// step sees the same instant.
////
//// This module is the only impure half of the step. Nothing in the reducer
//// imports it.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host_bootstrap
import tui/attachment
import tui/connection
import tui/daemon
import tui/effect.{type Effect}
import tui/herdr
import tui/model.{type Model, type Stamp, Model, Stamp}
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
  Model(..model, stamp: read_stamp(model.monotonic_time_ms))
}

/// Reads the presentation clock it is given and the host's transport and
/// wall clocks, once each.
///
/// ## Examples
///
/// ```gleam
/// let stamp = runtime.read_stamp(host_bootstrap.monotonic_time_ms)
/// ```
pub fn read_stamp(presentation: fn() -> Int) -> Stamp {
  Stamp(
    now_ms: presentation(),
    transport_ms: host_bootstrap.monotonic_time_ms(),
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

/// Takes every effect a step queued, oldest first, and empties the queues.
///
/// ## Examples
///
/// ```gleam
/// let #(model, effects) = runtime.take(model)
/// ```
pub fn take(model: Model) -> #(Model, List(Effect)) {
  let #(channel, adopted) = case model.channel {
    None -> #(None, [])
    Some(held) -> {
      let #(held, outputs) = session_channel.take_outputs(held)
      #(Some(held), list.map(outputs, effect.Channel))
    }
  }
  let #(candidate, provisional) = attachment.take_outputs(model.candidate)
  let effects =
    list.flatten([
      adopted,
      list.map(provisional, effect.Attachment),
      list.reverse(model.outbox),
    ])
  #(Model(..model, channel:, candidate:, outbox: []), effects)
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

    // Etui draws its frames with `io:put_chars`, so a sequence printed the
    // same way lands on the terminal in order with them.
    effect.WriteClipboard(sequence) -> io.print(sequence)
    effect.AnnounceHerdr(reporter, session) ->
      herdr.announce(Some(reporter), session)
    effect.ReportHerdr(reporter, state, session, message) ->
      herdr.report(Some(reporter), state, session, message)
  }
}
