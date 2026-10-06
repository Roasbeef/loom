//// The Changes tab: the files the session's own edits touched and the diff
//// each reported, drawn on both pages from the records the page holds.
////
//// The first group draws `view/changes` from a board, which is the module's
//// whole contract: the heading, the first file open, the rows' classes, the
//// cut lines, and every string arriving as escaped text. The second drives
//// the pages through a capture holding `fs_edit` results and reads the HTML
//// the browser would receive, so the pane's place in the strand panel, after
//// the transcript and the dock, is pinned on the operator's page and the
//// observer's, and so is its size.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/changes_view
import web_view/component
import web_view/operator_page
import web_view/view/changes
import web_view/worktrees

fn drawn(board: changes_view.Board) -> String {
  element.to_string(changes.view(board, changes.Whole, worktrees.Withheld, None))
}

fn row(kind: changes_view.Kind, text: String) -> changes_view.Row {
  changes_view.Row(kind, text)
}

fn file(path: String, rows: List(changes_view.Row)) -> changes_view.File {
  changes_view.File(
    path:,
    origin: changes_view.Edited,
    added: 1,
    removed: 1,
    rows:,
    cut: 0,
  )
}

// A file the session only wrote whole says so where an edit's counts go, and
// draws its lines as added rows.
pub fn a_written_file_says_written_where_the_counts_go_test() {
  let written =
    changes_view.File(
      path: "calc.py",
      origin: changes_view.Written,
      added: 23,
      removed: 0,
      rows: [row(changes_view.Added, "+a = 1")],
      cut: 22,
    )
  let html = drawn(board([written, file("b.gleam", [])]))

  assert string.contains(html, "calc.py")
  assert string.contains(html, "written · 23 lines")
  assert !string.contains(html, "+23 -0")
  assert string.contains(html, "diff-row diff-added")
  assert string.contains(html, " +1 -1")
}

fn board(files: List(changes_view.File)) -> changes_view.Board {
  changes_view.Board(
    files:,
    file_count: list.length(files),
    added: 14,
    removed: 2,
  )
}

// The pane is drawn whether or not the tab shows, and always with its heading,
// so it never moves the panes after it and the tab never opens on nothing.
pub fn no_edits_draw_the_heading_and_a_line_saying_so_test() {
  let html = drawn(changes_view.empty())

  assert string.contains(html, "pane pane-changes")
  assert string.contains(html, "Changes</h2>")
  assert string.contains(html, "No edits yet.")
  assert !string.contains(html, "changes-file")
}

// An empty board over a whole session says so plainly, and over a partial one
// says it looked only at what is loaded and where to load more. Both say which
// edits the tab can list.
pub fn an_empty_board_says_how_much_it_searched_test() {
  let whole =
    element.to_string(changes.view(
      changes_view.empty(),
      changes.Whole,
      worktrees.Withheld,
      None,
    ))
  let partial =
    element.to_string(changes.view(
      changes_view.empty(),
      changes.Partial,
      worktrees.Withheld,
      None,
    ))

  assert string.contains(whole, "No edits yet.")
  assert !string.contains(whole, "Load older")
  assert string.contains(
    partial,
    "No edits in the loaded part of this session.",
  )
  assert string.contains(partial, "Load older")
  assert !string.contains(partial, "No edits yet.")

  list.each([whole, partial], fn(html) {
    assert string.contains(html, "edits made through the edit and write tools")
    assert string.contains(html, "shell commands or editors are not shown")
  })
}

pub fn the_heading_names_the_files_and_the_totals_test() {
  let html = drawn(board([file("a.gleam", []), file("b.gleam", [])]))

  assert string.contains(html, "<section aria-label=\"Changes\"")
  assert string.contains(html, "pane pane-changes")
  assert string.contains(html, "Changes")
  assert string.contains(html, " · 2 files · +14 -2")
  assert string.contains(html, "from this session&#39;s edits")
}

pub fn the_first_file_is_open_and_the_rest_are_collapsed_test() {
  let html = drawn(board([file("a.gleam", []), file("b.gleam", [])]))

  // The fixed `open` attribute is on the first file's details alone.
  assert list.length(string.split(html, "<details")) == 3
  let assert Ok(#(first, second)) = string.split_once(html, "b.gleam")
  assert string.contains(
    first,
    "<details data-lustre-key=\"file:a.gleam\" class=\"changes-file\" open>",
  )
  assert !string.contains(second, " open")
}

// A file's `details` keeps the reader's open or closed choice in the browser,
// so it must stay the same element when a file appears before it: each file
// is keyed by its path, and the key does not move with its index.
pub fn a_file_is_keyed_by_its_path_not_its_place_test() {
  let later = drawn(board([file("b.gleam", []), file("c.gleam", [])]))
  let earlier =
    drawn(
      board([file("a.gleam", []), file("b.gleam", []), file("c.gleam", [])]),
    )
  list.each([later, earlier], fn(html) {
    assert string.contains(html, "data-lustre-key=\"file:b.gleam\"")
    assert string.contains(html, "data-lustre-key=\"file:c.gleam\"")
  })
  assert !string.contains(later, "file:a.gleam")
  assert string.contains(earlier, "data-lustre-key=\"file:a.gleam\"")
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

  // Each line is its own element, its class from its kind, with the old and
  // new line numbers in a gutter, the sign, and the text in a span.
  assert string.contains(
    html,
    "<div class=\"diff-row diff-hunk\"><span class=\"diff-text\">@@ -1 +1 @@</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-context\"><span class=\"diff-gutter\"><span class=\"diff-num\">1</span><span class=\"diff-num\">1</span><span class=\"diff-sign\"> </span></span><span class=\"diff-text\">same</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-removed\"><span class=\"diff-gutter\"><span class=\"diff-num\">2</span><span class=\"diff-num\"></span><span class=\"diff-sign\">−</span></span><span class=\"diff-text\">old</span></div>",
  )
  assert string.contains(
    html,
    "<div class=\"diff-row diff-added\"><span class=\"diff-gutter\"><span class=\"diff-num\"></span><span class=\"diff-num\">2</span><span class=\"diff-sign\">+</span></span><span class=\"diff-text\">new</span></div>",
  )
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
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
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

pub fn a_page_with_no_edit_draws_the_empty_pane_test() {
  let model = page([lane_fixture.captured(10, None)])
  list.each([operator(model), observer(model)], fn(html) {
    assert string.contains(html, "No edits yet.")
    assert !string.contains(html, "changes-file")
  })
}

// The pane is the strand panel's second child, after the Strands pane and
// before the Session pane, and the panel is drawn after the centre column: the
// transcript, the dock and the observer's bar all come before it.
pub fn both_pages_draw_the_pane_in_the_panel_after_the_centre_test() {
  let model =
    page([
      lane_fixture.edited([#("src/calc.gleam", diff), #("README.md", diff)]),
    ])

  assert in_order(operator(model), [
    "<loom-follow",
    "<footer class=\"dock\">",
    "<aside aria-label=\"Strand panel\"",
    "pane pane-strands",
    "pane pane-changes",
    " · 2 files · +4 -2",
    "src/calc.gleam",
    "pane pane-session",
  ])
  assert in_order(observer(model), [
    "<loom-follow",
    "<p class=\"observer-bar\">",
    "<aside aria-label=\"Strand panel\"",
    "pane pane-changes",
    "src/calc.gleam",
    "pane pane-session",
  ])
}

// The transcript's column holds no Changes: it moved into the panel.
pub fn the_centre_column_no_longer_holds_the_changes_test() {
  let model = page([lane_fixture.edited([#("src/calc.gleam", diff)])])
  list.each([operator(model), observer(model)], fn(html) {
    let assert Ok(#(centre, _)) =
      string.split_once(html, "<aside aria-label=\"Strand panel\"")
    assert !string.contains(centre, "src/calc.gleam")
    assert !string.contains(centre, "pane-changes")
  })
}

pub fn a_diff_on_a_page_is_escaped_text_test() {
  let model = page([lane_fixture.edited([#("<b>x</b>.gleam", diff)])])

  list.each([operator(model), observer(model)], fn(html) {
    assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
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
    string.split_once(html, "<section aria-label=\"Changes\"")
  let assert Ok(#(section, _)) =
    string.split_once(from, "<section aria-label=\"Session\"")
  // The board holds `max_rows` rows of at most `max_row_characters`
  // characters, plus the markup around each row (a gutter and a sign) and
  // each file.
  assert string.length(section) < 420_000
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

// A path under the workspace is drawn relative to it, so the line is not the
// full absolute path wrapped over two rows. A path elsewhere, or one that only
// shares the workspace's leading characters, is drawn as the edit named it.
pub fn a_path_under_the_workspace_is_drawn_relative_to_it_test() {
  let html =
    element.to_string(changes.view(
      board([
        file("/work/ws/src/m.py", []),
        file("/work/ws2/n.py", []),
        file("/etc/hosts", []),
      ]),
      changes.Whole,
      worktrees.Withheld,
      Some("/work/ws"),
    ))

  assert string.contains(html, ">src/m.py</span>")
  assert string.contains(html, ">/work/ws2/n.py</span>")
  assert string.contains(html, ">/etc/hosts</span>")
  assert !string.contains(html, ">/work/ws/src/m.py</span>")

  // The key stays the whole path, so display never merges two files.
  assert string.contains(html, "data-lustre-key=\"file:/work/ws/src/m.py\"")
}

// F143: a tab that says why it lists only the agent's edits does not also carry
// the `from this session's edits` label, which would say the same thing again.
// A tab with no reason keeps the label.
pub fn a_reason_and_the_label_are_never_drawn_together_test() {
  let edits = board([file("a.gleam", [row(changes_view.Added, "+x")])])
  let reasoned =
    element.to_string(changes.view(
      edits,
      changes.Whole,
      worktrees.Declined,
      None,
    ))
  assert string.contains(reasoned, "This page may not read the workspace")
  assert !string.contains(reasoned, "from this session")

  let plain = drawn(edits)
  assert string.contains(plain, "from this session")
}
