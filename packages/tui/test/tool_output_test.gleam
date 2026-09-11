//// What the terminal keeps of a running command's output, and how it
//// draws it (`protocol-change/030`).
////
//// A `tool_output` frame is a snapshot of one stream's window and not a
//// fragment of it, so the properties worth pinning are the ones that
//// differ from a provider delta: a later frame for the same stream
//// replaces the earlier one instead of joining it, two streams of one
//// call and two calls of one step are kept apart, and the transcript
//// draws the tail as one result line under the running call. The frames
//// enter as real wire text through the adopted channel, as every pushed
//// fixture here does.

import core/json
import gleam/int
import gleam/list
import gleam/string
import tui
import tui/connection
import tui_test/pushed

fn output(
  operation: String,
  step: String,
  stream: String,
  text: String,
  total_bytes: Int,
) -> connection.Message {
  pushed.push([
    #("event", json.String("tool_output")),
    #(
      "body",
      json.Object([
        #("strand", json.String("main")),
        #("op", json.String(operation)),
        #("step", json.String(step)),
        #("ephemeral", json.Bool(True)),
        #("stream", json.String(stream)),
        #("tail", json.String(text)),
        #("total_bytes", json.Int(total_bytes)),
      ]),
    ),
  ])
}

pub fn a_later_frame_replaces_the_tail_of_its_stream_test() {
  let model =
    pushed.attached()
    |> tui.accept_connection_message(output(
      "op-1",
      "step-1",
      "stdout",
      "compiling core\n",
      15,
    ))
    |> tui.accept_connection_message(output(
      "op-1",
      "step-1",
      "stdout",
      "compiling core\ncompiling tools\n",
      31,
    ))
  assert model.tool_tails
    == [
      tui.ToolTail(
        strand: "main",
        operation: "op-1",
        step: "step-1",
        stream: "stdout",
        text: "compiling core\ncompiling tools\n",
        total_bytes: 31,
      ),
    ]
    as "the frame carries the whole window, so the newest one is the only one kept"
}

pub fn streams_and_steps_are_kept_apart_test() {
  let model =
    pushed.attached()
    |> tui.accept_connection_message(output("op-1", "step-1", "stdout", "a", 1))
    |> tui.accept_connection_message(output("op-1", "step-1", "stderr", "b", 1))
    |> tui.accept_connection_message(output("op-1", "step-2", "stdout", "c", 1))
    |> tui.accept_connection_message(output("op-1", "step-1", "stdout", "ab", 2))
  assert list.map(model.tool_tails, fn(tail) {
      #(tail.step, tail.stream, tail.text)
    })
    == [
      #("step-1", "stdout", "ab"),
      #("step-1", "stderr", "b"),
      #("step-2", "stdout", "c"),
    ]
    as "one tail per stream per call, in first-seen order, replaced in place"
}

pub fn the_tail_is_drawn_as_one_result_line_under_the_running_call_test() {
  let model =
    pushed.attached()
    |> tui.accept_connection_message(output(
      "op-1",
      "step-1",
      "stdout",
      "compiling core\ncompiling tools\n",
      31,
    ))
  assert tui.tool_tail_lines(model)
    == [
      tui.Line(
        tui.ToolResult,
        "stdout · 31 B so far\ncompiling core\ncompiling tools",
      ),
    ]
}

pub fn only_the_last_lines_of_a_long_tail_are_drawn_test() {
  let lines =
    list.repeat(Nil, 20)
    |> list.index_map(fn(_nil, index) { "line " <> int.to_string(index + 1) })
  let model =
    pushed.attached()
    |> tui.accept_connection_message(output(
      "op-1",
      "step-1",
      "stdout",
      list.fold(lines, "", fn(acc, line) { acc <> line <> "\n" }),
      2048,
    ))
  let assert [tui.Line(tui.ToolResult, drawn)] = tui.tool_tail_lines(model)
  let assert ["stdout · 2 KiB so far", first, ..rest] =
    string.split(drawn, "\n")
  assert first == "line 13"
  assert list.length(rest) == tui.tail_lines_shown - 1
}

pub fn a_binary_tail_draws_its_heading_alone_test() {
  let model =
    pushed.attached()
    |> tui.accept_connection_message(output("op-1", "step-1", "stdout", "", 300))
  assert tui.tool_tail_lines(model)
    == [tui.Line(tui.ToolResult, "stdout · 300 B so far")]
}

pub fn another_strands_tail_is_not_drawn_here_test() {
  let model =
    pushed.attached()
    |> tui.accept_connection_message(
      pushed.push([
        #("event", json.String("tool_output")),
        #(
          "body",
          json.Object([
            #("strand", json.String("sub:1")),
            #("op", json.String("op-9")),
            #("step", json.String("step-1")),
            #("stream", json.String("stdout")),
            #("tail", json.String("elsewhere")),
            #("total_bytes", json.Int(9)),
          ]),
        ),
      ]),
    )
  assert list.length(model.tool_tails) == 1
  assert tui.tool_tail_lines(model) == []
}
