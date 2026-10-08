//// Two or more shipped daemons that trust each other as distributed Erlang
//// nodes, for the end-to-end tests of the distributed runtime (issue #697).
////
//// A distributed run has an orchestrator that owns sessions and a model
//// provider, and an executor that owns a checkout and runs the tools. The
//// unit tests of `client/distribution` and `client/remote` boot emulators of
//// their own. This module boots the real `bin/loomd` twice, because the
//// things an end-to-end test exists to catch are the ones a hand-built
//// emulator skips: the launcher's boot flags, the daemon's own startup
//// order, the configuration tables as an operator writes them, the home each
//// VM reads its cookie from, and the process that outlives the test.
////
//// The module has five parts, in the order a fixture uses them.
////
//// 1. **Credentials.** `mint_authority` and `issue` call `openssl` to make a
////    certificate authority and one leaf per node, with the exact node name as
////    a DNS name, and compute the SHA-256 pin of each leaf. `write_cookie`
////    writes the node's private cookie at that node's own `$HOME`, because the
////    emulator reads its cookie from there and `client/distribution` refuses
////    any other path.
//// 2. **Configuration.** `model_table`, `distribution_table`, `executor_table`
////    and `workspace_rows` render the pieces of a `loom.toml`. The executor's
////    `[workspaces.<name>] root` row is deliberately a separate function with
////    its own switch, `WorkspaceRows`, because that key does not exist on every
////    base this file runs against.
//// 3. **Daemons.** `layout` fixes where a daemon lives before it starts, so a
////    fixture can retire it after a failed assertion; `write_options` runs
////    `loomd distribution options`; `start` launches the daemon through a
////    wrapper that sets `LOOM_DISTRIBUTION_OPTFILE` inside an isolated home;
////    `retire` ends it by the process identity it recorded.
//// 4. **Observation.** A daemon dials no peer yet, so nothing in its VM says
////    whether it is connected. `run_probe` boots a throwaway emulator
////    (`support/remote_probe`) that the daemons list as a peer, and reads back
////    what it saw. `epmd_names` is the cheaper check that a node registered.
//// 5. **Sessions.** `open_control`, `create_registered` and `await_operation`
////    speak the control protocol to a daemon. `registered_script`,
////    `drive_registered_session` and the file assertions are the part of the
////    end-to-end that needs an orchestrator able to open a registered session.
////    They are complete but are not called by any test on the base this file
////    was written against, and each says so.
////
//// Everything a fixture creates lives under a directory the caller chose,
//// below `build/`. Nothing is written to `/tmp`, which Loom's jail replaces.

import broker/token
import client/daemon_server_test as wire
import client/tui_v2_test
import core/entry
import core/json.{type JsonValue}
import core/message
import etui/backend
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import session_view/session_channel
import simplifile
import support/daemon_observation
import support/internal/ffi_probe
import support/internal/ffi_proc
import support/internal/ffi_ws
import support/provider_http as provider
import support/shipped_server
import support/tui_driver
import tui/bootstrap
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/protocol
import weft/poll

// A reply from a shipped daemon waits behind its own admission budgets, as in
// the other shipped fixtures.
const wire_read_ms = 15_000

// --- credentials -------------------------------------------------------------

/// The certificate authority every node of one fixture trusts.
pub type Authority {
  Authority(
    /// PEM of the authority's certificate: each node's `ca`.
    certificate: String,
    /// PEM of the authority's private key, used only to sign leaves.
    key: String,
  )
}

/// One node's credentials, and where its VM reads its cookie.
pub type Identity {
  Identity(
    /// The full node name, `name@host`.
    node: String,
    /// The node's `$HOME`, which holds its `.erlang.cookie`.
    home: String,
    /// PEM certificate chain of the node.
    certificate: String,
    /// Private PEM key of the node, mode 0600.
    key: String,
    /// Lowercase hexadecimal SHA-256 of the DER of the certificate: the value
    /// every peer pins.
    pin: String,
  )
}

/// A peer a node trusts, as a `[[distribution.peers]]` row.
pub type Trust {
  Trust(
    /// The peer's full node name.
    node: String,
    /// The pin the peer's leaf certificate must hash to.
    pin: String,
  )
}

fn openssl(arguments: List(String), in directory: String) -> String {
  let assert Ok(executable) = ffi_proc.which("openssl")
    as "openssl is on PATH, which the credential minting needs"
  case ffi_proc.run(executable, arguments, in: directory) {
    Ok(#(0, output)) -> output
    other ->
      panic as {
        "openssl "
        <> string.join(arguments, " ")
        <> " failed: "
        <> string.inspect(other)
      }
  }
}

/// A random lowercase hexadecimal string of `bytes` bytes.
///
/// ## Examples
///
/// ```gleam
/// // random_hex(4) // -> "9f3a01c2"
/// ```
pub fn random_hex(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Makes a private P-256 certificate authority under `directory`.
///
/// ## Examples
///
/// ```gleam
/// // let authority = remote_daemons.mint_authority(directory)
/// ```
pub fn mint_authority(directory: String) -> Authority {
  let authority = Authority(directory <> "/ca.pem", directory <> "/ca.key")
  let config = directory <> "/ca.cnf"
  let assert Ok(Nil) =
    simplifile.write(
      config,
      string.join(
        [
          "[req]",
          "distinguished_name = dn",
          "x509_extensions = authority",
          "prompt = no",
          "[dn]",
          "CN = loom e2e authority",
          "[authority]",
          "basicConstraints = critical,CA:TRUE",
          "keyUsage = critical,keyCertSign,cRLSign",
          "subjectKeyIdentifier = hash",
          "",
        ],
        "\n",
      ),
    )
    as "the authority configuration is written"
  let _ =
    openssl(
      ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"],
      in: directory,
    )
  let _ =
    openssl(
      [
        "req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2",
        "-config", "ca.cnf", "-out", "ca.pem",
      ],
      in: directory,
    )
  let assert Ok(Nil) = simplifile.set_permissions_octal(authority.key, 0o600)
    as "the authority key is private"
  authority
}

/// Issues a leaf for `node` under `directory/label`, signed by `authority`.
///
/// The certificate carries the node name as a DNS name and `127.0.0.1` as both
/// a DNS name and an address, which is what `client/distribution` and TLS host
/// name checking need respectively. Two calls with the same `node` give two
/// different certificates, which is how a fixture makes a decoy that has the
/// right name and the wrong pin.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.issue(authority, directory, "exec", node, home)
/// ```
pub fn issue(
  authority: Authority,
  directory: String,
  label: String,
  node: String,
  home: String,
) -> Identity {
  let own = directory <> "/" <> label
  let assert Ok(Nil) = simplifile.create_directory_all(own)
    as "the credential directory is created"
  let assert Ok(Nil) = simplifile.set_permissions_octal(own, 0o700)
    as "the credential directory is private"
  let assert Ok(Nil) =
    simplifile.write(
      own <> "/leaf.cnf",
      string.join(
        [
          "basicConstraints = CA:FALSE",
          "keyUsage = digitalSignature",
          "extendedKeyUsage = serverAuth,clientAuth",
          "subjectAltName = DNS:" <> node <> ",DNS:127.0.0.1,IP:127.0.0.1",
          "",
        ],
        "\n",
      ),
    )
    as "the leaf extensions are written"
  let _ =
    openssl(
      ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "key.pem"],
      in: own,
    )
  let _ =
    openssl(
      [
        "req", "-new", "-key", "key.pem", "-subj", "/CN=loom-e2e-node", "-out",
        "leaf.csr",
      ],
      in: own,
    )
  let _ =
    openssl(
      [
        "x509", "-req", "-in", "leaf.csr", "-CA", authority.certificate,
        "-CAkey", authority.key, "-CAcreateserial", "-days", "2", "-sha256",
        "-extfile", "leaf.cnf", "-out", "cert.pem",
      ],
      in: own,
    )
  let _ =
    openssl(
      ["x509", "-in", "cert.pem", "-outform", "DER", "-out", "cert.der"],
      in: own,
    )
  let digest = openssl(["dgst", "-sha256", "-r", "cert.der"], in: own)
  let assert [pin, ..] = string.split(string.trim(digest), " ")
    as "openssl prints the digest first"
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(own <> "/key.pem", 0o600)
    as "the node key is private"
  assert string.length(pin) == 64
  Identity(
    node:,
    home:,
    certificate: own <> "/cert.pem",
    key: own <> "/key.pem",
    pin: string.lowercase(pin),
  )
}

/// Writes the cookie a node's VM reads from its own home, mode 0600, with no
/// trailing newline.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.write_cookie(identity, cookie)
/// ```
pub fn write_cookie(identity: Identity, cookie: String) -> Nil {
  let path = identity.home <> "/.erlang.cookie"
  let assert Ok(Nil) = simplifile.write(path, cookie)
    as "the node cookie is written at its own home"
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
    as "the node cookie is private"
  Nil
}

// --- configuration -----------------------------------------------------------

/// The `[models]`, `[roles]` and `[memory]` tables of a fixture daemon: one
/// model on `url`, which a daemon that never takes a model turn never calls,
/// and no distillation pass to race a test.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.model_table("http://127.0.0.1:9")
/// ```
pub fn model_table(url: String) -> String {
  "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
  <> url
  <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n"
}

/// The `[distribution]` table of `identity`, trusting `peers`.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.distribution_table(identity, authority, [Trust(node, pin)])
/// ```
pub fn distribution_table(
  identity: Identity,
  authority: Authority,
  peers: List(Trust),
) -> String {
  let rows =
    list.map(peers, fn(peer) {
      "[[distribution.peers]]\nnode = \""
      <> peer.node
      <> "\"\nsha256 = \""
      <> peer.pin
      <> "\"\n"
    })
  string.join(
    [
      "[distribution]",
      "node = \"" <> identity.node <> "\"",
      "ca = \"" <> authority.certificate <> "\"",
      "certificate = \"" <> identity.certificate <> "\"",
      "key = \"" <> identity.key <> "\"",
      "cookie = \"" <> identity.home <> "/.erlang.cookie\"",
      "",
      ..rows
    ],
    "\n",
  )
}

/// The `[executors.<name>]` table of an orchestrator.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.executor_table("box", executor.node)
/// ```
pub fn executor_table(name: String, node: String) -> String {
  "[executors." <> name <> "]\nnode = \"" <> node <> "\"\n"
}

/// Whether an executor's configuration registers a workspace.
///
/// The executor's `[workspaces.<name>] root` table is added to the daemon by a
/// separate change. A daemon built before it refuses the table as an unknown
/// key, so a fixture on such a base must leave it out, and a fixture on a base
/// that has it turns it on.
pub type WorkspaceRows {
  /// Write no `[workspaces]` table. The configuration every base accepts.
  WithoutWorkspaceRows

  /// Write the `[workspaces.<name>] root = "<checkout>"` table.
  WithWorkspaceRows
}

/// THE PLACE THAT WRITES THE EXECUTOR'S REGISTERED WORKSPACE.
///
/// With `WithWorkspaceRows` this registers `name` on the executor as the
/// directory `root`, which is what lets `sessions.create` on the orchestrator
/// say `executor: "box", workspace: "<name>"`. The follow-up that lands the
/// executor role turns the switch on in the test module and nowhere else.
///
/// ## Examples
///
/// ```gleam
/// remote_daemons.workspace_rows(WithoutWorkspaceRows, "repo", "/srv/repo")
/// // -> ""
/// ```
pub fn workspace_rows(
  rows: WorkspaceRows,
  name: String,
  root: String,
) -> String {
  case rows {
    WithoutWorkspaceRows -> ""
    WithWorkspaceRows ->
      "[workspaces." <> name <> "]\nroot = \"" <> root <> "\"\n"
  }
}

// --- daemons -----------------------------------------------------------------

/// Where one daemon lives, fixed before it starts so that a failed assertion
/// can still find and retire it.
pub type Layout {
  Layout(
    /// A short name for log lines.
    label: String,
    /// The directory holding everything of this daemon.
    directory: String,
    /// The isolated home of the daemon's VM: its cookie lives here.
    home: String,
    /// The isolated launcher of the shipped server, without distribution.
    launcher: String,
    /// The daemon's state root and endpoint files.
    paths: endpoint.Paths,
    /// The `loom.toml` the daemon is started with.
    config: String,
    /// The distribution options file `loomd distribution options` writes.
    options: String,
    /// A directory for the launching terminal's own workspace, which is not
    /// the checkout of any session.
    workspace: String,
  )
}

/// Lays out a daemon under `directory/label`, with an isolated home.
///
/// `shipped_server.from_environment` gives each daemon its own home, empty
/// apart from a Git identity, so the operator's Claude Code hooks, skills and
/// extensions cannot change what a fixture daemon does. That home is also
/// where the node's cookie must be, so this returns it.
///
/// The caller has already decided not to skip, so a missing
/// `LOOM_BOOTSTRAP_E2E_SERVER` is a fixture bug and not an absent shipment.
///
/// ## Examples
///
/// ```gleam
/// // let layout = remote_daemons.layout(directory, "orchestrator")
/// ```
pub fn layout(directory: String, label: String) -> Layout {
  let assert Ok(launcher) = shipped_server.from_environment()
    as "LOOM_BOOTSTRAP_E2E_SERVER names the shipped server"
  let own = directory <> "/" <> label
  let assert Ok(Nil) = simplifile.create_directory_all(own)
    as "the daemon directory is created"
  let assert Ok(paths) = endpoint.paths(own <> "/state")
    as "the daemon endpoint is reserved before launch"
  let workspace = own <> "/launch-workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the launch workspace is created"
  Layout(
    label:,
    directory: own,
    home: filepath.directory_name(launcher) <> "/home",
    launcher:,
    paths:,
    config: own <> "/loom.toml",
    options: own <> "/distribution.options",
    workspace:,
  )
}

/// Runs `loomd distribution options` for the daemon's configuration, with the
/// daemon's own isolated home, and checks it wrote the file.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.write_options(layout)
/// ```
pub fn write_options(layout: Layout) -> Nil {
  options_command(
    layout.launcher,
    layout.directory,
    layout.config,
    layout.options,
  )
}

fn options_command(
  launcher: String,
  directory: String,
  config: String,
  options: String,
) -> Nil {
  let assert Ok(#(status, output)) =
    ffi_proc.run(
      launcher,
      ["distribution", "options", config, options],
      in: directory,
    )
    as "the shipped options command runs"
  case status {
    0 -> Nil
    _ ->
      panic as {
        config
        <> ": loomd distribution options exited "
        <> int.to_string(status)
        <> ": "
        <> output
      }
  }
}

/// A launcher that adds the options file to the isolated one.
///
/// The `bin/loomd` script appends the TLS boot flags to `ERL_FLAGS` when
/// `LOOM_DISTRIBUTION_OPTFILE` is set. The wrapper sits beside the isolated
/// launcher, so the `--helper` the bootstrap derives from the launcher's
/// directory is the one it always was, and it `exec`s, so the process the
/// endpoint fences is the daemon.
fn distribution_launcher(layout: Layout) -> String {
  let path = filepath.directory_name(layout.launcher) <> "/loomd-distribution"
  let assert Ok(Nil) =
    simplifile.write(
      path,
      string.join(
        [
          "#!/bin/sh",
          "LOOM_DISTRIBUTION_OPTFILE=" <> quote(layout.options),
          "export LOOM_DISTRIBUTION_OPTFILE",
          "exec " <> quote(layout.launcher) <> " \"$@\"",
          "",
        ],
        "\n",
      ),
    )
    as "the distribution launcher is written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o700)
    as "the distribution launcher is executable"
  path
}

/// A running daemon and what a fixture needs to talk to it.
pub type Running {
  Running(
    layout: Layout,
    /// The authenticated bootstrap connection, kept open so the daemon has an
    /// owner for the duration of the test.
    connected: daemon_bootstrap.Connected,
    /// The loopback port of its client protocol.
    port: Int,
    /// `host:port` of the same listener, as the terminal client names it.
    address: String,
    /// The owner credential of the daemon.
    owner: String,
  )
}

/// Starts the daemon through the ordinary native bootstrap and authenticates.
///
/// A daemon whose distribution fails to start exits before it publishes an
/// endpoint, so the bootstrap's error is paired with the daemon's own log.
///
/// ## Examples
///
/// ```gleam
/// // let running = remote_daemons.start(layout)
/// ```
pub fn start(layout: Layout) -> Running {
  let launcher = distribution_launcher(layout)
  let started =
    bootstrap.resolve_daemon(
      bootstrap.Options(
        layout.workspace,
        "",
        launcher,
        layout.paths.root,
        layout.config,
        "",
      ),
      process.self(),
      60_000,
    )
  let connected = case started {
    Ok(connected) -> connected
    Error(reason) ->
      panic as {
        layout.label
        <> " did not start: "
        <> reason
        <> "\ndaemon log:\n"
        <> log_tail(layout)
      }
  }
  let assert Ok(address) = endpoint.address(connected.record)
    as "the daemon published its address"
  let assert endpoint.Ready(port:, ..) = connected.record
    as "the daemon published its port"
  let assert Ok(secret) = simplifile.read(connected.paths.token)
    as "the fixture owner reads its private credential"
  Running(layout:, connected:, port:, address:, owner: string.trim(secret))
}

/// The last lines of a daemon's log, for a failure message.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.log_tail(layout)
/// ```
pub fn log_tail(layout: Layout) -> String {
  case simplifile.read(layout.paths.log) {
    Ok(text) ->
      text
      |> string.split("\n")
      |> list.reverse
      |> list.take(40)
      |> list.reverse
      |> string.join("\n")
    Error(_) -> "(no daemon log)"
  }
}

/// Ends the daemon by the process identity its endpoint recorded, and waits
/// until that process is gone.
///
/// This runs outside the fixture body's deadline, so a body that failed or
/// timed out still leaves no daemon behind. It signals only the process whose
/// recorded birth still matches, never one that merely has the same number.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.retire(layout.paths)
/// ```
pub fn retire(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup decodes only this fixture's private endpoint"
  case record {
    None -> Nil
    Some(record) -> {
      assert record.fence.pid != native.current_process_id()
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth before signalling"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      let assert poll.Answered(Nil) =
        poll.until(within: 10_000, every: 25, attempt: fn() {
          case endpoint.is_present(record.fence) {
            Ok(False) -> poll.Done(Nil)
            Ok(True) -> poll.Retry
            Error(reason) -> poll.Fail(reason)
          }
        })
        as "actual native departure is witnessed before the fixture completes"
      Nil
    }
  }
}

// A POSIX single-quoted word.
fn quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\\''") <> "'"
}

// --- observation -------------------------------------------------------------

/// A probe emulator's own credentials and configuration.
pub type Probe {
  Probe(
    /// The probe's identity: its node name, home and certificate.
    identity: Identity,
    /// The `loom.toml` holding only the probe's `[distribution]` table.
    config: String,
    /// The options file generated for that table.
    options: String,
  )
}

/// Writes a probe's configuration and options file and returns the probe.
///
/// The options file is rendered by the shipped server's own command, through
/// `launcher`, exactly as for a daemon, so the probe boots with the same
/// flags and the same checks.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.probe(launcher, directory, "good", identity, authority, peers)
/// ```
pub fn probe(
  launcher: String,
  directory: String,
  label: String,
  identity: Identity,
  authority: Authority,
  peers: List(Trust),
) -> Probe {
  let config = directory <> "/probe-" <> label <> ".toml"
  let options = directory <> "/probe-" <> label <> ".options"
  let assert Ok(Nil) =
    simplifile.write(config, distribution_table(identity, authority, peers))
    as "the probe configuration is written"
  options_command(launcher, directory, config, options)
  Probe(identity:, config:, options:)
}

/// Boots the probe emulator, runs `steps`, and returns its `RESULT` lines.
///
/// The emulator is started with the production boot flags, in the probe's own
/// home, so it reads its own cookie. A probe that does not finish with its
/// completion line fails the test with everything it printed. A refused
/// connection is a `RESULT ... refused` line, not a failure of the probe.
///
/// ## Examples
///
/// ```gleam
/// // run_probe(probe, directory, ["connect exec@127.0.0.1"])
/// // -> ["RESULT connect exec@127.0.0.1 connected"]
/// ```
pub fn run_probe(
  probe: Probe,
  directory: String,
  steps: List(String),
) -> List(String) {
  let steps_path = directory <> "/steps-" <> random_hex(4)
  let assert Ok(Nil) = simplifile.write(steps_path, string.join(steps, "\n"))
    as "the probe steps are written"
  let assert Ok(env) = ffi_proc.which("env") as "env is on PATH"
  let assert Ok(erl) = ffi_proc.which("erl") as "erl is on PATH"
  let evaluation =
    "support@remote_probe:main(<<\""
    <> probe.config
    <> "\">>, <<\""
    <> steps_path
    <> "\">>)."
  let arguments =
    list.flatten([
      ["HOME=" <> probe.identity.home, erl, "+S", "2", "-pa"],
      ffi_probe.code_directories(),
      ["-proto_dist", "inet_tls", "-ssl_dist_optfile", probe.options],
      ["-noshell", "-eval", evaluation],
    ])
  let assert Ok(#(status, output)) = ffi_proc.run(env, arguments, in: directory)
    as "the probe emulator runs"
  case status == 0 && string.contains(output, "PROBE_COMPLETE") {
    True ->
      output
      |> string.split("\n")
      |> list.filter(fn(line) { string.starts_with(line, "RESULT ") })
    False -> {
      io.println_error("probe output:\n" <> output)
      panic as {
        "the probe did not complete (exit "
        <> int.to_string(status)
        <> "):\n"
        <> output
      }
    }
  }
}

/// The node names `epmd` lists as registered, one string per node.
///
/// A VM that booted as a distribution member registers with `epmd`, so this
/// is the lightest evidence that a daemon came up distributed. It says nothing
/// about trust; `run_probe` does.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.epmd_names() // -> ["loom_e2e_exec_9f3a01c2", ..]
/// ```
pub fn epmd_names() -> List(String) {
  let assert Ok(epmd) = ffi_proc.which("epmd") as "epmd is on PATH"
  let assert Ok(#(0, output)) = ffi_proc.run(epmd, ["-names"], in: ".")
    as "epmd answers"
  output
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.split(line, " ") {
      ["name", name, "at", "port", ..] -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

// --- sessions ----------------------------------------------------------------

/// An owner control socket and the epoch its `hello` announced.
pub type Control {
  Control(socket: ffi_ws.Socket, epoch: String)
}

/// Opens the owner control socket of a running daemon and reads its `hello`.
///
/// ## Examples
///
/// ```gleam
/// // let control = remote_daemons.open_control(running)
/// ```
pub fn open_control(running: Running) -> Control {
  let #(socket, response) =
    wire.connect(running.port, running.owner, "/v2/control")
  assert string.contains(response, "101 Switching Protocols")
  let hello = wire.frame(socket, within_ms: wire_read_ms)
  let assert json.String(epoch) = field(field(hello, "body"), "epoch")
    as "the hello announces the daemon epoch"
  Control(socket:, epoch:)
}

/// One command on the control socket, answered past any push around it.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.command(control, 1, "status", json.Object([]))
/// ```
pub fn command(
  control: Control,
  id: Int,
  name: String,
  body: JsonValue,
) -> JsonValue {
  wire.reply(control.socket, id, name, body, within_ms: wire_read_ms)
}

/// `sessions.create` for a workspace registered on an executor.
///
/// The reply is returned whole, so a test can assert on the event, the stored
/// name and the opening operation, or on the refusal.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.create_registered(control, 1, "key", "repo", "box")
/// ```
pub fn create_registered(
  control: Control,
  id: Int,
  key: String,
  workspace: String,
  executor: String,
) -> JsonValue {
  command(
    control,
    id,
    "sessions.create",
    json.Object([
      #("request_key", json.String(key)),
      #("workspace", json.String(workspace)),
      #("name", json.String("registered " <> key)),
      #("configuration", json.String("")),
      #("executor", json.String(executor)),
    ]),
  )
}

/// Polls `operations.get` until the opening has either failed or the session
/// is resident, and returns that reply.
///
/// On a daemon that cannot assemble a registered session the first poll is
/// already the failure. On one that can, the poll sees `opening` for a while,
/// then `resident`.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.await_operation(control, 10, session_id, operation)
/// ```
pub fn await_operation(
  control: Control,
  first_id: Int,
  session: String,
  operation: String,
) -> JsonValue {
  settle(control, first_id, session, operation, 300)
}

fn settle(
  control: Control,
  id: Int,
  session: String,
  operation: String,
  remaining: Int,
) -> JsonValue {
  assert remaining > 0 as "the opening settles within its bounded polls"
  let reply =
    command(
      control,
      id,
      "operations.get",
      json.Object([
        #("session_id", json.String(session)),
        #("operation", json.String(operation)),
        #("epoch", json.String(control.epoch)),
      ]),
    )
  case field(reply, "event") {
    json.String("operations.get") ->
      case opening(reply) {
        True -> {
          process.sleep(100)
          settle(control, id + 1, session, operation, remaining - 1)
        }
        False -> reply
      }
    _ -> reply
  }
}

// An `operations.get` reply whose status still says the open is in flight. It
// is asked only of a reply that is not an error, which carries no status.
fn opening(reply: JsonValue) -> Bool {
  case field(field(field(reply, "body"), "status"), "state") {
    json.String("opening") | json.String("reserved") -> True
    _ -> False
  }
}

/// A field of a JSON object, asserting it is present.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.field(reply, "event")
/// ```
pub fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the value is an object"
  let assert Ok(found) = list.key_find(fields, key)
    as { "the field is present: " <> key }
  found
}

// --- the end-to-end turn (not exercised on the base this file was written for)

/// The file the scripted model writes on the executor, relative to the
/// registered workspace.
pub const note_path = "e2e-note.txt"

/// What the scripted model writes into `note_path`.
pub const note_content = "written on the executor\n"

/// FOLLOW-UP SLICE. The model's side of one registered turn: write a file,
/// read it back through `bash`, read it through `fs_read`, and answer.
///
/// The paths are relative, so every call resolves inside the registered
/// workspace, which is on the executor. The three calls use three different
/// tools on purpose: `fs_write` and `fs_read` are the filesystem tools, and
/// `bash` is the one that runs a process in the executor's jail. Nothing
/// calls this on a base whose orchestrator cannot open a registered session.
///
/// ## Examples
///
/// ```gleam
/// // provider.with_server(remote_daemons.registered_script(), drive)
/// ```
pub fn registered_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      "write the note",
      "write-call",
      "fs_write",
      json.Object([
        #("path", json.String(note_path)),
        #("content", json.String(note_content)),
      ]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("write-call"), fn(_seen) {
      provider.ReplyToolUse(
        "cat-call",
        "bash",
        json.Object([#("command", json.String("cat -- " <> note_path))]),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("cat-call"), fn(_seen) {
      provider.ReplyToolUse(
        "read-call",
        "fs_read",
        json.Object([#("path", json.String(note_path))]),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("read-call"), fn(_seen) {
      provider.ReplyText("registered done")
    }),
  ]
}

/// FOLLOW-UP SLICE. Creates a session registered on `executor`, waits for it
/// to be resident, attaches a terminal and sends the prompt `registered_script`
/// answers, then waits for the final text.
///
/// `config` is the orchestrator's `loom.toml`, already rewritten to name the
/// provider of `provider.with_server(registered_script(), ..)`. The caller
/// asserts on the provider's report afterwards.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.drive_registered_session(orchestrator, "box", "repo")
/// ```
pub fn drive_registered_session(
  orchestrator: Running,
  executor: String,
  workspace: String,
) -> Nil {
  let control = open_control(orchestrator)
  let created = create_registered(control, 1, "e2e-turn", workspace, executor)
  let assert json.String(session) = field(field(created, "body"), "session_id")
    as "the registered session was created"
  let assert poll.Answered(Nil) =
    daemon_observation.session_until(
      orchestrator.connected.control,
      session,
      within: 30_000,
      every: 50,
      inspect: resident,
    )
    as "the registered session opens on the executor"
  let assert Ok(driver) =
    tui_driver.start(orchestrator.address, orchestrator.owner, session)
    as "a terminal attaches to the registered session"
  let _ = tui_v2_test.await(driver.data, writable)
  let _ =
    tui_driver.play(driver.data, [
      backend.Paste("write the note"),
      backend.KeyPress("enter"),
    ])
  let _ =
    tui_v2_test.await_within(
      driver.data,
      fn(sample) {
        writable(sample) && assistant_texts(sample) == ["registered done"]
      },
      60_000,
    )
  tui_driver.stop(driver.data)
  Nil
}

fn resident(session: protocol.Session) -> poll.Attempt(Nil, String) {
  case session.status {
    protocol.Resident(_) -> poll.Done(Nil)
    protocol.Reserved | protocol.Opening(_) -> poll.Retry
    protocol.Saved | protocol.Stopping(_) | protocol.RecoveryBlocked ->
      poll.Fail("the registered session did not open")
  }
}

fn writable(sample: tui_driver.Sample) -> Bool {
  case sample.model.shared.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn assistant_texts(sample: tui_driver.Sample) -> List(String) {
  list.filter_map(sample.model.shared.records, fn(record) {
    case record.entry {
      entry.MessageEntry(
        message: message.AssistantMessage(
          content: [message.AssistantText(text, None)],
          stop_reason: message.Stop,
          ..,
        ),
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

/// FOLLOW-UP SLICE. Asserts the note exists with its content under the
/// executor's checkout.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.assert_written_on_executor(checkout)
/// ```
pub fn assert_written_on_executor(checkout: String) -> Nil {
  let assert Ok(text) = simplifile.read(checkout <> "/" <> note_path)
    as "the note exists under the executor checkout"
  assert text == note_content
  Nil
}

/// FOLLOW-UP SLICE. Asserts no file named like the note exists anywhere under
/// `roots`, the orchestrator's directories.
///
/// The check is by file name, not by content, because the orchestrator's
/// session database legitimately records the text the tools returned.
///
/// ## Examples
///
/// ```gleam
/// // remote_daemons.assert_absent_from([orchestrator.layout.directory])
/// ```
pub fn assert_absent_from(roots: List(String)) -> Nil {
  list.each(roots, fn(root) {
    let assert Ok(files) = simplifile.get_files(root)
      as { "the directory can be walked: " <> root }
    let copies =
      list.filter(files, fn(file) { filepath.base_name(file) == note_path })
    assert copies == []
  })
}
