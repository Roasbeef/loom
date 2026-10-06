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
//// `message`, then `step`, then `perform`.
////
//// The effects come out in the order the step decided them. For the
//// sockets that is the order that matters: frames on one socket leave in
//// the order the protocol lane issued them, and a closed lane is in its
//// `Closed` phase and queues nothing further, so no channel writes after
//// its own close. For the recording it is the order ADR-009 requires: the
//// input's line is queued before the reducer runs, and every note after it
//// is queued where its cause was decided.
////
//// It also receives the step's traffic. `receive` runs before the step,
//// reads every inbox the model holds from its mailbox, each up to the room
//// its buffer has left (`arrivals`), and has the step's admission file what
//// it read (`tui/admission`); the reducers take from those buffers instead
//// of reading a mailbox. What arrives during the step waits for the next
//// one.
////
//// And it runs the background jobs the reducers ask for. `perform` starts
//// and cancels them in `Model.running`, a table no reducer reads, and
//// `settle` stores the table back on the model after the step. `receive`
//// reads every running job's replies and `hold` admits each into the slot
//// that names its key, or drops it when no slot does.
////
//// And it builds the message each step is given. `message` translates
//// etui's input event (`tui/keymap`), reads the clocks into it once, and
//// reads the file a pasted path names into it, so the step reads neither a
//// clock nor a file, and every reducer in a step sees the same instant.
////
//// This module and `tui/job_runner`, which it calls, are the impure half
//// of the step. Nothing in the reducer imports either.

import etui/backend
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import session_view/model as session_model
import session_view/msg.{type Stamp, Stamp} as _
import session_view/shared_set
import session_view/step_effect
import tui/admission
import tui/attachment
import tui/buffered
import tui/connection
import tui/daemon/selection as daemon_selection
import tui/effect.{type Effect}
import tui/herdr
import tui/image_drop
import tui/image_shown
import tui/internal/ffi_terminal
import tui/job
import tui/job_runner
import tui/keymap
import tui/layout_memory
import tui/model.{type Model, Model, View} as tui_model
import tui/msg.{type Msg}
import tui/recording
import tui/terminal_lane
import tui/view_set
import weft

/// Reads the clocks and writes them onto the model, for a caller that
/// drives a reducer outside `tui.step`.
///
/// The step takes its time from its message instead. A test driver handing
/// a selected socket message to `inbound.accept_connection_message` stamps
/// first, or the reducer runs at the time of the previous event.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.stamp(model)
/// ```
pub fn stamp(model: Model) -> Model {
  Model(
    shared: shared_set.stamp(
      model.shared,
      read_stamp(model.view.monotonic_time_ms, model.view.transport_time_ms),
    ),
    view: View(..model.view, wall_ms: host_bootstrap.system_time_ms()),
  )
}

/// Receives the traffic for one event, before the step, and has the step's
/// admission file it into the inboxes and slots the model holds.
///
/// Every running job's messages are received in full and handed over first
/// (`hold`). A job sends at most three messages, an attachment's `Prepared`
/// and its relay's two, so that is bounded, and reading a job's messages
/// even after its slot was cleared is what keeps them from staying in the
/// mailbox. The jobs go first so that an attachment's `Prepared`, which
/// names the frames inbox, is admitted before the attempt's frames are
/// read, and the first frames arrive with it.
///
/// Then each inbox's mailbox is read up to the room its buffer has
/// (`arrivals`) and the messages are admitted behind what the buffer holds.
/// The bound is kept here, by reading no more than there is room for, and
/// not by admission, which never drops a frame for capacity: what is not
/// read waits in the mailbox for the next event.
///
/// Admission is `tui/admission`, the same function the step runs for
/// `msg.Arrived`. This host calls it directly because it runs in the step's
/// own process, immediately before the step; a host that can only call the
/// step delivers the same arrivals as `msg.Arrived`.
///
/// `tui.update` calls this once per event, before the step. A caller that
/// runs `tui.step` itself and expects it to see traffic calls it first.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.receive(model)
/// ```
pub fn receive(model: Model) -> Model {
  let model = list.fold(job_runner.receive(model.view.running), model, hold)
  admission.admit(model, arrivals(model))
}

/// The traffic waiting for the model's inboxes, read from each mailbox up
/// to the room its buffer has left: the connection inbox to
/// `connection_batch`, the drain a tick or a key runs; the replay inbox to
/// one event, which is all a tick applies, and only while the peer is
/// `Replaying`; and the waiting attempt's frames to its batch, until its
/// initial cut is captured (`attachment.frame_room`).
///
/// Each subject is read from the model it is given, so after an adoption
/// the adopted inbox's subject is read and the replaced one never again. An
/// inbox the step did not drain has no room and reads nothing.
///
/// Every read here is a selective receive, which scans the whole mailbox
/// when nothing in it matches, so a read that cannot find anything is not
/// free: under a socket backlog it costs one pass over the backlog on every
/// event. The replay inbox is the one that is empty for the life of a live
/// terminal, since only the virtual backend of a replay sends to it
/// (`tui.replay_steps`) and a replay's peer is `Replaying` from its first
/// event to its last; no transition leaves or enters that peer. So the read
/// is skipped outside a replay rather than taken and found empty.
///
/// ## Examples
///
/// ```gleam
/// let model = admission.admit(model, runtime.arrivals(model))
/// ```
pub fn arrivals(model: Model) -> List(msg.Arrival) {
  let connection = buffered.sender(model.shared.inbox)
  let from_connection =
    buffered.waiting(
      connection,
      tui_model.connection_batch - buffered.held(model.shared.inbox),
    )
    |> list.map(msg.Frame(connection, _))
  let replayed = case model.shared.peer {
    session_model.Replaying ->
      buffered.waiting(
        buffered.sender(model.shared.replay_inbox),
        1 - buffered.held(model.shared.replay_inbox),
      )
      |> list.map(msg.Replayed)
    session_model.Attached
    | session_model.Disconnected
    | session_model.Preview -> []
  }
  let from_attempt = case attachment.frame_room(model.view.candidate) {
    Error(Nil) -> []
    Ok(#(frames, room)) ->
      buffered.waiting(frames, room) |> list.map(msg.Frame(frames, _))
  }
  list.flatten([from_connection, replayed, from_attempt])
}

/// Builds the message the step is given for one etui input event.
///
/// This is where the host does the reading the event needs, so the step
/// does none: it reads the presentation, transport and wall clocks once
/// each into the message's `Stamp`, and, for a paste that names one path,
/// reads that file (`image_drop.load_paste`) into the message's `Pasted`.
/// A read belongs to the paste it was taken for because it travels inside
/// that paste's message, and it is gone with the message once the step
/// has handled it.
///
/// A paste's file is read here rather than by a job because a job's answer
/// arrives a step later: a key typed between the paste and that answer
/// would be applied first, so an Enter could submit the prompt without the
/// image, and pasted text that names no image would be inserted after the
/// keys that followed it. The read happens whatever the step then does with
/// the paste, so a path pasted into an overlay that ignores pastes is read
/// and dropped; the bounds on the read (`pasted_image.max_image_bytes`) apply
/// either way.
///
/// `tui.update` calls this once per event. The model is read only for its
/// two clock functions.
///
/// ## Examples
///
/// ```gleam
/// let message = runtime.message(backend.Paste("/tmp/shot.png"), model)
/// ```
pub fn message(event: backend.InputEvent, model: Model) -> Msg {
  let pasted = case event {
    backend.Paste(text) -> image_drop.load_paste(text)
    backend.KeyPress(_)
    | backend.Resize(..)
    | backend.Tick
    | backend.MousePress(..)
    | backend.MouseRelease(..)
    | backend.MouseScroll(..)
    | backend.MouseDrag(..)
    | backend.MouseMove(..) -> Ok(None)
  }
  msg.Input(
    at: read_stamp(model.view.monotonic_time_ms, model.view.transport_time_ms),
    wall_ms: host_bootstrap.system_time_ms(),
    event: keymap.translate(event, pasted),
  )
}

/// Hands one job message to the step's admission, after the host's own
/// bookkeeping for it.
///
/// The host forgets the job once the message is the last its relay sends
/// (`job_runner.observed`), and turns an attachment job's end into
/// `job.Finished` with whether the socket the attempt would adopt is still
/// alive, which is a process read the step does not do (`checked`). Then
/// admission files the message into the slot that names its key, or drops
/// it and queues the release of what it holds (`tui/admission`). `hold`
/// performs nothing. `receive` calls this for every job message it read; a
/// test calls it to hand a step a reply without running a job, and a test
/// driver calls it with a reply its actor selected.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.hold(model, job.ControlArrived(key, weft.AllDelivered))
/// ```
pub fn hold(
  model: Model,
  arrival: job.Arrival(daemon_selection.Host),
) -> Model {
  let #(running, arrival) = job_runner.file(model.view.running, arrival)
  let arrival = checked(model, arrival)
  let model =
    Model(
      ..model,
      view: view_set.running(model.view, job_runner.observed(running, arrival)),
    )
  admission.admit(model, [msg.JobReplied(arrival)])
}

/// Puts a daemon control connection in the runtime's table and names it on
/// the model as the terminal's control route.
///
/// The launch paths call this with the connection they authenticated, and
/// a test calls it to give a model a control route. The step never sees the
/// connection, only the key and build `job.Daemon` carries.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.adopt_control(model, host)
/// ```
pub fn adopt_control(model: Model, host: daemon_selection.Host) -> Model {
  let #(running, daemon) = job_runner.adopt_control(model.view.running, host)
  Model(..model, view: view_set.running(model.view, running))
  |> tui_model.adopt_daemon(daemon)
}

// An attachment job's end permits adoption only on a socket that is still
// alive, and whether it is is a process read, which the step does not do.
// So the host reads it here, as it hands the end over, and the attempt gets
// `Finished` with the answer instead of the relay's `AllDelivered`. The
// read is taken only for the attempt the end belongs to; an end for any
// other key is dropped by the admission below whatever it carries. A socket
// can die after this read as it could after the step's read before phase
// 3; the adopted lane's own transport-loss handling covers that case.
fn checked(
  model: Model,
  arrival: job.Arrival(job.Daemon),
) -> job.Arrival(job.Daemon) {
  case arrival {
    job.AttachArrived(key:, reply: job.Settled(weft.AllDelivered)) ->
      case attachment.job_key(model.view.candidate) == Some(key) {
        False -> arrival
        True ->
          job.AttachArrived(
            key:,
            reply: job.Finished(liveness(model.view.candidate)),
          )
      }
    job.AttachArrived(..)
    | job.ControlArrived(..)
    | job.ReconnectArrived(..)
    | job.ActivityArrived(..)
    | job.ConfigurationArrived(..)
    | job.ImageArrived(..) -> arrival
  }
}

fn liveness(candidate: attachment.Status) -> job.SocketLiveness {
  case result.try(attachment.adoptable_socket(candidate), connection.adopt) {
    Ok(Nil) -> job.SocketAlive
    Error(reason) -> job.SocketGone(reason:)
  }
}

/// Reads the presentation and transport clocks it is given, once each.
///
/// The host's wall clock is read beside it, by `message` and `stamp`,
/// because it is stored in the terminal's view rather than in the stamp.
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
  Stamp(now_ms: presentation(), transport_ms: transport())
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
  #(
    Model(..model, view: view_set.outbox(model.view, [])),
    list.reverse(model.view.outbox),
  )
}

/// Performs effects in order, starting and cancelling jobs in `running`,
/// and returns the table as the effects left it.
///
/// The table is threaded through in the order the step decided, so a job
/// started and cancelled in the same step is started first.
///
/// ## Examples
///
/// ```gleam
/// let running = runtime.perform(effects, model.running)
/// ```
pub fn perform(
  effects: List(Effect),
  running: job_runner.Running,
) -> job_runner.Running {
  list.fold(effects, running, perform_one)
}

/// Performs what a step returned and stores the job table on its model.
///
/// `tui.update` is `settle(step(message(event, model), receive(model)))`.
/// The step never touches `Model.running`, so the table `perform` starts
/// from is the one the previous event left.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.settle(tui.step(event, model))
/// ```
pub fn settle(stepped: #(Model, List(Effect))) -> Model {
  let #(model, effects) = stepped
  Model(
    ..model,
    view: view_set.running(model.view, perform(effects, model.view.running)),
  )
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
  settle(take(model))
}

// Starts, cancels and control closes change the runtime's table; every
// other effect is one call that leaves it as it was.
fn perform_one(
  running: job_runner.Running,
  requested: Effect,
) -> job_runner.Running {
  case requested {
    effect.StartJob(key, spec) -> job_runner.start(running, key, spec)
    effect.CancelJob(key) -> job_runner.cancel(running, key)
    effect.CloseControl(control) -> job_runner.close_control(running, control)
    effect.Step(_)
    | effect.Attachment(_)
    | effect.CloseSocket(_)
    | effect.Discard(_)
    | effect.Record(..)
    | effect.WriteClipboard(_)
    | effect.DrawImages(_)
    | effect.SaveLayout(..)
    | effect.WakeLoop
    | effect.AnnounceHerdr(..)
    | effect.ReportHerdr(..)
    | effect.ReleaseHerdr(..) -> {
      perform_io(requested)
      running
    }
  }
}

fn perform_io(requested: Effect) -> Nil {
  case requested {
    effect.Step(step_effect.Lane(output)) -> terminal_lane.perform(output)
    effect.Step(step_effect.Recorded(recorder, message)) ->
      recording.append(recorder, recording.Arrived(message))
    effect.Attachment(output) -> attachment.perform(output)
    effect.CloseSocket(socket) -> connection.close(socket)
    effect.Discard(inbox) -> buffered.discard(inbox)
    effect.Record(recorder, event) -> recording.append(recorder, event)

    // Etui draws its frames with `io:put_chars`, so a sequence printed the
    // same way lands on the terminal in order with them.
    effect.WriteClipboard(sequence) -> io.print(sequence)

    // Image commands are written the same way, so they land between the
    // frames in the order the step decided them. The wake is sent to the
    // process performing the effect, which is the loop's.
    effect.DrawImages(commands) -> io.print(image_shown.sequence(commands))
    effect.WakeLoop -> ffi_terminal.wake_loop(process.self())

    // A failed save is dropped: the alternate screen is open, so there is
    // nowhere to say so, and the layout is a preference that the next change
    // writes again.
    effect.SaveLayout(path, key, layout) -> {
      let _ = layout_memory.save(path, key, layout)
      Nil
    }
    effect.AnnounceHerdr(reporter, session) ->
      herdr.announce(Some(reporter), session)
    effect.ReportHerdr(reporter, state, session, message) ->
      herdr.report(Some(reporter), state, session, message)
    effect.ReleaseHerdr(reporter) -> herdr.release(Some(reporter))

    // `perform_one` handles these three before it gets here, because each
    // changes the runtime's table.
    effect.StartJob(..) | effect.CancelJob(_) | effect.CloseControl(_) -> Nil
  }
}
