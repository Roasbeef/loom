//// Starting a daemon whose configuration asks for trusted distribution.
////
//// A daemon with a `[distribution]` table must run on a VM that was booted
//// with TLS distribution flags, and those flags exist before any Gleam code
//// does. They name an options file, which `loomd distribution options`
//// renders from the very table the daemon will read, and `bin/loomd` adds the
//// flags when `LOOM_DISTRIBUTION_OPTFILE` names that file. Without this
//// module an operator renders the file and exports the variable by hand before
//// `loom` can start such a daemon, and a restart that forgets either fails with
//// a boot refusal.
////
//// The launcher does both steps. It runs the renderer on every launch and
//// removes the previous file first, so a file the table no longer matches is
//// never handed to a daemon, and it sets the variable for the child only. It
//// runs the daemon's own `distribution options` command instead of rendering in
//// process because the text names the daemon's verify function and its pin
//// encoding, and this package cannot depend on the daemon's.
////
//// Two cases leave the launch as it was. A configuration with no
//// `[distribution]` table has nothing to render. An environment that already
//// sets `LOOM_DISTRIBUTION_OPTFILE` is the operator's explicit choice, so the
//// launcher neither renders nor overrides it.
////
//// ## Flow
////
//// `prepare` → `decide` → `render`, then `command` wraps the launch
////
//// 1. `prepare` reads the configuration the daemon will load and asks
////    `decide` what to do.
//// 2. `render` deletes the old options file, runs `loomd distribution
////    options CONFIG OUT`, and answers the environment to give the child.
//// 3. `command` turns that environment into the program and arguments to
////    spawn, because the paused wrapper that starts the daemon can run one
////    program and passes no environment of its own.

import filepath
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as host
import simplifile
import tom

/// The variable `bin/loomd` reads to boot the VM for TLS distribution.
pub const variable = "LOOM_DISTRIBUTION_OPTFILE"

// The renderer boots one short VM, which takes about a second, so the bound is
// loose enough for a loaded machine and tight enough that a wedged helper does
// not spend the caller's whole startup budget.
const render_timeout_ms = 20_000

/// What a launch does about the options file.
pub type Plan {
  /// The configuration has no `[distribution]` table, so the daemon boots
  /// without distribution and no file is needed.
  NotDistributed

  /// The environment already names an options file. It is used as given, even
  /// when it is stale, because the operator chose it.
  OperatorProvided

  /// The launcher renders the file at `path` and names it to the child.
  Render(
    /// Where the file is written, inside the private state root.
    path: String,
  )
}

/// Decides what a launch does about the options file.
///
/// `inherited` is the value of `LOOM_DISTRIBUTION_OPTFILE` in the launcher's
/// environment, with an empty value counting as unset because `bin/loomd` tests
/// it that way. Whether the configuration has a table is the daemon's own test,
/// the presence of the key `distribution`: a table that is malformed is still
/// rendered, so the renderer's refusal names the key instead of the daemon's
/// boot refusal later. Text that does not parse as TOML is not rendered, and
/// the daemon reports the parse error itself.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_launch.decide("", Error(Nil), "/state") == NotDistributed
/// ```
pub fn decide(
  config_text: String,
  inherited: Result(String, Nil),
  state: String,
) -> Plan {
  case inherited {
    Ok(path) if path != "" -> OperatorProvided
    Ok(_) | Error(Nil) ->
      case tom.parse(config_text) {
        Ok(document) ->
          case dict.has_key(document, "distribution") {
            True -> Render(options_path(state))
            False -> NotDistributed
          }
        Error(_) -> NotDistributed
      }
  }
}

/// The options file the launcher renders for the daemon of this state root.
///
/// It sits beside the state root's other private files and has a name of its
/// own, so it cannot replace a file the operator keeps elsewhere under the
/// documented `distribution.options` name.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_launch.options_path("/home/me/.loom")
///   == "/home/me/.loom/distribution-launch.options"
/// ```
pub fn options_path(state: String) -> String {
  filepath.join(state, "distribution-launch.options")
}

/// Prepares the environment a daemon launch needs, rendering the options file
/// when the configuration calls for one.
///
/// `server` is the executable that will be launched, `config` the configuration
/// path it will be given (empty when it gets none), `state` its state root and
/// `inherited` the launcher's own `LOOM_DISTRIBUTION_OPTFILE`. The answer is the
/// assignments to add to the child's environment, empty when the launch needs
/// nothing. A render that fails is an error carrying the renderer's own words,
/// so the operator sees the refused key and not a bare boot failure.
///
/// ## Examples
///
/// ```gleam
/// distribution_launch.prepare("/usr/local/bin/loomd", "", "/state", Error(Nil))
/// // -> Ok([])
/// ```
pub fn prepare(
  server: String,
  config: String,
  state: String,
  inherited: Result(String, Nil),
) -> Result(List(#(String, String)), String) {
  use text <- result.try(read_config(config))

  // Only a configuration with a table and no operator-chosen file needs the
  // renderer, so the other two outcomes spawn nothing.
  case decide(text, inherited, state) {
    NotDistributed | OperatorProvided -> Ok([])
    Render(path:) -> render(server, config, path)
  }
}

/// The program and arguments that start the daemon with `environment`.
///
/// With nothing to add the daemon is started directly. With assignments the
/// program is `env`, which sets them and executes the daemon in place, so the
/// process the launcher fenced is still the one that becomes the daemon and no
/// new process appears between them.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_launch.command("/bin/loomd", ["--state-dir", "/s"], [])
///   == #("/bin/loomd", ["--state-dir", "/s"])
/// ```
pub fn command(
  server: String,
  arguments: List(String),
  environment: List(#(String, String)),
) -> #(String, List(String)) {
  // An empty environment is the common launch and must stay a direct spawn, so
  // that the process the launcher fences is the daemon's own executable.
  case environment {
    [] -> #(server, arguments)
    _ -> {
      let assignments =
        list.map(environment, fn(entry) { entry.0 <> "=" <> entry.1 })
      #("/usr/bin/env", list.flatten([assignments, [server], arguments]))
    }
  }
}

/// Reads the configuration the daemon will load, or nothing when it gets none.
fn read_config(config: String) -> Result(String, String) {
  case config {
    "" -> Ok("")
    path ->
      simplifile.read(path)
      |> result.map_error(fn(error) {
        "read config " <> path <> ": " <> simplifile.describe_error(error)
      })
  }
}

/// Renders the options file with the daemon's own command and names it to the
/// child.
fn render(
  server: String,
  config: String,
  path: String,
) -> Result(List(#(String, String)), String) {
  use Nil <- result.try(remove_previous(path))
  use captured <- result.try(
    host.run_captured(
      server,
      ["distribution", "options", config, path],
      render_timeout_ms,
    )
    |> result.map_error(fn(reason) {
      "render the distribution options file: could not run "
      <> server
      <> ": "
      <> reason
    }),
  )

  // The status is the renderer's verdict on the table. Its output is the
  // reason, and it holds no credential: the renderer prints a refused key or a
  // path, never a certificate, key or cookie.
  case captured.status {
    0 -> Ok([#(variable, path)])
    status ->
      Error(
        "render the distribution options file for "
        <> config
        <> " failed with status "
        <> string.inspect(status)
        <> ": "
        <> string.slice(string.trim(captured.output), 0, 1000),
      )
  }
}

/// Deletes the file an earlier launch left, so that a failed render cannot
/// leave a stale file for the daemon to be pointed at.
fn remove_previous(path: String) -> Result(Nil, String) {
  case simplifile.delete(path) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "remove the previous distribution options file "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}
