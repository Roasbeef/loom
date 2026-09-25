//// Tests for `lsp/text`: line splitting, the UTF-16 ↔ codepoint
//// conversion, identifier-boundary lookup, and edit application.
////
//// The generated-text properties at the bottom walk a small deterministic
//// generator over the characters that make the arithmetic interesting —
//// every terminator, a two-byte and a three-byte BMP character, and two
//// astral characters — so a regression in any one conversion shows up as
//// a named seed rather than as a lucky pass.

import gleam/int
import gleam/list
import gleam/string
import lsp/query.{Site}
import lsp/range.{Position, Range, TextEdit}
import lsp/text.{
  ColumnOutOfRange, InvertedRange, Line, LineOutOfRange, MalformedPosition,
  NegativeCoordinate, OverlappingEdits, PositionOutOfRange, RangeSelects,
  SplitsSurrogatePair, SymbolAbsent,
}

fn edit(line: Int, from: Int, to: Int, new_text: String) -> range.TextEdit {
  TextEdit(Range(Position(line, from), Position(line, to)), new_text)
}

fn span(
  start_line: Int,
  start: Int,
  end_line: Int,
  end: Int,
  new_text: String,
) -> range.TextEdit {
  TextEdit(
    Range(Position(start_line, start), Position(end_line, end)),
    new_text,
  )
}

// --- lines -------------------------------------------------------------

pub fn lines_empty_text_is_one_empty_line_test() {
  assert text.lines("") == [Line("", "")]
}

pub fn lines_trailing_newline_has_empty_final_line_test() {
  assert text.lines("a\n") == [Line("a", "\n"), Line("", "")]
}

pub fn lines_no_final_newline_test() {
  assert text.lines("a\nb") == [Line("a", "\n"), Line("b", "")]
}

pub fn lines_mixed_terminators_test() {
  assert text.lines("a\r\nb\rc\nd")
    == [Line("a", "\r\n"), Line("b", "\r"), Line("c", "\n"), Line("d", "")]
}

pub fn lines_cr_then_crlf_test() {
  // A lone `\r` directly before a `\r\n` is its own terminator.
  assert text.lines("x\r\r\ny")
    == [Line("x", "\r"), Line("", "\r\n"), Line("y", "")]
}

pub fn lines_lf_then_cr_is_two_terminators_test() {
  // `\n\r` is not a terminator pair: it ends two lines.
  assert text.lines("x\n\ry")
    == [Line("x", "\n"), Line("", "\r"), Line("y", "")]
}

pub fn lines_only_terminators_test() {
  assert text.lines("\r\n\n\r")
    == [Line("", "\r\n"), Line("", "\n"), Line("", "\r"), Line("", "")]
}

pub fn join_round_trips_fixed_texts_test() {
  [
    "", "\n", "\r", "\r\n", "a", "a\n", "a\r\nb\r\n", "a\rb\nc\r\nd", "\n\n\r\r",
    "é\r\n中\r😀\n𝒳", "e\u{301}\r\n",
  ]
  |> list.each(fn(sample) {
    assert text.join(text.lines(sample)) == sample
  })
}

// --- UTF-16 ↔ codepoint -------------------------------------------------

pub fn codepoint_column_ascii_test() {
  assert text.to_codepoint_column("hello", Position(0, 0)) == Ok(1)
  assert text.to_codepoint_column("hello", Position(0, 3)) == Ok(4)
  assert text.to_codepoint_column("hello", Position(0, 5)) == Ok(6)
}

pub fn codepoint_column_two_and_three_byte_bmp_test() {
  // é is two bytes, 中 three; each is one UTF-16 unit and one codepoint.
  assert text.to_codepoint_column("é中x", Position(0, 1)) == Ok(2)
  assert text.to_codepoint_column("é中x", Position(0, 2)) == Ok(3)
  assert text.to_utf16_character("é中x", 3) == Ok(2)
}

pub fn codepoint_column_astral_counts_two_units_test() {
  assert text.to_codepoint_column("😀x", Position(0, 2)) == Ok(2)
  assert text.to_codepoint_column("𝒳𝒳y", Position(0, 4)) == Ok(3)
  assert text.to_utf16_character("😀x", 2) == Ok(2)
  assert text.to_utf16_character("𝒳𝒳y", 3) == Ok(4)
}

pub fn codepoint_column_between_surrogate_halves_is_malformed_test() {
  assert text.to_codepoint_column("😀x", Position(3, 1))
    == Error(MalformedPosition(Position(3, 1), SplitsSurrogatePair))
  assert text.to_codepoint_column("a𝒳𝒳", Position(0, 4))
    == Error(MalformedPosition(Position(0, 4), SplitsSurrogatePair))
}

pub fn codepoint_column_combining_mark_is_its_own_codepoint_test() {
  // One grapheme, two codepoints: columns are codepoints, not graphemes.
  assert text.to_codepoint_column("e\u{301}x", Position(0, 2)) == Ok(3)
}

pub fn codepoint_column_past_end_clamps_test() {
  assert text.to_codepoint_column("ab", Position(0, 99)) == Ok(3)
  assert text.to_codepoint_column("😀", Position(0, 7)) == Ok(2)
  assert text.to_codepoint_column("", Position(0, 1)) == Ok(1)
}

pub fn codepoint_column_negative_is_malformed_test() {
  assert text.to_codepoint_column("ab", Position(0, -1))
    == Error(MalformedPosition(Position(0, -1), NegativeCoordinate))
}

pub fn utf16_character_out_of_line_test() {
  assert text.to_utf16_character("ab", 0)
    == Error(ColumnOutOfRange(column: 0, width: 2))
  assert text.to_utf16_character("ab", 4)
    == Error(ColumnOutOfRange(column: 4, width: 2))
  assert text.to_utf16_character("ab", 3) == Ok(2)
}

// --- sites -------------------------------------------------------------

pub fn to_site_converts_and_strips_terminator_test() {
  assert text.to_site("a\n😀b\n", "m.gleam", Position(1, 2))
    == Ok(Site(path: "m.gleam", line: 2, column: 2, text: "😀b"))
  assert text.to_site("a\r\n😀b\r\n", "m.gleam", Position(1, 2))
    == Ok(Site(path: "m.gleam", line: 2, column: 2, text: "😀b\r"))
}

pub fn to_site_empty_final_line_test() {
  assert text.to_site("a\n", "m", Position(1, 0)) == Ok(Site("m", 2, 1, ""))
}

pub fn to_site_end_of_file_test() {
  // "a\n" has two lines; line 2 character 0 is the end of file.
  assert text.to_site("a\n", "m", Position(2, 0)) == Ok(Site("m", 3, 1, ""))
}

pub fn to_site_beyond_end_of_file_test() {
  assert text.to_site("a\n", "m", Position(2, 1))
    == Error(PositionOutOfRange(Position(2, 1), 2))
  assert text.to_site("a\n", "m", Position(3, 0))
    == Error(PositionOutOfRange(Position(3, 0), 2))
}

pub fn to_site_negative_line_test() {
  assert text.to_site("a", "m", Position(-1, 0))
    == Error(MalformedPosition(Position(-1, 0), NegativeCoordinate))
}

pub fn to_site_surrogate_split_test() {
  assert text.to_site("x\n😀", "m", Position(1, 1))
    == Error(MalformedPosition(Position(1, 1), SplitsSurrogatePair))
}

pub fn to_sites_many_positions_test() {
  assert text.to_sites("ab\ncd", "m", [Position(0, 1), Position(1, 0)])
    == Ok([Site("m", 1, 2, "ab"), Site("m", 2, 1, "cd")])
}

// --- identifier boundaries ---------------------------------------------

pub fn occurrences_rejects_longer_identifiers_test() {
  assert text.occurrences("foo_bar xfoo foo2 _foo", "foo") == []
}

pub fn occurrences_accepts_punctuation_neighbours_test() {
  assert text.occurrences("foo(a.foo, [foo])", "foo") == [1, 7, 13]
}

pub fn occurrences_at_line_start_and_end_test() {
  assert text.occurrences("foo = foo", "foo") == [1, 7]
}

pub fn occurrences_unicode_neighbours_join_test() {
  // A non-ASCII codepoint beside the symbol counts as identifier.
  assert text.occurrences("éfoo fooé foo中 (foo)", "foo") == [17]
}

pub fn occurrences_counts_codepoint_columns_test() {
  assert text.occurrences("😀 foo", "foo") == [3]
}

pub fn occurrences_absent_and_empty_test() {
  assert text.occurrences("bar baz", "foo") == []
  assert text.occurrences("bar", "") == []
  assert text.occurrences("", "foo") == []
}

pub fn occurrences_operator_symbol_needs_no_boundary_test() {
  assert text.occurrences("a<>b", "<>") == [2]
}

pub fn symbol_position_first_boundary_match_test() {
  // The first `greet` is inside `greeting`; the second is the one.
  assert text.symbol_position("x\ngreeting 😀greet greet()", 2, "greet")
    == Ok(Position(line: 1, character: 17))
}

pub fn symbol_position_after_astral_test() {
  assert text.symbol_position("𝒳 = greet()", 1, "greet")
    == Ok(Position(line: 0, character: 5))
}

pub fn symbol_position_absent_test() {
  assert text.symbol_position("greeting", 1, "greet")
    == Error(SymbolAbsent(line: 1, symbol: "greet"))
}

pub fn symbol_position_line_out_of_range_test() {
  assert text.symbol_position("a\nb", 3, "b")
    == Error(LineOutOfRange(line: 3, line_count: 2))
  assert text.symbol_position("a\nb", 0, "a")
    == Error(LineOutOfRange(line: 0, line_count: 2))
}

// --- apply -------------------------------------------------------------

const greet_module = "pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}

pub fn main() {
  greet(\"Joe\")
}
"

pub fn apply_gleam_rename_payload_test() {
  // The shape `gleam lsp` returns for renaming `greet` to `salute`: one
  // edit at the definition, one at the call, on different lines.
  let edits = [edit(0, 7, 12, "salute"), edit(5, 2, 7, "salute")]
  assert text.check_selects(greet_module, edits, "greet") == Ok(Nil)
  assert text.apply(greet_module, edits)
    == Ok(
      "pub fn salute(name: String) -> String {
  \"Hello, \" <> name
}

pub fn main() {
  salute(\"Joe\")
}
",
    )
}

pub fn apply_order_of_edits_in_list_does_not_matter_test() {
  let edits = [edit(5, 2, 7, "salute"), edit(0, 7, 12, "salute")]
  let assert Ok(renamed) = text.apply(greet_module, edits)
  assert string.contains(renamed, "pub fn salute(")
  assert string.contains(renamed, "  salute(\"Joe\")")
}

pub fn apply_multiple_edits_on_one_line_test() {
  // The second edit's offsets are against the base: were they measured
  // after the first (longer) replacement, they would cut into it.
  assert text.apply("a + a + a", [edit(0, 0, 1, "bee"), edit(0, 4, 5, "bee")])
    == Ok("bee + bee + a")
}

pub fn apply_insertion_at_end_of_file_test() {
  assert text.apply("a\n", [edit(2, 0, 0, "b\n")]) == Ok("a\nb\n")
  assert text.apply("a", [edit(1, 0, 0, "!")]) == Ok("a!")
}

pub fn apply_deletion_across_lines_test() {
  assert text.apply("one\ntwo\nthree\n", [span(0, 3, 2, 0, "")])
    == Ok("onethree\n")
}

pub fn apply_replacement_spanning_lines_keeps_far_terminators_test() {
  assert text.apply("a\r\nb\r\nc\r\nd", [span(1, 0, 2, 1, "X")])
    == Ok("a\r\nX\r\nd")
}

pub fn apply_crlf_file_stays_crlf_test() {
  let base = "fn greet() {}\r\ngreet()\r\n"
  assert text.apply(base, [edit(0, 3, 8, "salute"), edit(1, 0, 5, "salute")])
    == Ok("fn salute() {}\r\nsalute()\r\n")
}

pub fn apply_lone_cr_file_stays_lone_cr_test() {
  assert text.apply("a\rb\r", [edit(1, 0, 1, "c")]) == Ok("a\rc\r")
}

pub fn apply_astral_before_edit_on_same_line_test() {
  // 😀 and 𝒳 are two UTF-16 units each, so `greet` starts at 5.
  let base = "😀𝒳 greet()\n"
  assert text.check_selects(base, [edit(0, 5, 10, "x")], "greet") == Ok(Nil)
  assert text.apply(base, [edit(0, 5, 10, "salute")]) == Ok("😀𝒳 salute()\n")
}

pub fn apply_past_end_of_line_clamps_test() {
  assert text.apply("ab\ncd", [edit(0, 1, 50, "X")]) == Ok("aX\ncd")
}

pub fn apply_inserts_at_one_point_keep_server_order_test() {
  assert text.apply("ab", [edit(0, 1, 1, "1"), edit(0, 1, 1, "2")])
    == Ok("a12b")
}

pub fn apply_adjacent_edits_do_not_overlap_test() {
  assert text.apply("abcd", [edit(0, 2, 4, "Y"), edit(0, 0, 2, "X")])
    == Ok("XY")
}

pub fn apply_no_edits_is_identity_test() {
  assert text.apply("a\r\nb", []) == Ok("a\r\nb")
}

pub fn apply_overlapping_edits_fault_test() {
  let first = edit(0, 0, 3, "x")
  let second = edit(0, 2, 4, "y")
  assert text.apply("abcdef", [second, first])
    == Error(OverlappingEdits(first.range, second.range))
}

pub fn apply_insertion_inside_replacement_overlaps_test() {
  let replace = edit(0, 1, 3, "x")
  let insert = edit(0, 2, 2, "y")
  assert text.apply("abcd", [replace, insert])
    == Error(OverlappingEdits(replace.range, insert.range))
}

pub fn apply_inverted_range_fault_test() {
  let backwards = span(1, 0, 0, 2, "x")
  assert text.apply("ab\ncd", [backwards])
    == Error(InvertedRange(backwards.range))
}

pub fn apply_surrogate_split_fault_test() {
  assert text.apply("😀", [edit(0, 1, 2, "x")])
    == Error(MalformedPosition(Position(0, 1), SplitsSurrogatePair))
}

pub fn apply_out_of_range_fault_test() {
  assert text.apply("a", [edit(3, 0, 0, "x")])
    == Error(PositionOutOfRange(Position(3, 0), 1))
}

// --- check_selects -----------------------------------------------------

pub fn check_selects_catches_shifted_range_test() {
  let stale = edit(0, 8, 13, "salute")
  assert text.check_selects(greet_module, [edit(5, 2, 7, "s"), stale], "greet")
    == Error(RangeSelects(stale.range, expected: "greet", found_length: 5))
}

pub fn check_selects_across_lines_test() {
  assert text.check_selects("ab\r\ncd", [span(0, 1, 1, 1, "")], "b\r\nc")
    == Ok(Nil)
}

// --- describe ----------------------------------------------------------

pub fn describe_names_every_fault_test() {
  let at = Range(Position(0, 1), Position(0, 2))
  [
    MalformedPosition(Position(0, 1), SplitsSurrogatePair),
    MalformedPosition(Position(0, -1), NegativeCoordinate),
    PositionOutOfRange(Position(9, 0), 2),
    LineOutOfRange(9, 2),
    ColumnOutOfRange(9, 2),
    SymbolAbsent(1, "greet"),
    InvertedRange(at),
    OverlappingEdits(at, at),
    RangeSelects(at, "greet", 5),
  ]
  |> list.each(fn(fault) {
    assert text.describe(fault) != ""
  })
  assert text.describe(SymbolAbsent(line: 4, symbol: "greet"))
    == "`greet` does not occur as a whole identifier on line 4"
}

// A server chooses the range, so the text under it may be any part of any
// file; the refusal names the identifier the caller asked for and the
// span's length, and must not carry the span.
pub fn describe_never_echoes_the_selected_text_test() {
  let at = Range(Position(0, 8), Position(0, 14))
  let assert Error(fault) =
    text.check_selects("fn main(secret) {}", [TextEdit(at, "x")], "greet")
    as "the range selects `secret`, not `greet`"
  let message = text.describe(fault)
  assert !string.contains(message, "secret")
  assert message
    == "an edit at line 0, UTF-16 character 8, zero-based to line 0, "
    <> "UTF-16 character 14, zero-based selects 6 characters where `greet` "
    <> "(5 characters) was expected; the file changed since the server "
    <> "read it"
}

// --- generated properties ----------------------------------------------

/// The integers `from..to`, both included.
fn upto(from: Int, to: Int) -> List(Int) {
  int.range(from, to + 1, [], fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

/// The pieces generated texts are built from.
const alphabet = [
  "a", "b", "_", " ", "(", "é", "中", "😀", "𝒳", "\n", "\r\n", "\r", "foo",
]

/// A linear congruential step; deterministic, so a failure names its seed.
fn next(seed: Int) -> Int {
  { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
}

fn generate(seed: Int, length: Int, acc: List(String)) -> #(String, Int) {
  case length {
    0 -> #(string.concat(acc), seed)
    _ -> {
      let seed = next(seed)
      let index = { seed / 65_536 } % list.length(alphabet)
      let piece = list.drop(alphabet, index) |> list.first
      let assert Ok(piece) = piece as "index is within the alphabet"
      generate(seed, length - 1, [piece, ..acc])
    }
  }
}

fn each_generated(count: Int, check: fn(String) -> Nil) -> Nil {
  upto(1, count)
  |> list.each(fn(seed) {
    let #(sample, _) = generate(seed * 7919, seed % 24, [])
    check(sample)
  })
}

pub fn generated_lines_round_trip_test() {
  use sample <- each_generated(300)
  let split = text.lines(sample)
  assert text.join(split) == sample

  // Every line but the last is terminated; the last never is.
  let assert [last, ..earlier] = list.reverse(split) as "lines is non-empty"
  assert last.terminator == ""
  assert list.all(earlier, fn(line) { line.terminator != "" })
}

pub fn generated_column_conversion_round_trips_test() {
  use sample <- each_generated(300)
  use Line(text: line, ..) <- list.each(text.lines(sample))
  let width = list.length(string.to_utf_codepoints(line))
  use column <- list.each(upto(1, width + 1))
  let assert Ok(character) = text.to_utf16_character(line, column)
    as "every column of the line converts"
  assert text.to_codepoint_column(line, Position(0, character)) == Ok(column)
}

pub fn generated_identity_edits_preserve_text_test() {
  // Replacing any whole line with its own text, addressed through the
  // conversion, leaves the text byte-identical, and the range selects
  // exactly that text.
  use sample <- each_generated(300)
  let split = text.lines(sample)
  use #(line, index) <- list.each(list.index_map(split, fn(l, i) { #(l, i) }))
  let width = list.length(string.to_utf_codepoints(line.text))
  let assert Ok(end) = text.to_utf16_character(line.text, width + 1)
    as "line end converts"
  let whole = edit(index, 0, end, line.text)
  assert text.apply(sample, [whole]) == Ok(sample)
  assert text.check_selects(sample, [whole], line.text) == Ok(Nil)
}

pub fn generated_symbol_positions_select_the_symbol_test() {
  // Wherever `foo` is found, the position handed back selects `foo`.
  use sample <- each_generated(300)
  let numbered = list.index_map(text.lines(sample), fn(l, i) { #(l, i + 1) })
  use #(line, number) <- list.each(numbered)
  case text.symbol_position(sample, number, "foo") {
    Error(SymbolAbsent(..)) -> {
      assert text.occurrences(line.text, "foo") == []
    }
    Error(other) -> panic as text.describe(other)
    Ok(Position(line: at_line, character:)) -> {
      let selects = edit(at_line, character, character + 3, "")
      assert text.check_selects(sample, [selects], "foo") == Ok(Nil)
    }
  }
}

pub fn generator_covers_the_hard_characters_test() {
  // A sanity check on the generator itself: it does produce astral text
  // and every terminator, or the properties above prove less than claimed.
  let samples =
    upto(1, 300)
    |> list.map(fn(seed) { generate(seed * 7919, seed % 24, []).0 })
    |> string.concat
  ["😀", "𝒳", "\r\n", "\n", "\r", "中", "é"]
  |> list.each(fn(piece) {
    assert string.contains(samples, piece)
  })
}

// A CRLF line keeps its `\r` in a site's text, because hashline splits on
// `\n` alone and the site's anchor must equal the one `fs_read` prints.
pub fn to_site_keeps_the_carriage_return_of_a_crlf_line_test() {
  assert text.to_site("ab\r\ncd\nef", "m.gleam", range.Position(0, 1))
    == Ok(query.Site(path: "m.gleam", line: 1, column: 2, text: "ab\r"))
  assert text.to_site("ab\r\ncd\nef", "m.gleam", range.Position(1, 0))
    == Ok(query.Site(path: "m.gleam", line: 2, column: 1, text: "cd"))
}
