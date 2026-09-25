//// `lsp/text` — the pure arithmetic between the server's coordinates and
//// the harness's, and the one place a server's edits touch a text.
////
//// # Why this module exists
////
//// A language server addresses a document by zero-based line and
//// zero-based character offset counted in UTF-16 code units
//// (`lsp/range`). The harness addresses it by 1-based line and 1-based
//// column counted in Unicode codepoints (`lsp/query.Site`), because that
//// is what `fs_read` and `grep` print and what a model can read back. The
//// two agree on ASCII and disagree on everything else: `é` is one unit
//// and one codepoint but two bytes, `😀` is one codepoint but two UTF-16
//// units. A conversion done ad hoc at each call site gets one of those
//// wrong somewhere, so every conversion lives here, once, against the
//// exact text the position was computed on.
////
//// A rename is the sharpest case (ADR-013 §4). The server computes edits
//// against the text it holds; the harness applies them in pure code to
//// that same base and lands the result through the hashline path. So
//// this module also owns applying a list of `TextEdit`s, and the cheap
//// stale-position check the ADR asks for: every edit of a rename must
//// select exactly the old identifier in its base.
////
//// # How a text is seen
////
//// A text is a list of lines, each keeping its own terminator (`\n`,
//// `\r\n`, a lone `\r`, or nothing for a final unterminated line), so
//// splitting and rejoining is byte-identical and an edit leaves every
//// untouched terminator exactly as it was — a CRLF file stays CRLF. Line
//// counting follows LSP: the text after the last terminator is a line
//// even when it is empty, so `"a\n"` has two lines and a position may
//// address the empty second one. One position past that, line equal to
//// the line count with character zero, is the end of file and is legal;
//// anything further is `PositionOutOfRange`.
////
//// Columns are counted by walking codepoints (`string.to_utf_codepoints`),
//// never graphemes: `string.to_graphemes` would count `"e\u{301}"` as one
//// column and `"\r\n"` as one character, which is neither party's
//// measure. A UTF-16 offset that lands between the halves of a surrogate
//// pair names no codepoint and is `MalformedPosition`; it is never
//// rounded, because a rounded rename edit silently corrupts the character
//// beside the identifier. An offset past the end of a line clamps to the
//// line's end, as the LSP specification requires.
////
//// Everything here is pure: no I/O, no processes. Only `lsp/range`,
//// `lsp/query` and the standard library are imported.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import lsp/query.{type Site, Site}
import lsp/range.{type Position, type Range, type TextEdit, Position, Range}

// --- Types -------------------------------------------------------------

/// One line of a text together with the terminator that ended it.
pub type Line {
  Line(
    /// The line's content, without its terminator.
    text: String,
    /// Exactly what ended the line: `"\n"`, `"\r\n"`, `"\r"`, or `""` for
    /// the last line of the text, which no terminator ends.
    terminator: String,
  )
}

/// Why a UTF-16 position names no place in the text.
pub type Malformation {
  /// The line or the character is negative. The protocol's integers are
  /// unsigned, so only a broken server sends one.
  NegativeCoordinate

  /// The character offset falls between the two UTF-16 units of one
  /// codepoint above U+FFFF. There is no codepoint there to convert to.
  SplitsSurrogatePair
}

/// Why a conversion, a lookup or an edit could not be carried out. Every
/// variant names the coordinate that failed, so `describe` can tell the
/// model exactly what went wrong.
pub type TextFault {
  /// A server position that names no codepoint boundary.
  MalformedPosition(position: Position, reason: Malformation)

  /// A server position whose line lies beyond the text. Line equal to
  /// `line_count` is still legal with character zero (end of file); this
  /// is everything past that.
  PositionOutOfRange(position: Position, line_count: Int)

  /// A harness line (1-based) that the text does not have.
  LineOutOfRange(line: Int, line_count: Int)

  /// A harness column (1-based, in codepoints) outside `1..width + 1`,
  /// where `width` is the line's length in codepoints.
  ColumnOutOfRange(column: Int, width: Int)

  /// The symbol does not occur on identifier boundaries on the given
  /// 1-based line.
  SymbolAbsent(line: Int, symbol: String)

  /// An edit whose range starts after it ends.
  InvertedRange(range: Range)

  /// Two edits whose ranges overlap. The LSP specification forbids it,
  /// and no order of application would make the result well defined.
  OverlappingEdits(first: Range, second: Range)

  /// An edit's range does not select the text it was expected to: the
  /// server computed it against a different text, or it is not the
  /// identifier a rename claims to replace.
  ///
  /// The fault carries how long the selected span is, never the span
  /// itself. The range is the server's choice, so the text under it can be
  /// any part of any file the server was pointed at; a fault that held it
  /// would carry those bytes into every message rendered from it, and a
  /// server could read a file out through refusals. `expected` is safe to
  /// carry, because it is the identifier the caller already named.
  RangeSelects(range: Range, expected: String, found_length: Int)
}

/// A text indexed by line, built once so that converting many positions
/// against one base does not re-split it for each.
type Document {
  Document(lines: Dict(Int, Line), count: Int)
}

/// A resolved place in a document: a zero-based line and a zero-based
/// codepoint column already clamped to the line's width. Two points
/// compare in document order.
type Point {
  Point(line: Int, column: Int)
}

/// An edit with both ends resolved against the base, remembering the
/// server's range so a fault can name it.
type Resolved {
  Resolved(start: Point, end: Point, range: Range, new_text: String)
}

// --- Lines -------------------------------------------------------------

/// Split a text into lines on `\n`, `\r\n` and a lone `\r`, keeping each
/// terminator. The result is never empty, and the last line's
/// terminator is always `""`: a text ending in a terminator has an empty
/// final line, as LSP counts it.
///
/// Runs in linear time in the size of the text.
///
/// ## Examples
///
/// ```gleam
/// assert text.lines("a\r\nb") == [text.Line("a", "\r\n"), text.Line("b", "")]
/// ```
///
/// ```gleam
/// assert text.lines("a\n") == [text.Line("a", "\n"), text.Line("", "")]
/// ```
///
/// ```gleam
/// assert text.lines("") == [text.Line("", "")]
/// ```
pub fn lines(text: String) -> List(Line) {
  // `\r\n` is split out first so that neither of its halves is later
  // mistaken for a terminator of its own; within what remains, `\n` and
  // `\r` can no longer be adjacent in that order, so their order does
  // not matter.
  let #(last, earlier) = split_on(text, ["\r\n", "\n", "\r"])
  list.reverse([last, ..earlier])
}

/// Reassemble lines into the text they were split from. `join(lines(t))`
/// is `t`, byte for byte.
///
/// ## Examples
///
/// ```gleam
/// assert text.join(text.lines("a\rb\r\nc\n")) == "a\rb\r\nc\n"
/// ```
pub fn join(lines: List(Line)) -> String {
  lines
  |> list.fold(string_tree.new(), fn(tree, line) {
    tree
    |> string_tree.append(line.text)
    |> string_tree.append(line.terminator)
  })
  |> string_tree.to_string
}

/// Split `text` on each separator in turn, returning the last line and,
/// separately, the lines before it in reverse. Returning the last line
/// apart is what lets the caller stamp it with the separator that
/// followed it without walking the list to find it.
fn split_on(text: String, separators: List(String)) -> #(Line, List(Line)) {
  case separators {
    [] -> #(Line(text:, terminator: ""), [])

    // Every piece but the last was followed by `separator`; the last line
    // of each such piece takes it as its terminator. A piece's own lines
    // come back reversed, so prepending them keeps the whole reversed.
    [separator, ..rest] ->
      case string.split(text, separator) {
        [] -> #(Line(text:, terminator: ""), [])
        [first, ..more] ->
          list.fold(more, split_on(first, rest), fn(done, piece) {
            let #(last, earlier) = done
            let ended = Line(..last, terminator: separator)
            let #(piece_last, piece_earlier) = split_on(piece, rest)
            #(piece_last, list.append(piece_earlier, [ended, ..earlier]))
          })
      }
  }
}

/// Index a text by zero-based line.
fn document(text: String) -> Document {
  let all = lines(text)
  let count = list.length(all)
  let indexed = list.index_map(all, fn(line, index) { #(index, line) })
  Document(lines: dict.from_list(indexed), count:)
}

/// The line at a zero-based index. Only the end-of-file line, one past
/// the last, is ever asked for without being present, and it is empty
/// and unterminated.
fn line_at(document: Document, index: Int) -> Line {
  dict.get(document.lines, index)
  |> result.unwrap(Line(text: "", terminator: ""))
}

// --- Columns -----------------------------------------------------------

/// Convert a server position's UTF-16 `character` into a 1-based
/// codepoint column on `line_text`, the line the position's `line`
/// names. A character past the end clamps to one past the last
/// codepoint; one between the halves of a surrogate pair is
/// `MalformedPosition`.
///
/// ## Examples
///
/// ```gleam
/// // 😀 is two UTF-16 units and one codepoint.
/// assert text.to_codepoint_column("😀x", range.Position(0, 2)) == Ok(2)
/// ```
///
/// ```gleam
/// let assert Error(text.MalformedPosition(_, text.SplitsSurrogatePair)) =
///   text.to_codepoint_column("😀x", range.Position(0, 1))
/// ```
pub fn to_codepoint_column(
  line_text: String,
  at: Position,
) -> Result(Int, TextFault) {
  use offset <- result.map(codepoint_offset(line_text, at))
  offset + 1
}

/// Convert a 1-based codepoint column on `line_text` into the server's
/// zero-based UTF-16 `character`. The column may be one past the last
/// codepoint (the end of the line); anything else outside the line is
/// `ColumnOutOfRange`.
///
/// ## Examples
///
/// ```gleam
/// assert text.to_utf16_character("😀x", 2) == Ok(2)
/// ```
///
/// ```gleam
/// assert text.to_utf16_character("中x", 3) == Ok(2)
/// ```
pub fn to_utf16_character(
  line_text: String,
  column: Int,
) -> Result(Int, TextFault) {
  let codepoints = string.to_utf_codepoints(line_text)
  let width = list.length(codepoints)
  case column < 1 || column > width + 1 {
    True -> Error(ColumnOutOfRange(column:, width:))
    False ->
      codepoints
      |> list.take(column - 1)
      |> list.fold(0, fn(units, codepoint) { units + utf16_width(codepoint) })
      |> Ok
  }
}

/// The zero-based codepoint offset a UTF-16 character offset names on a
/// line, clamped to the line's width.
fn codepoint_offset(line_text: String, at: Position) -> Result(Int, TextFault) {
  case at.line < 0 || at.character < 0 {
    True -> Error(MalformedPosition(position: at, reason: NegativeCoordinate))
    False ->
      walk_units(string.to_utf_codepoints(line_text), at.character, 0, at)
  }
}

/// Consume codepoints until `remaining` UTF-16 units are spent. Running
/// out of codepoints first is the clamp the specification asks for;
/// needing half of a two-unit codepoint is the surrogate split, which is
/// refused rather than rounded either way.
fn walk_units(
  codepoints: List(UtfCodepoint),
  remaining: Int,
  taken: Int,
  at: Position,
) -> Result(Int, TextFault) {
  case codepoints {
    _ if remaining == 0 -> Ok(taken)
    [] -> Ok(taken)
    [codepoint, ..rest] -> {
      let units = utf16_width(codepoint)
      case remaining < units {
        True ->
          Error(MalformedPosition(position: at, reason: SplitsSurrogatePair))
        False -> walk_units(rest, remaining - units, taken + 1, at)
      }
    }
  }
}

/// How many UTF-16 code units a codepoint occupies: two above the Basic
/// Multilingual Plane (a surrogate pair), one otherwise.
fn utf16_width(codepoint: UtfCodepoint) -> Int {
  case string.utf_codepoint_to_int(codepoint) > 0xFFFF {
    True -> 2
    False -> 1
  }
}

/// Resolve a server position against a document into a clamped point.
/// This is the single gate every server position passes through, so the
/// end-of-file rule and the range check are stated once.
fn resolve(document: Document, at: Position) -> Result(Point, TextFault) {
  case int.compare(at.line, document.count) {
    order.Lt -> {
      use column <- result.map(codepoint_offset(
        line_at(document, at.line).text,
        at,
      ))
      Point(line: at.line, column:)
    }

    // One past the last line is the end of file, addressable only at its
    // start: it has no text for a later character to sit in.
    order.Eq if at.character == 0 -> Ok(Point(line: at.line, column: 0))
    order.Eq ->
      Error(PositionOutOfRange(position: at, line_count: document.count))
    order.Gt ->
      Error(PositionOutOfRange(position: at, line_count: document.count))
  }
}

// --- Sites -------------------------------------------------------------

/// Convert a server position in `text` into the harness's `Site` for
/// `path`: a 1-based line, a 1-based codepoint column, and the line's
/// text as the hashline tools see it — without its terminator, except
/// that a CRLF line keeps its `\r`, so the site's anchor matches the one
/// `fs_read` prints. The end-of-file position (line equal to
/// the line count, character zero) becomes column 1 of an empty line
/// after the last.
///
/// ## Examples
///
/// ```gleam
/// assert text.to_site("a\n😀b\n", "m.gleam", range.Position(1, 2))
///   == Ok(query.Site(path: "m.gleam", line: 2, column: 2, text: "😀b"))
/// ```
pub fn to_site(
  text: String,
  path: String,
  at: Position,
) -> Result(Site, TextFault) {
  site_in(document(text), path, at)
}

/// `to_site` for many positions in one text, splitting the text once.
/// The first position that fails is the error.
///
/// ## Examples
///
/// ```gleam
/// assert text.to_sites("ab\ncd", "m", [range.Position(0, 1), range.Position(1, 0)])
///   == Ok([query.Site("m", 1, 2, "ab"), query.Site("m", 2, 1, "cd")])
/// ```
pub fn to_sites(
  text: String,
  path: String,
  positions: List(Position),
) -> Result(List(Site), TextFault) {
  let indexed = document(text)
  list.try_map(positions, site_in(indexed, path, _))
}

/// `to_site` against an already indexed document.
fn site_in(
  document: Document,
  path: String,
  at: Position,
) -> Result(Site, TextFault) {
  use point <- result.map(resolve(document, at))
  let line = line_at(document, point.line)

  Site(
    path:,
    line: point.line + 1,
    column: point.column + 1,
    text: hashline_text(line),
  )
}

// A site's text is the line as the hashline tools see it, because its
// anchor is computed from it and must equal the one `fs_read` prints for
// the same line. Hashline splits on `\n` alone, so a CRLF line's `\r` is
// part of its content there; dropping it here would give every CRLF line
// an anchor `fs_edit` rejects as stale.
fn hashline_text(line: Line) -> String {
  case line.terminator {
    "\r\n" -> line.text <> "\r"
    _ -> line.text
  }
}

// --- Symbols -----------------------------------------------------------

/// The 1-based codepoint columns at which `symbol` occurs in `line_text`
/// on identifier boundaries, in order. An empty symbol occurs nowhere.
///
/// An identifier character is an ASCII letter, digit or `_`, or any
/// codepoint above U+007F. The rule is language-neutral on purpose:
/// Gleam, Go, Rust and TypeScript identifiers all fit it, and it knows
/// nothing about any one grammar. Counting *every* non-ASCII codepoint as
/// an identifier character, rather than only letters, is because the
/// standard library carries no Unicode category table and this module
/// takes no FFI; it errs toward not matching (`foo` is not found in
/// `foo→`), and a miss costs a `SymbolAbsent` the model can see, where a
/// false match would cost a wrong position it cannot.
///
/// The boundary is tested only on a side where the symbol itself begins
/// or ends with an identifier character, as a regular expression's `\b`
/// is: `foo` does not match in `foo_bar`, `xfoo` or `foo2`, while an
/// operator such as `<>` still matches in `a<>b`.
///
/// ## Examples
///
/// ```gleam
/// assert text.occurrences("foo(foo_bar, a.foo)", "foo") == [1, 17]
/// ```
pub fn occurrences(line_text: String, symbol: String) -> List(Int) {
  let needle = codes(symbol)
  case needle {
    [] -> []
    [first, ..rest] -> {
      let last = list.last(rest) |> result.unwrap(first)
      scan(codes(line_text), needle, #(first, last), None, 1, [])
    }
  }
}

/// The server position of the first character of `symbol`'s first
/// boundary occurrence on a 1-based `line` of `text`, which is how a
/// `path` + `line` + `symbol` query becomes something to send.
///
/// ## Examples
///
/// ```gleam
/// assert text.symbol_position("x\n😀 greet()", 2, "greet")
///   == Ok(range.Position(line: 1, character: 3))
/// ```
///
/// ```gleam
/// assert text.symbol_position("greeting", 1, "greet")
///   == Error(text.SymbolAbsent(line: 1, symbol: "greet"))
/// ```
pub fn symbol_position(
  text: String,
  line: Int,
  symbol: String,
) -> Result(Position, TextFault) {
  let indexed = document(text)
  use <- guard_line(line, indexed.count)
  let line_text = line_at(indexed, line - 1).text

  use column <- result.try(
    occurrences(line_text, symbol)
    |> list.first
    |> result.replace_error(SymbolAbsent(line:, symbol:)),
  )
  use character <- result.map(to_utf16_character(line_text, column))
  Position(line: line - 1, character:)
}

/// Refuse a 1-based line the document does not have, else continue.
fn guard_line(
  line: Int,
  count: Int,
  then: fn() -> Result(a, TextFault),
) -> Result(a, TextFault) {
  case line < 1 || line > count {
    True -> Error(LineOutOfRange(line:, line_count: count))
    False -> then()
  }
}

/// Slide `needle` along `haystack`, recording every column where it
/// matches on identifier boundaries. `previous` is the codepoint before
/// the current column, `None` at the start of the line.
fn scan(
  haystack: List(Int),
  needle: List(Int),
  edges: #(Int, Int),
  previous: Option(Int),
  column: Int,
  found: List(Int),
) -> List(Int) {
  case haystack {
    [] -> list.reverse(found)
    [code, ..rest] -> {
      let found = case matches_at(haystack, needle, edges, previous) {
        True -> [column, ..found]
        False -> found
      }
      scan(rest, needle, edges, Some(code), column + 1, found)
    }
  }
}

/// Whether `needle` starts `haystack` with a boundary on each side that
/// needs one. The needle's own first and last codepoints decide which
/// sides need one.
fn matches_at(
  haystack: List(Int),
  needle: List(Int),
  edges: #(Int, Int),
  previous: Option(Int),
) -> Bool {
  let #(first, last) = edges
  case strip_prefix(haystack, needle) {
    Error(Nil) -> False
    Ok(after) -> {
      let next = option.from_result(list.first(after))
      !joins(previous, first) && !joins(next, last)
    }
  }
}

/// Whether a neighbouring codepoint would run on into the symbol's edge
/// character, making the two one identifier.
fn joins(neighbour: Option(Int), edge: Int) -> Bool {
  case neighbour {
    None -> False
    Some(code) -> is_identifier(code) && is_identifier(edge)
  }
}

/// Remove `prefix` from the front of `list`, or fail if it is not there.
fn strip_prefix(list: List(Int), prefix: List(Int)) -> Result(List(Int), Nil) {
  case prefix, list {
    [], _ -> Ok(list)
    [want, ..more], [have, ..rest] if want == have -> strip_prefix(rest, more)
    [_, ..], _ -> Error(Nil)
  }
}

/// The identifier-character rule documented on `occurrences`.
fn is_identifier(code: Int) -> Bool {
  code == 0x5F
  || { code >= 0x30 && code <= 0x39 }
  || { code >= 0x41 && code <= 0x5A }
  || { code >= 0x61 && code <= 0x7A }
  || code > 0x7F
}

/// A string as its codepoints' integer values, for comparison.
fn codes(text: String) -> List(Int) {
  text
  |> string.to_utf_codepoints
  |> list.map(string.utf_codepoint_to_int)
}

// --- Edits -------------------------------------------------------------

/// Apply a server's edits to the exact text it computed them against.
///
/// Every range is converted against `base` — never against a partially
/// edited text, which is the mistake applying edits back-to-front exists
/// to prevent. This implementation has that property by construction: it
/// builds the result in one forward pass out of slices of `base` and the
/// edits' new text, so no offset is ever measured in anything but the
/// base. Untouched bytes, terminators included, are copied verbatim.
///
/// A range that starts after it ends is `InvertedRange`; two ranges that
/// overlap are `OverlappingEdits`. Insertions at one point keep the
/// order the server listed them in, as the specification requires; a
/// point insertion inside another edit's range is an overlap.
///
/// ## Examples
///
/// ```gleam
/// let edit = fn(line, from, to, new) {
///   range.TextEdit(range.Range(range.Position(line, from), range.Position(line, to)), new)
/// }
/// assert text.apply("fn greet() {}\r\ngreet()\r\n", [edit(0, 3, 8, "salute"), edit(1, 0, 5, "salute")])
///   == Ok("fn salute() {}\r\nsalute()\r\n")
/// ```
pub fn apply(base: String, edits: List(TextEdit)) -> Result(String, TextFault) {
  let indexed = document(base)
  use resolved <- result.try(list.try_map(edits, resolve_edit(indexed, _)))

  // Sorted by start only: the sort is stable, so edits at one point keep
  // the server's order, and a zero-width insertion listed after a
  // replacement starting at the same point then lands inside it and is
  // refused as an overlap below, which is what every editor does.
  let ordered = list.sort(resolved, fn(a, b) { compare(a.start, b.start) })
  use Nil <- result.try(refuse_overlaps(ordered))

  splice(indexed, ordered, Point(line: 0, column: 0), string_tree.new())
  |> string_tree.to_string
  |> Ok
}

/// Check that every edit's range selects exactly `old` in `base`. A
/// rename computed against a text that has since moved fails here and
/// costs nothing (ADR-013 §4). The first mismatch is the error.
///
/// ## Examples
///
/// ```gleam
/// let at = range.Range(range.Position(0, 3), range.Position(0, 8))
/// assert text.check_selects("fn greet()", [range.TextEdit(at, "salute")], "greet")
///   == Ok(Nil)
/// ```
pub fn check_selects(
  base: String,
  edits: List(TextEdit),
  old: String,
) -> Result(Nil, TextFault) {
  let indexed = document(base)
  list.try_each(edits, fn(edit) {
    use resolved <- result.try(resolve_edit(indexed, edit))
    let found =
      between(indexed, resolved.start, resolved.end)
      |> string_tree.to_string
    case found == old {
      True -> Ok(Nil)
      False ->
        Error(RangeSelects(
          range: edit.range,
          expected: old,
          found_length: string.length(found),
        ))
    }
  })
}

/// Resolve both ends of an edit against the base. The inversion test is
/// made on the server's own coordinates, before clamping, so a server
/// that sends a backwards range is told so even when clamping would have
/// collapsed it to something harmless.
fn resolve_edit(
  document: Document,
  edit: TextEdit,
) -> Result(Resolved, TextFault) {
  let Range(start:, end:) = edit.range
  use start_point <- result.try(resolve(document, start))
  use end_point <- result.try(resolve(document, end))
  case compare_positions(start, end) {
    order.Gt -> Error(InvertedRange(range: edit.range))
    order.Lt | order.Eq ->
      Ok(Resolved(
        start: start_point,
        end: end_point,
        range: edit.range,
        new_text: edit.new_text,
      ))
  }
}

/// Walk the edits in document order; each must begin at or after the
/// previous one's end.
fn refuse_overlaps(ordered: List(Resolved)) -> Result(Nil, TextFault) {
  case ordered {
    [] | [_] -> Ok(Nil)
    [first, second, ..rest] ->
      case compare(second.start, first.end) {
        order.Lt ->
          Error(OverlappingEdits(first: first.range, second: second.range))
        order.Eq | order.Gt -> refuse_overlaps([second, ..rest])
      }
  }
}

/// Emit the base from `cursor` up to the next edit, then that edit's new
/// text, and continue from the edit's end; after the last edit, emit the
/// rest of the base. `ordered` is sorted and overlap-free, so the cursor
/// only ever moves forward.
fn splice(
  document: Document,
  ordered: List(Resolved),
  cursor: Point,
  tree: StringTree,
) -> StringTree {
  case ordered {
    [] -> {
      let end_of_file = Point(line: document.count, column: 0)
      string_tree.append_tree(tree, between(document, cursor, end_of_file))
    }
    [edit, ..rest] -> {
      let tree =
        tree
        |> string_tree.append_tree(between(document, cursor, edit.start))
        |> string_tree.append(edit.new_text)
      splice(document, rest, edit.end, tree)
    }
  }
}

/// The base text from `from` up to `to`, with `from` not after `to`.
/// Whole lines in between are copied as they are, terminators included;
/// only the lines at either end are cut, and they are cut by codepoint.
fn between(document: Document, from: Point, to: Point) -> StringTree {
  let first = line_at(document, from.line)
  case from.line == to.line {
    True -> string_tree.from_string(cut(first.text, from.column, to.column))
    False -> {
      let head =
        string_tree.from_strings([
          cut_from(first.text, from.column),
          first.terminator,
        ])
      let body = whole_lines(document, from.line + 1, to.line, head)
      let last = line_at(document, to.line)
      string_tree.append(body, cut(last.text, 0, to.column))
    }
  }
}

/// Append every line from `line` up to, not including, `stop`.
fn whole_lines(
  document: Document,
  line: Int,
  stop: Int,
  tree: StringTree,
) -> StringTree {
  case line < stop {
    False -> tree
    True -> {
      let Line(text:, terminator:) = line_at(document, line)
      let tree =
        tree |> string_tree.append(text) |> string_tree.append(terminator)
      whole_lines(document, line + 1, stop, tree)
    }
  }
}

/// The codepoints of `text` from column `from` to the end of the line.
fn cut_from(text: String, from: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> list.drop(from)
  |> string.from_utf_codepoints
}

/// The codepoints of `text` from column `from` up to column `to`,
/// zero-based. Cutting by codepoint rather than with `string.slice`
/// matters: `string.slice` counts graphemes, and a grapheme may hold
/// several codepoints that the server counts separately.
fn cut(text: String, from: Int, to: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> list.drop(from)
  |> list.take(to - from)
  |> string.from_utf_codepoints
}

/// Document order on resolved points.
fn compare(a: Point, b: Point) -> Order {
  int.compare(a.line, b.line)
  |> order.break_tie(int.compare(a.column, b.column))
}

/// Document order on the server's own, unclamped positions.
fn compare_positions(a: Position, b: Position) -> Order {
  int.compare(a.line, b.line)
  |> order.break_tie(int.compare(a.character, b.character))
}

// --- Faults ------------------------------------------------------------

/// Render a fault as a sentence the model reads in a tool result. Server
/// positions are named in the server's own coordinates and labelled as
/// such, so a report is never mistaken for a 1-based line.
///
/// ## Examples
///
/// ```gleam
/// assert text.describe(text.SymbolAbsent(line: 4, symbol: "greet"))
///   == "`greet` does not occur as a whole identifier on line 4"
/// ```
pub fn describe(fault: TextFault) -> String {
  case fault {
    MalformedPosition(position:, reason: NegativeCoordinate) ->
      "the server sent a negative position (" <> show(position) <> ")"

    MalformedPosition(position:, reason: SplitsSurrogatePair) ->
      "the server's position ("
      <> show(position)
      <> ") falls between the two halves of one character"

    PositionOutOfRange(position:, line_count:) ->
      "the server's position ("
      <> show(position)
      <> ") lies beyond the end of a "
      <> int.to_string(line_count)
      <> "-line document"

    LineOutOfRange(line:, line_count:) ->
      "line "
      <> int.to_string(line)
      <> " does not exist; the file has "
      <> int.to_string(line_count)
      <> " lines"

    ColumnOutOfRange(column:, width:) ->
      "column "
      <> int.to_string(column)
      <> " is outside a line of "
      <> int.to_string(width)
      <> " characters"

    SymbolAbsent(line:, symbol:) ->
      "`"
      <> symbol
      <> "` does not occur as a whole identifier on line "
      <> int.to_string(line)

    InvertedRange(range:) ->
      "the server sent an edit whose range ends before it starts ("
      <> show_range(range)
      <> ")"

    OverlappingEdits(first:, second:) ->
      "the server sent overlapping edits ("
      <> show_range(first)
      <> " and "
      <> show_range(second)
      <> ")"

    // Only the span's length is rendered, beside the identifier the
    // caller named: see the variant's doc for why the text never is.
    RangeSelects(range:, expected:, found_length:) ->
      "an edit at "
      <> show_range(range)
      <> " selects "
      <> int.to_string(found_length)
      <> " characters where `"
      <> expected
      <> "` ("
      <> int.to_string(string.length(expected))
      <> " characters) was expected; the file changed since the server "
      <> "read it"
  }
}

/// A server position, labelled as zero-based UTF-16 so it is never read
/// as a 1-based line and column.
fn show(position: Position) -> String {
  "line "
  <> int.to_string(position.line)
  <> ", UTF-16 character "
  <> int.to_string(position.character)
  <> ", zero-based"
}

/// A server range as its two labelled ends.
fn show_range(range: Range) -> String {
  show(range.start) <> " to " <> show(range.end)
}
