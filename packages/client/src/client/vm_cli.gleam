//// `loom vm up | down | status`: one standing microVM executor.
////
//// A developer with the microVM artifacts installed runs `loom vm up
//// --workspace ~/src/proj` and gets a guest that runs an executor daemon named
//// `vm` (or `--name`), enrolled as an ordinary `[executors.<name>]` row of
//// their `loom.toml`. `loom --executor vm --workspace proj` then places a
//// session's tools in the guest through the same remote placement every
//// executor has. The guest is a separate `loom-vm run` process: the daemon
//// does not start it and does not own it, and `loom vm down` ends it.
////
//// `client/vm_spec` holds every decision that needs no effect. This module
//// performs them, in the order that leaves the least behind when a step fails.
////
//// ## Flow
////
//// - `run` dispatches on the command.
//// - `up` reads and checks the manifest, finds the workspace, provisions the
////   deployment (`deployment`), installs the orchestrator (`enroll`), stages the
////   guest root (`stage`) and boots it (`boot`).
//// - `down` signals the recorded process and waits for it (`down`).
//// - `status` reports what the pid file, the process table and the host epmd
////   say (`status`).
////
//// ## What `up` leaves where
////
//// Everything of one guest lives in `<vm home>/<name>/`, where the vm home is
//// `$LOOM_VM_HOME` or `~/.loom/vm`:
////
//// - `deploy/` holds the two provisioned bundles. A second `up` reads them
////   again rather than minting new certificates, so the orchestrator's
////   installed configuration keeps matching the executor it trusts.
//// - `orch/` holds the orchestrator's installed credentials.
//// - `root/` is the guest's own clone of the exported guest root. `up` replaces
////   it, so whatever the guest wrote into its checkout is gone after the next
////   `up`; `down` leaves it for the user to read.
//// - `loom-vm.pid` names the process and its birth marker, and `loom-vm.log`
////   holds the guest's console.
////
//// The orchestrator's bundle goes into the user's `loom.toml` the way `loom
//// distribution install` puts it: it merges `[distribution]` and
//// `[executors.<name>]`, and refuses a file that already holds a different
//// deployment instead of replacing it.
////
//// ## Why the process is signalled by birth marker
////
//// `loom-vm run` stays in the foreground for the guest's life and survives
//// this command exiting. `up` records its pid together with the platform's
//// birth marker for that process before the wrapper replaces itself with
//// `loom-vm`, and `down` signals the pid only while the same birth marker is
//// still there. A pid file left by a machine that rebooted therefore names no
//// process, and a recycled pid is never signalled.

import client/distribution_bundle.{type Bundle}
import client/distribution_install.{Options}
import client/distribution_provision.{RefuseExisting, ReplaceExisting}
import client/internal/ffi_os
import client/vm_spec.{
  type Command, type Manifest, type PidRecord, type UpOptions, Down, Launch,
  PidRecord, Status, Up,
}
import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/build_identity
import host/endpoint
import simplifile
import weft/poll

/// Complete help for the vm operator command.
pub const usage =
  "usage: loom vm up [--name NAME] [--workspace DIR] [--mem MIB] [--cpus N]
                  [--config PATH]
       loom vm down [--name NAME]
       loom vm status [--name NAME]

Run one standing executor in a microVM and use it from `loom --executor`.

  up        Provision a two-node deployment, enroll the orchestrator in your
            loom.toml as [executors.NAME], clone the guest root, copy the
            workspace into it, boot the guest with `loom-vm run` and wait until
            its executor serves. The guest keeps running after this command
            exits. NAME defaults to vm. DIR defaults to the current directory;
            its copy, .git included, is registered in the guest under the
            directory's own name. --mem is the guest's memory in MiB (default
            2048) and --cpus its virtual CPUs (default 4). --config is the
            loom.toml to enroll in (default ~/.loom/loom.toml).
            A loom.toml that already holds a different [distribution] table is
            refused, not replaced. The guest's checkout is replaced by every
            `up`.
  down      Stop the guest. Its root, and the checkout inside it, stay on disk.
  status    Say whether the guest runs, where it is registered and what it
            holds.

The artifacts come from `~/.loom/vm/manifest.json` ($LOOM_VM_HOME overrides
~/.loom/vm), which `loom vm setup` writes. They must be built from the release
this loom is.

Example:
  loom vm up --workspace ~/src/proj
  loom --executor vm --workspace proj"

/// Runs the command and exits nonzero with a one-line reason when it fails.
///
/// ## Examples
///
/// ```gleam
/// // loomd vm up --workspace ~/src/proj
/// ```
pub fn main(arguments: List(String)) -> Nil {
  // A refusal goes to standard error with the exit status every `loomd`
  // command uses, so a script can tell a refused `up` from a started one.
  case run(arguments) {
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Runs one command and returns what it prints. A refused command has started
/// no guest.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(vm_cli.run([]))
/// ```
pub fn run(arguments: List(String)) -> Result(String, String) {
  use command <- result.try(
    vm_spec.parse(arguments)
    |> result.map_error(fn(reason) { reason <> "\n\n" <> usage }),
  )
  dispatch(command)
}

/// Runs the command `run` parsed, each in its own section below.
fn dispatch(command: Command) -> Result(String, String) {
  // The three commands share nothing but where a guest's files are.
  case command {
    Up(options) -> up(options)
    Down(name) -> down(name)
    Status(name) -> status(name)
  }
}

// --- where things are --------------------------------------------------------

// The files of one guest, all under `directory`.
type Instance {
  Instance(
    directory: String,
    deploy: String,
    orchestrator_credentials: String,
    root: String,
    pid_file: String,
    log: String,
  )
}

/// The user's home directory, which holds the default `loom.toml` and the
/// cookie the orchestrator reads.
fn home() -> Result(String, String) {
  bootstrap.getenv("HOME") |> result.replace_error("HOME is unset")
}

/// `$LOOM_VM_HOME`, or `~/.loom/vm` when it is unset or empty.
fn vm_home() -> Result(String, String) {
  // An empty variable is unset: `LOOM_VM_HOME=` in a shell exports an empty
  // string, and a path of "" would put every guest at the filesystem root.
  case bootstrap.getenv("LOOM_VM_HOME") {
    Ok(path) if path != "" -> bootstrap.absolute_path(path)
    _ -> home() |> result.map(fn(home) { home <> "/.loom/vm" })
  }
}

/// Where each file of the guest called `name` lives.
fn instance(vm_home: String, name: String) -> Instance {
  let directory = vm_home <> "/" <> name
  Instance(
    directory:,
    deploy: directory <> "/deploy",
    orchestrator_credentials: directory <> "/orch",
    root: directory <> "/root",
    pid_file: directory <> "/loom-vm.pid",
    log: directory <> "/loom-vm.log",
  )
}

/// Reads and decodes the artifact manifest, naming how to make one when it is
/// missing.
fn read_manifest(vm_home: String) -> Result(Manifest, String) {
  let path = vm_home <> "/manifest.json"

  // A missing manifest is the ordinary first-run state, and the way out is a
  // command, so it gets its own words. Any other read error is the file's.
  use text <- result.try(case simplifile.read(path) {
    Ok(text) -> Ok(text)
    Error(simplifile.Enoent) ->
      Error(
        path
        <> " does not exist, so the microVM artifacts are not installed. Run "
        <> "`loom vm setup`, or build them in a checkout with `make vmm "
        <> "vmm-runner vmm-firmware vmm-guest-root`.",
      )
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
  })

  vm_spec.decode_manifest(text)
  |> result.map_error(fn(reason) { path <> ": " <> reason })
}

// --- running a program -------------------------------------------------------

/// Runs a host program to completion and answers its standard output. A
/// program that is missing, late or exits nonzero is the error.
fn tool(
  program: String,
  arguments: List(String),
  within within: Int,
) -> Result(String, String) {
  use path <- result.try(
    ffi_os.find_executable(program)
    |> result.map_error(fn(_) { program <> " is not on PATH" }),
  )
  let ran = ffi_os.run_capture(path, arguments, within)

  // `run_capture` answers a status for a program that ran and an error for one
  // that could not or did not finish, and only status zero is success.
  case ran {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, _)) ->
      Error(program <> " exited with status " <> int.to_string(status))
    Error(reason) -> Error(program <> ": " <> reason)
  }
}

// A copy of a tree of several hundred megabytes is metadata on a copy-on-write
// file system and data elsewhere, so it gets minutes, not seconds.
const copy_budget_ms = 600_000

const quick_ms = 10_000

// --- up ----------------------------------------------------------------------

/// Provisions, enrolls, stages and boots one guest.
fn up(options: UpOptions) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  use manifest <- result.try(read_manifest(vm_home))
  use Nil <- result.try(vm_spec.check_revision(
    manifest,
    build_identity.current().commit,
  ))
  use workspace <- result.try(workspace_of(options))
  let names = vm_spec.names(options.name)
  let guest = instance(vm_home, options.name)
  use Nil <- result.try(refuse_running(guest, options.name))

  // The deployment and the enrollment come before the guest root, so a
  // loom.toml that holds another deployment is refused before a root of
  // several hundred megabytes is cloned.
  use #(orchestrator, executor) <- result.try(deployment(guest, names))
  use enrolled <- result.try(enroll(orchestrator, options))
  use Nil <- result.try(stage(manifest, guest, executor, workspace))
  use port <- result.try(boot(manifest, guest, names, options))
  report(options, workspace, port, enrolled)
}

// The directory to copy, canonical, and the name its copy has in the guest.
type Workspace {
  Workspace(path: String, name: String)
}

/// The directory `up` copies: `--workspace` or the current directory, resolved,
/// with a name that is safe as a path segment in the guest.
fn workspace_of(options: UpOptions) -> Result(Workspace, String) {
  use asked <- result.try(
    bootstrap.absolute_path(option.unwrap(options.workspace, ".")),
  )
  use path <- result.try(
    bootstrap.canonical_directory(asked)
    |> result.map_error(fn(reason) {
      asked <> " is not a directory: " <> reason
    }),
  )
  let name = filepath.base_name(path)
  use Nil <- result.try(vm_spec.valid_workspace_name(name))
  let kind = bootstrap.path_kind(path <> "/.git")

  // A linked worktree's `.git` is a file that points at the main repository,
  // outside the copy, so the guest would see no history at all.
  use Nil <- result.try(case kind {
    bootstrap.RegularFile ->
      Error(
        path
        <> " is a linked Git worktree: its .git file points outside the "
        <> "directory, so the copy in the guest would have no history. Use "
        <> "the main checkout.",
      )
    _ -> Ok(Nil)
  })

  Ok(Workspace(path:, name:))
}

/// Refuses `up` for a guest whose process is still there.
fn refuse_running(guest: Instance, name: String) -> Result(Nil, String) {
  use state <- result.try(process_state(guest))

  // A second `loom-vm` on the same root would write into the files the first
  // one's guest has open.
  case state {
    Alive(record) ->
      Error(
        "the guest "
        <> name
        <> " already runs as process "
        <> int.to_string(record.pid)
        <> ". Stop it with `loom vm down --name "
        <> name
        <> "` first.",
      )
    NotRunning -> Ok(Nil)
  }
}

// --- the deployment ----------------------------------------------------------

/// The two bundles of a guest, read from `deploy/` when an earlier `up` made
/// them and minted there otherwise. Reading them again is what keeps the
/// orchestrator's installed pins matching the executor's certificate.
fn deployment(
  guest: Instance,
  names: vm_spec.Names,
) -> Result(#(Bundle, Bundle), String) {
  let orchestrator_file = bundle_file(guest, names.orchestrator)
  let executor_file = bundle_file(guest, names.name)
  let made =
    bootstrap.path_exists(orchestrator_file)
    && bootstrap.path_exists(executor_file)

  // A directory with one bundle was interrupted, and one bundle alone pins
  // nothing, so only a complete pair is reused.
  case made {
    True -> {
      use orchestrator <- result.try(read_bundle(
        orchestrator_file,
        names.orchestrator_node,
      ))
      use executor <- result.try(read_bundle(executor_file, names.executor_node))
      Ok(#(orchestrator, executor))
    }
    False -> provision(guest, names)
  }
}

/// Where a plan node's bundle is in `deploy/`.
fn bundle_file(guest: Instance, plan_name: String) -> String {
  guest.deploy <> "/" <> plan_name <> distribution_provision.bundle_extension
}

/// Reads one bundle and checks that it is the node this guest's name implies.
fn read_bundle(path: String, node: String) -> Result(Bundle, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      path <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use bundle <- result.try(
    distribution_bundle.decode(text)
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )

  // A directory left by another name or another host's naming would install
  // pins for a node this guest does not run.
  case bundle.erlang_node == node {
    True -> Ok(bundle)
    False ->
      Error(
        path
        <> " is the bundle of "
        <> bundle.erlang_node
        <> ", not "
        <> node
        <> ". Remove its directory and run `loom vm up` again.",
      )
  }
}

/// Mints the authority, the certificates and the cookie in this process and
/// writes the bundles, as `loom distribution provision --static` does. Static
/// mode keeps no authority key: nothing ever enrolls a third node here.
fn provision(
  guest: Instance,
  names: vm_spec.Names,
) -> Result(#(Bundle, Bundle), String) {
  use plan <- result.try(vm_spec.deployment_plan(
    names,
    guest.orchestrator_credentials,
  ))
  use minted <- result.try(distribution_provision.provision(plan))
  use Nil <- result.try(bootstrap.ensure_private_directory(guest.directory))
  use _written <- result.try(distribution_provision.write(
    minted,
    guest.deploy,
    ReplaceExisting,
  ))
  use orchestrator <- result.try(bundle_named(minted, names.orchestrator))
  use executor <- result.try(bundle_named(minted, names.name))
  Ok(#(orchestrator, executor))
}

/// The bundle a provisioned deployment holds for a plan node.
fn bundle_named(
  minted: distribution_provision.Deployment,
  name: String,
) -> Result(Bundle, String) {
  list.find(minted.bundles, fn(bundle) { bundle.name == name })
  |> result.map_error(fn(_) { "provisioning made no bundle for " <> name })
}

// --- enrolling the orchestrator ----------------------------------------------

// What installing the orchestrator did to the user's configuration.
type Enrolled {
  Enrolled(config: String, start: String)
}

/// Installs the orchestrator's bundle into the user's `loom.toml` the way
/// `loom distribution install` does, and refuses what it would replace.
fn enroll(
  orchestrator: Bundle,
  options: UpOptions,
) -> Result(Enrolled, String) {
  use home <- result.try(home())
  let config =
    option.lazy_unwrap(options.config, fn() {
      distribution_install.default_config(home)
    })
  use config <- result.try(bootstrap.absolute_path(config))
  use installed <- result.try(
    distribution_install.install(
      distribution_bundle.encode(orchestrator),
      Options(home:, config:, overwrite: RefuseExisting),
    )
    |> result.map_error(fn(reason) {
      vm_spec.without_force_hint(reason)
      <> "\n`loom vm up` never replaces a [distribution] table, an "
      <> "[executors."
      <> orchestrator_executor(orchestrator)
      <> "] table or a cookie that differs from the deployment's. Remove the "
      <> "conflicting one from "
      <> config
      <> " (the cookie is "
      <> home
      <> "/.erlang.cookie), or give `--config` another file."
    }),
  )
  Ok(Enrolled(config:, start: installed.start))
}

/// The executor row the orchestrator's bundle names, for the refusal's words.
fn orchestrator_executor(orchestrator: Bundle) -> String {
  case orchestrator.executors {
    [row, ..] -> row.name
    [] -> "NAME"
  }
}

// --- the guest root ----------------------------------------------------------

/// Gives the guest its own root, its executor node and its copy of the
/// workspace.
fn stage(
  manifest: Manifest,
  guest: Instance,
  executor: Bundle,
  workspace: Workspace,
) -> Result(Nil, String) {
  use uname <- result.try(tool("uname", ["-s"], within: quick_ms))
  use platform <- result.try(vm_spec.platform_of(uname))
  use Nil <- result.try(replace_root(manifest, guest, platform))
  use Nil <- result.try(stage_node(guest.root, executor, workspace.name))
  copy_workspace(guest.root, workspace, platform)
}

/// The guest boots a clone of the export and writes into it, so each guest has
/// its own and the export is never booted. An old root of this guest is
/// removed first: `cp` into an existing directory would copy beside its
/// contents. The clone keeps the export's modes, which can leave a directory
/// the owner cannot delete, so the old root is made writable before removal.
fn replace_root(
  manifest: Manifest,
  guest: Instance,
  platform: vm_spec.Platform,
) -> Result(Nil, String) {
  use Nil <- result.try(remove_root(guest))
  tool(
    "cp",
    vm_spec.copy_arguments(platform, manifest.guest_root, guest.root),
    within: copy_budget_ms,
  )
  |> result.replace(Nil)
}

/// Removes this guest's old root, when it has one.
fn remove_root(guest: Instance) -> Result(Nil, String) {
  // A first `up` has no root to remove.
  case bootstrap.path_exists(guest.root) {
    False -> Ok(Nil)
    True -> {
      use _ <- result.try(tool(
        "chmod",
        ["-R", "u+w", guest.root],
        within: copy_budget_ms,
      ))
      simplifile.delete_all([guest.root])
      |> result.map_error(fn(error) {
        guest.root
        <> " cannot be replaced: "
        <> simplifile.describe_error(error)
      })
    }
  }
}

/// Everything the executor needs is copied into the root, never shared
/// (ADR-022 D1): its configuration, its credentials and its cookie. Under the
/// default read scope the jail sees the whole guest, so what keeps the key and
/// the cookie from model code is the executor's own credential mask, not these
/// paths. The guest's init gives the directory to the `loom` user.
fn stage_node(
  root: String,
  executor: Bundle,
  workspace: String,
) -> Result(Nil, String) {
  let node = root <> vm_spec.node_dir
  use Nil <- result.try(
    make_directories([node <> "/home", node <> "/creds", node <> "/state"]),
  )
  use Nil <- result.try(write_private(node <> "/creds/ca.pem", executor.ca))
  use Nil <- result.try(write_private(
    node <> "/creds/cert.pem",
    executor.certificate,
  ))
  use Nil <- result.try(write_private(node <> "/creds/key.pem", executor.key))
  use Nil <- result.try(write_private(
    node <> "/home/.erlang.cookie",
    executor.cookie,
  ))
  write_private(node <> "/loom.toml", vm_spec.guest_config(executor, workspace))
}

/// Creates each directory, and its parents, or names the one that failed.
fn make_directories(paths: List(String)) -> Result(Nil, String) {
  list.try_each(paths, fn(path) {
    simplifile.create_directory_all(path)
    |> result.map_error(fn(error) {
      path <> " is unwritable: " <> simplifile.describe_error(error)
    })
  })
}

/// Writes a file only its owner can read, atomically.
fn write_private(path: String, contents: String) -> Result(Nil, String) {
  bootstrap.atomic_write_private(path, contents)
  |> result.map_error(fn(reason) { path <> " is unwritable: " <> reason })
}

/// The workspace is a copy, `.git` included, so the guest's history is its own
/// and nothing it does reaches the host's repository. The copy's Git
/// configuration loses what could authenticate as the user, because the
/// guest's default read scope can read it.
///
/// Git writes its objects read-only, and a clone keeps that. The guest's init
/// gives every workspace file to the `loom` user, and on the shared file
/// system that is an ownership record written through the host user, which
/// fails on a file the host user cannot write. Making the copy owner-writable
/// first is what lets the init finish.
fn copy_workspace(
  root: String,
  workspace: Workspace,
  platform: vm_spec.Platform,
) -> Result(Nil, String) {
  let parent = root <> vm_spec.workspaces_dir
  let copy = parent <> "/" <> workspace.name
  use Nil <- result.try(make_directories([parent]))
  use _ <- result.try(tool(
    "cp",
    vm_spec.copy_arguments(platform, workspace.path, copy),
    within: copy_budget_ms,
  ))
  use _ <- result.try(tool("chmod", ["-R", "u+w", copy], within: copy_budget_ms))
  scrub_config(copy <> "/.git/config")
}

/// Rewrites a copied `.git/config` without its credentials. A workspace that
/// is not a repository has none, and that is not an error.
fn scrub_config(path: String) -> Result(Nil, String) {
  // Only a missing file is skipped; an unreadable one would leave the original
  // credentials in the copy, so it stops `up`.
  case simplifile.read(path) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
    Ok(text) ->
      simplifile.write(path, vm_spec.scrub_git_config(text))
      |> result.map_error(fn(error) {
        path <> " is unwritable: " <> simplifile.describe_error(error)
      })
  }
}

// --- booting -----------------------------------------------------------------

// How long `up` waits for the executor's console marker. A cold boot takes
// well under a minute; the rest is for a first run on a loaded machine.
const ready_within_ms = 120_000

/// Boots the guest and answers the host port its executor is forwarded to.
fn boot(
  manifest: Manifest,
  guest: Instance,
  names: vm_spec.Names,
  options: UpOptions,
) -> Result(Int, String) {
  use port <- result.try(bootstrap.reserve_loopback_port())
  let launch =
    Launch(
      manifest:,
      names:,
      root: guest.root,
      memory_mib: options.memory_mib,
      cpus: options.cpus,
      host_port: port,
    )

  // The log is appended to, and the console of an earlier run says READY.
  use Nil <- result.try(
    simplifile.write(guest.log, "")
    |> result.map_error(fn(error) {
      guest.log <> " is unwritable: " <> simplifile.describe_error(error)
    }),
  )
  use record <- result.try(spawn(
    manifest,
    guest,
    vm_spec.launch_arguments(launch),
  ))
  use Nil <- result.try(await_ready(guest, record))
  Ok(port)
}

/// Starts `loom-vm run` detached, in its own process group, with its output in
/// the log. The wrapper waits for a release byte before it becomes `loom-vm`,
/// so the pid file is written, birth marker and all, before the guest exists.
fn spawn(
  manifest: Manifest,
  guest: Instance,
  arguments: List(String),
) -> Result(PidRecord, String) {
  use #(process, pid) <- result.try(bootstrap.spawn_server(
    manifest.loom_vm,
    arguments,
    guest.directory,
    guest.log,
  ))
  let recorded = record_and_release(guest, process, pid)

  // Closing the port does not stop the process once it has been released, and
  // an unreleased wrapper exits when its port closes, so one close is right
  // for both outcomes.
  bootstrap.close_server_process(process)
  recorded
}

/// Records the paused wrapper's pid with its birth marker, then releases it to
/// become `loom-vm`. A release that fails removes the record again.
fn record_and_release(
  guest: Instance,
  process: bootstrap.ServerProcess,
  pid: Int,
) -> Result(PidRecord, String) {
  use identity <- result.try(bootstrap.process_identity(pid))
  use birth <- result.try(birth_of(identity))
  let record = PidRecord(pid:, birth:)
  use Nil <- result.try(write_private(
    guest.pid_file,
    vm_spec.encode_pid(record),
  ))

  // A record for a process that never started would make the next `up` think
  // a guest was running.
  case bootstrap.release_server_process(process) {
    Ok(Nil) -> Ok(record)
    Error(reason) -> {
      let _ = simplifile.delete(guest.pid_file)
      Error(reason)
    }
  }
}

/// The birth marker of a process that is there.
fn birth_of(identity: bootstrap.ProcessIdentity) -> Result(String, String) {
  case identity {
    bootstrap.ProcessPresent(birth) -> Ok(birth)
    bootstrap.ProcessAbsent -> Error("loom-vm exited before it started")
  }
}

/// Waits for the guest's console to say its executor serves. The guest prints
/// one marker when it does and another, followed by the daemon's log, when it
/// died, and that log is the only account of why. A `loom-vm` that exits first
/// has the same log. Whatever the reason, a guest that did not come up is
/// stopped, so a failed `up` leaves nothing running.
fn await_ready(guest: Instance, record: PidRecord) -> Result(Nil, String) {
  let outcome =
    poll.until(within: ready_within_ms, every: 250, attempt: fn() {
      console_verdict(guest, record)
    })

  // Each way the wait ends is either the ready marker or a reason, and a
  // reason stops the guest.
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> stop_after_failure(guest, record, reason)
    poll.Expired ->
      stop_after_failure(
        guest,
        record,
        "the guest's executor did not report within "
          <> int.to_string(ready_within_ms / 1000)
          <> " s. Its console is in "
          <> guest.log
          <> ":\n"
          <> vm_spec.tail(result.unwrap(simplifile.read(guest.log), ""), 4000),
      )
  }
}

/// One look at the console: ready, failed, gone, or not yet.
fn console_verdict(
  guest: Instance,
  record: PidRecord,
) -> poll.Attempt(Nil, String) {
  let console = result.unwrap(simplifile.read(guest.log), "")
  let ready = string.contains(console, vm_spec.ready_marker)
  let failed = string.contains(console, vm_spec.failed_marker)

  // The ready marker wins over a failure marker in the same read: the guest
  // prints it only once the executor serves.
  case ready, failed {
    True, _ -> poll.Done(Nil)
    _, True ->
      poll.Fail("the guest's executor failed:\n" <> vm_spec.tail(console, 4000))
    False, False -> {
      // No marker yet. A launcher that is gone will print none, so waiting on
      // would only run out the clock.
      case alive(record) {
        True -> poll.Retry
        False -> poll.Fail("loom-vm exited:\n" <> vm_spec.tail(console, 4000))
      }
    }
  }
}

/// Stops a guest that did not come up and clears its record, so the failure
/// leaves nothing running and nothing for the next `up` to refuse.
fn stop_after_failure(
  guest: Instance,
  record: PidRecord,
  reason: String,
) -> Result(Nil, String) {
  let _ = terminate(record)
  let _ = simplifile.delete(guest.pid_file)
  Error(reason)
}

/// What `up` tells the user: how to use the guest, and what to do about the
/// daemon.
fn report(
  options: UpOptions,
  workspace: Workspace,
  port: Int,
  enrolled: Enrolled,
) -> Result(String, String) {
  let names = vm_spec.names(options.name)
  Ok(string.join(
    list.flatten([
      [
        "The guest "
          <> options.name
          <> " serves "
          <> names.executor_node
          <> " on host port "
          <> int.to_string(port)
          <> ".",
        "Enrolled it as [executors."
          <> options.name
          <> "] in "
          <> enrolled.config
          <> ".",
        "",
        "Use it with:",
        "  loom --executor "
          <> options.name
          <> " --workspace "
          <> workspace.name,
        "",
      ],
      daemon_note(enrolled),
      ["Stop it with: loom vm down --name " <> options.name],
    ]),
    "\n",
  ))
}

/// A running daemon read its configuration before the `[distribution]` table
/// existed, and the VM must be booted with the TLS flags, so only a restart
/// reaches the guest. Whether a daemon runs is the endpoint record's answer for
/// the default state directory.
fn daemon_note(enrolled: Enrolled) -> List(String) {
  // A daemon that is not running needs the command that starts it with the
  // options file; one that is running needs a restart, which the same command
  // does after it stops.
  case daemon_running() {
    True -> [
      "Your daemon is running, and it read its configuration before this "
        <> "[distribution] table was installed. Restart it so the table takes "
        <> "effect.",
      "",
    ]
    False -> [
      "Start the daemon with the distribution options:",
      "  " <> enrolled.start,
      "",
    ]
  }
}

/// Whether the default state directory's endpoint record names a daemon that
/// is still there. Anything unreadable counts as no daemon, because the note
/// it chooses is advice and not a decision.
fn daemon_running() -> Bool {
  let present = {
    use home <- result.try(home())
    use paths <- result.try(endpoint.paths(home <> "/.loom"))
    use found <- result.try(endpoint.load(paths))
    present_in(found)
  }
  result.unwrap(present, False)
}

/// Whether a loaded endpoint record's process is still there.
fn present_in(found: option.Option(endpoint.Endpoint)) -> Result(Bool, String) {
  case found {
    Some(record) -> endpoint.is_present(record.fence)
    None -> Ok(False)
  }
}

// --- the process -------------------------------------------------------------

// What the pid file and the process table say about a guest.
type ProcessState {
  Alive(PidRecord)
  NotRunning
}

/// Reads the pid file and asks whether the process it names is still there.
fn process_state(guest: Instance) -> Result(ProcessState, String) {
  // A guest that was never started has no pid file, and that is not an error.
  case simplifile.read(guest.pid_file) {
    Error(simplifile.Enoent) -> Ok(NotRunning)
    Error(error) ->
      Error(
        guest.pid_file <> " is unreadable: " <> simplifile.describe_error(error),
      )
    Ok(text) -> state_of(guest, text)
  }
}

/// The state the text of a pid file describes.
fn state_of(guest: Instance, text: String) -> Result(ProcessState, String) {
  use record <- result.try(
    vm_spec.decode_pid(text)
    |> result.map_error(fn(reason) { guest.pid_file <> ": " <> reason }),
  )
  use there <- result.try(present(record))

  // A record whose process is gone is the state of a guest that was stopped
  // another way, and is the same as no record.
  case there {
    True -> Ok(Alive(record))
    False -> Ok(NotRunning)
  }
}

/// Whether the process the record names is still there: the same pid with the
/// same birth marker.
fn present(record: PidRecord) -> Result(Bool, String) {
  use identity <- result.try(bootstrap.process_identity(record.pid))

  // A pid with another birth marker is a different process that took the pid
  // over, which is the case the marker exists to exclude.
  case identity {
    bootstrap.ProcessPresent(birth) -> Ok(birth == record.birth)
    bootstrap.ProcessAbsent -> Ok(False)
  }
}

/// Whether the recorded process is there; an observation error counts as not,
/// because a caller that waits on it has a deadline of its own.
fn alive(record: PidRecord) -> Bool {
  result.unwrap(present(record), False)
}

/// Asks the recorded process to stop, which `loom-vm` answers by stopping the
/// guest and releasing its epmd registration. The birth marker was checked by
/// the caller a moment ago; it is checked again here because a wait may have
/// passed in between.
fn terminate(record: PidRecord) -> Result(Nil, String) {
  // A process that is already gone needs no signal, and sending one to its
  // pid could reach whatever took the pid over.
  case alive(record) {
    False -> Ok(Nil)
    True ->
      tool("kill", ["-TERM", int.to_string(record.pid)], within: quick_ms)
      |> result.replace(Nil)
  }
}

// --- down --------------------------------------------------------------------

// How long `down` waits for `loom-vm` to exit, which it does only after the
// virtual machine monitor, the network stack and the epmd registration are
// released.
const stop_within_ms = 60_000

/// Stops the guest called `name`, if it is running.
fn down(name: String) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  let guest = instance(vm_home, name)
  use state <- result.try(process_state(guest))

  // A stale pid file is removed here, so `status` and the next `up` stop
  // reading it.
  case state {
    NotRunning -> {
      let _ = simplifile.delete(guest.pid_file)
      Ok("The guest " <> name <> " is not running.")
    }
    Alive(record) -> stop(guest, name, record)
  }
}

/// Signals a running guest and waits for `loom-vm` to exit.
fn stop(
  guest: Instance,
  name: String,
  record: PidRecord,
) -> Result(String, String) {
  use Nil <- result.try(is_loom_vm(record))
  use Nil <- result.try(terminate(record))
  let exited =
    poll.until(within: stop_within_ms, every: 100, attempt: fn() {
      case alive(record) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })

  // The record stays when the process does, so a later `down` can try again.
  case exited {
    poll.Answered(Nil) -> {
      let _ = simplifile.delete(guest.pid_file)
      Ok(
        "Stopped the guest "
        <> name
        <> ". Its root, with the checkout inside it, is still in "
        <> guest.root
        <> ".",
      )
    }
    _ ->
      Error(
        "loom-vm (process "
        <> int.to_string(record.pid)
        <> ") did not exit within "
        <> int.to_string(stop_within_ms / 1000)
        <> " s of SIGTERM; it is still recorded in "
        <> guest.pid_file
        <> ".",
      )
  }
}

/// The birth marker says this is the process `up` started. This is the second
/// witness that it is still `loom-vm` and not something else that took over the
/// pid after a reboot that happened to repeat the marker.
fn is_loom_vm(record: PidRecord) -> Result(Nil, String) {
  use command <- result.try(tool(
    "ps",
    ["-p", int.to_string(record.pid), "-o", "command="],
    within: quick_ms,
  ))

  // `ps` prints the command line, which names the launcher's own binary.
  case string.contains(command, "loom-vm") {
    True -> Ok(Nil)
    False ->
      Error(
        "process "
        <> int.to_string(record.pid)
        <> " is not loom-vm, so it is not signalled",
      )
  }
}

// --- status ------------------------------------------------------------------

/// Reports the guest called `name`.
fn status(name: String) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  let guest = instance(vm_home, name)
  let names = vm_spec.names(name)
  use state <- result.try(process_state(guest))
  Ok(string.join(
    [
      "guest:      " <> name,
      "process:    " <> process_line(state),
      "node:       " <> names.executor_node,
      "epmd:       " <> epmd_line(names),
      "revision:   " <> revision_line(vm_home),
      "root:       " <> root_line(guest),
      "workspaces: " <> workspace_line(guest),
    ],
    "\n",
  ))
}

/// The process's state in words.
fn process_line(state: ProcessState) -> String {
  case state {
    Alive(record) -> "running (process " <> int.to_string(record.pid) <> ")"
    NotRunning -> "not running"
  }
}

/// The host port the executor's node name is registered at, from the host's own
/// epmd. `loom-vm` holds the registration for the guest's life, so a name that
/// is listed is a guest that is up and reachable.
fn epmd_line(names: vm_spec.Names) -> String {
  let listing = tool("epmd", ["-names"], within: quick_ms)

  // Without `epmd` on PATH the answer is unknown, which is not the same as the
  // guest being absent.
  case listing {
    Error(reason) -> "unknown (" <> reason <> ")"
    Ok(listing) ->
      case vm_spec.registered_port(listing, names.executor_short) {
        Some(port) -> "registered, host port " <> int.to_string(port)
        None -> "not registered"
      }
  }
}

/// The manifest's revision, or why it cannot be read.
fn revision_line(vm_home: String) -> String {
  case read_manifest(vm_home) {
    Ok(manifest) -> manifest.revision
    Error(reason) -> "unknown (" <> reason <> ")"
  }
}

/// The guest's root, once `up` has made it.
fn root_line(guest: Instance) -> String {
  case bootstrap.path_exists(guest.root) {
    True -> guest.root
    False -> "none yet"
  }
}

/// The workspaces the guest's root holds, which are what `--workspace` names
/// to `loom --executor`.
fn workspace_line(guest: Instance) -> String {
  case simplifile.read_directory(guest.root <> vm_spec.workspaces_dir) {
    Ok([]) | Error(_) -> "none"
    Ok(names) -> string.join(list.sort(names, string.compare), ", ")
  }
}
