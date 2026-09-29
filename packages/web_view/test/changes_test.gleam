//// The Changes section: the files the session's own edits touched and the
//// diff each reported, drawn on both pages from the records the page holds.
////
//// The first group draws `view/changes` from a board, which is the module's
//// whole contract: the summary, the first file open, the rows' classes, the
//// cut lines, and every string arriving as escaped text. The second drives
//// the pages through a capture holding `fs_edit` results and reads the HTML
//// the browser would receive, so the section's place below the transcript is
//// pinned on the operator's page and the observer's, and so is its size.

import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/changes_view
import web_view/component
import web_view/operator_page
import web_view/view/changes

fn drawn(board: changes_view.Board) -> String {
  element.to_string(changes.view(board))
}

fn row(kind: changes_view.Kind, text: String) -> changes_view.Row {
  changes_view.Row(kind, text)
}

fn file(path: String, rows: List(changes_view.Row)) -> changes_view.File {
  changes_view.File(path:, added: 1, removed: 1, rows:, cut: 0)
}

fn board(files: List(changes_view.File)) -> changes_view.Board {
  changes_view.Board(
    files:,
    file_count: list.length(files),
    added: 14,
    removed: 2,
  )
}

pub fn no_edits_draw_nothing_test() {
  assert !string.contains(drawn(changes_view.empty()), "changes")
}

pub fn the_summary_names_the_files_and_the_totals_test() {
  let html = drawn(board([file("a.gleam", []), file("b.gleam", [])]))

  assert string.contains(html, "<details class=\"changes\">")
  assert string.contains(html, "Changes")
  assert string.contains(html, " · 2 files · +14 -2")
  assert string.contains(html, "from this session&#39;s edits")
}

pub fn the_first_file_is_open_and_the_rest_are_collapsed_test() {
  let html = drawn(board([file("a.gleam", []), file("b.gleam", [])]))

  // The fixed `open` attribute is on the first file's details alone.
  assert list.length(string.split(html, "<details")) == 4
  let assert Ok(#(first, second)) = string.split_once(html, "b.gleam")
  assert string.contains(first, "open")
  assert !string.contains(second, " open")
}

pub fn rows_carry_a_class_from_their_kind_and_their_text_test() {
  let html =
    drawn(
      board([
        file("a.gleam", [
          row(changes_view.Hunk, "@@ -1 +1 @@"),
          row(changes_view.Context, " same"),
          row(changes_view.Removed, "-old"),
          row(changes_view.Added, "+new"),
        ]),
      ]),
    )

  assert string.contains(
    html,
    "<div class=\"diff-row diff-hunk\">@@ -1 +1 @@</div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-context\"> same</div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-removed\">-old</div>",
  )
  assert string.contains(html, "<div class=\"diff-row diff-added\">+new</div>")
}

pub fn a_path_and_a_row_are_only_ever_text_nodes_test() {
  let html =
    drawn(
      board([
        file("<img src=x onerror=alert(1)>", [
          row(changes_view.Added, "+<script>alert(1)</script>"),
          row(changes_view.Context, " \" onmouseover=\"x\" class=\"diff-added"),
        ]),
      ]),
    )

  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert string.contains(html, "+&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<script")
  assert !string.contains(html, "onmouseover=\"x\"")
  assert string.contains(html, "&quot; onmouseover=&quot;x&quot;")
}

pub fn a_cut_is_said_for_a_file_and_for_the_board_test() {
  let held = changes_view.File(..file("a.gleam", []), cut: 300)
  let html =
    changes_view.Board(..board([held]), file_count: 30)
    |> drawn

  assert string.contains(html, "300 more lines not shown")
  assert string.contains(html, "29 more files not shown")
}

pub fn the_view_carries_no_handler_test() {
  let html = drawn(board([file("a.gleam", [row(changes_view.Added, "+x")])]))
  assert !string.contains(html, "data-lustre-on")
}

// --- on the pages ---------------------------------------------------------------

const diff = "@@ -1,2 +1,3 @@\n keep\n-old\n+new\n+<script>alert(1)</script>"

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

pub fn a_page_with_no_edit_draws_no_section_test() {
  let model = page([lane_fixture.captured(10, None)])
  assert !string.contains(operator(model), "class=\"changes\"")
  assert !string.contains(observer(model), "class=\"changes\"")
}

pub fn both_pages_draw_the_section_below_the_transcript_test() {
  let model =
    page([
      lane_fixture.edited([#("src/calc.gleam", diff), #("README.md", diff)]),
    ])

  assert in_order(operator(model), [
    "<loom-follow",
    "<details class=\"changes\">",
    "Changes",
    " · 2 files · +4 -2",
    "src/calc.gleam",
    "<footer class=\"dock\">",
  ])
  assert in_order(observer(model), [
    "<loom-follow",
    "<details class=\"changes\">",
    "src/calc.gleam",
    "<p class=\"observer-bar\">",
  ])
}

pub fn a_diff_on_a_page_is_escaped_text_test() {
  let model = page([lane_fixture.edited([#("<b>x</b>.gleam", diff)])])

  list.each([operator(model), observer(model)], fn(html) {
    assert string.contains(html, "+&lt;script&gt;alert(1)&lt;/script&gt;")
    assert string.contains(html, "&lt;b&gt;x&lt;/b&gt;.gleam")
    assert !string.contains(html, "<script")
    assert !string.contains(html, "<b>x")
  })
}

pub fn the_section_stays_within_a_fixed_size_test() {
  // Far more than the board holds: 60 files of 300 rows each, every row
  // longer than the row bound.
  let long = string.repeat("x", 1000)
  let hunk =
    list.repeat("+" <> long, 300)
    |> string.join("\n")
    |> string.append("@@ -1 +1 @@\n", _)
  let edits =
    list.repeat(Nil, 60)
    |> list.index_map(fn(_, index) {
      #("f" <> int.to_string(index) <> ".txt", hunk)
    })
  let html = observer(page([lane_fixture.edited(edits)]))

  let assert Ok(#(_, from)) =
    string.split_once(html, "<details class=\"changes\">")
  let assert Ok(#(section, _)) =
    string.split_once(from, "<p class=\"observer-bar\">")
  // The board holds `max_rows` rows of at most `max_row_characters`
  // characters, plus the markup around each row and each file.
  assert string.length(section) < 220_000
  assert list.length(string.split(section, "diff-row")) - 1
    == changes_view.max_rows
  assert string.contains(section, "36 more files not shown")
}

fn in_order(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> True
    [needle, ..rest] ->
      case string.split_once(haystack, needle) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}
