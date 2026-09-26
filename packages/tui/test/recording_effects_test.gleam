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
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/strand
import simplifile
import tui
import tui/attachment
import tui/attempt
import tui/connection
import tui/model as tui_model
import tui/recording
import tui/session_channel
import tui/snapshot
import tui/workspace
import tui_test/pushed
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
  list.each(opened, session_channel.perform)
  let model =
    tui_model.Model(
      ..tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None)),
      recorder: Some(recorder),
      peer: tui_model.Attached(socket),
      channel: Some(channel),
      session: "A",
      next_attempt: 2,
      transport_time_ms: fn() { 0 },
    )

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
  // failure, and leaves the adopted lane in place.
  let model =
    tui_model.Model(
      ..model,
      next_attempt: 3,
      candidate: attachment.start_recorded(
        fn() { Error("no route to the selected session") },
        5000,
        recording.trace(Some(recorder), attempt.Id(2)),
      ),
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

fn notes_reply(request: Int) -> connection.Message {
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
        case attachment.busy(model.candidate) {
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
