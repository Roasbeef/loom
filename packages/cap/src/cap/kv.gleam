//// `cap/kv` — the ephemeral scratch store: a session-scoped
//// key/value space a program can stash bytes in and read back, including
//// across the calls of a kept-alive satellite cell.
////
//// It is **ephemeral by design** (design §6.5). Anything worth keeping
//// leaves through a `cap/report` artifact; the scratch store may be
//// evicted or reset between calls, so a program must always tolerate a
//// vanished value — `get` returns `Ok(None)`, never an error, when a key
//// is absent. Treat it as a cache, never a database.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import gleam/option.{type Option, None, Some}
import gleam/result

/// Why a scratch-store call failed at the infrastructure level. A missing
/// key is *not* an error — it is `Ok(None)` from `get`.
pub type KvError {
  /// The broker refused the call in-band.
  KvDenied(code: String, message: String)

  /// The capability channel could not carry the call.
  KvUnavailable(reason: String)
}

/// Reads a key. `Ok(None)` when the key is absent or was evicted — the
/// case every caller must handle.
///
/// Capability: `kv.get`.
pub fn get(key: String) -> Result(Option(BitArray), KvError) {
  let args = wire.args([#("key", wire.string(key))])
  use value <- result.try(
    dispatch.call("kv.get", args) |> result.map_error(map_error),
  )
  use found <- result.try(
    wire.bool_field(value, "found")
    |> result.map_error(fn(reason) {
      KvUnavailable("bad kv.get result: " <> reason)
    }),
  )
  case found {
    False -> Ok(None)
    True ->
      wire.binary_field(value, "value")
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        KvUnavailable("bad kv.get result: " <> reason)
      })
  }
}

/// Stores bytes under a key, overwriting any prior value.
///
/// Capability: `kv.set`.
pub fn set(key: String, value: BitArray) -> Result(Nil, KvError) {
  let args =
    wire.args([#("key", wire.string(key)), #("value", wire.binary(value))])
  dispatch.call("kv.set", args)
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Deletes a key. Deleting an absent key succeeds.
///
/// Capability: `kv.delete`.
pub fn delete(key: String) -> Result(Nil, KvError) {
  let args = wire.args([#("key", wire.string(key))])
  dispatch.call("kv.delete", args)
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

fn map_error(error: CallError) -> KvError {
  case error {
    Unreachable(reason:) -> KvUnavailable(reason:)
    Denied(code:, message:) -> KvDenied(code:, message:)
  }
}
