//// The command that reaches a session on another orchestrator, in the words
//// every client uses for it (protocol-change/078, phase 3, and
//// protocol-change/085).
////
//// A client is connected to one orchestrator, and a session lives on the
//// orchestrator that created it. The client never forwards its user to the
//// other, because the other holds its own owner credential and this client has
//// none for it. What it can do is say which launch reaches the session, on the
//// machine whose owner token it needs. The terminal says it when a daemon
//// answers `not_owner`, and the web home says it beside a session another
//// orchestrator lists. Both must say the same thing, so the words live here,
//// below both hosts.
////
//// The line is advice for a person to run, so it names the owner token file with
//// a placeholder and never with a path: the file is on the other machine, and
//// this module could not know where.

import gleam/option.{type Option, None, Some}

/// What stands in for the address of an orchestrator whose configuration gives
/// none.
pub const unknown_address = "<its control address>"

/// What stands in for the owner token file on the other machine.
pub const token_placeholder = "<owner token file on that host>"

/// The launch that opens `session` on the orchestrator at `address`, or with the
/// placeholder when the configuration has no address for it.
///
/// ## Examples
///
/// ```gleam
/// assert launch_words.launch_line(Some("ws://10.0.0.4:7000"), "0198c1aa")
///   == "loom --addr ws://10.0.0.4:7000 --session 0198c1aa --token-file <owner token file on that host>"
/// ```
pub fn launch_line(address: Option(String), session: String) -> String {
  // Resolve the orchestrator address or fall back to the placeholder.
  let at = case address {
    Some(found) -> found
    None -> unknown_address
  }

  "loom --addr "
  <> at
  <> " --session "
  <> session
  <> " --token-file "
  <> token_placeholder
}
