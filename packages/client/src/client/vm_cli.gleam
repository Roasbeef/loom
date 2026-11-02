//// `loom vm setup | up | down | status | logs | list | rm | sync`: one standing
//// microVM executor and the commands for living with it.
////
//// A developer with loom and libkrun installed runs `loom vm up` in a checkout,
//// or with `--workspace ~/src/proj`, and gets a guest that runs an executor daemon named
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
//// - `setup` runs the `loom-vm` that ships beside the daemon to install the
////   artifacts for a release or a build tree, trying each tag the running
////   build may be published under (`install_artifacts`).
//// - `up` reads and checks the manifest, installing the running build's
////   release first when there is none (`installed_manifest`), finds the
////   workspace, provisions the
////   deployment (`deployment`), installs the orchestrator (`enroll`), stages the
////   guest root (`stage`) and boots it (`boot`).
//// - `down` signals the recorded process and waits for it (`down`).
//// - `status` reports what the pid file, the process table and the host epmd
////   say (`status`).
//// - logs prints the end of the console log (`logs`), and list prints one line
////   per guest directory (`guests`).
//// - rm deletes a stopped guest and undoes its enrolment (`remove`).
//// - sync fetches a copy's committed work into the developer's checkout, or
////   bundles the checkout's commits for the guest (`sync`).
////
//// ## The guest root is untrusted input
////
//// Model-influenced code writes the guest's root while the guest runs, so
//// everything the host reads from it afterwards is untrusted: a link where a
//// directory belongs, a `.git/config` that names a command, a ref name with a
//// terminal escape in it. The commands that read it never run `git` with a
//// working directory inside it (`sync` fetches into the developer's checkout
//// with the copy as the remote), read refs as plain bounded files without
//// following a link (`read_inventory`), write only through `make_inside`, and
//// print what they read through `vm_spec.printable`.
////
//// ## Where `loom-vm` comes from
////
//// A release ships `loom-vm` at `bin/loom-vm` in the server tree and the
//// installer does not put it on `PATH`, so `setup` finds it through
//// `client/install`. A development tree has none and `loom vm setup` refuses
//// there, naming `make vmm-install-dev`.
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
//// - `root/` is the guest's own clone of the exported guest root, and
////   `state.img` is the disk its executor keeps its ledger and scopes on. A
////   second `up` boots both again, so whatever the guest wrote into its
////   checkout and the sessions its executor holds survive `down`; `--fresh`
////   replaces both. `down` leaves them for the user to read.
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
import client/install
import client/internal/ffi_os
import client/vm_spec.{
  type Command, type Manifest, type PidRecord, type SyncOptions, type UpOptions,
  Down, Guests, Launch, Logs, PidRecord, Remove, Setup, Status, Sync, Up,
  UpOptions,
}
import core/json as core_json
import filepath
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/access
import host/bootstrap
import host/build_identity
import host/endpoint
import simplifile
import weft/poll

/// Complete help for the vm operator command.
pub const usage =
  "usage: loom vm setup [--release TAG | --from-build DIR]
       loom vm up [--name NAME] [--workspace DIR] [--mem MIB] [--cpus N]
                  [--config PATH] [--github gh|env|off] [--fresh]
                  [--allow HOST]... [--provision SCRIPT]
       loom vm down [--name NAME]
       loom vm status [--name NAME]
       loom vm logs [--name NAME] [--lines N]
       loom vm list
       loom vm rm [--name NAME] [--config PATH] [--yes]
       loom vm sync [--name NAME] [--workspace NAME] [--checkout PATH]
                    [--to-guest]

Run one standing executor in a microVM and use it from `loom --executor`.

  setup     Install the microVM artifacts the guest boots from and write their
            manifest, with the `loom-vm` that ships beside loomd. With no flag
            it tries the tag commit-<sha> of this build's own commit, when it
            has one, then v<version>, and keeps the first whose guest image
            was built from this commit. Nightly builds have no published
            artifacts yet. --release TAG installs only that tag and
            --from-build DIR records a build tree (packages/vmm/build). A
            development build has no release: build the artifacts in a
            checkout and run `make vmm-install-dev`.
  up        Provision a two-node deployment, enroll the orchestrator in your
            loom.toml as [executors.NAME], clone the guest root, copy the
            workspace into it, boot the guest with `loom-vm run` and wait until
            its executor serves. The guest keeps running after this command
            exits. NAME defaults to vm. DIR defaults to the current directory;
            its copy, .git included, is registered in the guest under the
            directory's own name, and only the latest up's copy is registered:
            another directory's copy joins the guest's root but needs its own
            up (with the guest stopped) before `loom --executor` can name it.
            A linked Git worktree is copied too, and its
            copy gets a repository of its own. With no artifacts installed it
            first runs `setup` for this release. --mem is the guest's memory in MiB (default
            2048) and --cpus its virtual CPUs (default 4). --config is the
            loom.toml to enroll in (default ~/.loom/loom.toml).
            A loom.toml that already holds a different [distribution] table is
            refused, not replaced.
            A guest that ran before keeps its root, the checkouts in it and its
            state disk, so `down` and `up` resume where it stopped. --fresh
            replaces all three.
            --github chooses where loom-vm reads the token its credential proxy
            injects: gh (the default) runs `gh auth token`, env reads
            LOOM_VM_GITHUB_TOKEN, and off gives the guest no network beyond
            the --allow hosts. The guest holds only a placeholder, never the
            token.
            --allow HOST adds a host to the guest's egress allowlist, on top
            of the GitHub hosts, so a build can reach a package registry. HOST
            is a hostname or *.domain.tld; repeat the flag for more. The list
            is recorded and a later up with no --allow keeps it; --allow
            replaces it and --fresh clears it. An allowed host can receive
            anything a jailed call sends, and it is never given the GitHub
            token.
            --provision SCRIPT copies a script you wrote into the guest, which
            runs it once as root before the executor starts, with its output
            in loom-vm.log. A failing script fails up, and the next up runs it
            again. A resume skips a script that succeeded, and refuses a new
            one: add --fresh. Use --allow for the hosts it needs.
  down      Stop the guest. Its root, and the checkout inside it, stay on disk.
  status    Say whether the guest runs, where it is registered and what it
            holds.
  logs      Print the last lines of the guest's console log, loom-vm.log:
            100, or --lines N. There is no follow mode.
  list      Print one line for each guest under the vm home: its name,
            whether it runs, and its workspaces.
  rm        Delete a stopped guest and undo its enrolment. It removes
            [executors.NAME] from loom.toml (--config PATH, default
            ~/.loom/loom.toml), and the [distribution] table and the home's
            .erlang.cookie only when they are this guest's deployment's and no
            other [executors.*] table remains; otherwise it leaves them and
            says so. Every other line of loom.toml is kept. A running guest is
            refused: run `loom vm down` first. Deleting a guest is permanent
            and work that is not pushed is lost, so without --yes it only lists
            the workspaces and the local branches that origin lacks.
  sync      Fetch a workspace copy's committed work into your own checkout as
            remote-tracking refs refs/remotes/vm/*, with no network and no
            daemon: `loom vm up` records which checkout each copy came from,
            and --checkout PATH names it (an older guest has no record). The
            guest's root is untrusted, so Git runs in your checkout and only
            reads the copy as a remote. Uncommitted edits are not fetched.
            --workspace NAME picks the copy when the guest holds several.
            --to-guest goes the other way: it bundles your checkout's refs into
            /srv/host-refs/NAME.bundle in the guest and prints the jailed
            command that fetches them as refs/remotes/host/*.

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
  // The commands share nothing but where a guest's files are.
  case command {
    Setup(source) -> setup(source)
    Up(options) -> up(options)
    Down(name) -> down(name)
    Status(name) -> status(name)
    Logs(name, lines) -> logs(name, lines)
    Guests -> guests()
    Remove(name, config, consent) -> remove(name, config, consent)
    Sync(options) -> sync(options)
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
    state_disk: String,
    pid_file: String,
    log: String,
    allow_file: String,
    checkouts_file: String,
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
    state_disk: directory <> "/state.img",
    pid_file: directory <> "/loom-vm.pid",
    log: directory <> "/loom-vm.log",
    allow_file: directory <> "/" <> vm_spec.allow_file,
    checkouts_file: directory <> "/" <> vm_spec.checkouts_file,
  )
}

/// Reads and decodes the artifact manifest, naming how to make one when it is
/// missing.
fn read_manifest(vm_home: String) -> Result(Manifest, String) {
  use found <- result.try(read_manifest_if_present(vm_home))

  // The words for a missing file depend on whether this build has a release
  // to install, so they are built only when the file is missing.
  case found {
    Some(manifest) -> Ok(manifest)
    None ->
      Error(vm_spec.missing_manifest(
        manifest_path(vm_home),
        build_identity.current().version,
      ))
  }
}

/// Where `loom-vm setup` writes the manifest.
fn manifest_path(vm_home: String) -> String {
  vm_home <> "/manifest.json"
}

/// The decoded manifest, or `None` when there is not one yet.
fn read_manifest_if_present(
  vm_home: String,
) -> Result(option.Option(Manifest), String) {
  let path = manifest_path(vm_home)

  // A missing manifest is the ordinary first-run state, and `up` answers it
  // by installing the artifacts. Any other read error is the file's.
  case simplifile.read(path) {
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
    Ok(text) ->
      vm_spec.decode_manifest(text)
      |> result.map(Some)
      |> result.map_error(fn(reason) { path <> ": " <> reason })
  }
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

// --- setup -------------------------------------------------------------------

// A release's guest image is several hundred megabytes, pulled from a
// registry, so setup gets half an hour and not the seconds of a lookup.
const setup_budget_ms = 1_800_000

/// Installs the microVM artifacts and says where the manifest is.
fn setup(source: vm_spec.SetupSource) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  use source <- result.try(absolute_source(source))
  use manifest <- result.try(install_artifacts(vm_home, source))
  Ok(
    "Installed the microVM artifacts for revision "
    <> manifest.revision
    <> ". The manifest is "
    <> manifest_path(vm_home)
    <> ".",
  )
}

/// Runs `loom-vm setup` for each attempt the source allows, in order, until
/// one installs. A run that fails counts as that attempt's failure and the next
/// is tried.
///
/// A tag guessed from the running build is run with `--revision`, so
/// `loom-vm` refuses an image of another commit after reading its labels and
/// before it downloads or writes anything. A failed attempt therefore leaves
/// the cache and the manifest as they were, and no restore is needed.
fn install_artifacts(
  vm_home: String,
  source: vm_spec.SetupSource,
) -> Result(Manifest, String) {
  let identity = build_identity.current()
  use attempts <- result.try(vm_spec.setup_attempts(
    source,
    identity.version,
    identity.commit,
    vm_home,
  ))

  try_attempts(vm_home, attempts, [])
  |> result.map_error(vm_spec.setup_failure(source, _))
}

/// Tries the attempts in order. The error is the failure of each, in the order
/// they were tried.
fn try_attempts(
  vm_home: String,
  attempts: List(vm_spec.Attempt),
  failures: List(#(String, String)),
) -> Result(Manifest, List(#(String, String))) {
  // The list is the order to try; an empty one is the end of the search.
  case attempts {
    [] -> Error(list.reverse(failures))
    [attempt, ..rest] -> {
      io.println_error(
        "Installing the microVM artifacts for " <> attempt.name <> ".",
      )

      // A failed attempt is recorded and the next one tried; the first that
      // installs ends the search.
      case run_attempt(vm_home, attempt) {
        Ok(manifest) -> Ok(manifest)
        Error(reason) ->
          try_attempts(vm_home, rest, [#(attempt.name, reason), ..failures])
      }
    }
  }
}

/// One `loom-vm setup` run and the manifest it wrote.
fn run_attempt(
  vm_home: String,
  attempt: vm_spec.Attempt,
) -> Result(Manifest, String) {
  use Nil <- result.try(run_launcher(attempt.arguments))
  installed_after_setup(vm_home)
}

/// A build tree named relatively is named from this directory, and the
/// launcher resolves it from its own, so it is made absolute here.
fn absolute_source(
  source: vm_spec.SetupSource,
) -> Result(vm_spec.SetupSource, String) {
  case source {
    vm_spec.BuildTree(directory) ->
      bootstrap.absolute_path(directory) |> result.map(vm_spec.BuildTree)
    vm_spec.OwnRelease | vm_spec.ReleaseTag(_) -> Ok(source)
  }
}

/// Runs the shipped `loom-vm` with `arguments`. Its progress goes to this
/// command's standard error, and its manifest on standard output is dropped:
/// the file it wrote is what `up` reads.
fn run_launcher(arguments: List(String)) -> Result(Nil, String) {
  use launcher <- result.try(
    install.bundled_launcher()
    |> result.map_error(fn(_) {
      install.launcher()
      <> " does not exist. This installation was built without the microVM "
      <> "launcher; install a release that ships it, or build the artifacts "
      <> "in a checkout and run `make vmm-install-dev`."
    }),
  )

  // Only status zero is success; the launcher's own refusal text went to
  // standard error already.
  case ffi_os.run_capture(launcher, arguments, setup_budget_ms) {
    Ok(#(0, _)) -> Ok(Nil)
    Ok(#(status, _)) ->
      Error(
        "loom-vm setup exited with status "
        <> int.to_string(status)
        <> "; the reason is above",
      )
    Error(reason) -> Error("loom-vm setup: " <> reason)
  }
}

/// The manifest setup just wrote. A launcher that exited zero and left none is
/// a broken installation, not a first run.
fn installed_after_setup(vm_home: String) -> Result(Manifest, String) {
  use found <- result.try(read_manifest_if_present(vm_home))
  option.to_result(
    found,
    manifest_path(vm_home) <> " was not written by loom-vm setup",
  )
}

/// The manifest `up` boots from. With none installed it installs the running
/// build's release first and says so; a development build has no release, so
/// it keeps the refusal that names the make target.
fn installed_manifest(vm_home: String) -> Result(Manifest, String) {
  use found <- result.try(read_manifest_if_present(vm_home))

  // An installed manifest is used as it is; only its absence starts a setup.
  case found {
    Some(manifest) -> Ok(manifest)
    None -> {
      let identity = build_identity.current()
      use _ <- result.try(
        vm_spec.release_candidates(identity.version, identity.commit)
        |> result.map_error(fn(_) {
          vm_spec.missing_manifest(manifest_path(vm_home), identity.version)
        }),
      )
      io.println_error(
        "No microVM artifacts are installed; running `loom vm setup` for this "
        <> "build.",
      )
      install_artifacts(vm_home, vm_spec.OwnRelease)
    }
  }
}

// --- up ----------------------------------------------------------------------

/// Provisions, enrolls, stages and boots one guest.
fn up(options: UpOptions) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  use manifest <- result.try(installed_manifest(vm_home))
  use Nil <- result.try(vm_spec.check_revision(
    manifest,
    build_identity.current().commit,
  ))
  use workspace <- result.try(workspace_of(options))
  let names = vm_spec.names(options.name)
  let guest = instance(vm_home, options.name)
  use Nil <- result.try(refuse_running(guest, options.name))

  // What the script and the allowlist ask for is settled before anything is
  // written, so a refused `--provision` or a bad allow file changes nothing.
  use plan <- result.try(provisioning(guest, options))
  use allow <- result.try(allowed_hosts(guest, options))
  let options = UpOptions(..options, allow:)

  // The deployment and the enrollment come before the guest root, so a
  // loom.toml that holds another deployment is refused before a root of
  // several hundred megabytes is cloned.
  use #(orchestrator, executor, provisioned) <- result.try(deployment(
    guest,
    names,
  ))
  use enrolled <- result.try(enroll(orchestrator, options, provisioned))
  use Nil <- result.try(stage(
    manifest,
    guest,
    executor,
    workspace,
    options,
    plan,
  ))
  use port <- result.try(boot(manifest, guest, names, options, plan))
  report(options, workspace, port, enrolled)
}

// --- the allowlist and the provisioning script --------------------------------

/// The hosts this `up` launches the guest with beyond GitHub's: the ones given,
/// or the ones an earlier `up` recorded in the guest's directory, or none for
/// `--fresh`.
fn allowed_hosts(
  guest: Instance,
  options: UpOptions,
) -> Result(List(String), String) {
  // The recorded file is read only when it decides the answer, so a damaged
  // one is replaced by `--allow` and ignored by `--fresh`.
  use recorded <- result.try(case options.allow, options.freshness {
    [], vm_spec.Resume -> recorded_allow(guest)
    _, _ -> Ok([])
  })

  Ok(vm_spec.effective_allow(options.allow, recorded, options.freshness))
}

/// The hosts the guest's allow file records, or none when it has no file.
fn recorded_allow(guest: Instance) -> Result(List(String), String) {
  case simplifile.read(guest.allow_file) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(
        guest.allow_file
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
    Ok(text) ->
      vm_spec.decode_allow(text)
      |> result.map_error(fn(reason) {
        guest.allow_file
        <> ", "
        <> reason
        <> ". Fix or remove the file, or give --allow to replace it."
      })
  }
}

/// Records the hosts the guest launches with, so `down` and `up` keep them.
/// An empty list removes the record.
fn record_allow(guest: Instance, hosts: List(String)) -> Result(Nil, String) {
  case hosts {
    [] ->
      case simplifile.delete(guest.allow_file) {
        Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) ->
          Error(
            guest.allow_file
            <> " cannot be removed: "
            <> simplifile.describe_error(error),
          )
      }
    _ -> write_private(guest.allow_file, vm_spec.encode_allow(hosts))
  }
}

/// What `--provision` and the guest root's history decide. The script must be
/// a file the developer named, and only this flag can name one: the workspace
/// is untrusted input and is never searched for a script.
fn provisioning(
  guest: Instance,
  options: UpOptions,
) -> Result(vm_spec.ProvisionPlan, String) {
  // Without the flag there is no script to check. With it, the path must name
  // a file now, so a typo is refused before the guest is touched.
  use requested <- result.try(case options.provision {
    None -> Ok(None)
    Some(path) -> {
      use absolute <- result.try(bootstrap.absolute_path(path))

      // A directory, a missing path and an unreadable one are the same refusal.
      case simplifile.is_file(absolute) {
        Ok(True) -> Ok(Some(absolute))
        _ -> Error("--provision " <> path <> " is not a file")
      }
    }
  })

  // `--fresh` replaces the root, so it has no history to consult.
  let seen = case options.freshness {
    vm_spec.Fresh -> vm_spec.NeverProvisioned
    vm_spec.Resume -> root_provisioning(guest)
  }

  vm_spec.provision_plan(requested, seen)
}

/// What the guest's existing root says about an earlier provisioning.
fn root_provisioning(guest: Instance) -> vm_spec.RootProvisioning {
  case
    bootstrap.path_exists(guest.root <> vm_spec.provision_marker),
    bootstrap.path_exists(guest.root <> vm_spec.provision_script)
  {
    True, _ -> vm_spec.AlreadyProvisioned
    False, True -> vm_spec.FailedBefore
    False, False -> vm_spec.NeverProvisioned
  }
}

// The directory to copy, canonical, the name its copy has in the guest, and
// whether its `.git` is a directory of its own.
type Workspace {
  Workspace(path: String, name: String, checkout: Checkout)
}

// A checkout's `.git` is a directory the copy takes along, or a file that
// points at a repository outside the directory (a linked worktree), which the
// copy cannot take along.
type Checkout {
  Standalone
  Linked
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

  // The path is recorded for `sync`, so it must be one the record can hold.
  use Nil <- result.try(vm_spec.valid_checkout_path(path))

  // A linked worktree's `.git` is a file that points at the main repository,
  // outside the copy. `copy_workspace` gives its copy a repository of its own.
  let checkout = case bootstrap.path_kind(path <> "/.git") {
    bootstrap.RegularFile -> Linked
    bootstrap.OtherEntry | bootstrap.NoEntry -> Standalone
  }

  Ok(Workspace(path:, name:, checkout:))
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
) -> Result(#(Bundle, Bundle, Provisioned), String) {
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
      Ok(#(orchestrator, executor, Reused))
    }
    False ->
      provision(guest, names)
      |> result.map(fn(pair) { #(pair.0, pair.1, Minted) })
  }
}

// Whether `deployment` minted this guest's bundles now or read the ones an
// earlier `up` wrote. Only new bundles are installed: the earlier install is
// already in the user's `loom.toml`, possibly with keys the user added since.
type Provisioned {
  Minted
  Reused
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
  Enrolled(config: String, file: ConfigFile)
}

// Whose configuration holds the guest's deployment. Only the daemon of the
// default state directory can be found and stopped, and it reads only the
// default file, so a `--config` run must never reach it: a private file, as a
// test uses, would otherwise shut down the developer's own idle daemon. A
// resumed guest counts as well: a first `up` that installed the deployment and
// then failed to boot leaves a daemon that never read it.
type ConfigFile {
  // The exact default file, which the default daemon reads.
  DefaultConfigFile

  // Another file.
  OtherConfigFile
}

/// Installs the orchestrator's bundle into the user's `loom.toml` the way
/// `loom distribution install` does, and refuses what it would replace.
fn enroll(
  orchestrator: Bundle,
  options: UpOptions,
  provisioned: Provisioned,
) -> Result(Enrolled, String) {
  use home <- result.try(home())
  let config =
    option.lazy_unwrap(options.config, fn() {
      distribution_install.default_config(home)
    })
  use config <- result.try(bootstrap.absolute_path(config))
  use default <- result.try(
    bootstrap.absolute_path(distribution_install.default_config(home)),
  )

  let file = config_file(config, default)

  // A resumed guest's deployment is already installed. Installing it again
  // compares the whole [distribution] table, so a key the user added since,
  // such as `listen_address`, would refuse the resume; the executor row is
  // what has to still be there.
  case provisioned {
    Reused -> still_enrolled(orchestrator, config, file)
    Minted -> install(orchestrator, config, home, file)
  }
}

/// Which file `config` is, for deciding whose daemon `up` may touch.
fn config_file(config: String, default: String) -> ConfigFile {
  // Only the exact default file belongs to the daemon `up` can find.
  case config == default {
    True -> DefaultConfigFile
    False -> OtherConfigFile
  }
}

/// Checks that a resumed guest's executor row is still in `config`.
fn still_enrolled(
  orchestrator: Bundle,
  config: String,
  file: ConfigFile,
) -> Result(Enrolled, String) {
  let row = "[executors." <> orchestrator_executor(orchestrator) <> "]"
  use text <- result.try(
    simplifile.read(config)
    |> result.map_error(fn(error) {
      config <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )

  // A resumed guest's deployment was installed by the `up` that minted it;
  // only the row it needs is checked, and a missing one is the operator's to
  // restore, since reinstalling would be refused as an existing deployment.
  case string.contains(text, row) {
    True -> Ok(Enrolled(config:, file:))
    False ->
      Error(
        config
        <> " no longer has "
        <> row
        <> ". The guest's deployment is still installed there, so add the row "
        <> "back:\n\n"
        <> enrolled_row(orchestrator),
      )
  }
}

/// Installs a newly minted orchestrator bundle into `config`, then binds the
/// daemon's distribution listener to loopback (protocol-change/106): the
/// orchestrator of a standing guest is never dialled, since the guest's
/// executor only accepts connections.
fn install(
  orchestrator: Bundle,
  config: String,
  home: String,
  file: ConfigFile,
) -> Result(Enrolled, String) {
  use _installed <- result.try(
    distribution_install.install(
      distribution_bundle.encode(orchestrator),
      Options(home:, config:, overwrite: RefuseExisting),
    )
    |> result.map_error(fn(reason) {
      vm_spec.without_force_hint(reason)
      <> "\n`loom vm up` never replaces a [distribution] table, an "
      <> "[executors."
      <> orchestrator_executor(orchestrator)
      <> "] table or a cookie that differs from the deployment's, and each "
      <> "guest mints its own, so only one guest per home is supported today. "
      <> "If another guest made the conflicting one, `loom vm rm --name NAME` "
      <> "removes it. Otherwise remove it from "
      <> config
      <> " (the cookie is "
      <> home
      <> "/.erlang.cookie), or give `--config` another file."
    }),
  )
  use text <- result.try(
    simplifile.read(config)
    |> result.map_error(fn(error) {
      config <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use Nil <- result.try(write_private(
    config,
    vm_spec.with_loopback_listener(text),
  ))
  Ok(Enrolled(config:, file:))
}

/// The `[executors.<name>]` table the orchestrator's bundle installed, as
/// text to add back.
fn enrolled_row(orchestrator: Bundle) -> String {
  // A bundle with no row names nothing to restore; the refusal then shows
  // the shape with placeholders.
  case orchestrator.executors {
    [row, ..] ->
      "[executors." <> row.name <> "]\nnode = \"" <> row.node <> "\"\n"
    [] -> "[executors.NAME]\nnode = \"NODE\"\n"
  }
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
  options: UpOptions,
  plan: vm_spec.ProvisionPlan,
) -> Result(Nil, String) {
  use uname <- result.try(tool("uname", ["-s"], within: quick_ms))
  use platform <- result.try(vm_spec.platform_of(uname))
  use Nil <- result.try(prepare_root(manifest, guest, platform, options))
  use Nil <- result.try(record_allow(guest, options.allow))
  use Nil <- result.try(stage_node(
    guest.root,
    executor,
    workspace.name,
    options.github,
    options.allow,
  ))
  use Nil <- result.try(stage_script(guest.root, plan))
  use copy <- result.try(copy_workspace(guest.root, workspace, platform))
  record_checkout(guest, workspace, copy)
}

/// Copies the developer's script into the guest root, where the init runs it
/// as root before the executor starts. The target is removed first so a link
/// in the root cannot redirect the write, and the mode keeps the script
/// private to root, which is who runs it.
fn stage_script(
  root: String,
  plan: vm_spec.ProvisionPlan,
) -> Result(Nil, String) {
  // Only a script `up` was given this time is copied; a retried one is already
  // in the root and a plan with none stages nothing.
  case plan {
    vm_spec.NoScript | vm_spec.RetryStaged -> Ok(Nil)
    vm_spec.StageScript(source) -> {
      let target = root <> vm_spec.provision_script
      use Nil <- result.try(make_inside(
        root,
        filepath.directory_name(vm_spec.provision_script),
      ))
      use bytes <- result.try(
        simplifile.read_bits(source)
        |> result.map_error(fn(error) {
          source <> " is unreadable: " <> simplifile.describe_error(error)
        }),
      )
      let _ = simplifile.delete(target)
      let written = {
        use Nil <- result.try(simplifile.write_bits(target, bytes))
        simplifile.set_permissions_octal(target, 0o700)
      }
      written
      |> result.map_error(fn(error) {
        target <> " is unwritable: " <> simplifile.describe_error(error)
      })
    }
  }
}

/// The root and state disk `up` boots with. A guest that ran before keeps
/// both unless `--fresh` was given: its root holds the workspace copies the
/// agent edited and its state disk the executor's ledger and scopes, so a
/// `down` and `up` resumes where the guest stopped. A first `up`, or a fresh
/// one, clones the export and leaves `loom-vm` to create a new disk.
fn prepare_root(
  manifest: Manifest,
  guest: Instance,
  platform: vm_spec.Platform,
  options: UpOptions,
) -> Result(Nil, String) {
  // Resuming needs a root of its own to resume. A missing one is a first
  // boot, and a symbolic link is a root an older `up` left pointing at the
  // shared export, which a boot would write into, so it is replaced.
  let resumable =
    bootstrap.path_exists(guest.root)
    && !result.unwrap(simplifile.is_symlink(guest.root), False)

  // `--fresh` discards the state disk as well as the root, since the disk
  // holds the guest's writes against that root.
  case options.freshness, resumable {
    vm_spec.Resume, True -> Ok(Nil)
    vm_spec.Resume, False -> replace_root(manifest, guest, platform)
    vm_spec.Fresh, _ -> {
      use Nil <- result.try(remove_state_disk(guest))
      replace_root(manifest, guest, platform)
    }
  }
}

/// Removes the guest's state disk so `loom-vm` creates and the guest formats
/// a new one.
fn remove_state_disk(guest: Instance) -> Result(Nil, String) {
  // A guest that never ran has no disk to remove.
  case simplifile.delete(guest.state_disk) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        guest.state_disk
        <> " cannot be removed: "
        <> simplifile.describe_error(error),
      )
  }
}

/// The guest boots a clone of the export and writes into it, so each guest has
/// its own and the export is never booted. An old root of this guest is
/// removed first: `cp` into an existing directory would copy beside its
/// contents. The clone keeps the export's modes, which can leave a directory
/// the owner cannot delete, so the old root is made writable before removal.
///
/// The manifest's path is resolved first. `cp -R` copies a symbolic link
/// named on its command line as a link, so a manifest whose `guest_root` is a
/// link (a build tree assembled from links, as `setup --from-build` allows)
/// would make the guest's root a link to the export, and the guest would boot
/// and write into the export itself.
fn replace_root(
  manifest: Manifest,
  guest: Instance,
  platform: vm_spec.Platform,
) -> Result(Nil, String) {
  use export <- result.try(
    bootstrap.canonical_directory(manifest.guest_root)
    |> result.map_error(fn(reason) {
      manifest.guest_root <> " is not a directory: " <> reason
    }),
  )
  use Nil <- result.try(remove_root(guest))

  // A record names a copy in this root, and the new root has none.
  use Nil <- result.try(remove_checkouts(guest))
  tool(
    "cp",
    vm_spec.copy_arguments(platform, export, guest.root),
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
  github: vm_spec.GitHubAccess,
  allow: List(String),
) -> Result(Nil, String) {
  let node = root <> vm_spec.node_dir
  use Nil <- result.try(
    list.try_each(["/home", "/creds", "/state"], fn(directory) {
      make_inside(root, vm_spec.node_dir <> directory)
    }),
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
  write_private(
    node <> "/loom.toml",
    vm_spec.guest_config(executor, workspace, github, allow),
  )
}

/// Creates the directory `below` under the guest root, one component at a time,
/// and checks after each that it is where the root keeps it: its canonical path
/// must be the canonical root plus the same suffix. The root is a directory the
/// guest's `loom` user can write into, so an earlier boot that escaped its jail
/// could have left a link where a directory belongs, and the next write would
/// then land in a host directory (the executor's key and cookie, for the node).
/// Checking each component before creating the next means nothing is created
/// through a link either. `below` is a guest path such as `/srv/loom-node/home`.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.make_inside("/vm/dev/root", "/srv/loom-node/home")
/// ```
@internal
pub fn make_inside(root: String, below: String) -> Result(Nil, String) {
  use real_root <- result.try(
    bootstrap.canonical_path(root)
    |> result.map_error(fn(reason) { root <> " is unreadable: " <> reason }),
  )
  let segments =
    string.split(below, "/") |> list.filter(fn(part) { part != "" })

  // Each step extends the guest-relative suffix by one component.
  list.try_fold(segments, "", fn(suffix, segment) {
    let suffix = suffix <> "/" <> segment
    let path = root <> suffix

    // An existing directory, or a link the check below judges, is not an
    // error to create over; anything else is.
    use Nil <- result.try(case simplifile.create_directory(path) {
      Ok(Nil) | Error(simplifile.Eexist) -> Ok(Nil)
      Error(error) ->
        Error(path <> " is unwritable: " <> simplifile.describe_error(error))
    })

    // A dangling link exists but resolves to nothing, which is as wrong as one
    // that resolves elsewhere.
    let resolved = result.unwrap(bootstrap.canonical_path(path), "nowhere")

    // Only the exact suffix under the real root is where the guest keeps it.
    case resolved == real_root <> suffix {
      True -> Ok(suffix)
      False ->
        Error(
          path
          <> " resolves to "
          <> resolved
          <> ", not inside the guest root, so something in the guest left a "
          <> "link there. Replace the guest with --fresh.",
        )
    }
  })
  |> result.replace(Nil)
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
) -> Result(Copy, String) {
  let parent = root <> vm_spec.workspaces_dir
  let copy = parent <> "/" <> workspace.name
  use Nil <- result.try(make_inside(root, vm_spec.workspaces_dir))

  // A resumed guest's copy is the one the agent has been editing; copying
  // the host's checkout over it would discard that work.
  use <- bool.guard(bootstrap.path_exists(copy), Ok(Kept))
  let copied = {
    use _ <- result.try(tool(
      "cp",
      vm_spec.copy_arguments(platform, workspace.path, copy),
      within: copy_budget_ms,
    ))
    use _ <- result.try(tool(
      "chmod",
      ["-R", "u+w", copy],
      within: copy_budget_ms,
    ))
    use Nil <- result.try(own_repository(root, workspace, copy))
    scrub_config(copy <> "/.git/config")
  }

  // A later `up` keeps a copy that exists, so a copy that a step failed on
  // (half copied, with a `.git` that still points at the host, or with the
  // credentials unscrubbed) is removed and the next `up` makes it again.
  case copied {
    Ok(Nil) -> Ok(Copied)
    Error(reason) -> {
      let _ = remove_tree(copy)
      Error(reason)
    }
  }
}

// Whether `up` made a workspace copy now or found the one an earlier `up`
// made. Only a copy made now is known to come from the directory `up` was
// given, so only it is recorded.
type Copy {
  Copied
  Kept
}

/// Records which developer checkout a workspace copy came from, in the file
/// beside the root that `sync` reads. A damaged record is replaced, since the
/// copy was just made from the checkout the record would name.
fn record_checkout(
  guest: Instance,
  workspace: Workspace,
  copy: Copy,
) -> Result(Nil, String) {
  // A kept copy's origin is whatever the record already says.
  case copy {
    Kept -> Ok(Nil)
    Copied -> {
      let known = result.unwrap(read_checkouts(guest), [])
      write_private(
        guest.checkouts_file,
        vm_spec.encode_checkouts(vm_spec.record_checkout(
          known,
          workspace.name,
          workspace.path,
        )),
      )
    }
  }
}

/// The recorded checkouts of a guest's workspaces; none when there is no
/// record, the error when it is damaged.
fn read_checkouts(guest: Instance) -> Result(List(#(String, String)), String) {
  case simplifile.read(guest.checkouts_file) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(
        guest.checkouts_file
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
    Ok(text) ->
      vm_spec.decode_checkouts(text)
      |> result.map_error(fn(reason) { guest.checkouts_file <> ", " <> reason })
  }
}

/// Removes the checkouts record, which a replaced root outdates.
fn remove_checkouts(guest: Instance) -> Result(Nil, String) {
  case simplifile.delete(guest.checkouts_file) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        guest.checkouts_file
        <> " cannot be removed: "
        <> simplifile.describe_error(error),
      )
  }
}

/// Gives a linked worktree's copy a repository of its own. A standalone
/// checkout's copy already has one. A Git failure is refused in one line naming
/// the worktree; `copy_workspace` removes the copy.
fn own_repository(
  root: String,
  workspace: Workspace,
  copy: String,
) -> Result(Nil, String) {
  // A standalone checkout's copy already carries its own `.git` directory.
  case workspace.checkout {
    Standalone -> Ok(Nil)
    Linked -> {
      // The staging directory is inside the node directory, which the guest
      // owns, so it is checked here as well as by `stage_node`.
      use Nil <- result.try(make_inside(root, vm_spec.node_dir))
      let staging = root <> vm_spec.node_dir <> "/git-staging"
      let made = standalone_repository(workspace.path, copy, staging)
      let _ = simplifile.delete_all([staging])
      result.map_error(made, vm_spec.git_refusal(workspace.path, _))
    }
  }
}

/// Clones the worktree's repository without a checkout into `staging`, moves
/// its `.git` over the copy's `.git` file, and points the copy at the
/// worktree's `HEAD` and `origin`. The copy's files are the worktree's files as
/// they are, so uncommitted edits stay; its index is reset to `HEAD`, which
/// makes them show as edits and not as a deleted and an untracked tree.
fn standalone_repository(
  worktree: String,
  copy: String,
  staging: String,
) -> Result(Nil, String) {
  use symbolic <- result.try(
    git(worktree, [
      "rev-parse",
      "--symbolic-full-name",
      "HEAD",
    ]),
  )
  use commit <- result.try(git(worktree, ["rev-parse", "--verify", "HEAD"]))
  use origin <- result.try(
    git(worktree, [
      "config",
      "--default",
      "",
      "--get",
      "remote.origin.url",
    ]),
  )
  use target <- result.try(vm_spec.head_target(symbolic, commit))
  use Nil <- result.try(
    simplifile.delete_all([staging])
    |> result.map_error(fn(error) {
      staging <> " cannot be cleared: " <> simplifile.describe_error(error)
    }),
  )
  use _ <- result.try(tool(
    "git",
    vm_spec.clone_arguments(worktree, staging),
    within: copy_budget_ms,
  ))

  // The copy's `.git` is a file, and the rename needs its place empty.
  use Nil <- result.try(
    simplifile.delete(copy <> "/.git")
    |> result.try(fn(_) {
      simplifile.rename(staging <> "/.git", copy <> "/.git")
    })
    |> result.map_error(fn(error) {
      copy <> "/.git cannot be replaced: " <> simplifile.describe_error(error)
    }),
  )
  use Nil <- result.try(
    list.try_each(vm_spec.head_arguments(target), fn(arguments) {
      git(copy, arguments) |> result.replace(Nil)
    }),
  )
  use _ <- result.try(git(copy, vm_spec.origin_arguments(origin)))
  use _ <- result.try(git(copy, ["reset", "--quiet"]))

  // The clone's object files are read-only, as every Git directory's are.
  tool("chmod", ["-R", "u+w", copy <> "/.git"], within: copy_budget_ms)
  |> result.replace(Nil)
}

/// Runs `git -C directory` with the arguments and answers its output.
fn git(directory: String, arguments: List(String)) -> Result(String, String) {
  tool("git", ["-C", directory, ..arguments], within: copy_budget_ms)
}

/// Removes a tree that may hold read-only files and directories. `chmod -R`
/// does not follow a link it meets, and `simplifile.delete_all` removes a link
/// itself, so a link a guest left in the tree is deleted and never entered.
fn remove_tree(path: String) -> Result(Nil, String) {
  use _ <- result.try(tool(
    "chmod",
    ["-R", "u+rwX", path],
    within: copy_budget_ms,
  ))
  simplifile.delete_all([path])
  |> result.map_error(fn(error) {
    path <> " cannot be removed: " <> simplifile.describe_error(error)
  })
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

/// Boots the guest and answers the host port its executor is forwarded to.
fn boot(
  manifest: Manifest,
  guest: Instance,
  names: vm_spec.Names,
  options: UpOptions,
  plan: vm_spec.ProvisionPlan,
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
      state_disk: guest.state_disk,
      github: options.github,
      allow: options.allow,
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
  use Nil <- result.try(await_ready(guest, record, vm_spec.boot_budget_ms(plan)))
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
/// stopped, so a failed `up` leaves nothing running. A cold boot takes well
/// under a minute, so the default budget is for a first run on a loaded
/// machine; a provisioning script gets the longer one, because the executor
/// starts only after it exits.
fn await_ready(
  guest: Instance,
  record: PidRecord,
  within within: Int,
) -> Result(Nil, String) {
  let outcome =
    poll.until(within:, every: 250, attempt: fn() {
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
          <> int.to_string(within / 1000)
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
  let provisioning_failed =
    string.contains(console, vm_spec.provision_failed_marker)

  // The ready marker wins over a failure marker in the same read: the guest
  // prints it only once the executor serves. The script's own output is the
  // account of a failed provisioning, so the tail of the console is the error.
  case ready, failed, provisioning_failed {
    True, _, _ -> poll.Done(Nil)
    _, _, True ->
      poll.Fail(
        "the guest's provisioning script failed. The end of its console, "
        <> "which is in "
        <> guest.log
        <> ":\n"
        <> vm_spec.tail(console, 4000),
      )
    _, True, _ ->
      poll.Fail("the guest's executor failed:\n" <> vm_spec.tail(console, 4000))
    False, False, False -> {
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
      daemon_lines(enrolled.file),
      ["Stop it with: loom vm down --name " <> options.name],
    ]),
    "\n",
  ))
}

/// The lines about daemons, after doing what this `up` calls for.
fn daemon_lines(file: ConfigFile) -> List(String) {
  // Only the default daemon is ever observed or stopped.
  case file {
    DefaultConfigFile -> daemon_note()
    OtherConfigFile -> [
      "A daemon already running with that file must restart to use the guest.",
      "",
    ]
  }
}

/// What `up` does about the user's daemon, and the lines that say so.
///
/// A running daemon read its configuration before the `[distribution]` table
/// existed, so only a restart reaches the guest. A daemon that holds no session
/// is stopped here, and the next `loom` command starts it again with the table
/// in effect: the `loom` client renders the TLS options file whenever it starts
/// a daemon whose configuration has `[distribution]` (protocol-change/106). A
/// daemon that holds any session is never stopped; the note names the command.
fn daemon_note() -> List(String) {
  // No daemon needs no action. A running one is decided on what it said about
  // its sessions, in `vm_spec.daemon_step`, which is the only place that
  // chooses to stop it.
  let outcome = case observe_daemon() {
    None -> vm_spec.NoDaemon
    Some(#(fence, sessions)) ->
      case vm_spec.daemon_step(fence.pid, sessions) {
        vm_spec.StopIt -> stop_daemon(fence)
        vm_spec.LeaveAlone(outcome) -> outcome
      }
  }

  vm_spec.daemon_note(outcome)
}

/// The daemon the default state directory's endpoint record names, if its
/// process is still there, with how many sessions it says it holds. Anything
/// that cannot be read counts as no daemon, because the note it chooses is
/// advice and not a decision; a daemon that answers no status is `Uncounted`.
fn observe_daemon() -> option.Option(#(endpoint.Fence, vm_spec.Sessions)) {
  let found = {
    use home <- result.try(home())
    use paths <- result.try(endpoint.paths(home <> "/.loom"))
    use found <- result.try(endpoint.load(paths))
    present_in(found)
  }

  // A record with no live process is no daemon; a live one is asked how many
  // sessions it holds, and an answer that cannot be read is not a count of zero.
  case result.unwrap(found, None) {
    None -> None
    Some(fence) ->
      case ask_daemon("status") |> result.try(vm_spec.occupied_sessions) {
        Ok(count) -> Some(#(fence, vm_spec.Counted(count)))
        Error(_) -> Some(#(fence, vm_spec.Uncounted))
      }
  }
}

/// The fence of a loaded endpoint record whose process is still there.
fn present_in(
  found: option.Option(endpoint.Endpoint),
) -> Result(option.Option(endpoint.Fence), String) {
  // No record names no process, and a record names one only while that exact
  // pid and birth marker are still there.
  case found {
    Some(record) -> {
      use there <- result.map(endpoint.is_present(record.fence))

      // A recorded process that has gone is the same as no record.
      case there {
        True -> Some(record.fence)
        False -> None
      }
    }
    None -> Ok(None)
  }
}

/// Sends one control command to the daemon of the default state directory,
/// as the owner, and answers its reply body. The exchange never starts a
/// daemon.
fn ask_daemon(command: String) -> Result(core_json.JsonValue, String) {
  use replies <- result.try(
    access.execute(access.raw_request("", command, "", [])),
  )

  // Both commands answer one reply body; anything else is not their answer.
  case replies {
    [body] -> Ok(body)
    _ -> Error("the daemon's reply to " <> command <> " is not one body")
  }
}

// How long `up` waits for a drained daemon's process to go. The daemon's own
// drain budget is longer than this in the worst case, in which case the
// command to run is printed.
const daemon_stop_within_ms = 60_000

/// Asks an idle daemon to drain and waits for its process to go.
fn stop_daemon(fence: endpoint.Fence) -> vm_spec.DaemonOutcome {
  let stopped = {
    use _ <- result.try(ask_daemon("daemon.shutdown"))
    await_departure(fence)
  }

  // A refusal or a timeout is a reason for the note, not a failed `up`: the
  // guest is already running.
  case stopped {
    Ok(Nil) -> vm_spec.Stopped
    Error(why) -> vm_spec.NotStopped(fence.pid, why)
  }
}

/// Polls until the daemon's process, by pid and birth marker, is gone.
fn await_departure(fence: endpoint.Fence) -> Result(Nil, String) {
  let gone =
    poll.until(within: daemon_stop_within_ms, every: 100, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })

  // Each end of the wait is either the process gone or a reason it is not.
  case gone {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired ->
      Error(
        "still running after "
        <> int.to_string(daemon_stop_within_ms / 1000)
        <> " s",
      )
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
      "allowed:    " <> allow_line(guest),
      "provision:  " <> provision_line(guest),
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

/// The workspace copies the guest's root holds. Only the one the latest `up`
/// registered in the guest's configuration is what `--workspace` can name to
/// `loom --executor`; the others are copies on disk.
fn workspace_line(guest: Instance) -> String {
  case workspace_names(guest) {
    Ok([]) | Error(_) -> "none"
    Ok(names) -> string.join(names, ", ")
  }
}

/// The hosts the guest may reach besides GitHub's, from its allow file.
fn allow_line(guest: Instance) -> String {
  case recorded_allow(guest) {
    Ok([]) -> "none"
    Ok(hosts) -> string.join(hosts, ", ")
    Error(reason) -> "unknown (" <> reason <> ")"
  }
}

/// Whether the guest's provisioning script ran, is waiting to run, or was never
/// given.
fn provision_line(guest: Instance) -> String {
  case root_provisioning(guest) {
    vm_spec.AlreadyProvisioned -> "done"
    vm_spec.FailedBefore -> "pending, the next up runs it again"
    vm_spec.NeverProvisioned -> "none"
  }
}

// --- reading a guest's root without trusting it -------------------------------

/// Checks that each directory of `segments` below `base` exists, is a
/// directory and is not a link, one component at a time, and answers the final
/// path. A guest's root is writable by model-influenced code, so a link may
/// have replaced any directory in it, and reading through one would read
/// whatever it points at.
fn plain_chain(base: String, segments: List(String)) -> Result(String, String) {
  list.try_fold(segments, base, fn(path, segment) {
    let next = path <> "/" <> segment

    // `link_info` describes the entry itself, never what a link points at.
    case simplifile.link_info(next) {
      Ok(info) ->
        case simplifile.file_info_type(info) {
          simplifile.Directory -> Ok(next)
          simplifile.Symlink ->
            Error(
              vm_spec.printable(next)
              <> " is a link, so something in the guest left it there. "
              <> "Replace the guest with --fresh.",
            )
          simplifile.File | simplifile.Other ->
            Error(vm_spec.printable(next) <> " is not a directory")
        }
      Error(error) ->
        Error(
          vm_spec.printable(next)
          <> " is unreadable: "
          <> simplifile.describe_error(error),
        )
    }
  })
}

/// Whether `path` is a directory itself and not a link to one.
fn is_plain_directory(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Directory
    Error(_) -> False
  }
}

/// Refuses a guest that has no directory under the vm home, or whose directory
/// is a link.
fn existing_guest(
  guest: Instance,
  name: String,
  vm_home: String,
) -> Result(Nil, String) {
  case is_plain_directory(guest.directory) {
    True -> Ok(Nil)
    False ->
      Error(
        "there is no guest "
        <> name
        <> " under "
        <> vm_home
        <> ". `loom vm list` names the guests there.",
      )
  }
}

/// The names of the workspace copies in a guest's root, sorted. Only names a
/// workspace can have are returned, because the directory is the guest's to
/// fill. A guest with no copies yet holds none, and a link anywhere on the way
/// is the error.
fn workspace_names(guest: Instance) -> Result(List(String), String) {
  // A root that was never made holds nothing; a link on the way is not
  // nothing, so only a missing path is skipped.
  use <- bool.guard(
    !bootstrap.path_exists(guest.root <> vm_spec.workspaces_dir),
    Ok([]),
  )
  use directory <- result.try(
    plain_chain(guest.directory, ["root", "srv", "workspaces"]),
  )
  use entries <- result.try(
    bootstrap.list_directory_bounded(directory, 1000)
    |> result.map_error(fn(reason) {
      vm_spec.printable(directory) <> ": " <> reason
    }),
  )

  Ok(
    entries
    |> list.filter(fn(entry) {
      result.is_ok(vm_spec.valid_workspace_name(entry))
    })
    |> list.sort(string.compare),
  )
}

// --- logs --------------------------------------------------------------------

// The last lines of a file, with whatever is not UTF-8 dropped. The console is
// the guest's own output, so it may hold any byte; `iconv -c` keeps the result
// text, and `|| true` is there because it exits nonzero when it dropped some.
const tail_script = "tail -n \"$1\" \"$2\" | iconv -c -f UTF-8 -t UTF-8 || true"

/// Prints the last `lines` lines of the guest's console log.
fn logs(name: String, lines: Int) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  let guest = instance(vm_home, name)

  // A guest that never started has no console.
  use Nil <- result.try(case bootstrap.path_kind(guest.log) {
    bootstrap.RegularFile -> Ok(Nil)
    bootstrap.OtherEntry | bootstrap.NoEntry ->
      Error(
        guest.log
        <> " does not exist, so the guest "
        <> name
        <> " has not been started. `loom vm list` names the guests.",
      )
  })

  use text <- result.try(tool(
    "sh",
    ["-c", tail_script, "sh", int.to_string(lines), guest.log],
    within: quick_ms,
  ))

  // Guest text goes to a terminal only after its control characters are gone.
  case string.trim_end(vm_spec.printable(text)) {
    "" -> Ok("The console log " <> guest.log <> " is empty.")
    printed -> Ok(printed)
  }
}

// --- list --------------------------------------------------------------------

/// One line for each guest under the vm home.
fn guests() -> Result(String, String) {
  use vm_home <- result.try(vm_home())

  // A home that does not exist yet holds no guests, which is not an error.
  use entries <- result.try(case simplifile.read_directory(vm_home) {
    Ok(entries) -> Ok(entries)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(vm_home <> " is unreadable: " <> simplifile.describe_error(error))
  })

  // A guest directory has a valid name, is a directory of its own and holds
  // the deployment `up` provisions first. The manifest and the artifact cache
  // that share the home are neither.
  let names =
    entries
    |> list.filter(fn(entry) {
      result.is_ok(vm_spec.valid_name(entry))
      && is_plain_directory(vm_home <> "/" <> entry)
      && is_plain_directory(vm_home <> "/" <> entry <> "/deploy")
    })
    |> list.sort(string.compare)
  let width =
    list.fold(names, 0, fn(widest, name) {
      int.max(widest, string.length(name))
    })

  // An empty home says so instead of printing nothing.
  case names {
    [] -> Ok("No guests under " <> vm_home <> ".")
    _ ->
      names
      |> list.map(guest_line(vm_home, _, width))
      |> string.join("\n")
      |> Ok
  }
}

/// A guest's name, whether it runs and its workspaces, in aligned columns. A
/// guest with no pid file is stopped.
fn guest_line(vm_home: String, name: String, width: Int) -> String {
  let guest = instance(vm_home, name)

  // A pid file that cannot be read says nothing either way, so the guest is
  // reported as unknown and not as stopped.
  let state = case process_state(guest) {
    Ok(Alive(_)) -> "running"
    Ok(NotRunning) -> "stopped"
    Error(_) -> "unknown"
  }

  string.pad_end(name, width, " ")
  <> "  "
  <> string.pad_end(state, 7, " ")
  <> "  "
  <> workspace_line(guest)
}

// --- rm ----------------------------------------------------------------------

// What `rm` will do to the user's configuration and cookie, decided before
// anything is written so a file that cannot be edited refuses the whole command.
type RemovalPlan {
  RemovalPlan(
    config: String,
    teardown: vm_spec.Teardown,
    // The configuration text after the tables go, or `None` when it is
    // unchanged.
    rewritten: option.Option(String),
  )
}

// How many refs, how deep and how large a ref file `rm` reads from a copy that
// a guest wrote. The limits are far above any real repository's branches and
// exist so a hostile tree costs one refusal and not the host's memory.
const refs_budget = 5000

const refs_depth = 8

const ref_file_limit = 512

const packed_refs_limit = 4_194_304

/// Deletes a stopped guest and undoes its enrolment.
fn remove(
  name: String,
  config: option.Option(String),
  consent: vm_spec.Consent,
) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  let guest = instance(vm_home, name)
  use Nil <- result.try(existing_guest(guest, name, vm_home))
  use state <- result.try(process_state(guest))

  // The guest's files are open in a running `loom-vm`, and its pid file is how
  // `down` finds it, so a running guest is stopped first.
  use Nil <- result.try(case state {
    Alive(record) ->
      Error(
        "the guest "
        <> name
        <> " runs as process "
        <> int.to_string(record.pid)
        <> ". Stop it with `loom vm down --name "
        <> name
        <> "` first.",
      )
    NotRunning -> Ok(Nil)
  })

  use home <- result.try(home())
  use config <- result.try(
    bootstrap.absolute_path(
      option.lazy_unwrap(config, fn() {
        distribution_install.default_config(home)
      }),
    ),
  )
  use plan <- result.try(removal_plan(guest, name, config, home))

  // Nothing is changed until the user has said yes, and the refusal is the
  // inventory of what the answer would lose.
  case consent {
    vm_spec.Unconfirmed ->
      Error(
        vm_spec.removal_refusal(name, inventory(guest))
        <> "\n"
        <> removal_preview(plan, home),
      )
    vm_spec.Confirmed -> apply_removal(guest, name, home, plan)
  }
}

/// Reads the configuration and the cookie and decides what undoing the guest's
/// enrolment removes. A configuration that cannot be parsed, or whose tables
/// cannot be removed line by line, refuses here with one line.
fn removal_plan(
  guest: Instance,
  name: String,
  config: String,
  home: String,
) -> Result(RemovalPlan, String) {
  let names = vm_spec.names(name)

  // A configuration that does not exist has no enrolment to undo.
  use text <- result.try(case simplifile.read(config) {
    Ok(text) -> Ok(text)
    Error(simplifile.Enoent) -> Ok("")
    Error(error) ->
      Error(config <> " is unreadable: " <> simplifile.describe_error(error))
  })

  use found <- result.try(
    vm_spec.read_enrolment(text, name)
    |> result.map_error(fn(reason) {
      config <> " " <> reason <> ". Nothing was removed."
    }),
  )
  use cookie <- result.try(cookie_state(guest, names, home))
  let teardown = vm_spec.plan_teardown(names, found, cookie)
  use edited <- result.try(
    distribution_install.without_tables(text, teardown.tables, config)
    |> result.map_error(fn(reason) { reason <> ". Nothing was removed." }),
  )

  // Text that is unchanged needs no write, so a guest that never enrolled
  // leaves the user's file untouched.
  let rewritten = case edited == text {
    True -> None
    False -> Some(edited)
  }

  Ok(RemovalPlan(config:, teardown:, rewritten:))
}

/// Compares the home's cookie with the one in the guest's deployment. A bundle
/// that is missing or unreadable cannot be compared, so the cookie counts as
/// another's and stays.
fn cookie_state(
  guest: Instance,
  names: vm_spec.Names,
  home: String,
) -> Result(vm_spec.CookieState, String) {
  let path = home <> "/.erlang.cookie"

  // No cookie file is a state of its own, not a failure.
  use found <- result.try(case simplifile.read(path) {
    Ok(text) -> Ok(Some(text))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
  })

  // The bundle is the record of what `up` installed, so it is what the file
  // is compared with.
  let deployed =
    read_bundle(bundle_file(guest, names.orchestrator), names.orchestrator_node)
    |> result.map(fn(bundle) { bundle.cookie })
    |> option.from_result

  Ok(vm_spec.cookie_state(found, deployed))
}

/// What `--yes` would remove and leave in the configuration, for the refusal.
fn removal_preview(plan: RemovalPlan, home: String) -> String {
  string.join(
    list.flatten([
      ["`--yes` also undoes the enrolment in " <> plan.config <> ":"],
      list.map(removed_things(plan, home), fn(thing) { "  removes " <> thing }),
      list.map(plan.teardown.left, fn(line) { "  leaves " <> line }),
    ]),
    "\n",
  )
}

/// The tables and the cookie the plan removes, each as the name a person
/// would use for it.
fn removed_things(plan: RemovalPlan, home: String) -> List(String) {
  let tables =
    list.map(plan.teardown.tables, fn(path) {
      "[" <> string.join(path, ".") <> "]"
    })

  // The cookie is listed only when the plan removes it.
  case plan.teardown.cookie {
    vm_spec.RemoveCookie -> list.append(tables, [home <> "/.erlang.cookie"])
    vm_spec.KeepCookie -> tables
  }
}

/// Removes the tables and the cookie the plan names, then the guest's
/// directory, and reports what it did and what it left.
fn apply_removal(
  guest: Instance,
  name: String,
  home: String,
  plan: RemovalPlan,
) -> Result(String, String) {
  // The enrolment is undone before the files go, so a failure part way leaves
  // a guest that can be removed again and no configuration naming a missing one.
  use Nil <- result.try(case plan.rewritten {
    Some(text) -> write_private(plan.config, text)
    None -> Ok(Nil)
  })

  // The cookie goes after the tables that name it, and only when the plan
  // found it to be this guest's deployment's.
  use Nil <- result.try(case plan.teardown.cookie {
    vm_spec.RemoveCookie ->
      simplifile.delete(home <> "/.erlang.cookie")
      |> result.map_error(fn(error) {
        home
        <> "/.erlang.cookie cannot be removed: "
        <> simplifile.describe_error(error)
      })
    vm_spec.KeepCookie -> Ok(Nil)
  })

  // The tree is made writable and removed without following a link.
  use Nil <- result.try(remove_tree(guest.directory))

  Ok(string.join(
    list.flatten([
      ["Removed the guest " <> name <> ": deleted " <> guest.directory <> "."],
      list.map(removed_things(plan, home), fn(thing) {
        "Removed " <> thing <> "."
      }),
      list.map(plan.teardown.left, fn(line) { "Left in place: " <> line }),
      enrolment_notice(plan),
    ]),
    "\n",
  ))
}

/// The reminder that a running daemon keeps the enrolment until it restarts,
/// when any table went.
fn enrolment_notice(plan: RemovalPlan) -> List(String) {
  case plan.teardown.tables {
    [] -> []
    _ -> [
      "A daemon that is already running keeps the enrolment until it restarts.",
    ]
  }
}

/// The branches each workspace copy holds that origin lacks, read as plain
/// files and never with `git`.
fn inventory(guest: Instance) -> List(#(String, vm_spec.Inventory)) {
  case workspace_names(guest) {
    Error(reason) -> [#("(workspaces)", vm_spec.Unreadable(reason))]
    Ok(names) ->
      list.map(names, fn(name) {
        #(name, read_inventory(guest.directory, name))
      })
  }
}

/// One copy's local branches that origin lacks at the same commit.
///
/// The copy is untrusted, so each directory on the way must be a plain
/// directory, each ref a plain file of bounded size, and any link, special
/// file or oversized tree makes the whole copy unreadable instead of partly
/// read. Packed refs come first, so a loose ref replaces its packed value as
/// Git reads them. `directory` is the guest's directory under the vm home.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.read_inventory("/vm/dev", "proj")
/// ```
@internal
pub fn read_inventory(
  directory: String,
  workspace: String,
) -> vm_spec.Inventory {
  let read = {
    use git <- result.try(
      plain_chain(directory, ["root", "srv", "workspaces", workspace, ".git"]),
    )
    use packed <- result.try(packed_refs(git <> "/packed-refs"))
    use heads <- result.try(loose_refs(git, ["refs", "heads"], "refs/heads"))
    use origin <- result.try(loose_refs(
      git,
      ["refs", "remotes", "origin"],
      "refs/remotes/origin",
    ))
    Ok(vm_spec.unpushed_branches(list.flatten([packed, heads, origin])))
  }

  // One unreadable ref makes the whole copy unreadable, and says why.
  case read {
    Ok(branches) -> vm_spec.Unpushed(branches)
    Error(reason) -> vm_spec.Unreadable(reason)
  }
}

/// The refs in a copy's `packed-refs`, none when it has no such file.
fn packed_refs(path: String) -> Result(List(#(String, String)), String) {
  case simplifile.link_info(path) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(
        vm_spec.printable(path)
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.File -> {
          use bytes <- result.try(
            bootstrap.read_bounded(path, packed_refs_limit)
            |> result.map_error(fn(reason) {
              vm_spec.printable(path) <> ": " <> reason
            }),
          )
          Ok(vm_spec.packed_refs(
            bit_array.to_string(bytes) |> result.unwrap(""),
          ))
        }
        simplifile.Directory | simplifile.Symlink | simplifile.Other ->
          Error(vm_spec.printable(path) <> " is a link or not a plain file")
      }
  }
}

/// The loose refs below `segments` under a copy's `.git`, named from
/// `prefix`. A directory that does not exist holds none, and a link anywhere on
/// the way is refused: the walk would otherwise read the link's target.
fn loose_refs(
  git: String,
  segments: List(String),
  prefix: String,
) -> Result(List(#(String, String)), String) {
  use found <- result.try(present_chain(git, segments))

  // A missing directory holds no refs, as a fresh repository has no remotes.
  case found {
    None -> Ok([])
    Some(directory) ->
      walk_refs(directory, prefix, refs_depth, refs_budget)
      |> result.map(fn(read) { read.0 })
  }
}

/// `plain_chain`, except that a component that does not exist ends the chain
/// with `None` instead of an error.
fn present_chain(
  base: String,
  segments: List(String),
) -> Result(option.Option(String), String) {
  list.try_fold(segments, Some(base), fn(found, segment) {
    // Once a component is absent, everything below it is too.
    case found {
      None -> Ok(None)
      Some(path) ->
        case simplifile.link_info(path <> "/" <> segment) {
          Error(simplifile.Enoent) -> Ok(None)
          Ok(_) | Error(_) -> plain_chain(path, [segment]) |> result.map(Some)
        }
    }
  })
}

/// Reads one directory of loose refs and the directories below it, and answers
/// the refs with the entries left of the budget.
fn walk_refs(
  directory: String,
  prefix: String,
  depth: Int,
  budget: Int,
) -> Result(#(List(#(String, String)), Int), String) {
  use <- bool.lazy_guard(depth < 0, fn() {
    Error(vm_spec.printable(directory) <> " is nested too deeply")
  })
  use entries <- result.try(
    bootstrap.list_directory_bounded(directory, budget)
    |> result.map_error(fn(reason) {
      vm_spec.printable(directory) <> ": " <> reason
    }),
  )

  // Every entry spends one of the budget, so the walk as a whole is bounded,
  // not only each directory.
  list.try_fold(entries, #([], budget - list.length(entries)), fn(state, entry) {
    let #(found, left) = state
    let path = directory <> "/" <> entry
    let ref = prefix <> "/" <> entry
    read_ref_entry(path, ref, depth, left)
    |> result.map(fn(read) { #(list.append(read.0, found), read.1) })
  })
}

/// One entry of a refs directory: a plain file is a ref, a plain directory is
/// walked, a lock file is a write in progress and skipped, and anything else
/// refuses the copy.
fn read_ref_entry(
  path: String,
  ref: String,
  depth: Int,
  left: Int,
) -> Result(#(List(#(String, String)), Int), String) {
  case simplifile.link_info(path) |> result.map(simplifile.file_info_type) {
    Ok(simplifile.File) ->
      case string.ends_with(path, ".lock") {
        True -> Ok(#([], left))
        False -> {
          use bytes <- result.try(
            bootstrap.read_bounded(path, ref_file_limit)
            |> result.map_error(fn(reason) {
              vm_spec.printable(path) <> ": " <> reason
            }),
          )
          let hash =
            vm_spec.loose_hash(bit_array.to_string(bytes) |> result.unwrap(""))
          Ok(#([#(ref, hash)], left))
        }
      }
    Ok(simplifile.Directory) -> walk_refs(path, ref, depth - 1, left)
    Ok(simplifile.Symlink) | Ok(simplifile.Other) ->
      Error(vm_spec.printable(path) <> " is a link or a special file")
    Error(error) ->
      Error(
        vm_spec.printable(path)
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
  }
}

// --- sync --------------------------------------------------------------------

/// Moves committed work between the developer's checkout and a guest's copy.
fn sync(options: SyncOptions) -> Result(String, String) {
  use vm_home <- result.try(vm_home())
  let guest = instance(vm_home, options.name)
  use Nil <- result.try(existing_guest(guest, options.name, vm_home))
  use held <- result.try(workspace_names(guest))
  use workspace <- result.try(
    vm_spec.only_workspace(held, options.workspace)
    |> result.map_error(fn(reason) {
      "the guest " <> options.name <> ": " <> reason
    }),
  )

  // `.git` of the copy must be a directory of its own: a link or a file there
  // would send Git to a repository outside the guest's root.
  use copy <- result.try(
    plain_chain(guest.directory, ["root", "srv", "workspaces", workspace]),
  )
  use _git <- result.try(plain_chain(copy, [".git"]))
  use checkout <- result.try(developer_checkout(guest, workspace, options))

  // The two directions share every check above and differ only in who is the
  // repository: the developer's checkout fetches, and its commits are bundled.
  case options.direction {
    vm_spec.FromGuest ->
      fetch_from_guest(options.name, workspace, copy, checkout)
    vm_spec.ToGuest -> bundle_to_guest(guest, options.name, workspace, checkout)
  }
}

/// The developer's checkout of a workspace: the one `--checkout` names, or the
/// one `up` recorded. It must be a directory, and not one inside the guest,
/// since Git runs there and the guest is never a place to run it.
fn developer_checkout(
  guest: Instance,
  workspace: String,
  options: SyncOptions,
) -> Result(String, String) {
  // The flag overrides the record, which an older guest does not have.
  use asked <- result.try(case options.checkout {
    Some(path) -> bootstrap.absolute_path(path)
    None -> recorded_checkout(guest, workspace, options.name)
  })

  use checkout <- result.try(
    bootstrap.canonical_directory(asked)
    |> result.map_error(fn(reason) {
      vm_spec.printable(asked) <> " is not a directory: " <> reason
    }),
  )
  use inside <- result.try(
    bootstrap.canonical_directory(guest.directory)
    |> result.map_error(fn(reason) { guest.directory <> ": " <> reason }),
  )

  // A path inside the guest's directory would make the checkout the guest's.
  case string.starts_with(checkout <> "/", inside <> "/") {
    True ->
      Error(
        checkout
        <> " is inside the guest's directory, which is untrusted. Name your own checkout with --checkout.",
      )
    False -> Ok(checkout)
  }
}

/// The checkout `up` recorded for a workspace, or the refusal that names the
/// flag that supplies it.
fn recorded_checkout(
  guest: Instance,
  workspace: String,
  name: String,
) -> Result(String, String) {
  use entries <- result.try(read_checkouts(guest))
  vm_spec.checkout_of(entries, workspace)
  |> option.to_result(
    "the guest "
    <> name
    <> " has no record of the checkout of "
    <> workspace
    <> ", because it was made by an older `loom vm up`. Name your checkout "
    <> "with --checkout PATH.",
  )
}

/// Fetches the copy's branches into the developer's checkout as
/// `refs/remotes/vm/*`. Git runs with the checkout as its repository and the
/// copy only as the remote, so nothing the guest wrote in `.git/config` is a
/// configuration of the process that fetches.
fn fetch_from_guest(
  name: String,
  workspace: String,
  copy: String,
  checkout: String,
) -> Result(String, String) {
  use output <- result.try(run_git(vm_spec.fetch_arguments(checkout, copy)))

  // A fetch with nothing new prints nothing, which would read as a failure.
  let fetched = case string.trim(vm_spec.printable(output)) {
    "" -> "Nothing new: every branch of the copy is already fetched."
    text -> text
  }

  Ok(string.join(
    [
      "Fetched the committed work of "
        <> workspace
        <> " in the guest "
        <> name
        <> " into "
        <> checkout
        <> " as refs/remotes/vm/*.",
      fetched,
      "",
      "Uncommitted edits in the guest are not fetched. List the branches "
        <> "with `git -C "
        <> checkout
        <> " branch -r`.",
    ],
    "\n",
  ))
}

/// Writes a bundle of the developer's refs into the guest root and says how to
/// fetch it in a jailed call. The bundle is made beside the root, where the
/// guest cannot reach it, and renamed into place, so a link the guest left at
/// the destination is replaced and never written through.
fn bundle_to_guest(
  guest: Instance,
  name: String,
  workspace: String,
  checkout: String,
) -> Result(String, String) {
  let staged = guest.directory <> "/to-guest-" <> workspace <> ".bundle"
  let target = guest.root <> vm_spec.bundle_guest_path(workspace)

  let placed = {
    use _ <- result.try(run_git(vm_spec.bundle_arguments(checkout, staged)))
    use Nil <- result.try(make_inside(guest.root, vm_spec.host_refs_dir))
    use Nil <- result.try(
      simplifile.set_permissions_octal(staged, 0o644)
      |> result.map_error(fn(error) {
        staged <> " is unwritable: " <> simplifile.describe_error(error)
      }),
    )
    simplifile.rename(staged, target)
    |> result.map_error(fn(error) {
      target <> " is unwritable: " <> simplifile.describe_error(error)
    })
  }

  // The staged file never stays: it was renamed away, or it is left over from
  // a failure.
  case placed {
    Ok(Nil) ->
      Ok(string.join(
        [
          "Wrote the commits of "
            <> checkout
            <> " to "
            <> vm_spec.bundle_guest_path(workspace)
            <> " in the guest "
            <> name
            <> ".",
          "Run this in the guest, in a jailed call in the workspace copy, to "
            <> "take them as refs/remotes/host/*:",
          "",
          "  " <> vm_spec.guest_fetch_command(workspace),
          "",
          "Uncommitted edits on the host are not included.",
        ],
        "\n",
      ))
    Error(reason) -> {
      let _ = simplifile.delete(staged)
      Error(reason)
    }
  }
}

/// Runs `git` with the arguments and answers its output, standard error
/// included. A refusal carries that output with its control characters gone,
/// because part of it is text a guest wrote.
fn run_git(arguments: List(String)) -> Result(String, String) {
  use git <- result.try(
    ffi_os.find_executable("git")
    |> result.map_error(fn(_) { "git is not on PATH" }),
  )

  // Only status zero is success, and the refusal shows Git's own words.
  case bootstrap.run_captured(git, arguments, copy_budget_ms) {
    Ok(bootstrap.Captured(0, output)) -> Ok(output)
    Ok(bootstrap.Captured(status, output)) ->
      Error(
        "git exited with status "
        <> int.to_string(status)
        <> ":\n"
        <> string.trim(vm_spec.printable(output)),
      )
    Error(reason) -> Error("git: " <> reason)
  }
}
