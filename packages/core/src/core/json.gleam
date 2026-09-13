//// A pattern-matchable JSON value type with a total parser and serializer.
////
//// `core` depends on nothing but the standard library, and the `Json` type
//// named by the frozen interface contracts must be inspectable by pure
//// code, so this module defines its own `JsonValue` ADT rather than using
//// an opaque builder type. The parser is a total decoder: any input that is
//// not a single well-formed JSON document yields `Error(CorruptionReport)`,
//// never a crash.
////
//// Notes on fidelity:
////
//// - Numbers without a fraction or exponent parse as `Int` (arbitrary
////   precision); numbers with either parse as `Float`. A float literal
////   whose magnitude exceeds the IEEE 754 double range is reported as
////   corruption rather than rounded to infinity, which the BEAM cannot
////   represent.
//// - Object fields keep their textual order. A duplicated key within one
////   object is corruption: decoders disagree on duplicate-key precedence
////   (first- versus last-occurrence wins), so at a durability boundary a
////   document carrying duplicates has no single meaning — the parser
////   rejects it rather than picking one. Data this module serialized
////   never contains duplicates, so nothing well-formed is lost.
//// - Containers (objects and arrays) may nest at most `max_depth` levels
////   deep. Deeper input — cheap to fabricate adversarially, one `[` per
////   level — is a corruption report, never a runaway recursion that
////   exhausts the parsing process's stack or heap.
//// - Strings must be valid JSON: unescaped control characters are
////   rejected, `\uXXXX` escapes are decoded including surrogate pairs, and
////   lone surrogates are rejected.

import core/corruption.{type CorruptionReport}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

/// The maximum container nesting depth `parse` accepts: objects and arrays
/// may nest at most this many levels deep. Generous for real durable
/// payloads (entries and register values nest a handful of levels); the
/// bound exists so hostile input is refused in-band instead of driving
/// the parser into unbounded recursion.
pub const max_depth = 256

/// A JSON document as plain data. Constructors carry no invariants beyond
/// their types except:
///
/// - `Object`: field order is meaningful and preserved; field names must
///   be unique — `parse` never produces duplicates (a duplicated key is
///   corruption), and a hand-built object with duplicated names
///   serializes to text that will not parse back. Readers that look
///   fields up take the first occurrence as the tiebreak for hand-built
///   values.
/// - `Object`/`Array`: containers nest at most `max_depth` levels; a
///   deeper value serializes to text that will not parse back.
/// - `Float`: always a finite IEEE 754 double (the BEAM has no NaN or
///   infinity), so serialization is always well-formed JSON.
pub type JsonValue {
  /// A JSON object as an ordered field list.
  Object(fields: List(#(String, JsonValue)))

  /// A JSON array.
  Array(items: List(JsonValue))

  /// A JSON string.
  String(value: String)

  /// A JSON number with no fraction or exponent part. Arbitrary precision.
  Int(value: Int)

  /// A JSON number with a fraction or exponent part. Always finite.
  Float(value: Float)

  /// A JSON boolean.
  Bool(value: Bool)

  /// The JSON null.
  Null
}

/// Parses a single JSON document. Total: every failure — malformed syntax,
/// trailing content, invalid escapes, lone surrogates, unrepresentable
/// numbers, duplicated object keys, containers nested past `max_depth` —
/// is a `CorruptionReport`, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert json.parse("[1, true, \"hi\"]")
///   == Ok(json.Array([json.Int(1), json.Bool(True), json.String("hi")]))
/// ```
///
/// ```gleam
/// let assert Error(_report) = json.parse("{\"open\": ")
/// ```
///
pub fn parse(text: String) -> Result(JsonValue, CorruptionReport) {
  let bytes = <<text:utf8>>
  let cursor = Cursor(rest: bytes, source: bytes, consumed: 0)
  use #(value, cursor) <- result.try(parse_value(skip_whitespace(cursor), 0))
  let cursor = skip_whitespace(cursor)
  case bit_array.byte_size(cursor.rest) {
    0 -> Ok(value)
    _ -> Error(fail(cursor, "end of input after the document"))
  }
}

/// Serializes a value to compact JSON text. The output always parses back
/// to an equal value: strings escape `"`, `\`, and all control characters;
/// floats print with a decimal point or exponent so they stay floats.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(json.Object([#("a", json.Int(1))])) == "{\"a\":1}"
/// ```
///
pub fn to_string(value: JsonValue) -> String {
  value
  |> build
  |> string_tree.to_string
}

// --- serialization ------------------------------------------------------

fn build(value: JsonValue) -> StringTree {
  case value {
    Null -> string_tree.from_string("null")
    Bool(True) -> string_tree.from_string("true")
    Bool(False) -> string_tree.from_string("false")
    Int(value:) -> string_tree.from_string(int.to_string(value))
    Float(value:) -> string_tree.from_string(float.to_string(value))
    String(value:) -> build_string(value)
    Array(items:) ->
      items
      |> list.map(build)
      |> string_tree.join(with: ",")
      |> wrap("[", "]")
    Object(fields:) ->
      fields
      |> list.map(fn(field) {
        let #(name, field_value) = field
        build_string(name)
        |> string_tree.append(":")
        |> string_tree.append_tree(build(field_value))
      })
      |> string_tree.join(with: ",")
      |> wrap("{", "}")
  }
}

fn wrap(tree: StringTree, open: String, close: String) -> StringTree {
  tree
  |> string_tree.prepend(open)
  |> string_tree.append(close)
}

fn build_string(text: String) -> StringTree {
  let bytes = <<text:utf8>>
  let size = bit_array.byte_size(bytes)

  // Most strings need no escape at all, and for those the original text
  // goes out as it is: no slice, and no re-validation of bytes that were
  // a `String` a moment ago. Only a string with something to escape is
  // cut into runs.
  case clean_run(bytes, 0) == size {
    True ->
      string_tree.from_string("\"")
      |> string_tree.append(text)
      |> string_tree.append("\"")
    False ->
      case escape_runs(string_tree.from_string("\""), bytes, bytes, 0, 0) {
        Ok(tree) -> string_tree.append(tree, "\"")
        Error(Nil) -> build_string_by_codepoint(text)
      }
  }
}

// Walks the string's bytes once and emits every run that needs no escape
// as a single slice. JSON escapes only `"`, `\` and the C0 controls, all
// of which are ASCII, and no byte of a multi-byte UTF-8 sequence is below
// 0x80, so a byte scan can neither split a codepoint nor miss an escape.
// The pattern keeps the BEAM's match context alive across the loop, so
// each step costs a byte compare rather than a new binary; the slices
// are validated in place, not copied. This was a per-codepoint fold that
// built one binary per character, and on a 1.3 MB request body it was the
// whole of the encode time (issue #359).
fn escape_runs(
  tree: StringTree,
  whole: BitArray,
  rest: BitArray,
  run_start: Int,
  at: Int,
) -> Result(StringTree, Nil) {
  case rest {
    <<byte, more:bits>> if byte == 0x22 || byte == 0x5C || byte < 0x20 -> {
      use tree <- result.try(flush_run(tree, whole, run_start, at))
      escape_runs(
        string_tree.append(tree, escape_of(byte)),
        whole,
        more,
        at + 1,
        at + 1,
      )
    }
    <<_, more:bits>> -> escape_runs(tree, whole, more, run_start, at + 1)
    _ -> flush_run(tree, whole, run_start, at)
  }
}

// Appends `whole[run_start, at)` as one chunk. Both bounds come from the
// same walk over `whole`, so the slice cannot be out of range and, cut at
// ASCII, cannot be invalid UTF-8; the `Result` is what keeps this total
// without a `let assert`, and the caller falls back to the slow path.
fn flush_run(
  tree: StringTree,
  whole: BitArray,
  run_start: Int,
  at: Int,
) -> Result(StringTree, Nil) {
  case at > run_start {
    False -> Ok(tree)
    True -> {
      use run <- result.try(bit_array.slice(whole, run_start, at - run_start))
      use text <- result.try(bit_array.to_string(run))
      Ok(string_tree.append(tree, text))
    }
  }
}

fn escape_of(byte: Int) -> String {
  case byte {
    0x22 -> "\\\""
    0x5C -> "\\\\"
    0x08 -> "\\b"
    0x0C -> "\\f"
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    _ ->
      "\\u"
      <> string.pad_start(
        string.lowercase(int.to_base16(byte)),
        to: 4,
        with: "0",
      )
  }
}

// The reference encoder, one codepoint at a time. It is the fallback for
// the impossible slice failure above and the oracle the tests compare the
// run-based encoder against.
@internal
pub fn build_string_by_codepoint(text: String) -> StringTree {
  text
  |> string.to_utf_codepoints
  |> list.fold(from: string_tree.from_string("\""), with: fn(tree, codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    case code == 0x22 || code == 0x5C || code < 0x20 {
      True -> string_tree.append(tree, escape_of(code))
      False -> string_tree.append(tree, string.from_utf_codepoints([codepoint]))
    }
  })
  |> string_tree.append("\"")
}

// --- parsing ------------------------------------------------------------

// The unread input, the whole document it came from, and how many bytes
// of it have been consumed. The parser walks `rest` with byte patterns,
// which the BEAM compiles to a match context that advances without
// allocating, and cuts strings and digit runs out of `source` as slices
// that are validated in place rather than rebuilt. It used to hold the
// document as a list of codepoint integers and rebuild every string one
// codepoint at a time; on a 5 MB branch that was tens of millions of heap
// words per projection and most of the server's per-step CPU (issue #359).
type Cursor {
  Cursor(rest: BitArray, source: BitArray, consumed: Int)
}

fn fail(cursor: Cursor, expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/json.parse",
    on: "codepoint offset " <> int.to_string(codepoint_offset(cursor)),
    expected:,
    context: excerpt(cursor.rest),
  )
}

// The report keeps counting in codepoints, as it always has, and pays for
// the count only when there is a report to write.
fn codepoint_offset(cursor: Cursor) -> Int {
  bit_array.slice(cursor.source, 0, cursor.consumed)
  |> result.try(bit_array.to_string)
  |> result.map(fn(prefix) { list.length(string.to_utf_codepoints(prefix)) })
  |> result.unwrap(cursor.consumed)
}

// Shows at most 24 codepoints of remaining input in a report.
fn excerpt(rest: BitArray) -> String {
  case bit_array.byte_size(rest) {
    0 -> "end of input"
    size -> {
      // Up to 96 bytes covers 24 codepoints of any width; a cut that lands
      // inside a codepoint is backed off until the prefix is valid UTF-8.
      let window = int.min(size, 96)
      let prefix = valid_prefix(rest, window)
      let shown = string.slice(prefix, 0, 24)
      case window < size || string.length(shown) < string.length(prefix) {
        True -> shown <> "…"
        False -> shown
      }
    }
  }
}

fn valid_prefix(rest: BitArray, length: Int) -> String {
  case length <= 0 {
    True -> ""
    False ->
      case bit_array.slice(rest, 0, length) |> result.try(bit_array.to_string) {
        Ok(text) -> text
        Error(Nil) -> valid_prefix(rest, length - 1)
      }
  }
}

fn advance(cursor: Cursor, rest: BitArray, by count: Int) -> Cursor {
  Cursor(..cursor, rest:, consumed: cursor.consumed + count)
}

fn skip_whitespace(cursor: Cursor) -> Cursor {
  case cursor.rest {
    <<byte, rest:bits>>
      if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    -> skip_whitespace(advance(cursor, rest, by: 1))
    _ -> cursor
  }
}

// `depth` counts the containers already entered; a new object or array is
// admitted only while `depth < max_depth`, which bounds the recursion.
fn parse_value(
  cursor: Cursor,
  depth: Int,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  case cursor.rest {
    <<0x7B, rest:bits>> -> {
      use Nil <- result.try(check_depth(cursor, depth))
      parse_members(
        advance(cursor, rest, by: 1),
        [],
        dict.new(),
        expect_first: True,
        depth: depth + 1,
      )
    }
    <<0x5B, rest:bits>> -> {
      use Nil <- result.try(check_depth(cursor, depth))
      parse_items(
        advance(cursor, rest, by: 1),
        [],
        expect_first: True,
        depth: depth + 1,
      )
    }
    <<0x22, rest:bits>> -> {
      use #(text, cursor) <- result.try(
        parse_string_body(advance(cursor, rest, by: 1), []),
      )
      Ok(#(String(text), cursor))
    }
    <<"true":utf8, rest:bits>> ->
      Ok(#(Bool(True), advance(cursor, rest, by: 4)))
    <<"false":utf8, rest:bits>> ->
      Ok(#(Bool(False), advance(cursor, rest, by: 5)))
    <<"null":utf8, rest:bits>> -> Ok(#(Null, advance(cursor, rest, by: 4)))
    <<byte, _:bits>> if byte == 0x2D || { byte >= 0x30 && byte <= 0x39 } ->
      parse_number(cursor)
    _ -> Error(fail(cursor, "a json value"))
  }
}

// --- objects and arrays -------------------------------------------------

// `seen` indexes the field names parsed so far in this object, so
// duplicate detection costs one dict probe per field rather than a
// quadratic rescan an adversarial many-field object could exploit.
fn parse_members(
  cursor: Cursor,
  fields: List(#(String, JsonValue)),
  seen: Dict(String, Nil),
  expect_first expect_first: Bool,
  depth depth: Int,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let cursor = skip_whitespace(cursor)
  case cursor.rest, expect_first {
    <<0x7D, rest:bits>>, True -> Ok(#(Object([]), advance(cursor, rest, by: 1)))
    _, _ -> {
      use #(#(name, value), cursor) <- result.try(parse_member(cursor, depth))
      use Nil <- result.try(check_unique_key(cursor, seen, name))
      let fields = [#(name, value), ..fields]
      let seen = dict.insert(seen, name, Nil)
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        <<0x2C, rest:bits>> ->
          parse_members(
            advance(cursor, rest, by: 1),
            fields,
            seen,
            expect_first: False,
            depth:,
          )
        <<0x7D, rest:bits>> ->
          Ok(#(Object(list.reverse(fields)), advance(cursor, rest, by: 1)))
        _ -> Error(fail(cursor, "\",\" or \"}\" in an object"))
      }
    }
  }
}

fn check_unique_key(
  cursor: Cursor,
  seen: Dict(String, Nil),
  name: String,
) -> Result(Nil, CorruptionReport) {
  case dict.has_key(seen, name) {
    False -> Ok(Nil)
    True ->
      Error(fail(cursor, "unique object keys (\"" <> name <> "\" repeats)"))
  }
}

fn parse_member(
  cursor: Cursor,
  depth: Int,
) -> Result(#(#(String, JsonValue), Cursor), CorruptionReport) {
  case cursor.rest {
    <<0x22, rest:bits>> -> {
      use #(name, cursor) <- result.try(
        parse_string_body(advance(cursor, rest, by: 1), []),
      )
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        <<0x3A, rest:bits>> -> {
          use #(value, cursor) <- result.try(parse_value(
            skip_whitespace(advance(cursor, rest, by: 1)),
            depth,
          ))
          Ok(#(#(name, value), cursor))
        }
        _ -> Error(fail(cursor, "\":\" after an object key"))
      }
    }
    _ -> Error(fail(cursor, "a string object key"))
  }
}

fn parse_items(
  cursor: Cursor,
  items: List(JsonValue),
  expect_first expect_first: Bool,
  depth depth: Int,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let cursor = skip_whitespace(cursor)
  case cursor.rest, expect_first {
    <<0x5D, rest:bits>>, True -> Ok(#(Array([]), advance(cursor, rest, by: 1)))
    _, _ -> {
      use #(item, cursor) <- result.try(parse_value(cursor, depth))
      let items = [item, ..items]
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        <<0x2C, rest:bits>> ->
          parse_items(
            advance(cursor, rest, by: 1),
            items,
            expect_first: False,
            depth:,
          )
        <<0x5D, rest:bits>> ->
          Ok(#(Array(list.reverse(items)), advance(cursor, rest, by: 1)))
        _ -> Error(fail(cursor, "\",\" or \"]\" in an array"))
      }
    }
  }
}

fn check_depth(cursor: Cursor, depth: Int) -> Result(Nil, CorruptionReport) {
  case depth < max_depth {
    True -> Ok(Nil)
    False ->
      Error(fail(
        cursor,
        "containers nested at most "
          <> int.to_string(max_depth)
          <> " levels deep",
      ))
  }
}

// --- strings ------------------------------------------------------------

// A string body is runs of bytes that need no attention, cut out as
// slices, separated by the three things that do: the closing quote, an
// escape, and a control character that should have been escaped.
fn parse_string_body(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  let run = clean_run(cursor.rest, 0)
  use #(chunk, after) <- result.try(cut(cursor, run))
  let chunks = case chunk {
    "" -> chunks
    _ -> [chunk, ..chunks]
  }
  let cursor = advance(cursor, after, by: run)
  case after {
    <<0x22, rest:bits>> ->
      Ok(#(string.concat(list.reverse(chunks)), advance(cursor, rest, by: 1)))
    <<0x5C, rest:bits>> -> parse_escape(advance(cursor, rest, by: 1), chunks)
    <<_, _:bits>> ->
      Error(fail(cursor, "control characters to be escaped in a string"))
    _ -> Error(fail(cursor, "a closing \" before end of input"))
  }
}

// How many leading bytes are neither a quote, a backslash nor a control.
// Every byte of a multi-byte codepoint is at least 0x80, so the count can
// only stop on an ASCII byte and the run it measures is whole codepoints.
fn clean_run(rest: BitArray, count: Int) -> Int {
  case rest {
    <<byte, more:bits>> if byte != 0x22 && byte != 0x5C && byte >= 0x20 ->
      clean_run(more, count + 1)
    _ -> count
  }
}

// The first `length` bytes of the unread input as text, and what follows
// them. Both slices are within a binary the caller has just walked, and a
// cut made at an ASCII byte of valid UTF-8 is valid UTF-8, so the error
// arm is the totality the durability boundary demands rather than a case
// that can occur.
fn cut(
  cursor: Cursor,
  length: Int,
) -> Result(#(String, BitArray), CorruptionReport) {
  let size = bit_array.byte_size(cursor.rest)
  let pieces = {
    use run <- result.try(bit_array.slice(cursor.rest, 0, length))
    use text <- result.try(bit_array.to_string(run))
    use after <- result.try(bit_array.slice(cursor.rest, length, size - length))
    Ok(#(text, after))
  }
  result.map_error(pieces, fn(_) { fail(cursor, "a valid utf-8 string") })
}

fn parse_escape(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    <<0x22, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\"", ..chunks])
    <<0x5C, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\\", ..chunks])
    <<0x2F, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["/", ..chunks])
    <<0x62, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\u{0008}", ..chunks])
    <<0x66, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\u{000C}", ..chunks])
    <<0x6E, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\n", ..chunks])
    <<0x72, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\r", ..chunks])
    <<0x74, rest:bits>> ->
      parse_string_body(advance(cursor, rest, by: 1), ["\t", ..chunks])
    <<0x75, rest:bits>> ->
      parse_unicode_escape(advance(cursor, rest, by: 1), chunks)
    _ -> Error(fail(cursor, "a valid escape character"))
  }
}

fn parse_unicode_escape(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  use #(code, after_first) <- result.try(parse_hex_4(cursor))
  case code >= 0xD800 && code <= 0xDBFF {
    True -> {
      use #(low, after_second) <- result.try(case after_first.rest {
        <<0x5C, 0x75, rest:bits>> ->
          parse_hex_4(advance(after_first, rest, by: 2))
        _ -> Error(fail(after_first, "a low surrogate escape"))
      })
      use <- bool.lazy_guard(when: low < 0xDC00 || low > 0xDFFF, return: fn() {
        Error(fail(after_first, "a low surrogate escape"))
      })
      let combined = 0x10000 + { code - 0xD800 } * 0x400 + { low - 0xDC00 }
      append_codepoint(after_second, chunks, combined)
    }
    False -> append_codepoint(after_first, chunks, code)
  }
}

fn append_codepoint(
  cursor: Cursor,
  chunks: List(String),
  code: Int,
) -> Result(#(String, Cursor), CorruptionReport) {
  case string.utf_codepoint(code) {
    Ok(codepoint) ->
      parse_string_body(cursor, [
        string.from_utf_codepoints([codepoint]),
        ..chunks
      ])
    Error(Nil) ->
      Error(fail(cursor, "a valid unicode escape, not a lone surrogate"))
  }
}

fn parse_hex_4(cursor: Cursor) -> Result(#(Int, Cursor), CorruptionReport) {
  case cursor.rest {
    <<a, b, c, d, rest:bits>> ->
      case hex_value(a), hex_value(b), hex_value(c), hex_value(d) {
        Ok(a), Ok(b), Ok(c), Ok(d) ->
          Ok(#(
            { { a * 16 + b } * 16 + c } * 16 + d,
            advance(cursor, rest, by: 4),
          ))
        _, _, _, _ -> Error(fail(cursor, "four hexadecimal digits"))
      }
    _ -> Error(fail(cursor, "four hexadecimal digits"))
  }
}

fn hex_value(code: Int) -> Result(Int, Nil) {
  use <- bool.guard(when: code >= 0x30 && code <= 0x39, return: Ok(code - 0x30))
  use <- bool.guard(
    when: code >= 0x61 && code <= 0x66,
    return: Ok(code - 0x61 + 10),
  )
  use <- bool.guard(
    when: code >= 0x41 && code <= 0x46,
    return: Ok(code - 0x41 + 10),
  )
  Error(Nil)
}

// --- numbers ------------------------------------------------------------

// Digits are cut out as one slice rather than accumulated one integer at a
// time; the grammar checks (no leading zero, digits after a point or an
// exponent) are made on the bytes before the slice is taken.
fn parse_number(
  cursor: Cursor,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let start = cursor
  let #(negative, cursor) = case cursor.rest {
    <<0x2D, rest:bits>> -> #(True, advance(cursor, rest, by: 1))
    _ -> #(False, cursor)
  }
  use #(int_digits, cursor) <- result.try(parse_integer_digits(cursor))
  use #(frac_digits, cursor) <- result.try(parse_fraction(cursor))
  use #(exponent, cursor) <- result.try(parse_exponent(cursor))
  case frac_digits, exponent {
    "", "" ->
      case int.parse(int_digits) {
        Ok(value) -> Ok(#(Int(apply_sign(value, negative)), cursor))
        Error(Nil) -> Error(fail(start, "a decimal integer"))
      }
    _, _ ->
      finish_float(start, cursor, negative, int_digits, frac_digits, exponent)
  }
}

fn parse_fraction(
  cursor: Cursor,
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    <<0x2E, rest:bits>> -> {
      let after = advance(cursor, rest, by: 1)
      use #(digits, after) <- result.try(take_digits(after))
      case digits {
        "" -> Error(fail(cursor, "digits after the decimal point"))
        _ -> Ok(#(digits, after))
      }
    }
    _ -> Ok(#("", cursor))
  }
}

fn parse_integer_digits(
  cursor: Cursor,
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    <<0x30, next, _:bits>> if next >= 0x30 && next <= 0x39 ->
      Error(fail(cursor, "no leading zero in a number"))
    <<byte, _:bits>> if byte >= 0x30 && byte <= 0x39 -> take_digits(cursor)
    _ -> Error(fail(cursor, "a digit"))
  }
}

fn take_digits(cursor: Cursor) -> Result(#(String, Cursor), CorruptionReport) {
  let run = digit_run(cursor.rest, 0)
  use #(digits, after) <- result.try(cut(cursor, run))
  Ok(#(digits, advance(cursor, after, by: run)))
}

fn digit_run(rest: BitArray, count: Int) -> Int {
  case rest {
    <<byte, more:bits>> if byte >= 0x30 && byte <= 0x39 ->
      digit_run(more, count + 1)
    _ -> count
  }
}

fn parse_exponent(
  cursor: Cursor,
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    <<byte, rest:bits>> if byte == 0x65 || byte == 0x45 -> {
      let cursor = advance(cursor, rest, by: 1)
      let #(sign, cursor) = case cursor.rest {
        <<0x2D, rest:bits>> -> #("-", advance(cursor, rest, by: 1))
        <<0x2B, rest:bits>> -> #("", advance(cursor, rest, by: 1))
        _ -> #("", cursor)
      }
      use #(digits, cursor) <- result.try(take_digits(cursor))
      case digits {
        "" -> Error(fail(cursor, "digits in the exponent"))
        _ -> Ok(#("e" <> sign <> digits, cursor))
      }
    }
    _ -> Ok(#("", cursor))
  }
}

fn finish_float(
  start: Cursor,
  cursor: Cursor,
  negative: Bool,
  int_digits: String,
  frac_digits: String,
  exponent: String,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let sign = case negative {
    True -> "-"
    False -> ""
  }
  let fraction = case frac_digits {
    "" -> "0"
    _ -> frac_digits
  }
  let literal = sign <> int_digits <> "." <> fraction <> exponent
  case float.parse(literal) {
    Ok(value) -> Ok(#(Float(value), cursor))
    Error(Nil) ->
      Error(fail(start, "a number representable as an ieee 754 double"))
  }
}

fn apply_sign(value: Int, negative: Bool) -> Int {
  case negative {
    True -> -value
    False -> value
  }
}
