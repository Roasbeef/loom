//// Scalar admission for the workspace codec.
////
//// Text remains UTF-8 data. Request paths, revisions and provenance use their
//// existing total constructors. Inventory checks run before allocating decoded
//// lists; their dict rejects repeated records without a quadratic comparison.
//// No rejected value enters an error, which is always the fixed Nil marker.

import core/msgpack
import core/workspace as cw
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import tools/search
import tools/workspace

/// Maximum bytes in an individual diagnostic, including post-write observation.
pub const max_diagnostic_bytes = 65_536

/// Maximum UTF-8 file material admitted by the existing workspace host.
pub const max_content_bytes = 8_388_608

/// Projects a typed inventory without changing its order.
///
/// ## Examples
///
/// `array([], msgpack.StringValue)` is an empty positional inventory.
@internal
pub fn array(
  xs: List(a),
  encode: fn(a) -> msgpack.MsgPackValue,
) -> msgpack.MsgPackValue {
  msgpack.ArrayValue(list.map(xs, encode))
}

/// Decodes an inventory after checking its count, before constructing results.
///
/// ## Examples
///
/// `items(msgpack.ArrayValue([]), 1, text)` returns `Ok([])`.
@internal
pub fn items(
  value: msgpack.MsgPackValue,
  cap: Int,
  decode: fn(msgpack.MsgPackValue) -> Result(a, Nil),
) -> Result(List(a), Nil) {
  case value {
    msgpack.ArrayValue(xs) -> {
      use Nil <- result.try(check(fn() { list.drop(xs, cap) == [] }))
      list.try_map(xs, decode)
    }
    _ -> Error(Nil)
  }
}

/// Rejects duplicate inventory records while preserving their supplied order.
///
/// ## Examples
///
/// Two identical entries fail rather than introducing first/last precedence.
@internal
pub fn inventory(
  value: msgpack.MsgPackValue,
  cap: Int,
  decode: fn(msgpack.MsgPackValue) -> Result(a, Nil),
) -> Result(List(a), Nil) {
  use xs <- result.try(items(value, cap, decode))
  use Nil <- result.try(unique(xs, dict.new()))
  Ok(xs)
}

fn unique(xs: List(a), seen: dict.Dict(a, Nil)) -> Result(Nil, Nil) {
  case xs {
    [] -> Ok(Nil)
    [x, ..rest] -> {
      use Nil <- result.try(check(fn() { !dict.has_key(seen, x) }))
      unique(rest, dict.insert(seen, x, Nil))
    }
  }
}

/// Converts a predicate to the codec's fixed failure marker.
///
/// ## Examples
///
/// `check(fn() { False })` returns `Error(Nil)`.
@internal
pub fn check(valid: fn() -> Bool) -> Result(Nil, Nil) {
  case valid() {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Decodes one signed-64-bit semantic integer.
///
/// ## Examples
///
/// `integer(msgpack.IntValue(-1))` returns `Ok(-1)`.
@internal
pub fn integer(value: msgpack.MsgPackValue) -> Result(Int, Nil) {
  range(value, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807)
}

/// Decodes an integer within inclusive domain bounds.
///
/// ## Examples
///
/// `range(msgpack.IntValue(2), 0, 1)` refuses the value.
@internal
pub fn range(
  value: msgpack.MsgPackValue,
  low: Int,
  high: Int,
) -> Result(Int, Nil) {
  case value {
    msgpack.IntValue(n) if n >= low && n <= high -> Ok(n)
    _ -> Error(Nil)
  }
}

/// Decodes a nonnegative signed-64-bit count.
///
/// ## Examples
///
/// Negative sizes fail closed.
@internal
pub fn natural(value: msgpack.MsgPackValue) -> Result(Int, Nil) {
  range(value, 0, 9_223_372_036_854_775_807)
}

/// Decodes a strictly positive signed-64-bit coordinate.
///
/// ## Examples
///
/// Zero is not a line number.
@internal
pub fn positive(value: msgpack.MsgPackValue) -> Result(Int, Nil) {
  range(value, 1, 9_223_372_036_854_775_807)
}

/// Decodes the negative value retained by a policy error.
///
/// ## Examples
///
/// A nonnegative NegativeLimit payload is refused.
@internal
pub fn negative(value: msgpack.MsgPackValue) -> Result(Int, Nil) {
  range(value, -9_223_372_036_854_775_808, -1)
}

/// Decodes only msgpack's boolean tags.
///
/// ## Examples
///
/// Integers zero and one are not booleans.
@internal
pub fn flag(value: msgpack.MsgPackValue) -> Result(Bool, Nil) {
  case value {
    msgpack.BoolValue(b) -> Ok(b)
    _ -> Error(Nil)
  }
}

/// Decodes bounded observation text, never path authority.
///
/// ## Examples
///
/// Filesystem error paths can be absolute observed data.
@internal
pub fn text(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  bounded_text(value, max_diagnostic_bytes)
}

/// Decodes a bounded individual diagnostic.
///
/// ## Examples
///
/// Oversized observer blocks are refused without truncation.
@internal
pub fn diagnostic(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  bounded_text(value, max_diagnostic_bytes)
}

/// Decodes whole-file text under the existing eight-MiB ceiling.
///
/// ## Examples
///
/// A larger file is refused without retaining an excerpt.
@internal
pub fn content(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  bounded_text(value, max_content_bytes)
}

fn bounded_text(value: msgpack.MsgPackValue, cap: Int) -> Result(String, Nil) {
  case value {
    msgpack.StringValue(s) -> {
      use Nil <- result.try(check(fn() { string.byte_size(s) <= cap }))
      Ok(s)
    }
    _ -> Error(Nil)
  }
}

/// Decodes a newline-free bounded line, retaining carriage returns.
///
/// ## Examples
///
/// CRLF line content retains its trailing carriage return.
@internal
pub fn line_text(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(content(value))
  use Nil <- result.try(check(fn() { !string.contains(s, "\n") }))
  Ok(s)
}

/// Encodes the exact canonical relative path spelling.
///
/// ## Examples
///
/// Workspace root remains the explicit dot spelling.
@internal
pub fn path_value(path: cw.RelativePath) -> msgpack.MsgPackValue {
  msgpack.StringValue(cw.path_string(path))
}

/// Decodes a path through the existing remote grammar constructor.
///
/// ## Examples
///
/// Traversal never becomes a RelativePath.
@internal
pub fn path(value: msgpack.MsgPackValue) -> Result(cw.RelativePath, Nil) {
  use s <- result.try(text(value))
  cw.relative_path(s) |> result.replace_error(Nil)
}

/// Retains filesystem-observed path spelling under the existing path byte cap.
/// Unix listing and search producers return names verbatim, including colons
/// and backslashes. Observations are data; request paths still pass through the
/// strict `RelativePath` constructor before they can authorize an operation.
///
/// ## Examples
///
/// A listed `a:b` survives observation but cannot become request authority.
@internal
pub fn observed_path(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  bounded_text(value, cw.max_path_bytes)
}

/// Encodes a full validated Git object ID.
///
/// ## Examples
///
/// Revision expressions never enter this field.
@internal
pub fn revision_value(revision: workspace.Revision) -> msgpack.MsgPackValue {
  msgpack.StringValue(workspace.revision_string(revision))
}

/// Decodes a full SHA-1 or SHA-256 ID through its existing constructor.
///
/// ## Examples
///
/// HEAD and option syntax fail closed.
@internal
pub fn revision(
  value: msgpack.MsgPackValue,
) -> Result(workspace.Revision, Nil) {
  use s <- result.try(text(value))
  workspace.revision(s) |> result.replace_error(Nil)
}

/// Validates commit IDs while retaining their exact case.
///
/// ## Examples
///
/// A log record carries the full object ID.
@internal
pub fn revision_text(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use r <- result.try(revision(value))
  Ok(workspace.revision_string(r))
}

/// Checks the existing eight-lowercase-hex anchor spelling.
///
/// ## Examples
///
/// Arbitrary text cannot become an edit reference.
@internal
pub fn anchor(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(text(value))
  use Nil <- result.try(
    check(fn() { string.byte_size(s) == 8 && hex(<<s:utf8>>) }),
  )
  Ok(s)
}

fn hex(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<b, rest:bytes>> if b >= 48 && b <= 57 || b >= 97 && b <= 102 -> hex(rest)
    _ -> False
  }
}

/// Checks the whole-file FNV digest plus canonical decimal byte length.
///
/// ## Examples
///
/// `cbf29ce484222325-0` is the empty file's digest.
@internal
pub fn digest(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(text(value))
  case string.split(s, "-") {
    [hash, size] -> {
      use Nil <- result.try(
        check(fn() { string.byte_size(hash) == 16 && hex(<<hash:utf8>>) }),
      )
      use n <- result.try(int.parse(size))
      use Nil <- result.try(
        check(fn() {
          n >= 0 && n <= max_content_bytes && int.to_string(n) == size
        }),
      )
      Ok(s)
    }
    _ -> Error(Nil)
  }
}

/// Decodes exact binary images under the read ceiling, requiring byte alignment.
///
/// ## Examples
///
/// Ragged bit arrays fail before encoding.
@internal
pub fn image(value: msgpack.MsgPackValue) -> Result(BitArray, Nil) {
  case value {
    msgpack.BinaryValue(b) -> {
      use Nil <- result.try(
        check(fn() {
          bit_array.bit_size(b) % 8 == 0
          && bit_array.byte_size(b) <= max_content_bytes
        }),
      )
      Ok(b)
    }
    _ -> Error(Nil)
  }
}

/// Checks a bounded glob using the existing total compiler.
///
/// ## Examples
///
/// Malformed glob syntax is refused before dispatch.
@internal
pub fn glob(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(text(value))
  use _ <- result.try(search.compile_glob(s) |> result.replace_error(Nil))
  Ok(s)
}

/// Checks the existing regex syntax and grapheme bound.
///
/// ## Examples
///
/// An invalid regex never becomes a Search request.
@internal
pub fn regex(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(text(value))
  use Nil <- result.try(
    check(fn() { string.drop_start(s, search.max_pattern_length) == "" }),
  )
  use _ <- result.try(regexp.from_string(s) |> result.replace_error(Nil))
  Ok(s)
}

/// Checks a request prune item through the strict path grammar as one component.
/// Prune input retains its admission rules independently of observed filenames.
///
/// ## Examples
///
/// A slash-bearing prune name fails rather than gaining subtree meaning.
@internal
pub fn prune(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use p <- result.try(path(value))
  let s = cw.path_string(p)
  use Nil <- result.try(check(fn() { s != "." && !string.contains(s, "/") }))
  Ok(s)
}

/// Validates Git's two-column porcelain alphabet.
///
/// ## Examples
///
/// Unknown status symbols fail closed.
@internal
pub fn status_code(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  use s <- result.try(text(value))
  use Nil <- result.try(
    check(fn() {
      string.byte_size(s) == 2
      && list.all(string.to_graphemes(s), fn(c) {
        string.contains(" MADRCU?!T", c)
      })
    }),
  )
  Ok(s)
}

/// Encodes a checked tool index and exact digest.
///
/// ## Examples
///
/// Provenance is data and grants no authority.
@internal
pub fn tool_origin_value(origin: workspace.ToolOrigin) -> msgpack.MsgPackValue {
  let #(index, digest) = workspace.tool_origin_fields(origin)
  msgpack.ArrayValue([msgpack.IntValue(index), msgpack.BinaryValue(digest)])
}

/// Uses the existing total provenance constructor.
///
/// ## Examples
///
/// Short digests and negative source indices fail closed.
@internal
pub fn tool_origin(
  value: msgpack.MsgPackValue,
) -> Result(workspace.ToolOrigin, Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(index), msgpack.BinaryValue(digest)]) ->
      workspace.tool_origin(index, digest) |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

/// Encodes an error's arbitrary-precision integer as canonical decimal data.
///
/// ## Examples
///
/// IntegerOutOfRange can itself contain a value outside msgpack integer widths.
@internal
pub fn big_integer_value(n: Int) -> msgpack.MsgPackValue {
  msgpack.StringValue(int.to_string(n))
}

/// Decodes a bounded canonical decimal integer without runtime serialization.
///
/// ## Examples
///
/// Leading zeroes are refused.
@internal
pub fn big_integer(value: msgpack.MsgPackValue) -> Result(Int, Nil) {
  use s <- result.try(bounded_text(value, 1024))
  use n <- result.try(int.parse(s))
  use Nil <- result.try(check(fn() { int.to_string(n) == s }))
  Ok(n)
}

/// Encodes success and failure as separate exact two-field arrays.
///
/// ## Examples
///
/// Success tag is zero; failure tag is one.
@internal
pub fn result_value(
  value: Result(a, b),
  success: fn(a) -> msgpack.MsgPackValue,
  failure: fn(b) -> msgpack.MsgPackValue,
) -> msgpack.MsgPackValue {
  case value {
    Ok(a) -> msgpack.ArrayValue([msgpack.IntValue(0), success(a)])
    Error(b) -> msgpack.ArrayValue([msgpack.IntValue(1), failure(b)])
  }
}

/// Decodes exact result tags without coercion.
///
/// ## Examples
///
/// Extra fields fail the array pattern.
@internal
pub fn result_field(
  value: msgpack.MsgPackValue,
  success: fn(msgpack.MsgPackValue) -> Result(a, Nil),
  failure: fn(msgpack.MsgPackValue) -> Result(b, Nil),
) -> Result(Result(a, b), Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0), a]) -> result.map(success(a), Ok)
    msgpack.ArrayValue([msgpack.IntValue(1), b]) ->
      result.map(failure(b), Error)
    _ -> Error(Nil)
  }
}

/// Encodes absence and presence as distinct exact arrays.
///
/// ## Examples
///
/// Empty text remains distinct from absence.
@internal
pub fn option_value(
  value: Option(a),
  encode: fn(a) -> msgpack.MsgPackValue,
) -> msgpack.MsgPackValue {
  case value {
    None -> msgpack.ArrayValue([msgpack.IntValue(0)])
    Some(a) -> msgpack.ArrayValue([msgpack.IntValue(1), encode(a)])
  }
}

/// Decodes only exact option tags and arities.
///
/// ## Examples
///
/// A present empty observer string is preserved.
@internal
pub fn option_field(
  value: msgpack.MsgPackValue,
  decode: fn(msgpack.MsgPackValue) -> Result(a, Nil),
) -> Result(Option(a), Nil) {
  case value {
    msgpack.ArrayValue([msgpack.IntValue(0)]) -> Ok(None)
    msgpack.ArrayValue([msgpack.IntValue(1), a]) -> result.map(decode(a), Some)
    _ -> Error(Nil)
  }
}

/// Refuses repeated logical keys even when the records differ in other fields.
///
/// ## Examples
///
/// Two listing records for one path are ambiguous inventory evidence.
@internal
pub fn unique_keys(xs: List(a), key: fn(a) -> b) -> Result(Nil, Nil) {
  unique(list.map(xs, key), dict.new())
}

/// Admits the largest possible postimage from an eight-MiB preimage and edit.
///
/// ## Examples
///
/// Final completion bytes still have the independent thirty-two-MiB ceiling.
@internal
pub fn postimage(value: msgpack.MsgPackValue) -> Result(String, Nil) {
  bounded_text(value, 16_777_216)
}
