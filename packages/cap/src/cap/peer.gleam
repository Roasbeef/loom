//// Caller-owned message inspection and authorized resident peer delivery.
////
//// The harness binds the sender, checks the recipient's directional grant,
//// and stores an admission receipt atomically with the message. These calls
//// grant no ownership, join authority, or ability to wake a saved session.
//// Caller-owned inspection also covers same-session strand delivery: `inbox`
//// reads pending inputs, `history` reads materialized inputs, and `received`
//// reads durable cross-session admission receipts. None consumes or acknowledges
//// a message. `roster` lists authorized remote links, never an inbox.

import cap/internal/dispatch
import cap/internal/wire
import core/msgpack
import gleam/result
import gleam/string

/// Returns linked session metadata and authorized exports as JSON text.
/// This lists remote links, never an inbox; an empty roster says nothing about
/// same-session strand sends or pending inputs.
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

fn call(
  name: String,
  arguments: msgpack.MsgPackValue,
) -> Result(String, String) {
  use value <- result.try(
    dispatch.call(name, arguments) |> result.map_error(string.inspect),
  )
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error("invalid peer response")
  }
}

/// Pages caller-owned pending strand inputs, including local and remote sends.
/// `after` is an exclusive ID cursor, empty for the first page; limit is 1..12.
/// JSON has revision, items, total, and next. Follow next even on an empty page.
/// Reads do not consume inputs. Pending bodies disappear on operation abort.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.inbox(after: "", limit: 12)
/// ```
pub fn inbox(after after: String, limit limit: Int) -> Result(String, String) {
  call(
    "peer.inbox",
    wire.args([#("after", wire.string(after)), #("limit", wire.int(limit))]),
  )
}

/// Reads one caller-owned pending or materialized input by its reserved entry ID.
/// JSON null means absent from these caller-owned stores. Consumption racing
/// inspection resolves against the ownership capture's transcript leaf.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.inbox_get(id: id)
/// ```
pub fn inbox_get(id id: String) -> Result(String, String) {
  call("peer.inbox_get", wire.args([#("id", wire.string(id))]))
}

/// Pages materialized user inputs on the caller's conversation branch.
/// `before` is an exclusive sequence cursor; zero starts at the current leaf.
/// Limit is 1..64 scanned message entries. Follow JSON next even when items
/// is empty: assistant/tool entries also advance the scanned window.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.history(before: 0, limit: 64)
/// ```
pub fn history(before before: Int, limit limit: Int) -> Result(String, String) {
  call(
    "peer.history",
    wire.args([#("before", wire.int(before)), #("limit", wire.int(limit))]),
  )
}

/// Pages retained cross-session admission receipts addressed to this caller.
/// `after` is the opaque cursor from JSON next, empty initially; limit is 1..64.
/// The cursor scans global receipt records before recipient filtering. Continue
/// through next on empty pages; other recipients' bodies are never returned.
/// Receipt keys are hashes, not arrival order. Start a fresh scan to observe
/// new admissions and reconcile stable message identities across scans.
/// Receipts retain bodies after abort and prove admission, never consumption.
/// Same-session sends have no receipt history; use inbox and history for them.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.received(after: "", limit: 64)
/// ```
pub fn received(
  after after: String,
  limit limit: Int,
) -> Result(String, String) {
  call(
    "peer.received",
    wire.args([#("after", wire.string(after)), #("limit", wire.int(limit))]),
  )
}

/// Reads an existing remote admission receipt only if its recipient is this caller.
/// Source fields select the send identity and confer no read authority.
/// JSON null means missing or addressed to another strand.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.received_get(source_session: session, source_strand: "reviewer", message_id: "finding-1")
/// ```
pub fn received_get(
  source_session source_session: String,
  source_strand source_strand: String,
  message_id message_id: String,
) -> Result(String, String) {
  call(
    "peer.received_get",
    wire.args([
      #("source_session", wire.string(source_session)),
      #("source_strand", wire.string(source_strand)),
      #("message_id", wire.string(message_id)),
    ]),
  )
}

/// Reads this caller's existing receipt from a linked resident remote session.
/// The harness binds source session and strand. An outgoing link is required;
/// the call never sends a message or opens a saved recipient.
///
/// All bodies are complete; oversized responses fail explicitly.
///
/// ## Examples
///
/// ```gleam
/// // peer.sent_receipt(session: session, message_id: "finding-1")
/// ```
pub fn sent_receipt(
  session session: String,
  message_id message_id: String,
) -> Result(String, String) {
  call(
    "peer.sent_receipt",
    wire.args([
      #("session", wire.string(session)),
      #("message_id", wire.string(message_id)),
    ]),
  )
}
