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
import gleam/list
import gleam/option.{type Option, None, Some}

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
  let arguments = argv.load().arguments
  case help_for(arguments) {
    // Help never starts the daemon: a flag before the token (`loomd
    // --state-dir X --help`) still answers usage rather than being
    // reported as an unknown daemon argument, and nothing is bound or
    // created on the way out.
    Some(text) -> io.println(text)
    None ->
      case arguments {
        ["access", ..rest] -> admin.main(rest)
        ["ext", ..rest] -> cli.main(rest)
        _other -> daemon.main()
      }
  }
}

// The `--help` and `-h` flags win wherever they appear in argv, matching
// the `loom` launcher's rule; the topic is the first recognised
// subcommand word, so `loomd access --help` and `loomd help access`
// describe the same command. The bare word `help` is recognised in first
// position only: anywhere else it is a plausible value — a principal or
// display name in an `access` command — and intercepting it would reach
// into arguments that belong to the subcommand.
fn help_for(arguments: List(String)) -> Option(String) {
  let asks = case arguments {
    ["help", ..] -> True
    _ -> list.contains(arguments, "--help") || list.contains(arguments, "-h")
  }
  case asks {
    False -> None
    True ->
      case list.find(arguments, is_topic) {
        Ok("access") -> Some(admin.usage)
        Ok("ext") -> Some(cli.usage)
        Ok(_other) | Error(Nil) -> Some(usage)
      }
  }
}

fn is_topic(word: String) -> Bool {
  case word {
    "access" | "ext" -> True
    _ -> False
  }
}

const usage = "usage: loomd [--state-dir PATH] [--bind ADDRESS] [--capacity N]\n       [--owner-name NAME] [--read-scope SCOPE] [--network NETWORK]\n       [--helper PATH] [--config PATH] [--codemode-seed PATH]\n       [--codemode-seams PATH] [--best-effort | --full-enforcement]\n       loomd <command> [options]\n\ncommands:\n  access <command>    Manage session access.\n  ext <command>       Manage extensions.\n\nRun `loomd help <command>` for command usage."
