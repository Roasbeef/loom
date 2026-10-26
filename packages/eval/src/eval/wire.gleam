//// The shared vocabulary of the instrument's total decoders.
////
//// Task files, arm files, plan files and ledger rows are all read back from
//// disk by a process that did not write them, possibly months later and
//// possibly after a person edited them by hand. Every one is therefore
//// decoded the same way: the value must be an object, every key must be one
//// the version knows, and every field must have the exact type. An unknown
//// key is refused rather than ignored because an ignored key is a field
//// that a later reader will believe was honoured.
////
//// The helpers here are deliberately small and string-typed in their
//// errors. A decode failure is shown to the operator who wrote the file, so
//// the message names the field, and nothing downstream branches on it.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The fields of a decoded object, in the order the file wrote them.
pub type Fields =
  List(#(String, JsonValue))

/// Accepts an object whose keys are all in `allowed` and unique, and returns
/// its fields. A hand-built value can repeat a key even though `json.parse`
/// never produces one, so the duplicate check keeps the decoder total over
/// both sources.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok([#("a", json.Int(1))]) =
///   wire.object(json.Object([#("a", json.Int(1))]), ["a"])
/// ```
///
pub fn object(
  value: JsonValue,
  allowed: List(String),
) -> Result(Fields, String) {
  // Only an object has named fields; every other JSON shape is refused rather
  // than read as empty.
  use fields <- result.try(case value {
    json.Object(fields:) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("expected an object")
  })

  let keys = list.map(fields, fn(field) { field.0 })

  // An unknown key means the file was written by a newer or different
  // version; guessing at its meaning would quietly change what is measured.
  use Nil <- result.try(
    case list.find(keys, fn(key) { !list.contains(allowed, key) }) {
      Ok(key) -> Error("unknown key \"" <> key <> "\"")
      Error(Nil) -> Ok(Nil)
    },
  )

  // Repeated keys are refused so a hand-built value cannot hide a field behind
  // its twin.
  case list.length(list.unique(keys)) == list.length(keys) {
    True -> Ok(fields)
    False -> Error("repeated key")
  }
}

/// Looks up a mandatory field.
///
/// ## Examples
///
/// ```gleam
/// assert wire.required([#("a", json.Null)], "a") == Ok(json.Null)
/// ```
///
pub fn required(fields: Fields, key: String) -> Result(JsonValue, String) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { "missing key \"" <> key <> "\"" })
}

/// Looks up a mandatory string field.
///
/// ## Examples
///
/// ```gleam
/// assert wire.text([#("a", json.String("x"))], "a") == Ok("x")
/// ```
///
pub fn text(fields: Fields, key: String) -> Result(String, String) {
  use value <- result.try(required(fields, key))
  string_value(value, key)
}

/// Reads a string out of a value already looked up, naming `key` on failure.
///
/// ## Examples
///
/// ```gleam
/// assert wire.string_value(json.String("x"), "k") == Ok("x")
/// ```
///
pub fn string_value(value: JsonValue, key: String) -> Result(String, String) {
  case value {
    json.String(value:) -> Ok(value)
    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("\"" <> key <> "\" must be a string")
  }
}

/// Looks up a mandatory integer field.
///
/// ## Examples
///
/// ```gleam
/// assert wire.int([#("n", json.Int(3))], "n") == Ok(3)
/// ```
///
pub fn int(fields: Fields, key: String) -> Result(Int, String) {
  use value <- result.try(required(fields, key))

  // Only a JSON integer qualifies; a float or numeric string would change
  // meaning at the bound checks.
  case value {
    json.Int(value:) -> Ok(value)
    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("\"" <> key <> "\" must be an integer")
  }
}

/// Looks up an integer field constrained to `low..high` inclusive.
///
/// ## Examples
///
/// ```gleam
/// assert wire.int_between([#("n", json.Int(3))], "n", 1, 5) == Ok(3)
/// ```
///
pub fn int_between(
  fields: Fields,
  key: String,
  low: Int,
  high: Int,
) -> Result(Int, String) {
  use value <- result.try(int(fields, key))

  // The range is inclusive at both ends, and the message states it so the
  // person editing the file sees the limit.
  case value >= low && value <= high {
    True -> Ok(value)
    False ->
      Error(
        "\""
        <> key
        <> "\" must be between "
        <> int.to_string(low)
        <> " and "
        <> int.to_string(high),
      )
  }
}

/// Looks up a mandatory non-negative finite number. An integer literal is
/// accepted because a hand-written `1` and a printed `1.0` mean one thing.
///
/// ## Examples
///
/// ```gleam
/// assert wire.number([#("r", json.Int(1))], "r") == Ok(1.0)
/// ```
///
pub fn number(fields: Fields, key: String) -> Result(Float, String) {
  use value <- result.try(required(fields, key))

  // Integers are accepted because a hand-written 1 and a printed 1.0 mean one
  // thing.
  use number <- result.try(case value {
    json.Float(value:) -> Ok(value)
    json.Int(value:) -> Ok(int.to_float(value))
    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Bool(..)
    | json.Null -> Error("\"" <> key <> "\" must be a number")
  })

  // A negative amount of money, tokens or time is never meaningful, so it is
  // refused.
  case number >=. 0.0 {
    True -> Ok(number)
    False -> Error("\"" <> key <> "\" must not be negative")
  }
}

/// Looks up a mandatory array field and decodes every element.
///
/// ## Examples
///
/// ```gleam
/// let items = json.Array([json.String("a")])
/// assert wire.list_of([#("k", items)], "k", fn(v) { wire.string_value(v, "k") })
///   == Ok(["a"])
/// ```
///
pub fn list_of(
  fields: Fields,
  key: String,
  element: fn(JsonValue) -> Result(a, String),
) -> Result(List(a), String) {
  use value <- result.try(required(fields, key))

  // Only an array can be a list; the element decoder then sees each item
  // alone.
  case value {
    json.Array(items:) -> list.try_map(items, element)
    json.Object(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("\"" <> key <> "\" must be an array")
  }
}

/// Looks up a mandatory array of strings.
///
/// ## Examples
///
/// ```gleam
/// let items = json.Array([json.String("a")])
/// assert wire.strings([#("k", items)], "k") == Ok(["a"])
/// ```
///
pub fn strings(fields: Fields, key: String) -> Result(List(String), String) {
  list_of(fields, key, string_value(_, key))
}

/// The UTF-8 size of a string, the unit every bound in the instrument is
/// stated in.
///
/// ## Examples
///
/// ```gleam
/// assert wire.bytes("é") == 2
/// ```
///
pub fn bytes(text: String) -> Int {
  bit_array.byte_size(<<text:utf8>>)
}

/// True when `text` is exactly `length` lowercase hexadecimal digits.
///
/// ## Examples
///
/// ```gleam
/// assert wire.is_hex("ab12", 4)
/// ```
///
pub fn is_hex(text: String, length: Int) -> Bool {
  string.length(text) == length
  && list.all(string.to_graphemes(text), fn(digit) {
    string.contains("0123456789abcdef", digit)
  })
}

/// A path the instrument will write under a root: relative, free of `.` and
/// `..` pieces, of NUL and of backslashes, and clear of the directories
/// (`.git`, `.loom`) that carry harness state. This mirrors
/// `client/evolution/tasks`, so a v1 fixture's paths remain admissible.
///
/// ## Examples
///
/// ```gleam
/// assert wire.safe_path("src/a.gleam")
/// ```
///
/// ```gleam
/// assert !wire.safe_path("../escape")
/// ```
///
pub fn safe_path(path: String) -> Bool {
  path != ""
  && bytes(path) <= 256
  && !string.starts_with(path, "/")
  && !string.contains(path, "\\")
  && !string.contains(path, "\u{0}")
  && list.all(string.split(path, "/"), fn(piece) {
    piece != ""
    && piece != "."
    && piece != ".."
    && piece != ".git"
    && piece != ".loom"
  })
}

/// True when no element repeats.
///
/// ## Examples
///
/// ```gleam
/// assert wire.is_distinct(["a", "b"])
/// ```
///
pub fn is_distinct(items: List(String)) -> Bool {
  list.length(list.unique(items)) == list.length(items)
}

/// The elements of a set in canonical order, without repeats. Sets are
/// encoded this way so two producers that list the same members in a
/// different order mint one identity.
///
/// ## Examples
///
/// ```gleam
/// assert wire.sorted_set(["b", "a", "b"]) == ["a", "b"]
/// ```
///
pub fn sorted_set(items: List(String)) -> List(String) {
  items
  |> list.unique
  |> list.sort(string.compare)
}
