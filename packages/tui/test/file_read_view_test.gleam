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

pub fn unrecognized_lines_and_empty_window_diagnostics_survive_test() {
  assert file_read_view.render("digest: abcdef0123456789-0\n(empty file)")
    == "(empty file)"
  assert file_read_view.render(
      "digest: unexpected\n12:not-hash|text\nplain: text",
    )
    == "digest: unexpected\n12:not-hash|text\nplain: text"
}
