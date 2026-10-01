//// Fixed, total schema decoders for generated MCP capability modules.
////
//// The generator composes these opaque decoders from a bounded schema plan;
//// server-provided strings become field names and literals, never executable
//// decoder bodies. A decoder reads only an already received report value and
//// carries no capability authority. Field and list failures accumulate a path
//// from the structured-content root without flattening hostile property names.
////
//// Missing properties and JSON null have different representations. An optional
//// nullable field decodes to `Option(Option(a))`: `None` is absent, `Some(None)`
//// is present null, and `Some(Some(a))` is present data. Encoders retain that
//// distinction rather than silently replacing absence with null.

import cap/mcp.{type DecodeError, DecodeError}
import cap/report
import core/msgpack
import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set

/// A schema decoder composed only through this module's total constructors.
pub opaque type Decoder(a) {
  Decoder(run: fn(report.Value) -> Result(a, DecodeError))
}

/// Whether properties outside the generated record are accepted.
pub type AdditionalProperties {
  /// Unknown properties remain valid but are not projected into the record.
  AllowAdditional

  /// Every property must be named by the schema's property list.
  RejectAdditional
}

/// Runs a decoder, reporting paths relative to this value.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.string("ok"), mcp_codec.string()) == Ok("ok")
/// ```
pub fn decode(
  value: report.Value,
  decoder: Decoder(a),
) -> Result(a, DecodeError) {
  decoder.run(value)
}

/// Completes a field chain with the generated record it constructed.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.null(), mcp_codec.success(42)) == Ok(42)
/// ```
pub fn success(value: a) -> Decoder(a) {
  Decoder(fn(_input) { Ok(value) })
}

/// Converts a decoded value into a generated record or variant.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.map(mcp_codec.string(), Some)
/// assert mcp_codec.decode(report.string("ok"), decoder) == Ok(Some("ok"))
/// ```
pub fn map(decoder: Decoder(a), convert: fn(a) -> b) -> Decoder(b) {
  Decoder(fn(value) { decode(value, decoder) |> result.map(convert) })
}

/// Accepts an unconstrained schema leaf without changing its value.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.null(), mcp_codec.value()) == Ok(report.null())
/// ```
pub fn value() -> Decoder(report.Value) {
  Decoder(Ok)
}

/// Requires a JSON string; other primitive shapes are never coerced.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.string("x"), mcp_codec.string()) == Ok("x")
/// ```
pub fn string() -> Decoder(String) {
  primitive(report.as_string, "expected a string")
}

/// Accepts integer JSON numbers, including integral floating-point values.
/// This does not change `report.as_int`'s strict MessagePack semantics.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.float(2.0), mcp_codec.int()) == Ok(2)
/// ```
pub fn int() -> Decoder(Int) {
  Decoder(fn(value) {
    case value {
      msgpack.IntValue(number) -> Ok(number)
      msgpack.FloatValue(number) -> integral(number)
      msgpack.NilValue
      | msgpack.BoolValue(..)
      | msgpack.StringValue(..)
      | msgpack.BinaryValue(..)
      | msgpack.ArrayValue(..)
      | msgpack.MapValue(..) -> failure("expected an integer")
    }
  })
}

fn integral(number: Float) -> Result(Int, DecodeError) {
  let truncated = float.truncate(number)
  case int.to_float(truncated) == number {
    True -> Ok(truncated)
    False -> failure("expected an integer")
  }
}

/// Accepts either JSON number representation and projects it to Float.
/// Integer conversion follows floating-point precision; `report.as_float`
/// remains strict for callers who need to inspect the wire representation.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.int(2), mcp_codec.number()) == Ok(2.0)
/// ```
pub fn number() -> Decoder(Float) {
  Decoder(fn(value) {
    case value {
      msgpack.IntValue(number) -> {
        // Hand-built report values can exceed MessagePack's integer range.
        // Parsing is total even when such an integer exceeds Float's range.
        float.parse(int.to_string(number) <> ".0")
        |> result.map_error(fn(_) {
          DecodeError([], "number exceeds Float range")
        })
      }
      msgpack.FloatValue(number) -> Ok(number)
      msgpack.NilValue
      | msgpack.BoolValue(..)
      | msgpack.StringValue(..)
      | msgpack.BinaryValue(..)
      | msgpack.ArrayValue(..)
      | msgpack.MapValue(..) -> failure("expected a number")
    }
  })
}

/// Reads the wire boolean so generated code can map it into a domain ADT.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.bool(True), mcp_codec.boolean()) == Ok(True)
/// ```
pub fn boolean() -> Decoder(Bool) {
  primitive(report.as_bool, "expected a boolean")
}

fn primitive(
  read: fn(report.Value) -> Result(a, Nil),
  reason: String,
) -> Decoder(a) {
  Decoder(fn(value) {
    read(value) |> result.map_error(fn(_nil) { DecodeError([], reason) })
  })
}

/// Decodes every list item, prefixing failures with its zero-based index.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.list(mcp_codec.int())
/// assert mcp_codec.decode(report.list([report.int(3)]), decoder) == Ok([3])
/// ```
pub fn list(item: Decoder(a)) -> Decoder(List(a)) {
  Decoder(fn(value) {
    use items <- result.try(
      report.as_list(value)
      |> result.map_error(fn(_nil) { DecodeError([], "expected an array") }),
    )
    list_loop(items, item, 0, [])
  })
}

// Stop at the first invalid element rather than decoding the unused tail.
fn list_loop(
  items: List(report.Value),
  decoder: Decoder(a),
  index: Int,
  reversed: List(a),
) -> Result(List(a), DecodeError) {
  case items {
    [] -> Ok(list.reverse(reversed))
    [item, ..rest] -> {
      use decoded <- result.try(at(decode(item, decoder), int.to_string(index)))
      list_loop(rest, decoder, index + 1, [decoded, ..reversed])
    }
  }
}

/// Represents explicit null as None, independently of field presence.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.nullable(mcp_codec.string())
/// assert mcp_codec.decode(report.null(), decoder) == Ok(None)
/// ```
pub fn nullable(decoder: Decoder(a)) -> Decoder(Option(a)) {
  Decoder(fn(value) {
    case value {
      msgpack.NilValue -> Ok(None)
      msgpack.BoolValue(..)
      | msgpack.IntValue(..)
      | msgpack.FloatValue(..)
      | msgpack.StringValue(..)
      | msgpack.BinaryValue(..)
      | msgpack.ArrayValue(..)
      | msgpack.MapValue(..) -> decode(value, decoder) |> result.map(Some)
    }
  })
}

/// Reads a required property and continues decoding the same parent object.
///
/// ## Examples
///
/// ```gleam
/// let decoder = {
///   use name <- mcp_codec.field("name", mcp_codec.string())
///   mcp_codec.success(name)
/// }
/// assert mcp_codec.decode(report.object([#("name", report.string("x"))]), decoder) == Ok("x")
/// ```
pub fn field(
  name: String,
  decoder: Decoder(a),
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  Decoder(fn(value) {
    use fields <- result.try(object_fields(value))
    use raw <- result.try(
      find_field(fields, name)
      |> result.map_error(fn(_nil) {
        DecodeError([name], "missing required field")
      }),
    )
    use decoded <- result.try(at(decode(raw, decoder), name))
    decode(value, next(decoded))
  })
}

/// Reads an optional property without treating a present null as absence.
/// A malformed present value still fails the containing object.
///
/// ## Examples
///
/// ```gleam
/// let decoder = {
///   use name <- mcp_codec.optional_field("name", mcp_codec.string())
///   mcp_codec.success(name)
/// }
/// assert mcp_codec.decode(report.object([]), decoder) == Ok(None)
/// ```
pub fn optional_field(
  name: String,
  decoder: Decoder(a),
  next: fn(Option(a)) -> Decoder(b),
) -> Decoder(b) {
  Decoder(fn(value) {
    use fields <- result.try(object_fields(value))
    use decoded <- result.try(optional_property(fields, name, decoder))
    decode(value, next(decoded))
  })
}

fn optional_property(
  fields: List(#(report.Value, report.Value)),
  name: String,
  decoder: Decoder(a),
) -> Result(Option(a), DecodeError) {
  case find_field(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(value) -> at(decode(value, decoder), name) |> result.map(Some)
  }
}

/// Checks object shape and additional-property policy before projecting fields.
/// Even an empty record requires an object; a scalar cannot vacuously succeed.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.object([], mcp_codec.RejectAdditional, mcp_codec.success(Nil))
/// assert mcp_codec.decode(report.object([]), decoder) == Ok(Nil)
/// ```
pub fn object(
  names: List(String),
  additional: AdditionalProperties,
  decoder: Decoder(a),
) -> Decoder(a) {
  Decoder(fn(value) {
    use fields <- result.try(object_fields(value))
    use Nil <- result.try(
      list.try_each(fields, fn(pair) {
        check_property(pair.0, names, additional)
      }),
    )
    decode(value, decoder)
  })
}

fn object_fields(
  value: report.Value,
) -> Result(List(#(report.Value, report.Value)), DecodeError) {
  case value {
    msgpack.MapValue(fields) -> Ok(fields)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> failure("expected an object")
  }
}

fn check_property(
  key: report.Value,
  names: List(String),
  additional: AdditionalProperties,
) -> Result(Nil, DecodeError) {
  use name <- result.try(decode(key, string()))
  case additional {
    AllowAdditional -> Ok(Nil)
    RejectAdditional -> {
      use <- bool.guard(list.contains(names, name), Ok(Nil))
      Error(DecodeError([name], "unexpected property"))
    }
  }
}

fn find_field(
  fields: List(#(report.Value, report.Value)),
  name: String,
) -> Result(report.Value, Nil) {
  use pair <- result.map(
    list.find(fields, fn(pair) { pair.0 == msgpack.StringValue(name) }),
  )
  pair.1
}

/// Requires a literal value before producing its generated enum variant.
/// Numeric literals compare as JSON numbers, so integer 1 matches float 1.0.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.literal(report.string("open"), 1)
/// assert mcp_codec.decode(report.string("open"), decoder) == Ok(1)
/// ```
pub fn literal(expected: report.Value, decoded: a) -> Decoder(a) {
  Decoder(fn(value) {
    case literal_matches(value, expected) {
      True -> Ok(decoded)
      False -> failure("expected the declared literal")
    }
  })
}

fn literal_matches(actual: report.Value, expected: report.Value) -> Bool {
  case actual, expected {
    msgpack.IntValue(a), msgpack.FloatValue(b) -> integral(b) == Ok(a)
    msgpack.FloatValue(a), msgpack.IntValue(b) -> integral(a) == Ok(b)
    _, _ -> actual == expected
  }
}

/// Requires exactly one alternative to match, as JSON Schema oneOf specifies.
/// A second success fails immediately; branch ordering cannot hide ambiguity.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.one_of([mcp_codec.int(), mcp_codec.int()])
/// assert mcp_codec.decode(report.int(1), decoder) == Error(mcp.DecodeError([], "multiple oneOf branches matched"))
/// ```
pub fn one_of(alternatives: List(Decoder(a))) -> Decoder(a) {
  Decoder(fn(value) {
    one_of_loop(
      alternatives,
      value,
      None,
      DecodeError([], "no oneOf branch matched"),
    )
  })
}

// Carry one success rather than collecting every matching branch. Keep a
// concrete branch failure for its nested path when no branch can decode.
fn one_of_loop(
  alternatives: List(Decoder(a)),
  value: report.Value,
  matched: Option(a),
  last_error: DecodeError,
) -> Result(a, DecodeError) {
  case alternatives {
    [] -> option.to_result(matched, last_error)
    [decoder, ..rest] -> {
      case decode(value, decoder), matched {
        Ok(_), Some(_) -> failure("multiple oneOf branches matched")
        Ok(decoded), None -> one_of_loop(rest, value, Some(decoded), last_error)
        Error(error), _ -> one_of_loop(rest, value, matched, error)
      }
    }
  }
}

/// Decodes an object whose property names are open and values share a schema.
/// Duplicate keys are refused even for hand-built values outside the wire codec.
///
/// ## Examples
///
/// ```gleam
/// let decoder = mcp_codec.dictionary(mcp_codec.int())
/// assert mcp_codec.decode(report.object([#("x", report.int(2))]), decoder) == Ok([#("x", 2)])
/// ```
pub fn dictionary(item: Decoder(a)) -> Decoder(List(#(String, a))) {
  Decoder(fn(value) {
    use fields <- result.try(object_fields(value))
    use #(_, reversed) <- result.map(
      list.try_fold(fields, #(set.new(), []), fn(state, field) {
        let #(seen, values) = state
        use name <- result.try(decode(field.0, string()))
        use <- bool.guard(
          set.contains(seen, name),
          Error(DecodeError([name], "duplicate property")),
        )
        use decoded <- result.map(at(decode(field.1, item), name))
        #(set.insert(seen, name), [#(name, decoded), ..values])
      }),
    )
    list.reverse(reversed)
  })
}

/// Requires object shape while retaining every open-schema property.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.object([]), mcp_codec.raw_object()) == Ok(report.object([]))
/// ```
pub fn raw_object() -> Decoder(report.Value) {
  dictionary(value()) |> map(report.object)
}

/// Requires array shape while retaining unconstrained items.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.list([]), mcp_codec.raw_array()) == Ok(report.list([]))
/// ```
pub fn raw_array() -> Decoder(report.Value) {
  list(value()) |> map(report.list)
}

/// Requires explicit JSON null rather than any absent field.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.decode(report.null(), mcp_codec.null()) == Ok(Nil)
/// ```
pub fn null() -> Decoder(Nil) {
  literal(report.null(), Nil)
}

/// Encodes absence by omitting the property, leaving explicit null to its codec.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.optional("name", None, report.string) == []
/// ```
pub fn optional(
  name: String,
  value: Option(a),
  encode: fn(a) -> report.Value,
) -> List(#(String, report.Value)) {
  case value {
    None -> []
    Some(value) -> [#(name, encode(value))]
  }
}

/// Encodes a nullable value without making any property-presence decision.
///
/// ## Examples
///
/// ```gleam
/// assert mcp_codec.nullable_value(None, report.string) == report.null()
/// ```
pub fn nullable_value(
  value: Option(a),
  encode: fn(a) -> report.Value,
) -> report.Value {
  case value {
    None -> report.null()
    Some(value) -> encode(value)
  }
}

fn failure(reason: String) -> Result(a, DecodeError) {
  Error(DecodeError([], reason))
}

fn at(
  result: Result(a, DecodeError),
  segment: String,
) -> Result(a, DecodeError) {
  result
  |> result.map_error(fn(error) {
    DecodeError(..error, path: [segment, ..error.path])
  })
}
