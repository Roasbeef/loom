//// The shared tokenizer's tests: each class of token, the cases that must
//// not fail (an unterminated string, an empty line), and the property both
//// hosts rely on, that the tokens joined are the line unchanged.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/code_tokens.{
  type CodePart, CodeAdded, CodeComment, CodeDiffMeta, CodeKeyword, CodeNumber,
  CodePart, CodePlain, CodePunctuation, CodeRemoved, CodeString, CodeType,
}

fn joined(parts: List(CodePart)) -> String {
  parts |> list.map(fn(part) { part.text }) |> string.concat
}

pub fn keywords_and_types_are_told_apart_from_plain_words_test() {
  assert code_tokens.gleam_line("pub fn main")
    == [
      CodePart("pub", CodeKeyword),
      CodePart(" ", CodePlain),
      CodePart("fn", CodeKeyword),
      CodePart(" ", CodePlain),
      CodePart("main", CodePlain),
    ]
  assert code_tokens.gleam_line("Ok(value)")
    == [
      CodePart("Ok", CodeType),
      CodePart("(", CodePunctuation),
      CodePart("value", CodePlain),
      CodePart(")", CodePunctuation),
    ]
}

pub fn a_keyword_inside_a_longer_word_is_not_a_keyword_test() {
  assert code_tokens.gleam_line("letter") == [CodePart("letter", CodePlain)]
}

pub fn a_string_keeps_its_escapes_and_its_quotes_test() {
  assert code_tokens.gleam_line("\"a\\\"b\" 1")
    == [
      CodePart("\"a\\\"b\"", CodeString),
      CodePart(" ", CodePlain),
      CodePart("1", CodeNumber),
    ]
}

pub fn a_comment_takes_the_rest_of_the_line_test() {
  assert code_tokens.gleam_line("x // let \"y\"")
    == [
      CodePart("x", CodePlain),
      CodePart(" ", CodePlain),
      CodePart("// let \"y\"", CodeComment),
    ]
}

pub fn numbers_take_digit_separators_test() {
  assert code_tokens.gleam_line("1_000") == [CodePart("1_000", CodeNumber)]
}

pub fn an_unterminated_string_runs_to_the_end_of_the_line_test() {
  let parts = code_tokens.gleam_line("let s = \"open")
  assert list.last(parts) == Ok(CodePart("\"open", CodeString))
  assert joined(parts) == "let s = \"open"
}

pub fn a_trailing_backslash_in_a_string_does_not_fail_test() {
  let parts = code_tokens.gleam_line("\"a\\")
  assert parts == [CodePart("\"a\\", CodeString)]
}

pub fn an_empty_line_has_no_tokens_test() {
  assert code_tokens.gleam_line("") == []
  assert code_tokens.line(Some("gleam"), "") == []
}

pub fn the_tokens_joined_are_the_line_unchanged_test() {
  let lines = [
    "", "   ", "\t", "pub fn main() { Ok(1) }", "// only a comment",
    "let x = \"a\" <> \"b\\\"c\"", "@external(erlang, \"m\", \"f\")",
    "héllo wörld 漢字 👍🏽", "\"</span><script>\"", "a//b", "1.5e3",
  ]
  list.each(lines, fn(line) {
    assert joined(code_tokens.gleam_line(line)) == line
  })
}

pub fn the_language_tag_picks_the_scanner_test() {
  assert code_tokens.line(Some(" Gleam "), "let")
    == [CodePart("let", CodeKeyword)]
  assert code_tokens.line(Some("rust"), "fn main()")
    == [CodePart("fn main()", CodePlain)]
  assert code_tokens.line(None, "let") == [CodePart("let", CodePlain)]
}

pub fn a_diff_line_is_classified_whole_test() {
  assert code_tokens.line(Some("diff"), "+let x = 1")
    == [CodePart("+let x = 1", CodeAdded)]
  assert code_tokens.line(Some("diff"), "-old")
    == [CodePart("-old", CodeRemoved)]
  assert code_tokens.line(Some("diff"), "@@ -1 +1 @@")
    == [CodePart("@@ -1 +1 @@", CodeDiffMeta)]
  assert code_tokens.line(Some("diff"), "--- a/f")
    == [CodePart("--- a/f", CodeDiffMeta)]
  assert code_tokens.line(Some("diff"), " context")
    == [CodePart(" context", CodePlain)]
}

pub fn python_has_keywords_both_quotes_numbers_and_hash_comments_test() {
  assert code_tokens.line(Some("python"), "def f(x): return 'a' + \"b\" # 2")
    == [
      CodePart("def", CodeKeyword),
      CodePart(" ", CodePlain),
      CodePart("f", CodePlain),
      CodePart("(", CodePunctuation),
      CodePart("x", CodePlain),
      CodePart(")", CodePunctuation),
      CodePart(":", CodePunctuation),
      CodePart(" ", CodePlain),
      CodePart("return", CodeKeyword),
      CodePart(" ", CodePlain),
      CodePart("'a'", CodeString),
      CodePart(" ", CodePlain),
      CodePart("+", CodePunctuation),
      CodePart(" ", CodePlain),
      CodePart("\"b\"", CodeString),
      CodePart(" ", CodePlain),
      CodePart("# 2", CodeComment),
    ]
  assert code_tokens.line(Some("py"), "n = 10")
    == code_tokens.python_line("n = 10")
}

// A `#` or `//` is a comment only in the language that says so, and an
// apostrophe opens a string only in Python.
pub fn each_language_keeps_its_own_comment_and_quote_test() {
  assert code_tokens.gleam_line("# x")
    == [
      CodePart("#", CodePunctuation),
      CodePart(" ", CodePlain),
      CodePart("x", CodePlain),
    ]
  assert code_tokens.python_line("// x")
    == [
      CodePart("/", CodePunctuation),
      CodePart("/", CodePunctuation),
      CodePart(" ", CodePlain),
      CodePart("x", CodePlain),
    ]
  assert code_tokens.gleam_line("'") == [CodePart("'", CodePunctuation)]
}

pub fn python_tokens_join_back_to_the_line_test() {
  let text = "class A: x = 'unterminated # not a comment"
  assert joined(code_tokens.python_line(text)) == text
}
