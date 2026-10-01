//// How a `code_mode` result draws once it carries the host's call record
//// (protocol change 060), and that one without a readable record draws
//// exactly as it did before the record existed.
////
//// The old-result cases are goldens written out in full: a change to what
//// a result with no record shows, collapsed or expanded, success or
//// failure, fails them. The new cases pin the summary beside the status,
//// the expanded rows, the closing row for calls that were counted and not
//// itemised, and that an error result with a record shows it.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/block_summary
import session_view/transcript_line.{
  type Line, Line, System, ToolDetail, ToolFailure, ToolResult,
}
import session_view/transcript_lines

fn result_entry(
  text: String,
  details: json.JsonValue,
  is_error is_error: Bool,
) -> entry.Entry {
  let id = ids.mint_entry(ids.generator(clock.fixed(1000), 1)).0
  entry.MessageEntry(
    id,
    None,
    1,
    1000,
    message.ToolResultMessage(
      "c",
      "code_mode",
      [message.ToolResultText(text, None)],
      Some(details),
      None,
      None,
      is_error,
      1000,
    ),
    False,
  )
}

fn lines(
  details: json.JsonValue,
  expanded expanded: Bool,
  is_error is_error: Bool,
) -> List(Line) {
  transcript_lines.entry_lines(
    result_entry("the text", details, is_error:),
    expanded,
    None,
    block_summary.new(),
  )
}

fn sandbox() -> json.JsonValue {
  json.Object([
    #(
      "build",
      json.Object([
        #("reported", json.Bool(True)),
        #("enforced", json.Array([json.String("a"), json.String("b")])),
        #("skipped", json.Array([])),
      ]),
    ),
    #("node", json.Object([#("reported", json.Bool(False))])),
  ])
}

// The details an old `code_mode` success carried.
fn old_success() -> List(#(String, json.JsonValue)) {
  [
    #("status", json.String("completed")),
    #("value", json.String("done")),
    #("manifest_hash", json.String("sha256-x")),
    #("sandbox", sandbox()),
  ]
}

// The details an old `run_failed` result carried.
fn old_failure() -> List(#(String, json.JsonValue)) {
  [
    #("status", json.String("run_failed")),
    #("kind", json.String("deadline_exceeded")),
    #("detail", json.String("the wall deadline passed")),
    #("sandbox", sandbox()),
  ]
}

const sandbox_line =
  "sandbox · build enforced 2 layers; skipped 0 · satellite not launched"

fn record() -> json.JsonValue {
  let assert Ok(calls) =
    json.parse(
      "{\"started_unix_ms\":1,\"elapsed_ms\":90,\"total\":3,\"failed\":1,\"cancelled\":0,\"unsettled\":0,\"items\":[{\"cap\":\"fs.read\",\"args\":\"a.txt\",\"status\":\"ok\",\"start_ms\":1,\"duration_ms\":2},{\"cap\":\"proc.run\",\"args\":\"gleam +2 args\",\"status\":\"failed\",\"error\":\"exec_failed\",\"start_ms\":5,\"duration_ms\":80}]}",
    )
    as "the fixture is well-formed JSON"
  calls
}

pub fn an_old_success_collapses_exactly_as_before_test() {
  assert lines(json.Object(old_success()), expanded: False, is_error: False)
    == [
      Line(
        ToolResult,
        "code_mode · completed · result \"done\" · " <> sandbox_line,
      ),
    ]
}

pub fn an_old_success_expands_exactly_as_before_test() {
  assert lines(json.Object(old_success()), expanded: True, is_error: False)
    == [
      Line(ToolResult, "code_mode · completed"),
      Line(ToolDetail, "result\n\n```json\n\"done\"\n```"),
      Line(System, sandbox_line),
    ]
}

pub fn an_old_error_result_renders_exactly_as_before_test() {
  let expected = [Line(ToolFailure, "code_mode\nthe text")]
  assert lines(json.Object(old_failure()), expanded: False, is_error: True)
    == expected
  assert lines(json.Object(old_failure()), expanded: True, is_error: True)
    == expected
}

pub fn a_malformed_record_renders_as_no_record_test() {
  let broken = json.Object([#("calls", json.String("not a record"))])
  let details = json.Object(list.append(old_success(), [#("calls", broken)]))
  assert lines(details, expanded: False, is_error: False)
    == lines(json.Object(old_success()), expanded: False, is_error: False)
  let failure = json.Object(list.append(old_failure(), [#("calls", broken)]))
  assert lines(failure, expanded: True, is_error: True)
    == lines(json.Object(old_failure()), expanded: True, is_error: True)
}

pub fn a_success_with_a_record_shows_the_summary_beside_the_status_test() {
  let details = json.Object(list.append(old_success(), [#("calls", record())]))
  assert lines(details, expanded: False, is_error: False)
    == [
      Line(
        ToolResult,
        "code_mode · completed · 3 calls · 1 failed · result \"done\" · "
          <> sandbox_line,
      ),
    ]
}

pub fn an_expanded_success_lists_each_call_and_the_ones_not_itemised_test() {
  let details = json.Object(list.append(old_success(), [#("calls", record())]))
  assert lines(details, expanded: True, is_error: False)
    == [
      Line(ToolResult, "code_mode · completed · 3 calls · 1 failed"),
      Line(ToolDetail, "result\n\n```json\n\"done\"\n```"),
      Line(
        ToolDetail,
        "calls\n\n```text\n"
          <> "fs.read a.txt · ok · +1ms, 2ms\n"
          <> "proc.run gleam +2 args · failed exec_failed · +5ms, 80ms\n"
          <> "… 1 more calls not itemised\n```",
      ),
      Line(System, sandbox_line),
    ]
}

pub fn an_error_result_with_a_record_shows_it_test() {
  let details = json.Object(list.append(old_failure(), [#("calls", record())]))
  assert lines(details, expanded: False, is_error: True)
    == [
      Line(ToolFailure, "code_mode\nthe text"),
      Line(ToolResult, "code_mode · 3 calls · 1 failed"),
    ]
  let expanded = lines(details, expanded: True, is_error: True)
  assert list.length(expanded) == 3
  let assert [_, _, Line(ToolDetail, rows)] = expanded
  assert string.contains(rows, "proc.run gleam +2 args · failed exec_failed")
}
