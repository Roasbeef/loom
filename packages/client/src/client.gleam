//// The package entry point. `gleam run` on this package — and the
//// erlang shipment's `entrypoint.sh run`, which is what `bin/loomd`
//// execs, starts one daemon. Assembly lives in
//// `client/daemon/main` and `client/extension/cli`; this module exists because
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
//// `loomd ext install …` reaches the installer, `loomd access …` reaches
//// the one-shot owner control client, and other arguments reach the daemon.
//// This note
//// is here so the next reader does not "fix" it back into a cycle.

import argv
import client/daemon/admin
import client/daemon/main as daemon
import client/extension/cli
import gleam/io

/// Starts the single daemon, or runs `loom ext` or `loomd access`. See `client/daemon/main` for
/// the flag and environment surface and `client/extension/cli` for the
/// verbs.
///
/// ## Examples
///
/// ```gleam
/// // bin/loomd --state-dir /private/loom
/// // bin/loomd ext install ./my-extension
/// ```
///
pub fn main() -> Nil {
  case argv.load().arguments {
    ["--help"] | ["-h"] | ["help"] -> io.println(usage)
    ["access", "--help"] | ["access", "-h"] | ["help", "access"] ->
      io.println(admin.usage)
    ["ext", "--help"] | ["ext", "-h"] | ["help", "ext"] -> io.println(cli.usage)
    ["access", ..rest] -> admin.main(rest)
    ["ext", ..rest] -> cli.main(rest)
    _other -> daemon.main()
  }
}

const usage = "usage: loomd [--state-dir PATH] [--bind ADDRESS] [--capacity N]\n       [--owner-name NAME] [--read-scope SCOPE] [--network NETWORK]\n       [--helper PATH] [--config PATH] [--codemode-seed PATH]\n       [--codemode-seams PATH] [--best-effort | --full-enforcement]\n       loomd <command> [options]\n\ncommands:\n  access <command>    Manage session access.\n  ext <command>       Manage extensions.\n\nRun `loomd help <command>` for command usage."
