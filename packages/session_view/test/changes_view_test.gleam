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

// The fold keys on the path an edit names and filters nothing by its
// segments, so a workspace under a hidden directory (a `.claude/worktrees/`
// checkout) lists its edits like any other. A session whose Changes tab is
// empty has therefore had no `fs_edit` or `fs_write` in the records the page
// holds, not an edit the fold dropped.
pub fn an_edit_under_a_hidden_directory_is_listed_test() {
  let path = "/home/u/proj/.claude/worktrees/wt-1/.config/calc.gleam"
  let board = changes_view.fold(records([edited(path, calc_diff)]))

  let assert [file] = board.files as "the edit is a file"
  assert file.path == path
  assert #(file.added, file.removed) == #(2, 1)
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
    record(1, call("c", "bash")),
    record(2, result("c", "bash", edit_details("w.gleam", "+a"), False)),
  ]

  assert changes_view.fold(other) == changes_view.empty()
}

// --- fs_write -----------------------------------------------------------------

fn write_call(call_id: String, path: String, content: String) {
  assistant([
    message.AssistantToolCall(message.ToolCall(
      call_id,
      "fs_write",
      json.Object([
        #("path", json.String(path)),
        #("content", json.String(content)),
      ]),
      None,
      None,
    )),
  ])
}

fn write_details(path: String) -> Option(json.JsonValue) {
  Some(json.Object([#("path", json.String(path)), #("bytes", json.Int(9))]))
}

// A write's records, newest first as a branch holds them, the call at
// sequence `first` and its result after it.
fn written_from(
  first: Int,
  path: String,
  content: String,
  failed: Bool,
) -> List(protocol.EntryRecord) {
  let call_id = "w" <> int.to_string(first)

  [
    record(first + 1, result(call_id, "fs_write", write_details(path), failed)),
    record(first, write_call(call_id, path, content)),
  ]
}

fn written(
  path: String,
  content: String,
  failed: Bool,
) -> List(protocol.EntryRecord) {
  written_from(1, path, content, failed)
}

pub fn a_write_is_a_file_whose_lines_are_all_added_test() {
  let board = changes_view.fold(written("calc.py", "a = 1\nb = 2\n", False))

  let assert [file] = board.files as "one file for one write"
  assert file.path == "calc.py"
  assert file.origin == changes_view.Written
  assert #(file.added, file.removed) == #(2, 0)

  // The write is one new-file hunk, so the drawer numbers its lines and tints
  // them as it does an edit's.
  assert list.map(file.rows, fn(row) { row.kind }) == [Hunk, Added, Added]
  assert list.map(file.rows, fn(row) { row.text })
    == ["@@ -0,0 +1,2 @@", "+a = 1", "+b = 2"]
  assert changes_view.counts_words(file) == "written · 2 lines"
  assert changes_view.totals(board) == "1 file · +2 -0"
}

pub fn a_one_line_write_is_singular_test() {
  let assert [file] = changes_view.fold(written("a", "x", False)).files
  assert changes_view.counts_words(file) == "written · 1 line"
}

pub fn a_failed_write_and_a_write_with_no_content_add_nothing_test() {
  assert changes_view.fold(written("a.py", "x = 1", True))
    == changes_view.empty()

  let no_content = [
    record(2, result("w", "fs_write", write_details("a.py"), False)),
    record(1, call("w", "fs_write")),
  ]
  assert changes_view.fold(no_content) == changes_view.empty()
}

// A file the session edited and later wrote is one file, listed as edited:
// its counts are the sum of a real hunk and a whole write.
pub fn a_file_that_was_edited_and_written_counts_as_edited_test() {
  let board =
    changes_view.fold(list.append(
      written_from(3, "a.py", "x\ny", False),
      records([edited("a.py", "@@ -1 +1 @@\n-one\n+two")]),
    ))

  let assert [file] = board.files as "one file"
  assert file.origin == changes_view.Edited
  assert #(file.added, file.removed) == #(3, 1)
  assert changes_view.counts_words(file) == "+3 -1"
}

// A write's text is a file's, so it can hold anything: it stays one text row
// per line, with its markup intact and never interpreted, and the file's row
// bound cuts it and says so.
pub fn a_writes_markup_stays_text_and_its_rows_are_bounded_test() {
  let assert [file] =
    changes_view.fold(written("p.html", "<script>alert(1)</script>", False)).files
  assert list.map(file.rows, fn(row) { row.text })
    == ["@@ -0,0 +1,1 @@", "+<script>alert(1)</script>"]

  let long =
    string.join(list.repeat("line", changes_view.max_file_rows + 5), "\n")
  let assert [big] = changes_view.fold(written("big.txt", long, False)).files
  assert list.length(big.rows) == changes_view.max_file_rows

  // The hunk header is a row of its own, so six rows are left out.
  assert big.cut == 6
  assert big.added == changes_view.max_file_rows + 5
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

// --- calls beside prose -------------------------------------------------------

// A call message that also carries a sentence of text, the shape real models
// write.
fn with_text(
  call_id: String,
  name: String,
  arguments: json.JsonValue,
) -> message.AgentMessage {
  assistant([
    message.AssistantText("Applying it now.", None),
    message.AssistantToolCall(message.ToolCall(
      call_id,
      name,
      arguments,
      None,
      None,
    )),
  ])
}

pub fn an_edit_in_a_message_with_text_is_a_file_test() {
  let records = [
    record(
      2,
      result("c0", "fs_edit", edit_details("calc.py", calc_diff), False),
    ),
    record(1, with_text("c0", "fs_edit", json.Object([]))),
  ]

  let assert [file] = changes_view.fold(records).files as "the edited file"
  assert file.path == "calc.py"
}

pub fn a_write_in_a_message_with_text_is_a_file_test() {
  let records = [
    record(2, result("w1", "fs_write", write_details("calc.py"), False)),
    record(
      1,
      with_text(
        "w1",
        "fs_write",
        json.Object([
          #("path", json.String("calc.py")),
          #("content", json.String("a = 1\n")),
        ]),
      ),
    ),
  ]

  let assert [file] = changes_view.fold(records).files as "the written file"
  assert file.origin == changes_view.Written
}

// A host that closes each settled turn folds the turn's records once and joins
// the boards when it draws, and the board it draws is the one a fold of every
// record would give: files in the order they were first edited, a path both
// stretches name as one file with the later rows after the earlier ones, and
// the counts added.
pub fn joining_two_stretches_is_folding_them_together_test() {
  let first = [
    #("a.gleam", edit_details("a.gleam", "@@ -1 +1 @@\n-a\n+b"), False),
    #("b.gleam", edit_details("b.gleam", "@@ -1 +1,2 @@\n-x\n+y\n+z"), False),
  ]
  let second = [
    #("b.gleam", edit_details("b.gleam", "@@ -4 +4 @@\n-p\n+q"), False),
    #("c.gleam", edit_details("c.gleam", "@@ -1 +0,0 @@\n-gone"), False),
  ]
  let joined =
    changes_view.append(
      changes_view.fold(records(first)),
      changes_view.fold(records(second)),
    )
  assert joined == changes_view.fold(records(list.append(first, second)))
  assert joined.file_count == 3
  assert joined.added == 4
  assert joined.removed == 4
}

// Joining with nothing changes nothing, whichever side holds it.
pub fn joining_with_an_empty_board_changes_nothing_test() {
  let board =
    changes_view.fold(
      records([
        #("a.gleam", edit_details("a.gleam", "@@ -1 +1 @@\n-a\n+b"), False),
      ]),
    )
  assert changes_view.append(changes_view.empty(), board) == board
  assert changes_view.append(board, changes_view.empty()) == board
}

// The joined board holds no more than a folded one does, and says how much it
// left out: a file past the bound is counted and not listed.
pub fn a_joined_board_keeps_the_bounds_test() {
  let many = fn(from: Int, count: Int) {
    int.range(from: from + count - 1, to: from - 1, with: [], run: fn(all, n) {
      [n, ..all]
    })
    |> list.map(fn(index) {
      let path = "f" <> int.to_string(index) <> ".gleam"
      #(path, edit_details(path, "@@ -1 +1 @@\n-a\n+b"), False)
    })
  }
  let joined =
    changes_view.append(
      changes_view.fold(records(many(0, 20))),
      changes_view.fold(records(many(20, 20))),
    )
  assert list.length(joined.files) == changes_view.max_files
  assert joined.file_count == 40
}
