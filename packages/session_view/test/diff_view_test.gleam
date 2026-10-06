//// The diff reader: what each line of a unified diff is, the line numbers a
//// hunk header gives, and the bound on how many lines it keeps.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/diff_view.{
  Added, Context, FileHeader, Hunk, Line, NoNewline, Removed,
}

pub fn each_kind_of_line_is_told_apart_and_numbered_from_the_hunk_test() {
  let diff =
    diff_view.parse("@@ -9,3 +9,4 @@\n keep\n-old\n+new\n+newer\n tail")
  assert diff.cut == 0
  assert diff.lines
    == [
      Line(Hunk, None, None, "@@ -9,3 +9,4 @@"),
      Line(Context, Some(9), Some(9), "keep"),
      Line(Removed, Some(10), None, "old"),
      Line(Added, None, Some(10), "new"),
      Line(Added, None, Some(11), "newer"),
      Line(Context, Some(11), Some(12), "tail"),
    ]
}

pub fn a_whole_diff_has_file_headers_only_before_its_first_hunk_test() {
  let diff =
    diff_view.parse(
      "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+++b",
    )
  let kinds = list.map(diff.lines, fn(line) { line.kind })
  assert kinds
    == [FileHeader, FileHeader, FileHeader, FileHeader, Hunk, Removed, Added]

  // Inside a hunk `+++b` is an added line whose text is `++b`.
  let assert Ok(last) = list.last(diff.lines)
  assert last.text == "++b"
}

pub fn a_hunk_header_with_no_numbers_leaves_the_gutter_empty_test() {
  let diff = diff_view.parse("@@ weird @@\n-a\n+b")
  assert list.map(diff.lines, fn(line) { #(line.old, line.new) })
    == [#(None, None), #(None, None), #(None, None)]
}

pub fn a_carriage_return_before_the_end_of_a_line_is_not_part_of_it_test() {
  let diff = diff_view.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")
  let assert [_, removed, added, ..] = diff.lines
  assert removed.text == "a"
  assert added.text == "b"
}

pub fn the_no_newline_note_is_its_own_kind_and_takes_no_number_test() {
  let diff =
    diff_view.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b")
  assert diff.lines
    == [
      Line(Hunk, None, None, "@@ -1 +1 @@"),
      Line(Removed, Some(1), None, "a"),
      Line(NoNewline, None, None, "\\ No newline at end of file"),
      Line(Added, None, Some(1), "b"),
    ]
}

pub fn hostile_text_is_kept_as_text_and_never_a_kind_test() {
  let diff =
    diff_view.parse(
      "@@ -1 +1 @@\n+<script>alert(1)</script>\n\" onmouseover=\"x",
    )
  let assert [_, added, other] = diff.lines
  assert added.kind == Added
  assert added.text == "<script>alert(1)</script>"

  // A line with no marker is context with its whole text.
  assert other.kind == Context
  assert other.text == "\" onmouseover=\"x"
}

pub fn a_long_diff_is_cut_and_the_rest_counted_test() {
  let body =
    list.repeat("+x", diff_view.max_lines + 25)
    |> string.join("\n")
  let diff = diff_view.parse("@@ -0,0 +1 @@\n" <> body)
  assert list.length(diff.lines) == diff_view.max_lines
  assert diff.cut == 26
  assert string.contains(int.to_string(diff.cut), "26")
}

// A diff's text ends in a newline, which splits into one empty string at the
// end. That is the end of the text and not a context row.
pub fn a_final_newline_is_not_a_line_test() {
  let diff = diff_view.parse("@@ -1 +1 @@\n-a\n+b\n")
  assert list.length(diff.lines) == 3
  assert diff.cut == 0
  assert list.length(diff_view.of_lines(["@@ -1 +1 @@", "-a", "+b", ""])) == 3

  // A context line that is empty in the file is a single space in the diff,
  // and stays a line.
  assert list.length(diff_view.parse("@@ -1,2 +1,2 @@\n \n-a\n+b").lines) == 4
}
