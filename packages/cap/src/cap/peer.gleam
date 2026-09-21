//// Explicitly authorized communication with resident peer strands.
////
//// The harness binds the sender, checks the recipient's directional grant,
//// and stores an admission receipt atomically with the message. These calls
//// grant no ownership, join authority, or ability to wake a saved session.

import cap/internal/dispatch
import cap/internal/wire
import core/msgpack
import gleam/result
import gleam/string

/// Returns linked session metadata and authorized exports as JSON text.
///
/// ## Examples
///
/// ```gleam
/// // peer.roster()
/// ```
pub fn roster() -> Result(String, String) {
  call("peer.roster", wire.args([]))
}

/// Sends one message with a stable retry identity and returns its JSON receipt.
/// Reuse an identity only with the same recipient and body. The receipt means
/// admitted durably, not read or completed by the recipient.
///
/// ## Examples
///
/// ```gleam
/// // peer.send(session: session, strand: "reviewer", message_id: "finding-1", text: "Review ready.")
/// ```
pub fn send(
  session session: String,
  strand strand: String,
  message_id id: String,
  text body: String,
) -> Result(String, String) {
  call(
    "peer.send",
    wire.args([
      #("session", wire.string(session)),
      #("strand", wire.string(strand)),
      #("message_id", wire.string(id)),
      #("text", wire.string(body)),
    ]),
  )
}

fn call(name, arguments) -> Result(String, String) {
  use value <- result.try(
    dispatch.call(name, arguments) |> result.map_error(string.inspect),
  )
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("invalid peer response")
  }
}
