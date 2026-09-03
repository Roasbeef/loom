//// `ext/memory` — the durable memory an installed extension owns:
//// something it wrote on one call and can read on the next, and after
//// the session it was written in has been closed and reopened.
////
//// One extension, one subtree. The harness composes the key from the
//// name an operator installed this extension under, so every cell an
//// extension writes is its own and no cell another extension wrote is
//// reachable from here — there is no argument in which one could be
//// named. `key` is a leaf: non-empty, no `/`, and bounded, refused in
//// band if it is not.
////
//// ## Not `cap/kv`, and not a database
////
//// `cap/kv` is the ephemeral scratch store: bytes that may be evicted
//// between calls and are gone with the session. This is the opposite —
//// a durable cell in the session's own store — and the choice between
//// them is the choice between a cache and a memory.
////
//// It is still not a database. A write is latest-wins over one cell,
//// there is no listing and no delete, and the value is bounded (64 KiB
//// of JSON text). Anything larger is a file, and an extension has
//// `cap/fs` to write one.
////
//// ## Nothing here reaches the model by itself
////
//// A remembered cell is never rendered into a prompt. It is reserved
//// blackboard state the model can neither read nor write, so an
//// extension that wants the model to see what it remembered injects it
//// itself, from a `before_agent_start` hook.
////
//// ## Hooks may remember too
////
//// The capability is served per extension rather than per invocation
//// kind, so a `[[hook]]`'s handler may call both of these exactly as a
//// tool's may. Recording what a hook saw for a later tool call to read
//// is the intended use, not a loophole.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import ext.{type Refusal, Refusal}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result

/// Writes `value` into this extension's cell named `key`, replacing
/// whatever it held.
///
/// Latest-wins and durable: the write is committed to the session's
/// store before this returns, and the next `recall` of the same key —
/// on this call, on a later call, or in a later session over the same
/// session file — reads it back.
///
/// Capability: `ext.remember`.
///
/// ## Examples
///
/// ```gleam
/// let seen = json.object([#("last_query", json.string("loom"))])
/// let assert Ok(Nil) = memory.remember("state", seen)
/// ```
///
pub fn remember(key: String, value: Json) -> Result(Nil, Refusal) {
  dispatch.call(
    "ext.remember",
    wire.args([
      #("key", wire.string(key)),
      #("value", wire.string(json.to_string(value))),
    ]),
  )
  |> result.replace(Nil)
  |> result.map_error(refusal("ext.remember"))
}

/// Reads this extension's cell named `key`.
///
/// `Ok(None)` is a cell that was never written — the case every
/// extension meets on its first call, and never an error. The value
/// comes back as a `Dynamic` because its shape is the extension's own;
/// `ext.decode_args` turns one into a typed value with the same decoder
/// vocabulary a tool's arguments use.
///
/// Capability: `ext.recall`.
///
/// ## Examples
///
/// ```gleam
/// let decoder = {
///   use last <- decode.field("last_query", decode.string)
///   decode.success(last)
/// }
/// let assert Ok(Some(value)) = memory.recall("state")
/// let assert Ok(last) = ext.decode_args(value, decoder)
/// ```
///
pub fn recall(key: String) -> Result(Option(Dynamic), Refusal) {
  use answer <- result.try(
    dispatch.call("ext.recall", wire.args([#("key", wire.string(key))]))
    |> result.map_error(refusal("ext.recall")),
  )
  use found <- result.try(
    wire.bool_field(answer, "found") |> result.map_error(malformed),
  )
  case found {
    False -> Ok(None)
    True -> {
      use text <- result.try(
        wire.string_field(answer, "value") |> result.map_error(malformed),
      )
      decoded(text)
    }
  }
}

// The stored document as a `Dynamic`. Parsed rather than handed back as
// text because the extension wrote a value and should read a value: the
// text is the wire's business, and an author who wanted the string could
// not tell it apart from a stored string.
fn decoded(text: String) -> Result(Option(Dynamic), Refusal) {
  json.parse(text, decode.dynamic)
  |> result.map(Some)
  |> result.map_error(fn(_error) {
    Refusal(message: "the remembered value did not parse back as JSON")
  })
}

// A capability failure as the refusal an author can pass straight back
// to the model. The code travels inside the sentence rather than being
// dropped: `memory_unavailable` is the host's problem and worth
// retrying, and `invalid_argument` is this extension's and is not.
fn refusal(cap: String) -> fn(CallError) -> Refusal {
  fn(error) {
    case error {
      Denied(code:, message:) ->
        Refusal(message: cap <> " was refused (" <> code <> "): " <> message)
      Unreachable(reason:) ->
        Refusal(message: cap <> " could not be reached: " <> reason)
    }
  }
}

fn malformed(reason: String) -> Refusal {
  Refusal(message: "bad ext.recall result: " <> reason)
}
