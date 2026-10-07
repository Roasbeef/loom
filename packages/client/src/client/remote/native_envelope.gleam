//// Canonical native custody bytes shared by static bindings and the original owner.
//// The decoder proves complete Prepared and exact owner/scope equality without
//// retaining Dispatch callbacks or consulting a replacement generation.

import core/ids
import core/msgpack as mp
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/wire
import gleam/bit_array
import gleam/result

/// Encodes the exact post-clearance native custody envelope.
///
/// ## Examples
///
/// `encode(owner, scope, operation, prepared)` preserves ordered environment.
pub fn encode(
  owner: String,
  scope: identity.Scope,
  operation: ids.OpId,
  prepared: wire.Prepared,
) -> Result(BitArray, Nil) {
  use encoded <- result.try(wire.encode_prepared(prepared) |> failed)
  use decoded <- result.try(wire.decode_prepared(encoded) |> failed)
  use Nil <- result.try(case decoded == prepared {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use envelope <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue(owner),
        mp.BinaryValue(journal_codec.binding(scope)),
        mp.StringValue(ids.op_id_to_string(operation)),
        mp.StringValue(prepared.step),
        mp.BinaryValue(encoded),
      ]),
    )
    |> failed,
  )

  // Scope and physical coordinates consume the same existing 128 KiB child
  // allowance. A Prepared that fits alone may still be refused as an envelope.
  case bit_array.byte_size(envelope) <= 131_072 {
    True -> Ok(envelope)
    False -> Error(Nil)
  }
}

/// Decodes canonical native bytes against original configured coordinates.
///
/// ## Examples
///
/// `decode(owner, scope, bytes)` refuses another owner or scope.
fn decode_original(
  owner: String,
  scope: identity.Scope,
  bytes: BitArray,
) -> Result(#(ids.OpId, wire.Prepared), Nil) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use value <- result.try(wire.decode_value(bytes) |> failed)
  use fields <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(actual_owner),
      mp.BinaryValue(actual_scope),
      mp.StringValue(operation),
      mp.StringValue(step),
      mp.BinaryValue(prepared),
    ]) -> Ok(#(actual_owner, actual_scope, operation, step, prepared))
    _ -> Error(Nil)
  })
  use Nil <- result.try(
    case fields.0 == owner && fields.1 == journal_codec.binding(scope) {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  use operation <- result.try(ids.parse_op_id(fields.2) |> failed)
  use prepared <- result.try(wire.decode_prepared(fields.4) |> failed)
  use canonical <- result.try(encode(owner, scope, operation, prepared))
  case fields.3 == prepared.step && canonical == bytes {
    True -> Ok(#(operation, prepared))
    False -> Error(Nil)
  }
}

fn failed(value: Result(a, e)) -> Result(a, Nil) {
  result.replace_error(value, Nil)
}

/// Encodes the immutable actual clearance deadline alongside complete Prepared.
/// Ordinary historical version-one bytes retain their existing spelling.
///
/// ## Examples
///
/// `encode_cleared(owner, scope, operation, prepared, deadline)` never renews a deadline.
pub fn encode_cleared(
  owner: String,
  scope: identity.Scope,
  operation: ids.OpId,
  prepared: wire.Prepared,
  deadline_ms: Int,
) -> Result(BitArray, Nil) {
  use original <- result.try(encode(owner, scope, operation, prepared))
  use bytes <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(2),
        mp.IntValue(deadline_ms),
        mp.BinaryValue(original),
      ]),
    )
    |> failed,
  )
  case deadline_ms > 0 && bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(bytes)
    False -> Error(Nil)
  }
}

/// Requires the exact full clearance envelope, including its original deadline.
///
/// ## Examples
///
/// `decode_cleared(owner, scope, bytes)` refuses legacy bytes without a deadline.
pub fn decode_cleared(
  owner: String,
  scope: identity.Scope,
  bytes: BitArray,
) -> Result(#(ids.OpId, wire.Prepared, Int), Nil) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use value <- result.try(wire.decode_value(bytes) |> failed)
  use fields <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(2),
      mp.IntValue(deadline),
      mp.BinaryValue(original),
    ]) -> Ok(#(deadline, original))
    _ -> Error(Nil)
  })
  use original <- result.try(decode_original(owner, scope, fields.1))
  use canonical <- result.try(encode_cleared(
    owner,
    scope,
    original.0,
    original.1,
    fields.0,
  ))
  case canonical == bytes {
    True -> Ok(#(original.0, original.1, fields.0))
    False -> Error(Nil)
  }
}

/// Reads either original historical envelope or complete current clearance bytes.
///
/// ## Examples
///
/// `decode(owner, scope, bytes)` preserves both admitted historical formats.
pub fn decode(
  owner: String,
  scope: identity.Scope,
  bytes: BitArray,
) -> Result(#(ids.OpId, wire.Prepared), Nil) {
  case decode_original(owner, scope, bytes) {
    Ok(original) -> Ok(original)
    Error(Nil) -> {
      use cleared <- result.try(decode_cleared(owner, scope, bytes))
      Ok(#(cleared.0, cleared.1))
    }
  }
}
