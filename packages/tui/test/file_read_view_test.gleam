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
