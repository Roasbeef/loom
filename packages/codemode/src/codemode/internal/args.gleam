//// Decoding one capability call's arguments, for every router in this
//// package.
////
//// A `cap_call`'s `args` arrive from the satellite, which is untrusted
//// by construction: it runs model-authored code. So every field of every
//// inbound frame is *decoded* rather than assumed, and a wrong-shaped
//// argument becomes a `CapDenial` the program reads and repairs — never
//// a crash, and never a call made with a guessed value.
////
//// The three routers — `codemode/workspace`, `codemode/artifact`,
//// `codemode/orchestration` — each held a verbatim copy of these
//// decoders. One package, one wire, one msgpack map shape, three
//// implementations of reading a key out of it: the drift that invites is
//// not a wrong answer so much as a *differently worded* one, where the
//// same malformed call reads back one way through `report.emit` and
//// another through `fs.write`. The refusals a program repairs from
//// should be one vocabulary, so they come from one place.
////
//// Every function here is total over anything a satellite can send, and
//// every refusal names the offending field, so a program repairs the
//// call instead of guessing which of its arguments was wrong.

import codemode/satellite.{type CapDenial, CapDenial}
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// The code a structurally invalid argument travels under.
///
/// One literal, referenced by each router's own public constant rather
/// than restated in it: those constants are half of a contract whose
/// other half is `cap/fs.map_error` and `cap/kv.map_error`, and a
/// contract stated three times is a contract that can hold in two
/// places.
pub const invalid_argument_code = "invalid_argument"

/// One field of a call's argument map.
///
/// Both failures are the program's to repair and both say which: an
/// absent key names the key, and arguments that are not a map at all say
/// so rather than reporting every key as missing in turn.
///
/// ## Examples
///
/// ```gleam
/// // args.field(msgpack.MapValue([]), "path") == Error(args.invalid(..))
/// ```
///
pub fn field(
  value: MsgPackValue,
  key: String,
) -> Result(MsgPackValue, CapDenial) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.map_error(fn(_nil) { invalid("`" <> key <> "` is missing") })
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(invalid("arguments must be a map"))
  }
}

/// One field of a call's argument map, as text.
///
/// ## Examples
///
/// ```gleam
/// // args.string(request.args, "path")
/// ```
///
pub fn string(value: MsgPackValue, key: String) -> Result(String, CapDenial) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(invalid("`" <> key <> "` must be text"))
  }
}

/// One field of a call's argument map, as bytes.
///
/// `cap/kv.set` and `cap/report.emit` both marshal a `BitArray` with
/// `wire.binary`, so binary is the shape to expect — but text is taken
/// as its own bytes rather than refused, because a program that built
/// its value by string concatenation and sent it as text meant exactly
/// that, and refusing would cost a round trip to learn a distinction
/// neither the blob store nor the scratch store has.
///
/// ## Examples
///
/// ```gleam
/// // args.binary(request.args, "bytes")
/// ```
///
pub fn binary(value: MsgPackValue, key: String) -> Result(BitArray, CapDenial) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.BinaryValue(bytes:) -> Ok(bytes)
    msgpack.StringValue(text) -> Ok(<<text:utf8>>)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(invalid("`" <> key <> "` must be bytes or text"))
  }
}

/// One structurally invalid argument, as the denial a program reads.
///
/// ## Examples
///
/// ```gleam
/// assert args.invalid("bad").code == args.invalid_argument_code
/// ```
///
pub fn invalid(reason: String) -> CapDenial {
  CapDenial(code: invalid_argument_code, message: reason)
}
