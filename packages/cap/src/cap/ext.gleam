//// `cap/ext` — the one capability an extension satellite calls before it
//// does anything else: "which tool did the model ask for, and with what?"
////
//// A code-mode program is submitted source with a `main`, so the harness
//// already knows what it wants when it launches the node. An extension is
//// the other way round: the artifact is compiled once at install and run
//// many times, and the *call* is what varies. Rather than smuggle the
//// call into the node's environment — where it would be un-typed, size
//// limited, and visible to every process in the jail — the satellite asks
//// for it over the capability channel it was going to open anyway. One
//// call, at boot, on the authenticated socket, under the same token every
//// other capability is judged against.
////
//// ## Wire shape (pin this)
////
//// Capability `ext.call`, arguments the empty map. The result is
////
//// ```
//// {tool: String, args: String, strand: String, deadline_ms: Int}
//// ```
////
//// `args` is **JSON text**, not a msgpack value. An extension tool is
//// typed `fn(dynamic.Dynamic, Ctx)`, and `gleam_json`'s parser is the
//// only route from bytes to a `Dynamic` that the extension seam's
//// allowlist admits — decoding a msgpack value into one would need an
//// FFI the prelude deliberately does not offer. Carrying the arguments as
//// text also means the harness hands over exactly the bytes the model's
//// tool call carried, with no re-encoding step in between to disagree
//// about.
////
//// Nothing here refuses anything, the same standing caveat `cap/net`
//// carries: this module marshals and labels, and the harness-side router
//// is what decides whether an `ext.call` is answered at all.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/result

/// The call an extension satellite was launched to serve.
pub type Call {
  Call(
    /// The manifest tool name the model invoked.
    tool: String,
    /// The call's arguments, as JSON text (see the module doc).
    args: String,
    /// The strand the call belongs to, for attribution.
    strand: String,
    /// Wall-clock milliseconds remaining when the call was handed over.
    deadline_ms: Int,
  )
}

/// Why the call could not be fetched.
pub type CallRefused {
  /// The harness refused to hand over a call.
  CallDenied(code: String, message: String)

  /// The capability channel could not carry the request.
  CallUnavailable(reason: String)
}

/// Asks the harness which tool this execution is for.
///
/// Capability: `ext.call`. Exactly one per execution: the satellite is
/// launched to serve one call, and a second request would be a second
/// admission against the same token.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(call) = ext.call()
/// assert call.tool != ""
/// ```
///
pub fn call() -> Result(Call, CallRefused) {
  use value <- result.try(
    dispatch.call("ext.call", wire.args([])) |> result.map_error(map_error),
  )
  decode(value)
  |> result.map_error(fn(reason) {
    CallUnavailable("bad ext.call result: " <> reason)
  })
}

fn decode(value: MsgPackValue) -> Result(Call, String) {
  use tool <- result.try(wire.string_field(value, "tool"))
  use args <- result.try(wire.string_field(value, "args"))
  use strand <- result.try(wire.string_field(value, "strand"))
  use deadline_ms <- result.try(wire.int_field(value, "deadline_ms"))
  Ok(Call(tool:, args:, strand:, deadline_ms:))
}

fn map_error(error: CallError) -> CallRefused {
  case error {
    Unreachable(reason:) -> CallUnavailable(reason:)
    Denied(code:, message:) -> CallDenied(code:, message:)
  }
}
