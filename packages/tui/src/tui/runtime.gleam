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
//// And it runs the background jobs the reducers ask for. `perform` starts
//// and cancels them in `Model.running`, a table no reducer reads, and
//// `settle` stores the table back on the model after the step. `receive`
//// reads every running job's replies and `hold` admits each into the slot
//// that names its key, or drops it when no slot does.
////
//// And it reads the file a pasted path names. `read_paste` runs before
//// the step and writes what the read found onto the model, so the
//// composer attaches a dropped image without the step opening a file.
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
import tui/attachment
import tui/buffered
import tui/connection
import tui/daemon
import tui/effect.{type Effect}
import tui/herdr
import tui/image_drop
import tui/job
import tui/job_runner
import tui/model.{
  type Model, type Stamp, ActivityAsking, ActivityDue, ActivityResting,
  ControlRequest, Model, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
  Stamp,
} as tui_model
import tui/recording
import tui/session_channel

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
/// Every running job's replies are received in full and passed to `hold`
/// first. A job sends at most three messages, an attachment's `Prepared`
/// and its relay's two, so that is bounded too, and reading a job's
/// messages even after its slot was cleared is what keeps them from
/// staying in the mailbox. The jobs go first so that an attachment's
/// `Prepared`, which names the frames inbox, is admitted before the
/// candidate's frames are topped up, and the first frames arrive with it.
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
  let model = list.fold(job_runner.receive(model.running), model, hold)
  Model(
    ..model,
    inbox: buffered.top_up(model.inbox, up_to: tui_model.connection_batch),
    replay_inbox: buffered.top_up(model.replay_inbox, up_to: 1),
    candidate: attachment.top_up(model.candidate),
  )
}

/// Reads the file a paste event names, before the step, and writes what the
/// read found onto the model as `Model.dropped`.
///
/// A terminal delivers a dragged file as a paste of its path. The read is
/// done here rather than as a job because a job's answer arrives a step
/// later: a key typed between the paste and that answer would be applied
/// first, so an Enter could submit the prompt without the image, and pasted
/// text that names no image would be inserted after the keys that followed
/// it. Read here, the paste is still handled in one step.
///
/// Every event overwrites the field, so a read never outlives the event it
/// was taken for, and an image the read held is not kept on the model after
/// the composer has taken it. Nothing is read for a paste that does not
/// name exactly one path. The read happens whatever the step then does with
/// the paste, so a path pasted into an overlay that ignores pastes is read
/// and then dropped; the bounds on the read (`image_drop.max_image_bytes`)
/// apply either way.
///
/// `tui.update` calls this once per event, after `receive`. A caller that
/// runs `tui.step` itself with a paste naming an image calls it first.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.read_paste(backend.Paste("/tmp/shot.png"), model)
/// ```
pub fn read_paste(event: backend.InputEvent, model: Model) -> Model {
  case event, model.dropped {
    backend.Paste(text), _ ->
      Model(..model, dropped: image_drop.read_dropped(text))

    // Most events are not pastes and find nothing to clear, so the model is
    // returned as it was rather than rebuilt.
    _, image_drop.NothingDropped -> model
    _, image_drop.Dropped(..) ->
      Model(..model, dropped: image_drop.NothingDropped)
  }
}

/// Admits one job reply into the slot that waits for it, and forgets the
/// job once the reply is the last its relay sends.
///
/// A reply goes to the slot of its kind only when that slot names the
/// reply's key. Otherwise it belongs to a job no reducer waits for any
/// more, one that was cancelled or whose slot moved on, and it is dropped
/// here; that comparison of keys is the only fence a job reply passes.
/// Most replies are data and are simply forgotten. Two carry a resource
/// nobody else will release: an attachment's `Prepared` holds an open
/// socket and names its frames subject, and a relaunch's `Completed` holds
/// a control connection. Dropping either queues the effects that release
/// it, `CloseSocket` then `Discard`, or `CloseControl`, which the runtime
/// performs after the next step like any other (`tui_model.release`, which
/// a reducer clearing a slot also uses). `hold` itself performs
/// nothing, so `receive` only reads mailboxes. `receive` calls this for
/// everything it read; a test calls it to hand a step a reply without
/// running a job, and a test driver calls it with a reply its actor
/// selected.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.hold(model, job.ControlArrived(key, weft.AllDelivered))
/// ```
pub fn hold(model: Model, arrival: job.Arrival) -> Model {
  let model =
    Model(..model, running: job_runner.observed(model.running, arrival))
  let admitted = case arrival {
    job.ControlArrived(key:, reply:) -> hold_control(model, key, reply)
    job.ReconnectArrived(key:, reply:) -> hold_reconnect(model, key, reply)
    job.ActivityArrived(key:, reply:) -> hold_activity(model, key, reply)
    job.ConfigurationArrived(key:, reply:) ->
      hold_configuration(model, key, reply)
    job.AttachArrived(key:, reply:) ->
      attachment.admit(model.candidate, key, reply)
      |> result.map(fn(candidate) { Model(..model, candidate:) })
  }
  case admitted {
    Ok(model) -> model
    Error(Nil) -> tui_model.release(model, arrival)
  }
}

fn hold_control(
  model: Model,
  key: job.Key,
  reply: job.ControlReply,
) -> Result(Model, Nil) {
  case model.control_request {
    None -> Error(Nil)
    Some(run) ->
      job.admit(run.job, key, reply)
      |> result.map(fn(awaiting) {
        Model(
          ..model,
          control_request: Some(ControlRequest(..run, job: awaiting)),
        )
      })
  }
}

fn hold_reconnect(
  model: Model,
  key: job.Key,
  reply: job.ReconnectReply,
) -> Result(Model, Nil) {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> Error(Nil)
    ReconnectAttempting(job: awaiting) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) {
        Model(..model, reconnect: ReconnectAttempting(awaiting))
      })
  }
}

fn hold_activity(
  model: Model,
  key: job.Key,
  reply: job.ActivityReply,
) -> Result(Model, Nil) {
  case model.activity_poll {
    ActivityDue | ActivityResting(..) -> Error(Nil)
    ActivityAsking(job: awaiting, asked:) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) {
        Model(..model, activity_poll: ActivityAsking(awaiting, asked))
      })
  }
}

fn hold_configuration(
  model: Model,
  key: job.Key,
  reply: job.ConfigurationReply,
) -> Result(Model, Nil) {
  case model.configuring {
    None -> Error(Nil)
    Some(awaiting) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) { Model(..model, configuring: Some(awaiting)) })
  }
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
/// `tui.update` is `settle(step(event, receive(stamp(model))))`. The step
/// never touches `Model.running`, so the table `perform` starts from is the
/// one the previous event left.
///
/// ## Examples
///
/// ```gleam
/// let model = runtime.settle(tui.step(event, model))
/// ```
pub fn settle(stepped: #(Model, List(Effect))) -> Model {
  let #(model, effects) = stepped
  Model(..model, running: perform(effects, model.running))
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

// Starts and cancels change the job table; every other effect is one call
// that leaves it as it was.
fn perform_one(
  running: job_runner.Running,
  requested: Effect,
) -> job_runner.Running {
  case requested {
    effect.StartJob(key, spec) -> job_runner.start(running, key, spec)
    effect.CancelJob(key) -> job_runner.cancel(running, key)
    effect.Channel(_)
    | effect.Attachment(_)
    | effect.Send(..)
    | effect.CloseSocket(_)
    | effect.CloseControl(_)
    | effect.Discard(_)
    | effect.Record(..)
    | effect.WriteClipboard(_)
    | effect.AnnounceHerdr(..)
    | effect.ReportHerdr(..) -> {
      perform_io(requested)
      running
    }
  }
}

fn perform_io(requested: Effect) -> Nil {
  case requested {
    effect.Channel(output) -> session_channel.perform(output)
    effect.Attachment(output) -> attachment.perform(output)
    effect.Send(socket, frame) -> connection.send(socket, frame)
    effect.CloseSocket(socket) -> connection.close(socket)
    effect.CloseControl(control) -> daemon.close(control)
    effect.Discard(inbox) -> buffered.discard(inbox)
    effect.Record(recorder, event) -> recording.append(recorder, event)

    // Etui draws its frames with `io:put_chars`, so a sequence printed the
    // same way lands on the terminal in order with them.
    effect.WriteClipboard(sequence) -> io.print(sequence)
    effect.AnnounceHerdr(reporter, session) ->
      herdr.announce(Some(reporter), session)
    effect.ReportHerdr(reporter, state, session, message) ->
      herdr.report(Some(reporter), state, session, message)

    // `perform_one` handles these two before it gets here.
    effect.StartJob(..) | effect.CancelJob(_) -> Nil
  }
}
