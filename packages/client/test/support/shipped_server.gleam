//// The shipped `loomd` a fixture launches, run with a home of its own.
////
//// The shipped-daemon fixtures start the real `bin/loomd` named by
//// `LOOM_BOOTSTRAP_E2E_SERVER`, and the launcher spawns it with the test
//// VM's environment. A daemon reads several things from `HOME`: the
//// Claude Code hooks in `~/.claude/settings.json`, skills under
//// `~/.claude/skills` and `~/.agents/skills`, the extensions installed
//// under `~/.loom`, the home guidance files the system prompt carries,
//// and the global Git identity it copies into each tool home. On a
//// developer's machine every one of those is the operator's own
//// configuration, so a fixture session ran the operator's hooks and
//// failed, while CI passed because its container has no `~/.claude`.
//// A fixture's outcome must not depend on whose machine it runs on.
////
//// The isolation cannot be set on the test VM itself. Other suites in the
//// same VM read the real process environment, `git_identity_test` among
//// them, and `os:putenv` would change it for all of them at once. So
//// `from_environment` writes a small launcher script which exports a
//// fresh `HOME`, an `XDG_CONFIG_HOME` inside it, and a `GIT_CONFIG_GLOBAL`
//// naming a generated identity, then execs the real server with its
//// arguments unchanged. The fixture passes that script wherever it passed
//// the server path before. `exec` keeps the process id, so the endpoint's
//// process-birth fence names the daemon itself, as it did before.
////
//// The launcher derives `--helper` from the server's directory, and the
//// enforcement probe looks for `loom-exec` in the same place. The script's
//// directory therefore carries a symbolic link to the real sibling
//// helper, so the daemon receives the same helper argument it did when it
//// was launched directly.

import broker/token
import filepath
import gleam/bit_array
import gleam/string
import host/bootstrap as native
import simplifile

/// The isolated launcher for the shipped server, or `Error(Nil)` when
/// `LOOM_BOOTSTRAP_E2E_SERVER` is unset and the fixture should skip.
///
/// Each call builds a new launcher with a new home under `build/`, so two
/// fixtures never share configuration. A fixture that relaunches its
/// daemon reuses the one path it was given, which keeps the executable
/// the launcher records identical across the relaunch.
///
/// ## Examples
///
/// ```gleam
/// // case shipped_server.from_environment() {
/// //   Error(Nil) -> io.println_error("SKIP: LOOM_BOOTSTRAP_E2E_SERVER is unset")
/// //   Ok(server) -> fixture(server)
/// // }
/// ```
pub fn from_environment() -> Result(String, Nil) {
  case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
    Error(Nil) -> Error(Nil)
    Ok(server) -> Ok(isolate(server))
  }
}

fn isolate(server: String) -> String {
  let assert Ok(server) = native.find_executable(server)
    as "LOOM_BOOTSTRAP_E2E_SERVER names an executable shipped server"
  let directory =
    "build/shipped-home-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the isolated launcher has a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the isolated launcher uses absolute paths"

  // The home starts empty apart from the Git identity. Nothing the daemon
  // discovers under it can come from the operator who runs the fixture.
  let home = directory <> "/home"
  let git_config = home <> "/.gitconfig"
  let assert Ok(Nil) = native.ensure_private_directory(home)
    as "the isolated home is private"
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.config")
    as "the isolated home has an empty XDG configuration directory"
  let assert Ok(Nil) =
    simplifile.write(
      git_config,
      "[user]\n\tname = Loom Fixture\n\temail = fixture@loom.invalid\n",
    )
    as "the isolated home has an explicit Git identity"

  // The helper is linked only when the real server has one beside it, so
  // the launcher passes `--helper` in exactly the cases it did before.
  let helper = filepath.join(filepath.directory_name(server), "loom-exec")
  case native.find_executable(helper) {
    Error(_) -> Nil
    Ok(helper) -> {
      let assert Ok(Nil) =
        simplifile.create_symlink(to: helper, from: directory <> "/loom-exec")
        as "the isolated launcher sits beside the shipped helper"
      Nil
    }
  }

  let launcher = directory <> "/loomd"
  let assert Ok(Nil) =
    simplifile.write(
      launcher,
      string.join(
        [
          "#!/bin/sh",
          "HOME=" <> quote(home),
          "XDG_CONFIG_HOME=" <> quote(home <> "/.config"),
          "GIT_CONFIG_GLOBAL=" <> quote(git_config),
          "export HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL",
          "exec " <> quote(server) <> " \"$@\"",
          "",
        ],
        "\n",
      ),
    )
    as "the isolated launcher script is written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(launcher, 0o700)
    as "the isolated launcher is executable by its owner"
  launcher
}

// A POSIX single-quoted word. The only character a single-quoted word
// cannot hold is the quote itself, which closes the word, adds an escaped
// quote, and reopens it.
fn quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\\''") <> "'"
}
