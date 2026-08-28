import core/json
import gleam/list
import gleam/string
import mcp/stdio

// --- frame -------------------------------------------------------------------

pub fn frame_is_one_terminated_line_test() {
  assert stdio.frame(json.Object([#("a", json.Int(1))])) == "{\"a\":1}\n"
}

// A newline inside a string value must never reach the wire literally,
// or the peer would read two broken frames instead of one message.
pub fn frame_escapes_embedded_newlines_test() {
  let framed = stdio.frame(json.Object([#("a", json.String("x\ny"))]))
  assert framed == "{\"a\":\"x\\ny\"}\n"
  assert count_newlines(framed) == 1
}

pub fn frame_round_trips_through_push_test() {
  let message = json.Object([#("k", json.String("line one\nline two"))])
  let assert Ok(#(_, [line])) = stdio.push(stdio.new(), stdio.frame(message))
  assert json.parse(line) == Ok(message)
}

fn count_newlines(text: String) -> Int {
  list.length(string.split(text, "\n")) - 1
}

// --- push: line assembly -------------------------------------------------------

pub fn push_complete_line_test() {
  assert stdio.push(stdio.new(), "{\"a\":1}\n")
    == Ok(#(stdio.new(), ["{\"a\":1}"]))
}

pub fn push_split_across_pushes_test() {
  let assert Ok(#(buffer, [])) = stdio.push(stdio.new(), "{\"a\"")
  let assert Ok(#(buffer, [])) = stdio.push(buffer, ":1")
  assert stdio.push(buffer, "}\ntail") |> lines == ["{\"a\":1}"]
}

pub fn push_three_way_split_keeps_order_test() {
  let assert Ok(#(buffer, [])) = stdio.push(stdio.new(), "one")
  let assert Ok(#(buffer, first)) = stdio.push(buffer, " half\ntwo\nthr")
  assert first == ["one half", "two"]
  let assert Ok(#(_, second)) = stdio.push(buffer, "ee\n")
  assert second == ["three"]
}

pub fn push_multiple_lines_in_one_chunk_test() {
  assert stdio.push(stdio.new(), "a\nb\nc\n") |> lines == ["a", "b", "c"]
}

pub fn push_carriage_return_newline_is_trimmed_test() {
  assert stdio.push(stdio.new(), "a\r\nb\r\n") |> lines == ["a", "b"]
}

pub fn push_interior_carriage_return_survives_test() {
  assert stdio.push(stdio.new(), "a\rb\n") |> lines == ["a\rb"]
}

pub fn push_empty_lines_are_emitted_test() {
  // An empty line is a complete (malformed) message; the jsonrpc layer
  // owns refusing it, not the framing layer.
  assert stdio.push(stdio.new(), "\n\n") |> lines == ["", ""]
}

pub fn push_without_newline_buffers_test() {
  assert stdio.push(stdio.new(), "no newline yet") |> lines == []
}

pub fn push_empty_chunk_is_a_no_op_test() {
  assert stdio.push(stdio.new(), "") |> lines == []
}

fn lines(
  pushed: Result(#(stdio.Buffer, List(String)), stdio.FramingFault),
) -> List(String) {
  let assert Ok(#(_, lines)) = pushed
  lines
}

// --- push: the line cap ---------------------------------------------------------

pub fn push_oversized_unterminated_line_faults_test() {
  // Grown past the cap across pushes, never seeing a newline.
  let chunk = string.repeat("a", 8_388_609)
  let assert Ok(#(buffer, [])) = stdio.push(stdio.new(), chunk)
  let assert Error(stdio.LineTooLong(limit:, seen:)) = stdio.push(buffer, chunk)
  assert limit == stdio.max_line_bytes
  assert seen == 16_777_218
}

pub fn push_oversized_complete_line_faults_test() {
  // A terminated line past the cap in a single chunk is refused too:
  // the cap bounds what one peer message may cost, not just the buffer.
  let line = string.repeat("a", stdio.max_line_bytes + 1) <> "\n"
  let assert Error(stdio.LineTooLong(..)) = stdio.push(stdio.new(), line)
}

pub fn push_line_at_the_cap_passes_test() {
  let line = string.repeat("a", stdio.max_line_bytes)
  let assert Ok(#(_, [emitted])) = stdio.push(stdio.new(), line <> "\n")
  assert string.byte_size(emitted) == stdio.max_line_bytes
}

pub fn cap_counts_bytes_not_codepoints_test() {
  // "é" is one codepoint, two UTF-8 bytes; the cap is a byte bound.
  let assert Ok(#(buffer, [])) = stdio.push(stdio.new(), "é")
  let assert Ok(#(_, [line])) = stdio.push(buffer, "\n")
  assert string.byte_size(line) == 2
}
