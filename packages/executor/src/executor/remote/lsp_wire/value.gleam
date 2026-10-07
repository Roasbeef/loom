//// Scalar checks shared by the closed LSP semantic codec.
////
//// Raw byte/node preflight precedes these functions. Paths retain executor
//// spellings; syntax checking never resolves an owner filesystem or grants
//// physical access. The executor readmits every returned path before use.

import core/msgpack as m
import core/workspace
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Converts a predicate into a fixed validation refusal.
///
/// ## Examples
///
/// `check(fn() { False })` refuses without retaining input.
@internal
pub fn check(valid: fn() -> Bool) -> Result(Nil, Nil) {
  case valid() {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Decodes bounded UTF-8 payload text.
///
/// ## Examples
///
/// Limits use bytes rather than graphemes.
@internal
pub fn text(value: m.MsgPackValue, limit: Int) -> Result(String, Nil) {
  case value {
    m.StringValue(text) -> {
      use Nil <- result.try(check(fn() { string.byte_size(text) <= limit }))
      Ok(text)
    }
    _ -> Error(Nil)
  }
}

/// Decodes nonempty bounded text.
///
/// ## Examples
///
/// An empty configured server name is refused.
@internal
pub fn name(value: m.MsgPackValue, limit: Int) -> Result(String, Nil) {
  use text <- result.try(text(value, limit))
  use Nil <- result.try(
    check(fn() { text != "" && !string.contains(text, "\u{0000}") }),
  )
  Ok(text)
}

/// Decodes a canonical admitted path spelling without physical resolution.
///
/// ## Examples
///
/// Relative traversal and host-dependent separators are refused.
@internal
pub fn path(value: m.MsgPackValue) -> Result(String, Nil) {
  use path <- result.try(name(value, 8192))
  case string.starts_with(path, "/") {
    False -> {
      use _ <- result.try(
        workspace.relative_path(path) |> result.replace_error(Nil),
      )
      Ok(path)
    }
    True -> {
      use Nil <- result.try(check(fn() { !string.contains(path, "\\") }))
      case path {
        "/" -> Ok(path)
        _ -> {
          use Nil <- result.try(
            check(fn() {
              list.all(string.split(string.drop_start(path, 1), "/"), fn(part) {
                part != "" && part != "." && part != ".."
              })
            }),
          )
          Ok(path)
        }
      }
    }
  }
}

/// Decodes an inclusive signed integer range.
///
/// ## Examples
///
/// Zero is refused when decoding a one-based position.
@internal
pub fn integer(value: m.MsgPackValue, low: Int, high: Int) -> Result(Int, Nil) {
  case value {
    m.IntValue(n) if n >= low && n <= high -> Ok(n)
    _ -> Error(Nil)
  }
}

/// Decodes a nil optional through the supplied total field decoder.
///
/// ## Examples
///
/// An explicit extra tag is not an optional nil.
@internal
pub fn optional(
  value: m.MsgPackValue,
  decode: fn(m.MsgPackValue) -> Result(a, Nil),
) -> Result(Option(a), Nil) {
  case value {
    m.NilValue -> Ok(None)
    _ -> decode(value) |> result.map(Some)
  }
}

/// Encodes the only admitted optional spelling.
///
/// ## Examples
///
/// `option(None, m.IntValue)` encodes nil.
@internal
pub fn option(
  value: Option(a),
  encode: fn(a) -> m.MsgPackValue,
) -> m.MsgPackValue {
  case value {
    None -> m.NilValue
    Some(value) -> encode(value)
  }
}

/// Checks a complete array count before building another typed inventory.
///
/// ## Examples
///
/// A 10001-row array is refused before row decoding.
@internal
pub fn items(
  value: m.MsgPackValue,
  limit: Int,
  decode: fn(m.MsgPackValue) -> Result(a, Nil),
) -> Result(List(a), Nil) {
  case value {
    m.ArrayValue(items) -> {
      use Nil <- result.try(check(fn() { list.drop(items, limit) == [] }))
      list.try_map(items, decode)
    }
    _ -> Error(Nil)
  }
}

/// Projects positional row arrays without changing their order.
///
/// ## Examples
///
/// An empty inventory retains an empty array.
@internal
pub fn array(
  items: List(a),
  encode: fn(a) -> m.MsgPackValue,
) -> m.MsgPackValue {
  m.ArrayValue(list.map(items, encode))
}

/// Checks the existing SHA256 content-address spelling.
///
/// ## Examples
///
/// Observation generations and document digests retain their algorithm prefix.
@internal
pub fn content_digest(value: m.MsgPackValue) -> Result(String, Nil) {
  use digest <- result.try(text(value, 71))
  use Nil <- result.try(
    check(fn() {
      string.byte_size(digest) == 71
      && string.starts_with(digest, "sha256-")
      && list.all(string.to_graphemes(string.drop_start(digest, 7)), fn(c) {
        string.contains("0123456789abcdef", c)
      })
    }),
  )
  Ok(digest)
}
