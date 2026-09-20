//// File-read presentation keeps source content while hiding edit metadata.

import tui/file_read_view
import tui/text_hygiene

pub fn anchored_source_keeps_numbers_indentation_and_delimiters_test() {
  let result =
    "digest: abcdef0123456789-42\n1186:0662f68e|\t\t// a:b|c\n1187:cbf29ce4|"
  assert file_read_view.render(result) == "1186 │ \t\t// a:b|c\n1187 │ "
  assert text_hygiene.multiline(file_read_view.render(result))
    == "1186 │         // a:b|c\n1187 │ "
}

// A successful edit's fresh-anchor block is for the model. The transcript
// row shows that the edit landed and the patch preview shows what changed,
// so the anchors are dropped from the projection the way a read's are —
// while the recorded result the model reads keeps them.
pub fn without_fresh_anchors_drops_a_writes_block_too_test() {
  assert file_read_view.without_fresh_anchors(
      "wrote 9 bytes to a/b.gleam\ndigest: abcdef0123456789-9\nFresh anchors:\n1:0662f68e|let x = 1",
    )
    == "wrote 9 bytes to a/b.gleam\ndigest: abcdef0123456789-9"
}

pub fn edit_summary_drops_the_fresh_anchor_block_test() {
  assert file_read_view.without_fresh_anchors(
      "applied 2 hunk(s) to a/b.gleam\ndigest: abcdef0123456789-42\nFresh anchors:\n7:0662f68e|  let x = 1\n8:cbf29ce4|",
    )
    == "applied 2 hunk(s) to a/b.gleam\ndigest: abcdef0123456789-42"
}

// An edit whose regions were too large to echo carries the heading with the
// offset on the same line, and an emptied file carries no heading at all.
// Neither may lose the summary.
pub fn edit_summary_keeps_a_success_without_a_block_test() {
  assert file_read_view.without_fresh_anchors(
      "applied 1 hunk(s) to a\ndigest: abcdef0123456789-1\n(the file is now empty)",
    )
    == "applied 1 hunk(s) to a\ndigest: abcdef0123456789-1\n(the file is now empty)"
  assert file_read_view.without_fresh_anchors(
      "applied 1 hunk(s) to a\ndigest: abcdef0123456789-9\nFresh anchors: the changed regions are too large to echo; read them with fs_read offset 1",
    )
    == "applied 1 hunk(s) to a\ndigest: abcdef0123456789-9"
}

// The window notice is not an anchored line and is the one statement that
// says the read was windowed, so the projection must pass it through
// rather than strip it with the digest and the anchors.
pub fn window_notice_survives_test() {
  assert file_read_view.render(
      "digest: abcdef0123456789-9\n2:0662f68e|l2\n(lines 2-2 of 5; read the rest with offset 3)",
    )
    == "2 │ l2\n(lines 2-2 of 5; read the rest with offset 3)"
}

pub fn unrecognized_lines_and_empty_window_diagnostics_survive_test() {
  assert file_read_view.render("digest: abcdef0123456789-0\n(empty file)")
    == "(empty file)"
  assert file_read_view.render(
      "digest: unexpected\n12:not-hash|text\nplain: text",
    )
    == "digest: unexpected\n12:not-hash|text\nplain: text"
}
