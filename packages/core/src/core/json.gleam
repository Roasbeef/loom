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
  let cursor =
    Cursor(
      rest: list.map(
        string.to_utf_codepoints(text),
        string.utf_codepoint_to_int,
      ),
      offset: 0,
    )
  use #(value, cursor) <- result.try(parse_value(skip_whitespace(cursor), 0))
  let cursor = skip_whitespace(cursor)
  case cursor.rest {
    [] -> Ok(value)
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
  text
  |> string.to_utf_codepoints
  |> list.fold(from: string_tree.from_string("\""), with: fn(tree, codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    case code {
      0x22 -> string_tree.append(tree, "\\\"")
      0x5C -> string_tree.append(tree, "\\\\")
      0x08 -> string_tree.append(tree, "\\b")
      0x0C -> string_tree.append(tree, "\\f")
      0x0A -> string_tree.append(tree, "\\n")
      0x0D -> string_tree.append(tree, "\\r")
      0x09 -> string_tree.append(tree, "\\t")
      _ ->
        case code < 0x20 {
          True ->
            string_tree.append(
              tree,
              "\\u"
                <> string.pad_start(
                string.lowercase(int.to_base16(code)),
                to: 4,
                with: "0",
              ),
            )
          False ->
            string_tree.append(tree, string.from_utf_codepoints([codepoint]))
        }
    }
  })
  |> string_tree.append("\"")
}

// --- parsing ------------------------------------------------------------

/// Parser position: the remaining input as codepoint values plus the count
/// of codepoints already consumed, for error reporting.
type Cursor {
  Cursor(rest: List(Int), offset: Int)
}

fn fail(cursor: Cursor, expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/json.parse",
    on: "codepoint offset " <> int.to_string(cursor.offset),
    expected:,
    context: excerpt(cursor.rest),
  )
}

// Shows at most 24 codepoints of remaining input in a report.
fn excerpt(rest: List(Int)) -> String {
  let shown =
    rest
    |> list.take(24)
    |> list.filter_map(string.utf_codepoint)
    |> string.from_utf_codepoints
  // `list.drop` stops at 24; `list.length` would walk the whole tail,
  // which is what made a report on a hot path cost the rest of the input.
  case list.drop(rest, 24) != [] {
    True -> shown <> "…"
    False ->
      case rest {
        [] -> "end of input"
        _ -> shown
      }
  }
}

fn advance(cursor: Cursor, rest: List(Int), by count: Int) -> Cursor {
  Cursor(rest:, offset: cursor.offset + count)
}

fn skip_whitespace(cursor: Cursor) -> Cursor {
  case cursor.rest {
    [0x20, ..rest] | [0x09, ..rest] | [0x0A, ..rest] | [0x0D, ..rest] ->
      skip_whitespace(advance(cursor, rest, by: 1))
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
    [0x7B, ..rest] -> {
      use Nil <- result.try(check_depth(cursor, depth))
      parse_members(
        advance(cursor, rest, by: 1),
        [],
        dict.new(),
        expect_first: True,
        depth: depth + 1,
      )
    }
    [0x5B, ..rest] -> {
      use Nil <- result.try(check_depth(cursor, depth))
      parse_items(
        advance(cursor, rest, by: 1),
        [],
        expect_first: True,
        depth: depth + 1,
      )
    }
    [0x22, ..rest] -> {
      use #(text, cursor) <- result.try(
        parse_string_body(advance(cursor, rest, by: 1), []),
      )
      Ok(#(String(text), cursor))
    }
    [0x74, 0x72, 0x75, 0x65, ..rest] ->
      Ok(#(Bool(True), advance(cursor, rest, by: 4)))
    [0x66, 0x61, 0x6C, 0x73, 0x65, ..rest] ->
      Ok(#(Bool(False), advance(cursor, rest, by: 5)))
    [0x6E, 0x75, 0x6C, 0x6C, ..rest] ->
      Ok(#(Null, advance(cursor, rest, by: 4)))
    [code, ..] ->
      case code == 0x2D || is_digit(code) {
        True -> parse_number(cursor)
        False -> Error(fail(cursor, "a json value"))
      }
    [] -> Error(fail(cursor, "a json value"))
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
    [0x7D, ..rest], True -> Ok(#(Object([]), advance(cursor, rest, by: 1)))
    _, _ -> {
      use #(#(name, value), cursor) <- result.try(parse_member(cursor, depth))
      use Nil <- result.try(check_unique_key(cursor, seen, name))
      let fields = [#(name, value), ..fields]
      let seen = dict.insert(seen, name, Nil)
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        [0x2C, ..rest] ->
          parse_members(
            advance(cursor, rest, by: 1),
            fields,
            seen,
            expect_first: False,
            depth:,
          )
        [0x7D, ..rest] ->
          Ok(#(Object(list.reverse(fields)), advance(cursor, rest, by: 1)))
        _ -> Error(fail(cursor, "\",\" or \"}\" in an object"))
      }
    }
  }
}

// Refuses a field name that already appeared earlier in this object.
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
    [0x22, ..rest] -> {
      use #(name, cursor) <- result.try(
        parse_string_body(advance(cursor, rest, by: 1), []),
      )
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        [0x3A, ..rest] -> {
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
    [0x5D, ..rest], True -> Ok(#(Array([]), advance(cursor, rest, by: 1)))
    _, _ -> {
      use #(item, cursor) <- result.try(parse_value(cursor, depth))
      let items = [item, ..items]
      let cursor = skip_whitespace(cursor)
      case cursor.rest {
        [0x2C, ..rest] ->
          parse_items(
            advance(cursor, rest, by: 1),
            items,
            expect_first: False,
            depth:,
          )
        [0x5D, ..rest] ->
          Ok(#(Array(list.reverse(items)), advance(cursor, rest, by: 1)))
        _ -> Error(fail(cursor, "\",\" or \"]\" in an array"))
      }
    }
  }
}

// Refuses to open one more container once `max_depth` levels are already
// open, keeping parser recursion bounded by a constant.
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

// Accumulates decoded chunks in reverse; called after the opening quote.
fn parse_string_body(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    [0x22, ..rest] ->
      Ok(#(string.concat(list.reverse(chunks)), advance(cursor, rest, by: 1)))
    [0x5C, ..rest] -> parse_escape(advance(cursor, rest, by: 1), chunks)
    // Both arms below stay a plain `case` on purpose. This runs once per
    // character of every string in every document the harness decodes,
    // and each `use` here costs a heap-allocated closure per character:
    // `bool.lazy_guard` alone is two, and `result.try` over
    // `result.map_error` is two more. Measured at 1.75x on an 8 KB
    // string. The style guide's escape hatch is the whole of the reason
    // — a plain `case` is always correct and sometimes clearest.
    [code, ..rest] ->
      case code < 0x20 {
        True ->
          Error(fail(cursor, "control characters to be escaped in a string"))
        False ->
          // Unreachable in practice: the input came from a valid string,
          // so every non-surrogate codepoint is valid. Reported totally.
          case string.utf_codepoint(code) {
            Error(_) -> Error(fail(cursor, "a valid unicode codepoint"))
            Ok(codepoint) ->
              parse_string_body(advance(cursor, rest, by: 1), [
                string.from_utf_codepoints([codepoint]),
                ..chunks
              ])
          }
      }
    [] -> Error(fail(cursor, "a closing \" before end of input"))
  }
}

fn parse_escape(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    [0x22, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\"", ..chunks])
    [0x5C, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\\", ..chunks])
    [0x2F, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["/", ..chunks])
    [0x62, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\u{0008}", ..chunks])
    [0x66, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\u{000C}", ..chunks])
    [0x6E, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\n", ..chunks])
    [0x72, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\r", ..chunks])
    [0x74, ..rest] ->
      parse_string_body(advance(cursor, rest, by: 1), ["\t", ..chunks])
    [0x75, ..rest] -> parse_unicode_escape(advance(cursor, rest, by: 1), chunks)
    _ -> Error(fail(cursor, "a valid escape character"))
  }
}

fn parse_unicode_escape(
  cursor: Cursor,
  chunks: List(String),
) -> Result(#(String, Cursor), CorruptionReport) {
  use #(code, after_first) <- result.try(parse_hex_4(cursor))
  case code >= 0xD800 && code <= 0xDBFF {
    // A high surrogate must pair with a following \uXXXX low surrogate.
    True -> {
      use #(low, after_second) <- result.try(case after_first.rest {
        [0x5C, 0x75, ..rest] -> parse_hex_4(advance(after_first, rest, by: 2))
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
    [a, b, c, d, ..rest] ->
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

fn is_digit(code: Int) -> Bool {
  code >= 0x30 && code <= 0x39
}

// JSON number grammar: -? int frac? exp?. Integers with neither fraction
// nor exponent become `Int`; anything else becomes `Float`.
fn parse_number(
  cursor: Cursor,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let start = cursor
  let #(negative, cursor) = case cursor.rest {
    [0x2D, ..rest] -> #(True, advance(cursor, rest, by: 1))
    _ -> #(False, cursor)
  }
  use #(int_digits, cursor) <- result.try(parse_integer_digits(cursor))
  use #(frac_digits, cursor) <- result.try(parse_fraction(cursor))
  use #(exponent, cursor) <- result.try(parse_exponent(cursor))
  case frac_digits, exponent {
    [], "" ->
      Ok(#(Int(apply_sign(digits_to_int(int_digits), negative)), cursor))
    _, _ ->
      finish_float(start, cursor, negative, int_digits, frac_digits, exponent)
  }
}

// The fraction part: a "." followed by at least one digit; absent entirely
// is legal (empty digit list, cursor unmoved).
fn parse_fraction(
  cursor: Cursor,
) -> Result(#(List(Int), Cursor), CorruptionReport) {
  case cursor.rest {
    [0x2E, ..rest] ->
      case take_digits(advance(cursor, rest, by: 1)) {
        #([], _) -> Error(fail(cursor, "digits after the decimal point"))
        #(digits, cursor) -> Ok(#(digits, cursor))
      }
    _ -> Ok(#([], cursor))
  }
}

// The integer part: "0", or a nonzero digit followed by digits. Leading
// zeros are rejected per the JSON grammar.
fn parse_integer_digits(
  cursor: Cursor,
) -> Result(#(List(Int), Cursor), CorruptionReport) {
  case cursor.rest {
    [0x30, next, ..] -> {
      use <- bool.lazy_guard(when: is_digit(next), return: fn() {
        Error(fail(cursor, "no leading zero in a number"))
      })
      Ok(take_digits(cursor))
    }
    [code, ..] -> {
      use <- bool.lazy_guard(when: !is_digit(code), return: fn() {
        Error(fail(cursor, "a digit"))
      })
      Ok(take_digits(cursor))
    }
    [] -> Error(fail(cursor, "a digit"))
  }
}

fn take_digits(cursor: Cursor) -> #(List(Int), Cursor) {
  take_digits_loop(cursor, [])
}

fn take_digits_loop(
  cursor: Cursor,
  accumulator: List(Int),
) -> #(List(Int), Cursor) {
  case cursor.rest {
    [code, ..rest] ->
      case is_digit(code) {
        True ->
          take_digits_loop(advance(cursor, rest, by: 1), [
            code - 0x30,
            ..accumulator
          ])
        False -> #(list.reverse(accumulator), cursor)
      }
    [] -> #(list.reverse(accumulator), cursor)
  }
}

// Returns the exponent as canonical text ("" when absent, "e<sign><digits>"
// otherwise) so the float can be rebuilt through one well-formed literal.
fn parse_exponent(
  cursor: Cursor,
) -> Result(#(String, Cursor), CorruptionReport) {
  case cursor.rest {
    [0x65, ..rest] | [0x45, ..rest] -> {
      let cursor = advance(cursor, rest, by: 1)
      let #(sign, cursor) = case cursor.rest {
        [0x2D, ..rest] -> #("-", advance(cursor, rest, by: 1))
        [0x2B, ..rest] -> #("", advance(cursor, rest, by: 1))
        _ -> #("", cursor)
      }
      case take_digits(cursor) {
        #([], _) -> Error(fail(cursor, "digits in the exponent"))
        #(digits, cursor) ->
          Ok(#("e" <> sign <> digits_to_string(digits), cursor))
      }
    }
    _ -> Ok(#("", cursor))
  }
}

// Rebuilds the digits into one Gleam float literal and hands it to
// `float.parse` rather than computing the value by hand, so parsing and
// serialization agree with the runtime's own float-literal semantics
// instead of a second, possibly divergent, arithmetic path.
fn finish_float(
  start: Cursor,
  cursor: Cursor,
  negative: Bool,
  int_digits: List(Int),
  frac_digits: List(Int),
  exponent: String,
) -> Result(#(JsonValue, Cursor), CorruptionReport) {
  let sign = case negative {
    True -> "-"
    False -> ""
  }
  let fraction = case frac_digits {
    [] -> "0"
    _ -> digits_to_string(frac_digits)
  }
  let literal =
    sign <> digits_to_string(int_digits) <> "." <> fraction <> exponent
  case float.parse(literal) {
    Ok(value) -> Ok(#(Float(value), cursor))
    Error(Nil) ->
      Error(fail(start, "a number representable as an ieee 754 double"))
  }
}

fn digits_to_int(digits: List(Int)) -> Int {
  list.fold(digits, from: 0, with: fn(accumulator, digit) {
    accumulator * 10 + digit
  })
}

fn digits_to_string(digits: List(Int)) -> String {
  digits
  |> list.map(int.to_string)
  |> string.concat
}

fn apply_sign(value: Int, negative: Bool) -> Int {
  case negative {
    True -> -value
    False -> value
  }
}
