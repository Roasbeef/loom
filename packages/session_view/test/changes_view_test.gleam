//// `changes_view.fold` turns a strand's records into the board of the edits
//// they carry. These tests build records holding `fs_edit` calls and results
//// and check what the board holds, what it counts, that a failed or diffless
//// edit adds nothing, that the bounds cut and say so, and that a markup-laden
//// diff stays text.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/changes_view.{Added, Context, Hunk, Removed}
import session_view/protocol

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn record(seq: Int, body: message.AgentMessage) -> protocol.EntryRecord {
  let parent = case seq {
    1 -> None
    _ -> Some(id(seq - 1))
  }

  protocol.EntryRecord(
    "main",
    entry.MessageEntry(id(seq), parent, seq, seq * 1000, body, False),
  )
}

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content,
    "test",
    "test",
    "test",
    None,
    None,
    None,
    usage(),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  )
}

fn call(call_id: String, name: String) -> message.AgentMessage {
  assistant([
    message.AssistantToolCall(message.ToolCall(
      call_id,
      name,
      json.Object([]),
      None,
      None,
    )),
  ])
}

fn result(
  call_id: String,
  name: String,
  details: Option(json.JsonValue),
  failed: Bool,
) -> message.AgentMessage {
  message.ToolResultMessage(
    call_id,
    name,
    [message.ToolResultText("ok", None)],
    details,
    None,
    None,
    failed,
    0,
  )
}

fn edit_details(path: String, diff: String) -> Option(json.JsonValue) {
  Some(
    json.Object([#("path", json.String(path)), #("diff", json.String(diff))]),
  )
}

// Records for a list of edits, newest first as a branch holds them: each edit
// is a call and its result, two records.
fn records(
  edits: List(#(String, Option(json.JsonValue), Bool)),
) -> List(protocol.EntryRecord) {
  edits
  |> list.index_map(fn(edit, index) {
    let call_id = "call-" <> int.to_string(index)
    let base = index * 2 + 1

    [
      record(base, call(call_id, "fs_edit")),
      record(base + 1, result(call_id, "fs_edit", edit.1, edit.2)),
    ]
  })
  |> list.flatten
  |> list.reverse
}

fn edited(
  path: String,
  diff: String,
) -> #(String, Option(json.JsonValue), Bool) {
  #(path, edit_details(path, diff), False)
}

const calc_diff =
  "@@ -1,3 +1,4 @@
 pub fn add(a: Int, b: Int) -> Int {
-  a - b
+  a + b
+  // plus
 }"

pub fn no_records_fold_to_the_empty_board_test() {
  assert changes_view.fold([]) == changes_view.empty()
}

pub fn an_edit_is_a_file_with_counts_and_kinded_rows_test() {
  let board = changes_view.fold(records([edited("src/calc.gleam", calc_diff)]))

  let assert [file] = board.files as "one file for one edit"
  assert file.path == "src/calc.gleam"
  assert #(file.added, file.removed) == #(2, 1)
  assert #(board.added, board.removed, board.file_count) == #(2, 1, 1)
  assert list.map(file.rows, fn(row) { row.kind })
    == [Hunk, Context, Removed, Added, Added, Context]
  assert changes_view.totals(board) == "1 file · +2 -1"
}

pub fn two_edits_of_one_path_are_one_file_in_order_test() {
  let board =
    changes_view.fold(
      records([
        edited("a.gleam", "@@ -1 +1 @@\n-one\n+two"),
        edited("b.gleam", "@@ -1 +1 @@\n-x\n+y"),
        edited("a.gleam", "@@ -5 +5 @@\n-three\n+four"),
      ]),
    )

  assert list.map(board.files, fn(file) { file.path }) == ["a.gleam", "b.gleam"]
  let assert [first, _] = board.files as "two files"
  assert #(first.added, first.removed) == #(2, 2)
  assert list.map(first.rows, fn(row) { row.text })
    == ["@@ -1 +1 @@", "-one", "+two", "@@ -5 +5 @@", "-three", "+four"]
}

pub fn a_failed_edit_and_a_diffless_result_add_nothing_test() {
  let board =
    changes_view.fold(
      records([
        #("bad.gleam", edit_details("bad.gleam", "@@ -1 +1 @@\n-a\n+b"), True),
        #(
          "old.gleam",
          Some(json.Object([#("path", json.String("old.gleam"))])),
          False,
        ),
        #("none.gleam", None, False),
      ]),
    )

  assert board == changes_view.empty()
}

pub fn a_call_with_no_result_in_the_window_adds_nothing_test() {
  let only_call = [record(1, call("orphan", "fs_edit"))]

  assert changes_view.fold(only_call) == changes_view.empty()
}

pub fn another_tool_with_a_diff_field_adds_nothing_test() {
  let other = [
    record(1, call("c", "fs_write")),
    record(2, result("c", "fs_write", edit_details("w.gleam", "+a"), False)),
  ]

  assert changes_view.fold(other) == changes_view.empty()
}

pub fn markup_in_a_diff_stays_text_and_a_hostile_kind_is_impossible_test() {
  let board =
    changes_view.fold(
      records([
        edited(
          "<img src=x onerror=alert(1)>.html",
          "@@ -1 +1 @@\n-<script>old</script>\n+<b onclick=\"x()\">new</b>\n+++ not a header",
        ),
      ]),
    )

  let assert [file] = board.files as "one file"
  assert file.path == "<img src=x onerror=alert(1)>.html"
  assert list.map(file.rows, fn(row) { row.text })
    == [
      "@@ -1 +1 @@",
      "-<script>old</script>",
      "+<b onclick=\"x()\">new</b>",
      "+++ not a header",
    ]
  // A line that begins with three plus signs is an added line, not a header.
  assert list.map(file.rows, fn(row) { row.kind })
    == [Hunk, Removed, Added, Added]
}

pub fn control_characters_are_stripped_from_rows_and_paths_test() {
  let board =
    changes_view.fold(
      records([edited("a\u{1b}[31mb.txt", "@@ -1 +1 @@\n+red\u{1b}[0m")]),
    )

  let assert [file] = board.files as "one file"
  assert !string.contains(file.path, "\u{1b}")
  assert list.all(file.rows, fn(row) { !string.contains(row.text, "\u{1b}") })
}

pub fn a_long_row_and_a_long_path_are_cut_test() {
  let long = string.repeat("x", 1000)
  let board =
    changes_view.fold(
      records([edited(long <> ".gleam", "@@ -1 +1 @@\n+" <> long)]),
    )

  let assert [file] = board.files as "one file"
  assert string.length(file.path) == changes_view.max_path_characters
  assert string.starts_with(file.path, "…")
  let assert [_, added] = file.rows as "a header and an added row"
  assert string.length(added.text) == changes_view.max_row_characters
  assert string.ends_with(added.text, "…")
}

pub fn a_row_of_combining_marks_is_bounded_in_bytes_test() {
  // One base character and a thousand combining marks is one grapheme, so
  // only a code point cut bounds the row's bytes.
  let marks = string.repeat("\u{0301}", 1000)
  let board =
    changes_view.fold(records([edited("m.txt", "@@ -1 +1 @@\n+a" <> marks)]))

  let assert [file] = board.files as "one file"
  let assert [_, row] = file.rows as "a header and a row"
  assert string.byte_size(row.text) <= 4 * changes_view.max_row_characters
}

pub fn a_file_holds_at_most_its_rows_and_counts_the_rest_test() {
  let lines = list.repeat("+line", 500) |> string.join("\n")
  let board = changes_view.fold(records([edited("big.txt", lines)]))

  let assert [file] = board.files as "one file"
  assert list.length(file.rows) == changes_view.max_file_rows
  assert file.cut == 300
  // The counts report every line, whatever the board held.
  assert file.added == 500
  assert board.added == 500
}

pub fn the_board_holds_at_most_its_rows_across_files_test() {
  let lines = list.repeat("+line", 200) |> string.join("\n")
  let edits =
    list.repeat(Nil, 5)
    |> list.index_map(fn(_, index) {
      edited("f" <> int.to_string(index) <> ".txt", lines)
    })
  let board = changes_view.fold(records(edits))

  let held =
    list.fold(board.files, 0, fn(total, file) { total + list.length(file.rows) })
  assert held == changes_view.max_rows
  assert board.added == 1000
  let assert [_, _, _, fourth, fifth] = board.files as "five files"
  assert fourth.rows == []
  assert #(fourth.cut, fifth.cut) == #(200, 200)
}

pub fn the_board_holds_at_most_its_files_and_counts_them_all_test() {
  let edits =
    list.repeat(Nil, 40)
    |> list.index_map(fn(_, index) {
      edited("f" <> int.to_string(index) <> ".txt", "@@ -1 +1 @@\n+a")
    })
  let board = changes_view.fold(records(edits))

  assert list.length(board.files) == changes_view.max_files
  assert board.file_count == 40
  assert board.added == 40
}
