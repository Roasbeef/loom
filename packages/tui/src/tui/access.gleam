//// `loom access`: the owner's access commands from the client shipment
//// (protocol-change/053).
////
//// The grammar, the control exchange and the lines printed are `host/access`,
//// which `loomd access` runs too, so the two binaries answer one command with
//// the same output. This launcher adds only what `loomd` cannot offer: with
//// `--addr` and `--token-file` the command reaches a daemon on another host
//// over `wss`, authenticated by the owner token in a private file. That
//// grants nothing the token did not already grant; it works only where the
//// owner has copied the token, and `ssh HOST loom access ...` avoids the copy.
////
//// Like `loom claim`, this installs no terminal state and starts no daemon.
//// It exits with status 0 when the daemon answered and 1 otherwise.

import host/access
import tui/internal/ffi_terminal

/// The usage `loom access --help` prints.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(access_command.usage(), "usage: loom access")
/// ```
pub fn usage() -> String {
  access.usage(access.Loom)
}

/// Runs `loom access` and exits with its status.
///
/// ## Examples
///
/// ```sh
/// loom access list
/// loom access --addr wss://loom.example.com/v2/control --token-file owner.token show alice
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case access.run(arguments, access.Loom, no_further_check) {
    access.Succeeded -> ffi_terminal.halt(0)
    access.Failed -> ffi_terminal.halt(1)
  }
}

// `loomd` also checks a request with the daemon's decoder before sending it.
// This package cannot import that decoder, so the daemon answers `bad_request`
// to anything the shared grammar let through and it refused.
fn no_further_check(_envelope: String) -> Result(Nil, String) {
  Ok(Nil)
}
