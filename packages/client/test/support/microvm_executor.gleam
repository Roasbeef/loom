//// An executor daemon inside a libkrun microVM, for end-to-end tests of the
//// microVM tier (issue #85, ADR-022).
////
//// `support/remote_pair` runs both daemons of the distributed runtime as host
//// processes. This module replaces the executor half: it copies a prepared
//// linux guest root, stages the executor's configuration, credentials and
//// checkout into the copy, and boots it with `loom-vm run`. The guest runs the
//// same `loomd` release in the executor role, under `loom-exec`, on the
//// guest's own kernel. The orchestrator stays a host process and is driven
//// through `remote_daemons` exactly as the host fixture drives it.
////
//// ## How the orchestrator reaches the guest
////
//// The host has no route into the guest's network. `loom-vm run --publish`
//// forwards the guest's distribution port to a host loopback port and
//// registers the executor's node name in the host's epmd at that port, held
//// for the guest's life. The orchestrator dials `<name>@127.0.0.1` as it
//// would any local node, and the pinned TLS handshake, the certificate's
//// node-name SAN and the distribution handshake's name check run unchanged.
////
//// ## What is staged where
////
//// Everything the executor needs is copied into the guest root before boot,
//// never shared (ADR-022 D1): `/srv/loom-node` holds its configuration, its
//// HOME with the cookie, and its key; `/srv/workspaces/<name>` is the
//// checkout. Under the default host read scope the jail sees the whole guest,
//// `/srv` included, so what keeps the node's key and cookie from model code
//// is the executor's own credential mask, which the test proves.
//// `packages/vmm/guest/loom-guest-executor` is the guest side.
////
//// ## Prerequisites
////
//// `LOOM_VM` names the `loom-vm` binary, `LOOM_VM_GUEST_ROOT` the guest root
//// `make vmm-guest-root` exports, and `LOOM_VM_RUNNER`, `LOOM_VM_LIB_DIR` and
//// `LOOM_VM_FIRMWARE_DIR` (the Landlock kernel `make vmm-firmware` builds) the
//// native pieces `loom-vm` reads itself.
//// A host without them, or whose `loom-vm probe` fails, skips.

import gleam/int
import gleam/io
import gleam/result
import gleam/string
import host/bootstrap as native
import simplifile
import support/internal/ffi_proc
import support/remote_daemons.{type Authority, type Identity, Trust}
import support/remote_pair
import weft/poll

/// The executor's distribution port inside the guest.
pub const guest_listen_port = 4370

/// Where the node directory sits inside the guest.
pub const node_dir = "/srv/loom-node"

/// Where workspaces sit inside the guest.
pub const workspaces_dir = "/srv/workspaces"

/// The prepared pieces a guest executor boots from.
pub type Prerequisites {
  Prerequisites(
    /// The `loom-vm` binary.
    launcher: String,
    /// The guest root `make vmm-guest-root` exported.
    guest_root: String,
  )
}

/// A guest executor that has been launched.
pub type Guest {
  Guest(
    /// This guest's private copy of the root, which it boots from and
    /// writes into.
    root: String,
    /// The file `loom-vm run` writes the guest console and its own log to.
    log: String,
    /// The process id of `loom-vm run`.
    pid: String,
  )
}

/// The prerequisites, or a reason to skip naming the first one missing.
///
/// ## Examples
///
/// ```gleam
/// // case microvm_executor.prerequisites() { Ok(p) -> .. Error(why) -> .. }
/// ```
pub fn prerequisites() -> Result(Prerequisites, String) {
  use launcher <- result.try(
    native.getenv("LOOM_VM") |> result.replace_error("LOOM_VM is unset"),
  )
  use guest_root <- result.try(
    native.getenv("LOOM_VM_GUEST_ROOT")
    |> result.replace_error("LOOM_VM_GUEST_ROOT is unset"),
  )

  // The broker demands the landlock layer on Linux, which the stock
  // libkrunfw kernel lacks, so a guest on it refuses every jailed call
  // (ADR-022 D3). `loom-vm` reads the variable itself; it is checked here
  // so that a host without the tier's kernel skips instead of failing.
  use _firmware <- result.try(
    native.getenv("LOOM_VM_FIRMWARE_DIR")
    |> result.replace_error(
      "LOOM_VM_FIRMWARE_DIR is unset (the tier needs `make vmm-firmware`)",
    ),
  )

  // A probe that fails names what this host lacks: a hypervisor, the runner.
  case ffi_proc.run(launcher, ["probe"], in: ".") {
    Ok(#(0, _)) -> Ok(Prerequisites(launcher:, guest_root:))
    Ok(#(_, output)) -> Error("loom-vm probe: " <> string.trim(output))
    Error(_) -> Error("loom-vm could not be run")
  }
}

/// Copies the guest root into `directory/guest-root` and stages the executor
/// node and one workspace into the copy. `files` are written into the
/// workspace before boot.
///
/// The executor's configuration names guest paths only. It trusts
/// `orchestrator`, listens on `guest_listen_port`, and serves the workspace
/// under `workspace`. `models` is the executor's model table, which it never
/// uses but which every daemon's configuration carries.
///
/// ## Examples
///
/// ```gleam
/// // let root = microvm_executor.stage(p, dir, authority, executor, orchestrator, "repo", [])
/// ```
pub fn stage(
  prerequisites: Prerequisites,
  directory: String,
  authority: Authority,
  executor: Identity,
  orchestrator: Identity,
  workspace: String,
  files: List(#(String, String)),
) -> String {
  let root = directory <> "/guest-root"

  // `cp -c` clones on APFS, so a copy of a root of several hundred megabytes
  // costs metadata, not data. Each test boots and writes its own copy. `-p`
  // keeps directory modes, without which /tmp loses its world-write bit.
  let assert Ok(cp) = ffi_proc.which("cp") as "cp is on PATH"
  let assert Ok(#(0, _)) =
    ffi_proc.run(cp, ["-cRp", prerequisites.guest_root, root], in: directory)
    as "the guest root is copied"

  // The tree's own guest script replaces the image's, so a root exported
  // before the script last changed still boots the script under test. Tests
  // run from packages/client.
  let script = root <> "/usr/local/sbin/loom-guest-executor"
  let _ = simplifile.delete(script)
  copy("../vmm/guest/loom-guest-executor", script)
  let assert Ok(Nil) = simplifile.set_permissions_octal(script, 0o755)
    as "the guest script is executable"

  let node = root <> node_dir
  let assert Ok(Nil) =
    simplifile.create_directory_all(node <> "/home")
    |> result.try(fn(_) { simplifile.create_directory_all(node <> "/creds") })
    |> result.try(fn(_) { simplifile.create_directory_all(node <> "/state") })
    as "the node directory is staged"

  copy(authority.certificate, node <> "/creds/ca.pem")
  copy(executor.certificate, node <> "/creds/cert.pem")
  copy(executor.key, node <> "/creds/key.pem")
  copy(executor.home <> "/.erlang.cookie", node <> "/home/.erlang.cookie")

  let guest =
    remote_daemons.Identity(
      node: executor.node,
      home: node_dir <> "/home",
      certificate: node_dir <> "/creds/cert.pem",
      key: node_dir <> "/creds/key.pem",
      pin: executor.pin,
    )
  let guest_authority =
    remote_daemons.Authority(certificate: node_dir <> "/creds/ca.pem", key: "")
  let assert Ok(Nil) =
    simplifile.write(
      node <> "/loom.toml",
      string.join(
        [
          remote_daemons.model_table("http://127.0.0.1:9"),
          // The port goes inside [distribution] itself; after the peer rows
          // TOML would read it as a key of the last [[distribution.peers]].
          remote_daemons.distribution_table(guest, guest_authority, [
            Trust(orchestrator.node, orchestrator.pin),
          ])
            |> string.replace(
              "[distribution]\n",
              "[distribution]\nlisten_port = "
                <> int.to_string(guest_listen_port)
                <> "\n",
            ),
          remote_daemons.workspace_table(
            workspace,
            workspaces_dir <> "/" <> workspace,
          ),
        ],
        "\n",
      ),
    )
    as "the executor configuration is staged"

  let checkout = root <> workspaces_dir <> "/" <> workspace
  let assert Ok(Nil) = simplifile.create_directory_all(checkout)
    as "the workspace is staged"
  remote_pair.write_files(checkout, files)
  root
}

fn copy(from: String, to: String) -> Nil {
  let assert Ok(Nil) = simplifile.copy_file(from, to) as { "staged " <> from }
  Nil
}

/// Boots the staged root and waits until the executor's distribution listener
/// accepts, publishing `node` at `host_port` in the host's epmd.
///
/// ## Examples
///
/// ```gleam
/// // let guest = microvm_executor.boot(p, dir, root, executor.node, 47011)
/// ```
pub fn boot(
  prerequisites: Prerequisites,
  directory: String,
  root: String,
  node: String,
  host_port: Int,
) -> Guest {
  let assert [short, ..] = string.split(node, "@") as "a node name has a host"
  let log = directory <> "/loom-vm.log"
  let publish =
    short
    <> ":"
    <> int.to_string(host_port)
    <> ":"
    <> int.to_string(guest_listen_port)

  // `loom-vm run` stays in the foreground for the guest's life, so it is
  // started detached and found again by its pid. It stops the guest on
  // SIGTERM, which is how `retire` ends it.
  let command =
    string.join(
      [
        "nohup",
        quote(prerequisites.launcher),
        "run",
        "--name",
        quote(short),
        "--root-dir",
        quote(root),
        "--cpus",
        "4",
        "--mem",
        "4096",
        "--timeout",
        "30m",
        "--publish",
        quote(publish),
        "--",
        "/usr/local/sbin/loom-guest-executor",
        node_dir,
        ">",
        quote(log),
        "2>&1",
        "</dev/null",
        "&",
        "echo",
        "$!",
      ],
      " ",
    )
  let assert Ok(sh) = ffi_proc.which("sh") as "sh is on PATH"
  let assert Ok(#(0, pid)) = ffi_proc.run(sh, ["-c", command], in: directory)
    as "loom-vm is launched"
  let guest = Guest(root:, log:, pid: string.trim(pid))
  io.println_error("microvm executor: loom-vm pid " <> guest.pid)

  // The guest prints a marker once its node is registered; a failed daemon
  // prints another and its log, which is the only account of why it died.
  let ready =
    poll.until(within: 240_000, every: 250, attempt: fn() {
      let text = result.unwrap(simplifile.read(log), "")
      case
        string.contains(text, "LOOM-EXECUTOR-READY"),
        string.contains(text, "LOOM-EXECUTOR-FAILED")
      {
        True, _ -> poll.Done(Nil)
        _, True -> poll.Fail(text)
        False, False ->
          case alive(guest) {
            True -> poll.Retry
            False -> poll.Fail("loom-vm exited:\n" <> text)
          }
      }
    })
  case ready {
    poll.Answered(Nil) -> guest
    other -> {
      retire(guest)
      panic as { "the guest executor did not start: " <> string.inspect(other) }
    }
  }
}

/// The guest's console and launcher log so far.
///
/// ## Examples
///
/// ```gleam
/// // io.println_error(microvm_executor.console(guest))
/// ```
pub fn console(guest: Guest) -> String {
  result.unwrap(simplifile.read(guest.log), "")
}

/// Stops the guest and waits for `loom-vm` to exit, which it does only after
/// the VMM, the network stack and the epmd registration are released.
///
/// ## Examples
///
/// ```gleam
/// // microvm_executor.retire(guest)
/// ```
pub fn retire(guest: Guest) -> Nil {
  let assert Ok(kill) = ffi_proc.which("kill") as "kill is on PATH"
  let _ = ffi_proc.run(kill, ["-TERM", guest.pid], in: ".")
  let assert poll.Answered(Nil) =
    poll.until(within: 60_000, every: 100, attempt: fn() {
      case alive(guest) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    as "loom-vm exits after SIGTERM"
  Nil
}

fn alive(guest: Guest) -> Bool {
  let assert Ok(kill) = ffi_proc.which("kill") as "kill is on PATH"
  case ffi_proc.run(kill, ["-0", guest.pid], in: ".") {
    Ok(#(0, _)) -> True
    _other -> False
  }
}

// A POSIX single-quoted word.
fn quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\\''") <> "'"
}
