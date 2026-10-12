//// A provisioned ledger deployment on disk, for the tests of the operator
//// commands and of `install` (protocol-change/086).
////
//// Each test provisions its own two-node plan with the real commands, so the
//// certificates, the signatures and the sealed authority key are what an
//// operator would have. The one thing a test chooses is the home directory the
//// authority key is sealed under, so no test touches the real `$HOME`.

import client/daemon/distribution_cli
import client/ledger_control.{type Handle, Handle}
import client/ledger_reference
import client/ledger_service
import client/ledger_sync.{type Daemon, Daemon}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/log

/// The passphrase every test deployment is sealed under.
pub const passphrase = "correct horse battery"

/// A laptop that uses one executor, the smallest plan whose pin tables are not
/// empty and whose executor has an orchestrator to be dialed by.
pub const plan_text =
  "[[node]]
name = \"hub\"
role = \"orchestrator\"
erlang_node = \"loom@hub.example\"
executors = [\"devbox\"]

[[node]]
name = \"devbox\"
role = \"executor\"
erlang_node = \"loom@devbox.example\"
[node.workspaces]
repo = \"/home/me/src/loom\"
"

/// Where a test deployment lives.
pub type Deployed {
  Deployed(
    /// An absolute scratch directory, empty at the start.
    base: String,
    /// The home the authority key was sealed under: `<base>/operator`.
    home: String,
    /// The passphrase file, mode 0600.
    passphrase_file: String,
    /// The directory `provision` wrote bundles and `ledger.log` into.
    out: String,
  )
}

/// A fresh absolute scratch directory.
pub fn scratch(label: String) -> String {
  let directory =
    "build/ledger-deployment-" <> label <> "-" <> int.to_string(unique())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(absolute) = bootstrap.absolute_path(directory)
  absolute
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(a)) -> Int

fn unique() -> Int {
  int.absolute_value(unique_integer([]))
}

/// Provisions `plan` in ledger mode into a fresh directory, sealing the key
/// under `<base>/operator`.
///
/// ## Examples
///
/// ```gleam
/// let deployed = ledger_deployment.provision("enroll", ledger_deployment.plan_text)
/// ```
pub fn provision(label: String, plan: String) -> Deployed {
  let base = scratch(label)
  let phrase = base <> "/passphrase"
  let assert Ok(Nil) = simplifile.write(phrase, passphrase <> "\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(phrase, 0o600)
  let plan_path = base <> "/plan.toml"
  let assert Ok(Nil) = simplifile.write(plan_path, plan)
  let assert Ok(_) =
    distribution_cli.run([
      "provision",
      plan_path,
      base <> "/out",
      "--ledger",
      "--passphrase-file",
      phrase,
      "--home",
      base <> "/operator",
    ])
  Deployed(
    base:,
    home: base <> "/operator",
    passphrase_file: phrase,
    out: base <> "/out",
  )
}

/// The directory the authority key was sealed in.
pub fn authority_directory(deployed: Deployed) -> String {
  let assert Ok(entries) =
    simplifile.read_directory(deployed.home <> "/.loom/authority")
  let assert [deployment] = entries
  deployed.home <> "/.loom/authority/" <> deployment
}

/// The text of a file, which must exist.
pub fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)
  text
}

/// The lines of a ledger file, without the final newline.
pub fn lines(path: String) -> List(String) {
  read(path)
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
}

/// Runs a command and returns what it printed or the reason it was refused.
pub fn run(arguments: List(String)) -> Result(String, String) {
  distribution_cli.run(arguments) |> result.map(string.trim_end)
}

/// A ledger process for the node `node` of a provisioned deployment, over a
/// copy of the ledger `provision` wrote, in its own directory. It is the
/// production process with a name of its own and no peers, so a test can run it
/// beside others and drive it as a daemon would be driven.
///
/// ## Examples
///
/// ```gleam
/// let handle = ledger_deployment.serve(deployed, "hub", "loom@hub.example")
/// ```
pub fn serve(
  deployed: Deployed,
  label: String,
  name: String,
  node: String,
) -> Handle {
  let directory = deployed.base <> "/served-" <> label
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) =
    simplifile.write(
      directory <> "/ledger.log",
      read(deployed.out <> "/ledger.log"),
    )
  let assert Ok(Nil) =
    simplifile.write(
      directory <> "/ca.pem",
      read(authority_directory(deployed) <> "/ca.pem"),
    )
  let assert Ok(loaded) =
    ledger_reference.load(
      directory <> "/ledger.log",
      directory <> "/ca.pem",
      node,
    )
  let config =
    ledger_service.Config(
      ..ledger_service.configuration(
        loaded.store,
        loaded.ledger,
        loaded.verifier,
        [],
        log.discard(),
      ),
      peers: ledger_service.Supplied(reach: fn() { [] }),
      name: process.new_name("served"),
      tick_ms: 3_600_000,
    )
  let assert Ok(service) = ledger_service.start(config)
  Handle(service:, local: node, name:)
}

/// The `Daemon` a command sees when it is pointed at `handle`: the three
/// commands, with every reply passed through the decoder an operator uses.
pub fn daemon_over(handle: Handle) -> Daemon {
  Daemon(
    status: fn() {
      ledger_control.status(handle)
      |> result.map_error(describe)
      |> result.try(ledger_control.decode_status)
    },
    entries: fn(after, limit) {
      ledger_control.entries(handle, after, limit)
      |> result.map_error(describe)
      |> result.try(ledger_control.decode_entries)
    },
    append: fn(lines) {
      ledger_control.append(handle, lines)
      |> result.map_error(describe)
      |> result.try(ledger_control.decode_applied)
    },
  )
}

fn describe(failure: ledger_control.Failure) -> String {
  case failure {
    ledger_control.Invalid(step:) -> "ledger_invalid: " <> step
    ledger_control.Unavailable(reason:) -> reason
  }
}

/// A daemon nothing answers for, as when no daemon runs on the host.
pub fn nobody() -> Daemon {
  let refuse = "request not sent: no ready local daemon"
  Daemon(
    status: fn() { Error(refuse) },
    entries: fn(_, _) { Error(refuse) },
    append: fn(_) { Error(refuse) },
  )
}

/// The flags every signing command of a test takes: the home the key is sealed
/// under and the passphrase file.
pub fn signing(deployed: Deployed) -> List(String) {
  ["--home", deployed.home, "--passphrase-file", deployed.passphrase_file]
}
