//// A fixed-size command vocabulary for executor custody replay.
////
//// Records carry validated UUIDs and exact digests, never command or result
//// payloads. Complete bit patterns reject trailing, truncated and unknown data.
//// The journal supplies the metadata-bound scope; replay uses admission's public
//// reducer and discards its effects. `binding` encodes every scope field.

import core/ids
import executor/remote/admission
import executor/remote/identity
import gleam/bit_array
import gleam/result
import gleam/string

/// One persisted change, applied only through the pure admission reducer.
pub type Command {
  /// Reserve one lifetime slot with exact request evidence.
  Admit(
    /// The complete validated logical request.
    key: identity.RequestKey,
    /// Exactly 32 bytes of canonical request evidence.
    digest: identity.Digest,
  )

  /// Advance a previously admitted request's custody evidence.
  Apply(
    /// The complete validated logical request.
    key: identity.RequestKey,
    /// The original request evidence.
    digest: identity.Digest,
    /// A closed reducer vocabulary, never an arbitrary replacement state.
    event: admission.Event,
  )

  /// Permanently close the metadata-bound scope.
  CloseEpoch
}

/// The largest encoded record, including a terminal result digest.
pub const record_bytes = 138

/// Encodes an exact scope, including both epochs, for metadata equality.
///
/// ## Examples
///
/// ```gleam
/// journal_codec.binding(scope) // -> bounded versioned bytes.
/// ```
pub fn binding(scope: identity.Scope) -> BitArray {
  let #(session, workspace, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(scope)
  <<
    1,
    session:utf8,
    string.byte_size(workspace),
    workspace:utf8,
    string.byte_size(executor),
    executor:utf8,
    session_epoch:size(32),
    workspace_epoch:size(32),
  >>
}

/// Encodes a command into at most 138 bytes, with no optional unknown fields.
///
/// ## Examples
///
/// ```gleam
/// assert journal_codec.encode(journal_codec.CloseEpoch) == <<1, 0>>
/// ```
pub fn encode(command: Command) -> BitArray {
  case command {
    CloseEpoch -> <<1, 0>>
    Admit(key, digest) -> request_bytes(1, key, digest, <<>>)
    Apply(key, digest, event) -> {
      let #(tag, result) = event_bytes(event)
      request_bytes(tag, key, digest, result)
    }
  }
}

fn request_bytes(
  tag: Int,
  key: identity.RequestKey,
  digest: identity.Digest,
  result: BitArray,
) -> BitArray {
  let #(operation, request) = identity.key_fields(key)
  <<
    1,
    tag,
    operation:utf8,
    request:utf8,
    identity.digest_bytes(digest):bits,
    result:bits,
  >>
}

fn event_bytes(event: admission.Event) -> #(Int, BitArray) {
  case event {
    admission.AuthorizeLaunch -> #(2, <<>>)
    admission.RefuseBeforeLaunch(digest) -> #(3, identity.digest_bytes(digest))
    admission.ObserveTerminal(digest) -> #(4, identity.digest_bytes(digest))
    admission.ConfirmRetirement -> #(5, <<>>)
    admission.ConfirmOwnerReceipt(digest) -> #(6, identity.digest_bytes(digest))
    admission.Compact -> #(7, <<>>)
  }
}

/// Totally decodes one complete bounded record; input never enters an error.
///
/// ## Examples
///
/// ```gleam
/// assert journal_codec.decode(<<1, 0>>, scope) == Ok(journal_codec.CloseEpoch)
/// assert journal_codec.decode(<<1, 0, 0>>, scope) == Error(Nil)
/// ```
pub fn decode(bytes: BitArray, scope: identity.Scope) -> Result(Command, Nil) {
  use command <- result.try(decode_complete(bytes, scope))
  case encode(command) == bytes {
    True -> Ok(command)
    False -> Error(Nil)
  }
}

fn decode_complete(
  bytes: BitArray,
  scope: identity.Scope,
) -> Result(Command, Nil) {
  case bytes {
    <<1, 0>> -> Ok(CloseEpoch)
    <<
      1,
      tag,
      operation_bytes:bytes-size(36),
      request_bytes:bytes-size(36),
      digest_bytes:bytes-size(32),
      rest:bits,
    >> -> {
      use key <- result.try(decode_key(operation_bytes, request_bytes, scope))
      use digest <- result.try(identity.digest(digest_bytes) |> invalid)
      decode_event(tag, key, digest, rest)
    }
    _ -> Error(Nil)
  }
}

fn decode_key(
  operation_bytes: BitArray,
  request_bytes: BitArray,
  scope: identity.Scope,
) -> Result(identity.RequestKey, Nil) {
  use operation_text <- result.try(bit_array.to_string(operation_bytes))
  use request_text <- result.try(bit_array.to_string(request_bytes))
  use operation <- result.try(ids.parse_op_id(operation_text) |> invalid)
  use request <- result.try(identity.request_id(request_text) |> invalid)
  Ok(identity.request_key(scope, operation, request))
}

fn decode_event(
  tag: Int,
  key: identity.RequestKey,
  digest: identity.Digest,
  rest: BitArray,
) -> Result(Command, Nil) {
  case tag, rest {
    1, <<>> -> Ok(Admit(key, digest))
    2, <<>> -> Ok(Apply(key, digest, admission.AuthorizeLaunch))
    5, <<>> -> Ok(Apply(key, digest, admission.ConfirmRetirement))
    7, <<>> -> Ok(Apply(key, digest, admission.Compact))
    3, <<bytes:bytes-size(32)>>
    | 4, <<bytes:bytes-size(32)>>
    | 6, <<bytes:bytes-size(32)>>
    -> {
      use value <- result.try(identity.digest(bytes) |> invalid)
      use event <- result.try(case tag {
        3 -> Ok(admission.RefuseBeforeLaunch(value))
        4 -> Ok(admission.ObserveTerminal(value))
        6 -> Ok(admission.ConfirmOwnerReceipt(value))
        _ -> Error(Nil)
      })
      Ok(Apply(key, digest, event))
    }
    _, _ -> Error(Nil)
  }
}

fn invalid(value: Result(a, error)) -> Result(a, Nil) {
  result.map_error(value, fn(_) { Nil })
}
