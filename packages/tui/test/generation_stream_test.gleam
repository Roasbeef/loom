//// Provider attempts share an operation but never share a live answer.
//// These fixtures enter through actual v2 frames and the adopted channel.

import core/clock
import core/ids
import core/json
import core/register
import etui/backend
import etui/geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import tui
import tui/frame
import tui/session_channel
import tui/snapshot
import tui_test/pushed

fn delta(generation, kind, text) {
  delta_for("operation", generation, kind, text)
}

fn delta_for(operation, generation, kind, text) {
  pushed.push([
    #("event", json.String("stream_delta")),
    #(
      "body",
      json.Object([
        #("strand", json.String("main")),
        #("op", json.String(operation)),
        #("generation", json.String(generation)),
        #("kind", json.String(kind)),
        #("text", json.String(text)),
      ]),
    ),
  ])
}

pub fn a_new_request_replaces_every_kind_of_the_previous_answer_test() {
  let first =
    pushed.attached()
    |> tui.accept_connection_message(delta(
      "request-1",
      "thinking",
      "old thought",
    ))
    |> tui.accept_connection_message(delta("request-1", "text", "old answer"))
    |> tui.accept_connection_message(delta("request-2", "text", "new answer"))
  assert list.map(first.streams, fn(stream) { stream.fragments })
    == [["new answer"]]
    as "a tool round or retry starts a new answer within the same operation"
}

pub fn a_late_terminal_cannot_remove_a_newer_answer_test() {
  let first =
    pushed.attached()
    |> tui.accept_connection_message(delta("request-1", "text", "old answer"))
    |> tui.accept_connection_message(delta("request-2", "text", "new answer"))
    |> tui.accept_connection_message(delta("request-1", "end", ""))
  assert list.map(first.streams, fn(stream) { stream.fragments })
    == [["new answer"]]
    as "completion owns only its original request"
  let ended =
    first |> tui.accept_connection_message(delta("request-2", "end", ""))
  assert list.map(ended.streams, fn(stream) { stream.fragments }) == [[]]
    as "completion retains only an empty identity marker against late previews"
}

// This transfer was captured before the new request began. Its lack of a live
// operation is old metadata, not authority to erase a newer pushed answer.
pub fn a_late_credited_idle_cut_preserves_a_new_request_test() {
  let first =
    pushed.attached()
    |> tui.accept_connection_message(delta("request-2", "text", "new answer"))
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(_, after) =
    list.fold(
      pushed.transfer(1, "1:1", "recent", 10),
      #(channel, first),
      fn(acc, incoming) {
        let #(channel, changes) = session_channel.receive(acc.0, incoming)
        #(channel, list.fold(changes, acc.1, tui.apply_channel_update))
      },
    )
  assert list.map(after.streams, fn(stream) { stream.fragments })
    == [["new answer"]]
    as "snapshot credit and end validation must not erase a later request"
}

fn cell(namespace, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String("main")),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn metadata(current, last, preview) {
  let assert Ok(json.Object(base)) = json.parse(pushed.metadata())
    as "the fixture contains metadata"
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
      codec.encode_strand_state(strand.StrandState(current, [])),
    ),
  ]
  let cells = case current {
    None -> cells
    Some(id) -> [
      json.Object([
        #("namespace", json.String(register.ns_to_string(register.OpState))),
        #("key", json.String(ids.op_id_to_string(id))),
        #("seq", json.Int(1)),
        #(
          "value",
          codec.encode_state(operation.CompactionState(
            operation.Running,
            None,
            operation.Deciding("fixture"),
          )),
        ),
      ]),
      ..cells
    ]
  }
  let cells = case last {
    None -> cells
    Some(id) -> [
      cell(
        register.StrandLastResult,
        codec.encode_last_result(operation.RunLastResult(
          id,
          None,
          operation.RunAborted,
          None,
        )),
      ),
      ..cells
    ]
  }
  json.to_string(
    json.Object([
      #("cells", json.Array(cells)),
      #("stream_preview", preview),
      ..list.filter(base, fn(pair) { pair.0 != "cells" })
    ]),
  )
}

fn captured(model, metadata) {
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(_, model) =
    list.fold(
      pushed.transfer_with_metadata(1, "1:1", "recent", 10, metadata),
      #(channel, model),
      fn(acc, incoming) {
        let #(channel, changes) = session_channel.receive(acc.0, incoming)
        #(channel, list.fold(changes, acc.1, tui.apply_channel_update))
      },
    )
  model
}

fn rendered(model) {
  let painted = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = tui.view(painted, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

pub fn a_newer_request_end_never_resurrects_an_older_captured_preview_test() {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(1000), 1))
  let id = ids.op_id_to_string(op)
  let preview =
    json.Object([
      #("revision", json.Int(1)),
      #("operation", json.String(id)),
      #("discontinuous", json.Bool(True)),
      #("generation", json.String("request-A")),
      #("kind", json.String("text")),
      #("text", json.String("obsolete-preview")),
    ])
  let data = metadata(Some(op), None, preview)
  let first = captured(pushed.attached(), data)
  assert string.contains(rendered(first), "obsolete-preview") as rendered(first)
  let ended =
    first
    |> tui.accept_connection_message(delta_for(
      id,
      "request-B",
      "text",
      "new-answer",
    ))
    |> tui.accept_connection_message(delta_for(id, "request-B", "end", ""))
  assert !string.contains(rendered(ended), "obsolete-preview")
    as "ending B cannot reveal A from the prior cut"
  assert !string.contains(rendered(captured(ended, data)), "obsolete-preview")
    as "a credited late cut cannot resurrect A either"
}

pub fn exact_durable_retirement_clears_a_request_without_an_end_push_test() {
  let #(op, generator) = ids.mint_op(ids.generator(clock.fixed(1000), 1))
  let #(other, _) = ids.mint_op(generator)
  let first =
    pushed.attached()
    |> tui.accept_connection_message(delta_for(
      ids.op_id_to_string(op),
      "request",
      "text",
      "live-fragment",
    ))
  let absent = captured(first, metadata(None, None, json.Null))
  assert list.length(absent.streams) == 1
    as "idle alone could be a cut from before this request"
  let unrelated = captured(first, metadata(None, Some(other), json.Null))
  assert list.length(unrelated.streams) == 1
    as "another operation's result cannot retire this request"
  let retired = captured(first, metadata(None, Some(op), json.Null))
  assert retired.streams == []
    as "the exact result closes a relay failure which omitted its end push"
  assert !string.contains(rendered(retired), "live-fragment")
}
