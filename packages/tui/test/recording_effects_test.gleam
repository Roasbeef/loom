//// What a recorded session writes, byte for byte.
////
//// A recording is only useful if the terminal writes the same lines for the
//// same session whatever changes underneath it: a replay of last month's
//// recording answers a question about the client only while the two agree on
//// what a session looks like. The golden session here drives the shipped
//// `tui.update` over a stand-in socket, through an initial capture, a resize,
//// a prompt, a failed session switch and a quit, and compares the file it
//// wrote with a copy taken before recording joined the effect stream. The
//// `at` offsets are wall time and are the only field set aside.

import core/json
import core/register
import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/codec
import machine/strand
import session_view/attempt
import session_view/connection_event
import session_view/model as session_model
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/step_effect
import simplifile
import tui
import tui/attachment
import tui/buffered
import tui/connection
import tui/effect
import tui/inbound
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/recording
import tui/runtime
import tui/terminal_lane
import tui/view_set
import tui/virtual_backend
import tui/workspace
import tui_test/pushed
import tui_test/stepping
import weft
import weft/poll

const golden = "test/recordings/scripted-session.golden.jsonl"

// The session touches every in-step recording write the terminal has: the
// input lines, the adopted lane's start, requests, frames and close, and an
// attempt that fails before it opens a socket. Its transport clock is frozen,
// so no idle refresh can add a request whose timing depends on the host.
pub fn a_scripted_session_records_the_golden_bytes_test() {
  let path = "build/recording-effects-scripted-session.jsonl"
  let recorded = scripted_session(path)
  let assert Ok(expected) = simplifile.read(golden)
    as "the golden recording is committed beside the replay fixtures"
  assert recorded == expected
  let assert Ok(_) = recording.decode_text(recorded)
    as "the session is one well-formed local format-two log"
  let assert Ok(Nil) = simplifile.delete(path)
    as "the generated recording is removed"
}

// A step decides its recording lines and writes none. The prompt's own key
// is the first effect, ahead of anything the reducer queued for it, and the
// lane notes the request it issued before the frame that carries it, so the
// recording can never hold a frame on the wire that it has no request for.
pub fn a_prompt_queues_its_input_then_its_request_then_its_frame_test() {
  let sink = process.new_subject()
  let recorder = recording.observed(sink)
  let model = captured_session(recorder)
  let model = tui.update(backend.Paste("one prompt"), model)
  let _ = drain(sink)

  let #(_, effects) = stepping.step(backend.KeyPress("enter"), model)
  let assert [first, ..] = effects as "the step decided something"
  assert first == effect.Record(recorder, recording.Key("enter"))
    as "the input's line is the first effect of its step"
  assert list.filter_map(effects, prompt_traffic)
    == ["input enter", "issued prompt", "sent prompt"]
  assert drain(sink) == [] as "the step itself recorded nothing"

  // Performing them is what writes the lines, in the same order.
  let _running = runtime.perform(effects, job_runner.new())
  let assert [recording.Key("enter"), ..rest] = drain(sink)
    as "the key is recorded first"
  let assert [recording.Attempt(attempt.Issued(_, request))] =
    list.filter(rest, fn(recorded) {
      case recorded {
        recording.Attempt(attempt.Issued(..)) -> True
        _ -> False
      }
    })
    as "one request was recorded, after the key"
  assert request.kind == "prompt"
}

// An adoption replaces the adopted lane in the middle of a step. The lane it
// retires queues its close and its recorded close as it is retired, and they
// go into the step's queue there, before the new lane is stored over it, so
// both survive the replacement and the retirement is noted before the
// adoption. Storing the retired lane without moving its outputs would lose
// its socket close and leave the recording without its `Closed`, which is
// the loss `release_channel` used to guard against one site at a time.
pub fn an_adoption_queues_the_retired_lanes_close_before_the_adoption_test() {
  let sink = process.new_subject()
  let recorder = recording.observed(sink)
  let model = captured_session(recorder)
  let assert Some(retired) = model.shared.channel
    as "premise: a lane is adopted"
  let assert Some(old_socket) = session_channel.socket(retired)
    as "premise: the adopted lane has a socket"

  // The test plays the replacement job's part: a published socket and one
  // complete transfer, then the worker's completion.
  let #(model, key) =
    playing_the_worker(model, recording.trace(Some(recorder), attempt.Id(2)))
  let captured = tui.update(backend.Tick, model)
  let captured =
    runtime.hold(
      captured,
      job.AttachArrived(key, job.Settled(weft.AllDelivered)),
    )
  let _ = drain(sink)

  let #(adopted, effects) =
    stepping.step(backend.Tick, runtime.receive(runtime.stamp(captured)))
  assert !attachment.busy(adopted.view.candidate) as "premise: the step adopted"
  assert list.filter_map(effects, lifecycle(_, old_socket))
    == ["closed 1", "shut old socket", "adopted 2"]
    as "the retired lane's close is queued before the adoption and kept"
}

// An attempt waiting for the attachment job `key` names, with that job's
// socket already published: a stand-in socket, and a frames subject this
// process owns carrying one complete transfer. The step creates no subject,
// so the test creates the frames subject the runtime would, and hands it
// over in the `Prepared` the way the worker does.
fn playing_the_worker(
  model: tui_model.Model,
  trace: Option(recording.Trace),
) -> #(tui_model.Model, job.Key) {
  let #(model, key) = tui_model.allocate_job(model)
  let frames = connection.new_inbox()
  list.each(pushed.transfer(1, "1:1", "recent", 10), process.send(frames, _))
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(model.view, attachment.opening(key, trace)),
    )
    |> runtime.hold(job.AttachArrived(key, job.Published(prepared_on(frames))))
  #(model, key)
}

fn prepared_on(frames: Subject(connection_event.Message)) -> job.Prepared {
  job.Prepared(
    socket: socket_on(process.new_subject()),
    expected: snapshot.Expected("A", "epoch", "incarnation"),
    workspace: workspace.Context("/w/demo", None),
    session_name: "Session A",
    creation_key: None,
    acknowledgement: process.new_subject(),
    frames:,
  )
}

// A replacement whose lane fails part way through a poll is discarded as it
// stood before that poll's advance: the credit and the close the failing
// advance decided are dropped, and `Abandon` closes the socket once. What
// the advance received is still recorded, ahead of the failure, because the
// recording has always held it.
pub fn a_failing_replacement_keeps_its_notes_and_drops_its_writes_test() {
  let sink = process.new_subject()
  let recorder = recording.observed(sink)
  let #(model, key) =
    tui_model.allocate_job(tui.new_model(
      connection.new_inbox(),
      workspace.Context(path: "/w/demo", branch: None),
    ))
  let frames = connection.new_inbox()
  let assert [begin, ..] = pushed.transfer(1, "1:1", "recent", 10)
    as "the transfer opens with its begin frame"
  process.send(frames, begin)
  process.send(frames, connection_event.Incoming("not a frame"))
  let model =
    tui_model.Model(
      ..model,
      view: view_set.candidate(
        model.view,
        attachment.opening(key, recording.trace(Some(recorder), attempt.Id(2))),
      ),
    )
    |> runtime.hold(job.AttachArrived(key, job.Published(prepared_on(frames))))

  let #(failed, effects) =
    stepping.step(backend.Tick, runtime.receive(runtime.stamp(model)))
  assert !attachment.busy(failed.view.candidate)
    as "premise: the attempt failed"

  // The lane's own close here and the abandon's second one below are a
  // known wart that predates recording as effects; fixing it changes this.
  assert list.filter_map(effects, attempt_traffic)
    == [
      "note started", "note issued subscribe", "write", "note received",
      "note issued snapshot_next", "note received", "note closed", "note failed",
      "abandon",
    ]
    as "the failing advance's notes are kept and its writes are not"

  // The abandon cancels the waiting worker and records the attempt's close.
  let _ = drain(sink)
  let _running = runtime.perform(effects, job_runner.new())
  assert list.contains(
    drain(sink),
    recording.Attempt(attempt.Closed(attempt.Id(2))),
  )
    as "the abandoned attempt's close is recorded when it is performed"
}

fn attempt_traffic(decided: effect.Effect) -> Result(String, Nil) {
  case decided {
    effect.Attachment(attachment.FromChannel(output)) ->
      case output {
        session_channel.Note(_, event) -> Ok("note " <> note_name(event))
        session_channel.Transmit(..) -> Ok("write")
        session_channel.Shut(..) -> Ok("shut")
      }
    effect.Attachment(attachment.Abandon(..)) -> Ok("abandon")
    _ -> Error(Nil)
  }
}

fn note_name(event: attempt.Event) -> String {
  case event {
    attempt.Started(..) -> "started"
    attempt.Issued(_, request) -> "issued " <> request.kind
    attempt.Received(..) -> "received"
    attempt.Adopted(..) -> "adopted"
    attempt.Closed(..) -> "closed"
    attempt.Failed(..) -> "failed"
  }
}

// The lane lifecycle effects of an adoption step, named in queue order.
fn lifecycle(
  decided: effect.Effect,
  old_socket: connection.Connection,
) -> Result(String, Nil) {
  case decided {
    effect.Step(step_effect.Lane(session_channel.Note(
      _,
      attempt.Closed(attempt.Id(id)),
    ))) -> Ok("closed " <> int.to_string(id))
    effect.Step(step_effect.Lane(session_channel.Note(
      _,
      attempt.Adopted(attempt.Id(id)),
    ))) -> Ok("adopted " <> int.to_string(id))
    effect.Step(step_effect.Lane(session_channel.Shut(socket)))
      if socket == old_socket
    -> Ok("shut old socket")
    _ -> Error(Nil)
  }
}

// A replay opens no recorder, and its lanes carry no trace, so replaying a
// whole recorded session through the shipped step queues no recording
// effect of any kind. This is the behaviour replay had before recording
// joined the effect stream, when both sources wrote nothing for the same
// two reasons.
pub fn replaying_a_recording_queues_no_recording_effect_test() {
  let assert Ok(moments) = recording.decode_file(golden)
    as "the golden recording decodes"
  let model = {
    let base =
      tui.new_model(
        connection.new_inbox(),
        workspace.Context(path: "replay", branch: None),
      )
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.peer(session_model.Replaying)
        |> shared_set.session("replay"),
    )
  }
  let steps = recording.to_steps(moments)
  let #(replayed, effects) =
    list.fold(steps, #(model, []), fn(acc, step) {
      let #(model, effects) = acc
      let #(model, decided) = replay_step(model, step)
      #(model, list.append(effects, decided))
    })

  // The premises that keep the check from passing on an empty run: every
  // recorded line was stepped without a replay error, the recorded quit was
  // reached, and the steps did decide effects, just none that record.
  assert list.length(steps) == list.length(moments) && steps != []
  assert replayed.shared.replay_error == None
    as "premise: the replay applied every attempt event"
  assert replayed.shared.quit as "premise: the replay reached the recorded quit"
  assert effects != [] as "premise: the replayed steps decided effects"
  assert list.filter(effects, records) == []
    as "a replay queues no recording line and no attempt note"
}

fn scripted_session(path: String) -> String {
  let assert Ok(recorder) = recording.start(path)
    as "the recording opens under the build directory"
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let inbox = connection.new_inbox()

  // The lane is started outside the loop, as the launch path does before the
  // first event, so what it decided is performed here.
  let #(channel, opened) =
    session_channel.start_recorded(
      socket,
      snapshot.Expected("A", "epoch", "incarnation"),
      recording.trace(Some(recorder), attempt.Id(1)),
      now: 0,
    )
    |> session_channel.take_outputs
  list.each(opened, terminal_lane.perform)
  let model = {
    let base =
      tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None))
    tui_model.Model(
      shared: base.shared
        |> shared_set.recorder(Some(recorder))
        |> shared_set.peer(session_model.Attached)
        |> shared_set.channel(Some(channel))
        |> shared_set.session("A"),
      view: base.view
        |> view_set.next_attempt(2)
        |> view_set.transport_time_ms(fn() { 0 }),
    )
  }

  // The initial capture: three credited frames, received on one tick.
  list.each(
    pushed.transfer_with_metadata(1, "1:1", "recent", 10, main_strand()),
    process.send(inbox, _),
  )
  let model = tui.update(backend.Tick, model)

  // Operator input, including a prompt the adopted lane sends.
  let model =
    list.fold(
      [
        backend.Resize(80, 24),
        backend.Paste("recorded prompt"),
        backend.KeyPress("enter"),
      ],
      model,
      fn(model, event) { tui.update(event, model) },
    )

  // The capture was followed by a notes read, so the prompt waited behind
  // it. The read's reply is what sends the prompt, on the same tick.
  process.send(inbox, notes_reply(4))
  let model = tui.update(backend.Tick, model)

  // A switch whose worker fails before it prepares a socket records only its
  // failure, and leaves the adopted lane in place. The worker is a real job,
  // started the way the runtime starts one, with a resolution that fails.
  let #(model, key) = tui_model.allocate_job(model)
  let model =
    tui_model.Model(
      ..model,
      view: model.view
        |> view_set.next_attempt(3)
        |> view_set.running(job_runner.start_attach(
          model.view.running,
          key,
          fn() { Error("no route to the selected session") },
          5000,
        ))
        |> view_set.candidate(attachment.opening(
          key,
          recording.trace(Some(recorder), attempt.Id(2)),
        )),
    )
  let model = tick_until_settled(model)
  let _ = tui.update(backend.KeyPress("ctrl+c"), model)

  let assert Ok(text) = simplifile.read(path)
    as "the recording is readable after the quit"
  text
  |> string.split("\n")
  |> list.map(without_offset)
  |> string.join("\n")
}

// A lane that has captured its first cut, with its one request slot free for
// a prompt. The frames are handed to the reducer directly rather than on a
// tick, so none of the reads a tick services goes out ahead of the prompt.
// Everything the lane recorded on the way is performed into `recorder`.
fn captured_session(recorder: recording.Recorder) {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let channel =
    session_channel.start_recorded(
      socket,
      snapshot.Expected("A", "epoch", "incarnation"),
      recording.trace(Some(recorder), attempt.Id(1)),
      now: 0,
    )
  let model =
    {
      let base =
        tui.new_model(
          connection.new_inbox(),
          workspace.Context(path: "/w/demo", branch: None),
        )
      tui_model.Model(
        shared: base.shared
          |> shared_set.recorder(Some(recorder))
          |> shared_set.peer(session_model.Attached)
          |> shared_set.session("A"),
        view: view_set.transport_time_ms(base.view, fn() { 0 }),
      )
    }
    |> tui_model.hold_channel(channel)
  let model =
    pushed.transfer_with_metadata(1, "1:1", "recent", 10, main_strand())
    |> list.fold(model, inbound.accept_connection_message)
    |> runtime.flush
  let assert Some(lane) = model.shared.channel as "the lane is still attached"
  assert session_channel.mutation_available(lane)
    && !session_channel.in_flight(lane)
    as "premise: the lane is synchronized with its request slot free"
  model
}

// One step of a replay, as the virtual backend drives it: an attempt event
// goes to the replay inbox and is applied on the next tick, and an input is
// stepped as it was recorded.
fn replay_step(model: tui_model.Model, step: virtual_backend.Step) {
  case step {
    virtual_backend.Attempt(event) -> {
      process.send(buffered.sender(model.shared.replay_inbox), event)
      stepping.step(backend.Tick, runtime.receive(model))
    }
    virtual_backend.Input(event) -> stepping.step(event, runtime.receive(model))
    virtual_backend.Deliver(message) -> {
      process.send(buffered.sender(model.shared.inbox), message)
      stepping.step(backend.Tick, runtime.receive(model))
    }
  }
}

fn records(decided: effect.Effect) -> Bool {
  case decided {
    effect.Record(..) -> True
    effect.Step(step_effect.Recorded(..)) -> True
    effect.Step(step_effect.Lane(session_channel.Note(..))) -> True
    effect.Attachment(attachment.FromChannel(session_channel.Note(..))) -> True
    _ -> False
  }
}

// The effects that carry the prompt, named in the order they were queued.
fn prompt_traffic(decided: effect.Effect) -> Result(String, Nil) {
  case decided {
    effect.Record(_, recording.Key(key)) -> Ok("input " <> key)
    effect.Step(step_effect.Lane(session_channel.Note(
      _,
      attempt.Issued(_, attempt.Request(kind: "prompt", ..)),
    ))) -> Ok("issued prompt")
    effect.Step(step_effect.Lane(session_channel.Transmit(_, frame))) ->
      case string.contains(frame, "\"prompt\"") {
        True -> Ok("sent prompt")
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn drain(sink: Subject(recording.Recorded)) -> List(recording.Recorded) {
  case process.receive(sink, 0) {
    Ok(recorded) -> [recorded, ..drain(sink)]
    Error(Nil) -> []
  }
}

// The capture's metadata names the `main` strand, so the prompt has a
// recipient the terminal knows.
fn main_strand() -> String {
  let assert Ok(json.Object(base)) = json.parse(pushed.metadata())
    as "the capture fixture is a metadata object"
  let cells = [
    cell(
      register.StrandConfig,
      codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("test", "test"),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, json.Null),
    cell(
      register.StrandState,
      codec.encode_strand_state(strand.StrandState(None, [])),
    ),
  ]
  json.to_string(
    json.Object([
      #("cells", json.Array(cells)),
      ..list.filter(base, fn(pair) { pair.0 != "cells" })
    ]),
  )
}

fn cell(namespace, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String("main")),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn notes_reply(request: Int) -> connection_event.Message {
  pushed.reply(
    request,
    "snapshot",
    json.Object([
      #("mode", json.String("notes")),
      #(
        "board",
        json.Object([
          #("strand", json.String("main")),
          #("as_of", json.Int(10)),
          #("total", json.Int(0)),
          #("notes", json.Array([])),
        ]),
      ),
    ]),
  )
}

// Ticks are never recorded, so how many it takes for the worker's failure to
// arrive changes nothing in the file.
fn tick_until_settled(model: tui_model.Model) -> tui_model.Model {
  let settled =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 2000,
      every: poll.Fixed(5),
      from: model,
      attempt: fn(model) {
        let model = tui.update(backend.Tick, model)
        case attachment.busy(model.view.candidate) {
          True -> poll.Pending(model)
          False -> poll.Settled(model)
        }
      },
    )
  let assert poll.Answer(model) = settled
    as "the failing worker settles within two seconds"
  model
}

// Every line opens with its offset, `{"at":N,`, and nothing else in it
// depends on when the session ran.
fn without_offset(line: String) -> String {
  case string.split_once(line, ",") {
    Ok(#(_, rest)) -> "{\"at\":0," <> rest
    Error(Nil) -> line
  }
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection
