//// The package entry point. `gleam run` on this package — and the
//// erlang shipment's `entrypoint.sh run`, which is what `bin/loomd`
//// execs — starts the session server. Everything real lives in
//// `client/serve` and `client/extension/cli`; this module exists because
//// both runners call the module named after the package.
////
//// ## Why the verb split is here and not in `client/serve`
////
//// `loomd` grew its first subcommand with `loom ext`, and the natural
//// place for the split reads like `serve.main`. It cannot be: the
//// extension CLI needs the boot's own effect plane
//// (`serve.start_build_plane`), so `client/extension/cli` imports
//// `client/serve`, and Gleam has no cyclic imports. The two-line
//// dispatch therefore lives one module out, where both are importable.
//// The behaviour is the same either way — `loomd ext install …` reaches
//// the installer and everything else reaches the server — and this note
//// is here so the next reader does not "fix" it back into a cycle.

import argv
import client/extension/cli
import client/serve

/// Starts the session server, or runs `loom ext`. See `client/serve` for
/// the flag and environment surface and `client/extension/cli` for the
/// verbs.
///
/// ## Examples
///
/// ```gleam
/// // bin/loomd --session ./loom.db
/// // bin/loomd ext install ./my-extension
/// ```
///
pub fn main() -> Nil {
  case argv.load().arguments {
    ["ext", ..rest] -> cli.main(rest)
    _other -> serve.main()
  }
}
