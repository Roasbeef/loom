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
////   workspace, settles the deployment (`deployment`: mint one, `join` the
////   ledger deployment the configuration holds, or refuse a static one),
////   installs the orchestrator of a minted one (`enroll`), stages the guest
////   root (`stage`) and boots it (`boot`).
//// - `ensure` makes the guest of one workspace ready for `loom --vm`: it names
////   the guest after the workspace (`vm_spec.guest_name_for`), reads the
////   facts (`ensure_facts`), lets `vm_spec.ensure_step` decide, and boots
////   through `bring_up`, the same code `up` runs. Its last line of standard
////   output names the executor and workspace, and status 75 with
////   `daemon=required` says only a running daemon is missing (`ensure`).
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
//// following a link (`plain_chain`), write only through `make_inside`, and
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
//// - `deploy/` holds the two provisioned bundles and the public ledger. A
////   second `up` reads the bundles again rather than minting new certificates,
////   so the orchestrator's installed configuration keeps matching the executor
////   it trusts. A guest minted before the membership ledger holds `/1` bundles
////   that list their peers; they are read and installed as they were, and are
////   never converted.
//// - `orch/` holds the orchestrator's installed credentials. A guest that joined
////   its daemon's deployment has none and no orchestrator bundle: the daemon is
////   already a member, and its configuration is not touched.
//// - `root/` is the guest's own clone of the exported guest root, and
////   `state.img` is the disk its executor keeps its ledger and scopes on. A
////   second `up` boots both again, so whatever the guest wrote into its
////   checkout and the sessions its executor holds survive `down`; `--fresh`
////   replaces both. `down` leaves them for the user to read.
//// - `loom-vm.pid` names the process and its birth marker, and `loom-vm.log`
////   holds the guest's console.
////
//// ## The authority key
////
//// `up` mints a deployment in ledger mode (protocol-change/086), so a node can
//// be enrolled into it later without minting everything again. The authority
//// key that signs the ledger is sealed under
//// `<vm home>/authority/<deployment id>/` with `client/authority_key`, beside
//// the authority certificate, the operator's copy of the ledger, the cookie
//// and a `passphrase` file `up` generated (32 bytes from the production
//// entropy source, mode 0600). A standing guest has no terminal, and the file
//// is what a later `loom distribution enroll --passphrase-file` reads.
////
//// That directory is outside every guest root and no bundle that reaches the
//// guest holds the key: the executor's bundle has its own node key and the
//// deployment's cookie. The daemon's jails mask `~/.loom/vm` and the state
//// root's `vm` (`workspace_policy`), so the directory is out of reach of
//// jailed tools under either. A `$LOOM_VM_HOME` elsewhere is not masked, and
//// the key and its passphrase are then readable by any process of the user.
//// `rm` deletes the directory with the guest that minted it, unless another
//// guest's bundle names the same deployment.
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

import broker/token
import client/authority_home
import client/authority_key
import client/daemon/admin
import client/daemon/ledger_cli
import client/distribution
import client/distribution_bundle.{type Bundle}
import client/distribution_install.{Options}
import client/distribution_provision.{RefuseExisting, ReplaceExisting}
import client/install
import client/internal/ffi_os
import client/ledger_operator
import client/membership_ledger
import client/membership_provision
import client/vm_link
import client/vm_link_pki
import client/vm_spec.{
  type Command, type Manifest, type PidRecord, type SyncOptions, type UpOptions,
  Down, Ensure, Guests, Launch, Logs, PidRecord, Remove, Setup, Status, Sync, Up,
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
import gleam/time/timestamp
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
                  [--link distribution|untrusted]
       loom vm ensure [--workspace DIR] [--github gh|env|off] [--allow HOST]...
                      [--config PATH] [--link distribution|untrusted]
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
            was built from this commit. A nightly has them from the first
            nightly that carries the workflow which publishes them; older
            nightlies have none. --release TAG installs only that tag and
            --from-build DIR records a build tree (packages/vmm/build). A
            development build has no release: build the artifacts in a
            checkout and run `make vmm-install-dev`.
  up        Make the guest a member of your daemon's deployment. A loom.toml
            with no deployment gets a two-node ledger deployment, with the
            orchestrator enrolled as [executors.NAME]. A loom.toml that holds a
            ledger deployment gets the guest enrolled in it through the running
            daemon, which derives [executors.NAME] from the ledger with no
            restart and no change to the file. Then clone the guest root, copy
            the workspace into it, boot the guest with `loom-vm run` and wait until
            its executor serves. The guest keeps running after this command
            exits. NAME defaults to vm. DIR defaults to the current directory;
            its copy, .git included, is registered in the guest under the
            directory's own name. Every copy an earlier up recorded stays
            registered, so a stopped guest brought up with another DIR serves
            both (a running guest refuses up). A linked Git worktree is copied too, and its
            copy gets a repository of its own. With no artifacts installed it
            first runs `setup` for this release. --mem is the guest's memory in MiB (default
            2048) and --cpus its virtual CPUs (default 4). --config is the
            loom.toml to enroll in (default ~/.loom/loom.toml).
            A static deployment is refused, and so is a ledger deployment when
            its daemon is not running or its authority key is not on this
            machine. Each guest has its own NAME, so several can run at once.
            A guest that ran before keeps its root, the checkouts in it and its
            state disk, so `down` and `up` resume where it stopped. --fresh
            replaces all three.
            --github chooses where loom-vm reads the token its credential proxy
            injects: gh (the default) runs `gh auth token`, env reads
            LOOM_VM_GITHUB_TOKEN, and off gives the guest no network beyond
            the --allow hosts. The guest holds only a placeholder, never the
            token. The choice is recorded and a later up with no --github
            keeps it; --fresh returns to gh.
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
            --link untrusted reaches the guest over a pinned TLS link that is
            not Erlang distribution, so the guest holds no cookie and its
            takeover reaches no code in your daemon. It mints a private link
            authority under the vm home, writes [executor_link] and
            [executors.NAME] into loom.toml beside whatever is there (it never
            replaces a table that differs, and leaves [distribution] as it is),
            and needs no deployment, ledger or running daemon. A daemon that is
            already running reads the new row only when it restarts. The link
            is recorded and kept for the guest's life; `distribution` is the
            default. The link lacks project hooks, goal checks and the Changes
            tab for now: docs/architecture/microvm.md lists them.
  ensure   Make the guest of one workspace ready, which is what `loom --vm`
            runs. The guest is named after DIR (default: the current
            directory): its last segment and six digits of its path, so every
            workspace has a guest of its own. A guest that already serves is
            left alone and the command ends at once. Otherwise it installs the
            microVM artifacts when they are missing or from another release,
            then boots the guest as up does, resuming one that ran before.
            --github, --allow and --config mean what they mean for up, and a
            resume keeps the access and hosts the guest was started with. A
            guest that already serves ignores --github and --allow, and says
            so. A guest whose root came from another release, or whose
            executor is still booting, is refused with the command to run.
            Progress goes to standard error. The last line of standard output
            is `executor=NAME workspace=NAME`, the words `loom --executor E
            --workspace W` takes. Exit status 75 with the line `daemon=required`
            means the only thing missing is a running daemon, which ensure
            never starts: start one and run it again. It fails, leaving the
            guest up, when a daemon that holds sessions must restart to read the
            deployment this call installed.
  down      Stop the guest. Its root, and the checkout inside it, stay on disk.
  status    Say whether the guest runs, where it is registered and what it
            holds.
  logs      Print the last lines of the guest's console log, loom-vm.log:
            100, or --lines N, and at most the last 4 MiB of them. There is
            no follow mode.
  list      Print one line for each guest under the vm home: its name,
            whether it runs, and its workspaces.
  rm        Delete a stopped guest and undo its enrolment. It removes
            [executors.NAME] from loom.toml (--config PATH, default
            ~/.loom/loom.toml), and the [distribution] table and the home's
            .erlang.cookie only when they are this guest's deployment's and no
            other [executors.*] table remains; otherwise it leaves them and
            says so. A guest that joined a ledger deployment is revoked with
            the key, when it is on this machine, and otherwise rm prints the
            revoke to run. A guest that others joined is removed last. A guest
            on the untrusted link has nothing to revoke: rm removes its
            [executors.NAME] table, and [executor_link] with the vm home's
            link credentials when no other untrusted guest remains. Every other line of loom.toml is kept. A running guest is
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
            It needs a Git with the 2024 upload-pack fix. --to-guest goes the
            other way: it
            bundles your checkout's local branches (not tags, remote-tracking
            refs or the stash) into
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
  // command uses, so a script can tell a refused `up` from a started one. The
  // one other ending is `ensure` finding only a daemon missing: its reason is
  // on standard error, and standard output holds the line a launcher matches.
  case finish(arguments) {
    Printed(text) -> io.println(text)
    Failed(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
    NeedsLaunchedDaemon(reason) -> {
      io.println_error("loomd: " <> reason)
      io.println(vm_spec.daemon_required_line)
      ffi_os.halt(vm_spec.daemon_required_status)
    }
  }
}

/// How a command ended.
type Finish {
  // It ran, and this is what it prints on standard output.
  Printed(String)

  // It refused or failed, for this reason, with status 1.
  Failed(String)

  // `ensure` stopped before writing anything because only a running daemon is
  // missing; the status is `vm_spec.daemon_required_status`.
  NeedsLaunchedDaemon(String)
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
  case finish(arguments) {
    Printed(text) -> Ok(text)
    Failed(reason) | NeedsLaunchedDaemon(reason) -> Error(reason)
  }
}

/// Parses and runs one command, and says how it ended.
fn finish(arguments: List(String)) -> Finish {
  case vm_spec.parse(arguments) {
    Ok(command) -> dispatch(named(command, arguments))
    Error(reason) -> Failed(reason <> "\n\n" <> usage)
  }
}

/// The command with the guest it means. `down`, `status`, `logs`, `rm` and
/// `sync` given no `--name` name the guest `vm`, which a developer with one
/// guest per workspace never made, so they mean this directory's guest when no
/// guest is named `vm` (`vm_spec.default_guest`), and say which on standard
/// error. `up` and the rest keep their default.
fn named(command: Command, arguments: List(String)) -> Command {
  // A command that named its guest is left as it is.
  case list.contains(arguments, "--name") {
    True -> command
    False ->
      case command {
        Down(_) -> Down(default_guest())
        Status(_) -> Status(default_guest())
        Logs(_, lines) -> Logs(default_guest(), lines)
        Remove(_, config, consent) -> Remove(default_guest(), config, consent)
        Sync(options) ->
          Sync(vm_spec.SyncOptions(..options, name: default_guest()))
        Setup(_) | Up(_) | Ensure(_) | Guests -> command
      }
  }
}

/// The guest a command with no `--name` means, found from the vm home and the
/// current directory. A home or directory that cannot be read means `vm`.
fn default_guest() -> String {
  let found = {
    use vm_home <- result.try(vm_home())
    use directory <- result.try(
      bootstrap.absolute_path(".")
      |> result.try(fn(path) { bootstrap.canonical_directory(path) }),
    )
    let workspace_guest = vm_spec.guest_name_for(directory)
    Ok(vm_spec.default_guest(
      presence_of(vm_home <> "/" <> vm_spec.default_name),
      workspace_guest,
      presence_of(vm_home <> "/" <> workspace_guest),
    ))
  }
  let chosen = result.unwrap(found, vm_spec.default_name)

  // Say which guest was chosen when it is not the one the command always meant.
  case chosen == vm_spec.default_name {
    True -> Nil
    False ->
      io.println_error(
        "loom vm: no guest is named vm, so this directory's guest "
        <> chosen
        <> " is meant; `--name` names another.",
      )
  }

  chosen
}

/// Runs the command `finish` parsed, each in its own section below.
fn dispatch(command: Command) -> Finish {
  // The commands share nothing but where a guest's files are.
  case command {
    Ensure(options) ->
      case ensure(options) {
        Ok(line) -> Printed(line)
        Error(Refused(reason)) -> Failed(reason)
        Error(DaemonRequired(reason)) -> NeedsLaunchedDaemon(reason)
      }
    Setup(source) -> ended(setup(source))
    Up(options) -> ended(up(options))
    Down(name) -> ended(down(name))
    Status(name) -> ended(status(name))
    Logs(name, lines) -> ended(logs(name, lines))
    Guests -> ended(guests())
    Remove(name, config, consent) -> ended(remove(name, config, consent))
    Sync(options) -> ended(sync(options))
  }
}

/// The ending of a command that either prints or refuses.
fn ended(outcome: Result(String, String)) -> Finish {
  case outcome {
    Ok(text) -> Printed(text)
    Error(reason) -> Failed(reason)
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
    github_file: String,
    checkouts_file: String,
    root_revision_file: String,
    provision_file: String,
    next_root: String,
    building_root: String,
    kind_file: String,
    port_file: String,
    link_credentials: String,
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
    github_file: directory <> "/" <> vm_spec.github_file,
    checkouts_file: directory <> "/" <> vm_spec.checkouts_file,
    root_revision_file: directory <> "/" <> vm_spec.root_revision_file,
    provision_file: directory <> "/" <> vm_spec.provision_copy_file,
    next_root: directory <> "/" <> vm_spec.next_root_dir,
    building_root: directory <> "/" <> vm_spec.building_root_dir,
    kind_file: directory <> "/" <> vm_link.kind_file,
    port_file: directory <> "/" <> vm_link.port_file,
    link_credentials: directory <> "/" <> vm_link.guest_credentials_dir,
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

/// What `up` and `ensure` should do about the manifest on disk, read once.
fn manifest_decision(
  vm_home: String,
) -> Result(vm_spec.ManifestAction, String) {
  use found <- result.map(read_manifest_if_present(vm_home))
  let identity = build_identity.current()
  vm_spec.manifest_action(
    found,
    identity.version,
    identity.commit,
    manifest_path(vm_home),
  )
}

/// The manifest `up` boots from. With none installed, or one from another
/// release, it installs the running build's release first and says so; a
/// development build has no release, so it keeps the refusals that name the
/// make target.
fn installed_manifest(vm_home: String) -> Result(Manifest, String) {
  use decision <- result.try(manifest_decision(vm_home))
  use_decision(vm_home, decision)
}

/// Carries out a manifest decision: use the manifest, install the release and
/// answer what it wrote, or refuse.
fn use_decision(
  vm_home: String,
  decision: vm_spec.ManifestAction,
) -> Result(Manifest, String) {
  // A usable manifest is used as it is; an installable one is installed and
  // the installation says why first.
  case decision {
    vm_spec.UseManifest(manifest) -> Ok(manifest)
    vm_spec.RefuseManifest(reason) -> Error(reason)
    vm_spec.InstallRelease(why) -> {
      io.println_error(why)
      install_artifacts(vm_home, vm_spec.OwnRelease)
    }
  }
}

// --- up ----------------------------------------------------------------------

// What a finished `up` knows: the options it settled, the workspace copy, the
// host port and how the daemon learns of the guest.
type Upped {
  Upped(
    options: UpOptions,
    workspace: Workspace,
    port: Int,
    enrolled: Enrolled,
    link: vm_spec.LinkKind,
  )
}

/// Boots one guest and tells the user how to use it and what to do about the
/// daemon.
fn up(options: UpOptions) -> Result(String, String) {
  use upped <- result.try(bring_up(options))
  Ok(report(upped, restart_of(upped)))
}

/// Provisions, enrolls, stages and boots one guest. `ensure` calls this too, so
/// the boot path exists once.
fn bring_up(options: UpOptions) -> Result(Upped, String) {
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
  use Nil <- result.try(refuse_stranded(
    guest,
    options.name,
    Some(manifest.runner),
    vm_spec.BlocksUp,
  ))

  // What the root needs is read before anything is written, because the
  // provisioning plan depends on whether the root is replaced.
  use step <- result.try(root_step_of(guest, manifest, options))

  // What the script and the allowlist ask for is settled before anything is
  // written, so a refused `--provision` or a bad allow file changes nothing.
  use plan <- result.try(provisioning(guest, options, step))
  use allow <- result.try(allowed_hosts(guest, options))
  use github <- result.try(github_access(guest, options))
  let options = UpOptions(..options, allow:)

  // A guest on the untrusted link has no deployment to settle, and shares only
  // the checks above and the root, state and boot steps below.
  use kind <- result.try(link_of(guest, options))
  use <- on_link(kind, fn() {
    bring_up_linked(LinkedUp(
      manifest:,
      vm_home:,
      guest:,
      names:,
      workspace:,
      options:,
      github:,
      plan:,
      step:,
    ))
  })

  // The deployment and the enrollment come before the guest root, so a
  // loom.toml that holds another deployment is refused before a root of
  // several hundred megabytes is cloned.
  use #(config, file) <- result.try(config_of(options))
  use deployed <- result.try(deployment(vm_home, guest, names, config, file))
  use enrolled <- result.try(enroll(deployed, config, file))
  use Nil <- result.try(stage(
    manifest,
    guest,
    executor_of(deployed),
    installed_ledger(config),
    workspace,
    options,
    github,
    plan,
    step,
  ))
  use port <- result.try(boot(manifest, guest, names, options, github, plan))
  Ok(Upped(options:, workspace:, port:, enrolled:, link: vm_spec.Distribution))
}

// --- ensure ------------------------------------------------------------------

// How `ensure` failed: a refusal, or the one case a launcher can repair.
type EnsureFailure {
  // The command cannot make the guest ready, for the reason given.
  Refused(String)

  // Only a running daemon is missing, which `up` never starts and a launcher
  // does. Nothing was written.
  DaemonRequired(String)
}

/// Makes the guest that serves one workspace ready and answers the line that
/// names it: `executor=<guest> workspace=<registered name>`.
///
/// The guest's name is derived from the workspace's canonical path, so the same
/// directory finds the same guest on every call. What happens next is decided
/// by `vm_spec.ensure_step` from what the host shows, and each step prints one
/// line on standard error saying which ran, so a developer can see whether a
/// call was the fast path, a setup, or a boot. The boot is `bring_up`, the code
/// `up` runs, so a guest `ensure` starts is one `up` could have started.
fn ensure(options: UpOptions) -> Result(String, EnsureFailure) {
  use vm_home <- result.try(vm_home() |> result.map_error(Refused))
  use workspace <- result.try(
    workspace_of(options) |> result.map_error(Refused),
  )
  let name = vm_spec.guest_name_for(workspace.path)
  use Nil <- result.try(vm_spec.valid_name(name) |> result.map_error(Refused))
  let options = UpOptions(..options, name:, workspace: Some(workspace.path))
  let line = vm_spec.ensure_line(name, workspace.name)
  use facts <- result.try(ensure_facts(vm_home, options))

  // A serving guest is answered without the lock, so the common call costs
  // reads only. Anything else may write, so it takes the guest's lock and
  // decides again once it holds it.
  case vm_spec.ensure_step(facts) {
    vm_spec.AlreadyServing -> serving(vm_home, options, name, line)
    _ ->
      exclusive(vm_home, name, fn() { decided(vm_home, options, name, line) })
  }
}

/// Decides from the facts as they are now, with the guest's lock held, and
/// carries the decision out. A caller that waited for the lock finds the guest
/// already serving when the holder succeeded.
fn decided(
  vm_home: String,
  options: UpOptions,
  name: String,
  line: String,
) -> Result(String, EnsureFailure) {
  use facts <- result.try(ensure_facts(vm_home, options))

  // `ensure_step` is the whole decision; each arm only carries it out and
  // says which step ran.
  case vm_spec.ensure_step(facts) {
    vm_spec.AlreadyServing -> serving(vm_home, options, name, line)
    vm_spec.NeedsDaemon ->
      Error(DaemonRequired(
        "the guest "
        <> name
        <> " would join the ledger deployment of your configuration, which "
        <> "needs its daemon running; `ensure` starts none",
      ))
    vm_spec.Boot -> boot_ensured(options, name, line)
    vm_spec.Refuse(reason) -> Error(Refused(reason))
  }
}

/// The answer for a guest that serves: its root must come from this build, and
/// flags that would change how it started are said to be ignored.
fn serving(
  vm_home: String,
  options: UpOptions,
  name: String,
  line: String,
) -> Result(String, EnsureFailure) {
  let guest = instance(vm_home, name)
  use recorded <- result.try(
    recorded_root_revision(guest) |> result.map_error(Refused),
  )

  // A manifest that cannot be read leaves the `dev` exception unknown, and the
  // comparison then stands on the record and the build alone.
  let manifest = case read_manifest_if_present(vm_home) {
    Ok(Some(manifest)) -> Some(manifest.revision)
    Ok(None) | Error(_) -> None
  }

  use Nil <- result.try(
    vm_spec.serving_release_refusal(
      name,
      recorded,
      build_identity.current().commit,
      manifest,
    )
    |> result.map_error(Refused),
  )

  // The fast path writes nothing, so a flag that would change the guest cannot
  // take effect, and saying so is better than ignoring it silently.
  case options.github, options.allow {
    None, [] -> Nil
    _, _ ->
      progress(
        name,
        "--github and --allow are ignored while the guest serves; stop it with "
          <> "`loom vm down --name "
          <> name
          <> "` and run this again to change them",
      )
  }

  progress(name, "already serving, nothing to do")
  Ok(line)
}

/// Runs `work` with the guest's lock held, so two `ensure` calls for one
/// workspace never stage one root together. The lock is a kernel lock on
/// `<vm home>/<name>.lock` that dies with the process; a caller that finds it
/// busy waits for the holder, up to the longest boot, and then reads the facts
/// again.
fn exclusive(
  vm_home: String,
  name: String,
  work: fn() -> Result(String, EnsureFailure),
) -> Result(String, EnsureFailure) {
  use Nil <- result.try(
    simplifile.create_directory_all(vm_home)
    |> result.map_error(fn(error) {
      Refused(vm_home <> " is unwritable: " <> simplifile.describe_error(error))
    }),
  )
  let path = vm_home <> "/" <> name <> ".lock"
  use lock <- result.try(acquire(path, name))
  let outcome = work()
  bootstrap.release_launch_lock(lock)
  outcome
}

/// Takes the lock at `path`, waiting while another call holds it.
fn acquire(
  path: String,
  name: String,
) -> Result(bootstrap.LaunchLock, EnsureFailure) {
  // The first try is made before saying anything, so an uncontended call is
  // silent.
  case bootstrap.try_launch_lock(path) {
    Ok(lock) -> Ok(lock)
    Error("busy") -> {
      progress(name, "another loom is starting this guest; waiting for it")
      wait_for(path)
    }
    Error(reason) -> Error(Refused(path <> ": " <> reason))
  }
}

/// Polls for the lock at `path` until the holder lets go or the longest boot
/// has passed.
fn wait_for(path: String) -> Result(bootstrap.LaunchLock, EnsureFailure) {
  let waited =
    poll.until(within: vm_spec.provision_budget_ms, every: 250, attempt: fn() {
      case bootstrap.try_launch_lock(path) {
        Ok(lock) -> poll.Done(lock)
        Error("busy") -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })

  // The wait ends with the lock, a reason, or the end of the budget.
  case waited {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error(Refused(path <> ": " <> reason))
    poll.Expired ->
      Error(Refused(
        "another loom still holds " <> path <> " after the boot budget",
      ))
  }
}

/// Boots the guest through `up`'s own path, then refuses when the user's daemon
/// has not read the deployment the guest needs. The guest stays up in that
/// case, so the next `ensure` after the restart is the fast path.
fn boot_ensured(
  options: UpOptions,
  name: String,
  line: String,
) -> Result(String, EnsureFailure) {
  progress(name, "booting the guest")
  use upped <- result.try(bring_up(options) |> result.map_error(Refused))
  progress(name, "the guest serves port " <> int.to_string(upped.port))
  use Nil <- result.try(restart_check(upped) |> result.map_error(Refused))
  Ok(line)
}

/// Whether the user's daemon must restart to read the deployment, answered as
/// the refusal that says so, or Ok when it need not.
///
/// A deployment this call installed can have been missed by a running daemon.
/// So can one an earlier call installed whose boot then failed, which is why a
/// resumed guest asks the daemon whether it runs with distribution at all. A
/// guest that joined a ledger is derived by the daemon and needs nothing. A
/// configuration other than the default belongs to a daemon `ensure` cannot
/// ask, so a daemon that runs after the install is told to restart.
fn restart_check(upped: Upped) -> Result(Nil, String) {
  // An untrusted guest needs the daemon to hold its row and nothing of
  // distribution, so it is asked another question.
  case upped.link {
    vm_spec.Distribution -> distribution_restart_check(upped.enrolled)
    vm_spec.Untrusted -> untrusted_restart_check(upped)
  }
}

/// `restart_check` for a guest on the untrusted link. In the default
/// configuration the daemon is asked which executors it holds, and one that
/// does not hold the guest has not read its row, whether this call wrote the
/// row or an earlier call did and then failed to boot. A configuration other
/// than the default belongs to a daemon that cannot be asked, as for any guest.
fn untrusted_restart_check(upped: Upped) -> Result(Nil, String) {
  let enrolled = upped.enrolled

  // The distribution check's other-configuration arms say nothing of
  // distribution, so they serve here too.
  case enrolled.file {
    OtherConfigFile -> distribution_restart_check(enrolled)
    DefaultConfigFile ->
      case untrusted_need(upped) {
        vm_link.MustRestart -> vm_spec.restart_refusal(daemon_outcome())
        vm_link.NeedsNothing -> Ok(Nil)
      }
  }
}

/// Whether the default daemon must restart to reach an untrusted guest: the
/// decision of `vm_link.daemon_need`, from what the row's state is and what the
/// daemon says it holds. A daemon is asked only about a row that was already
/// there.
fn untrusted_need(upped: Upped) -> vm_link.DaemonNeed {
  let name = upped.options.name

  // A row this call wrote is unread without asking anyone.
  case upped.enrolled.row {
    Resumed -> vm_link.daemon_need(vm_link.RowStanding, daemon_saw(), name)
    Written | Derived ->
      vm_link.daemon_need(vm_link.RowChanged, vm_link.SawNoDaemon, name)
  }
}

/// What the default daemon says it holds: nothing when none runs, the names of
/// its executor rows when its deployment read lists them, and an unanswered
/// question otherwise.
fn daemon_saw() -> vm_link.DaemonSaw {
  // The same observation `daemon_lacks_distribution` makes, read for the
  // executors instead.
  case running_fence() {
    None -> vm_link.SawNoDaemon
    Some(_) ->
      case ask_daemon("deployment.status") {
        Ok(body) ->
          case vm_link.listed_executors(body) {
            Some(names) -> vm_link.SawExecutors(names)
            None -> vm_link.SawUnanswered
          }
        Error(_) -> vm_link.SawUnanswered
      }
  }
}

/// The restart check of a distribution guest, which asks whether the daemon
/// runs with distribution at all.
fn distribution_restart_check(enrolled: Enrolled) -> Result(Nil, String) {
  case enrolled.row, enrolled.file {
    Derived, _ -> Ok(Nil)
    Resumed, OtherConfigFile -> Ok(Nil)
    Resumed, DefaultConfigFile ->
      case daemon_lacks_distribution() {
        True -> vm_spec.restart_refusal(daemon_outcome())
        False -> Ok(Nil)
      }
    Written, DefaultConfigFile -> vm_spec.restart_refusal(daemon_outcome())
    Written, OtherConfigFile ->
      case running_fence() {
        Some(_) -> Error(vm_spec.other_config_refusal(enrolled.config))
        None -> Ok(Nil)
      }
  }
}

/// Whether the running default daemon says it has no distribution, which means
/// it has not read a `[distribution]` table. No daemon, or one that does not
/// answer, is not claimed to lack it.
fn daemon_lacks_distribution() -> Bool {
  case running_fence() {
    None -> False
    Some(_) ->
      case ask_daemon("deployment.status") {
        Ok(body) -> vm_spec.lacks_distribution(body)
        Error(_) -> False
      }
  }
}

/// One progress line on standard error, named for the guest and prefixed so a
/// reader can tell `ensure` from the steps it runs.
fn progress(name: String, text: String) -> Nil {
  io.println_error("loom vm ensure: " <> name <> ": " <> text <> ".")
}

/// Observes what `ensure_step` decides on. The guest's process and epmd
/// registration come first and are all the fast path needs, but the manifest
/// and the daemon are read too: they are small reads, and reading them here
/// keeps the decision a function of facts and not of order.
fn ensure_facts(
  vm_home: String,
  options: UpOptions,
) -> Result(vm_spec.EnsureFacts, EnsureFailure) {
  let name = options.name
  let names = vm_spec.names(name)
  let guest = instance(vm_home, name)
  use state <- result.try(process_state(guest) |> result.map_error(Refused))
  use kind <- result.try(link_of(guest, options) |> result.map_error(Refused))

  // The record's process is read through its birth marker, so a stale record
  // is no process, and the node's epmd registration is read beside it.
  let pid = case state {
    Alive(record) -> Some(record.pid)
    NotRunning -> None
  }

  Ok(vm_spec.EnsureFacts(
    name:,
    state: vm_spec.guest_state(pid, registration_for(guest, names, kind)),
    manifest: manifest_decision(vm_home),
    enrolment: enrolment_for(kind, guest, names, options),
    daemon: daemon_fact(),
  ))
}

/// Whether the guest's executor serves, by the evidence its link leaves: the
/// host's epmd for a distribution guest, and the console's ready line for an
/// untrusted one, which registers no node.
fn registration_for(
  guest: Instance,
  names: vm_spec.Names,
  kind: vm_spec.LinkKind,
) -> vm_spec.Registration {
  case kind {
    vm_spec.Distribution -> registration_of(names, guest)
    vm_spec.Untrusted ->
      case console_ready(guest) {
        True -> vm_spec.Registered
        False -> vm_spec.Unregistered
      }
  }
}

/// Whether bringing the guest up would need the daemon. An untrusted guest
/// joins no deployment, so it never does.
fn enrolment_for(
  kind: vm_spec.LinkKind,
  guest: Instance,
  names: vm_spec.Names,
  options: UpOptions,
) -> vm_spec.EnrolmentNeed {
  case kind {
    vm_spec.Distribution -> enrolment_need(guest, names, options)
    vm_spec.Untrusted -> vm_spec.NeedsNoDaemon
  }
}

/// Whether the guest's executor serves: the host epmd lists its node and its
/// console says the executor is ready. `loom-vm` registers the node right after
/// it starts the guest, long before the executor serves (a provisioning script
/// can take half an hour), so the listing alone would call a booting guest
/// serving. The console is the witness `await_ready` uses, and it is truncated
/// at every launch. An epmd that cannot be run lists nothing, which reads as
/// not registered: a guest that cannot be confirmed is not claimed to serve.
fn registration_of(
  names: vm_spec.Names,
  guest: Instance,
) -> vm_spec.Registration {
  let listing = tool("epmd", ["-names"], within: quick_ms)

  // Only a listing that names the node counts, and then only a ready console.
  case listing {
    Ok(listing) ->
      case
        vm_spec.registered_port(listing, names.executor_short),
        console_ready(guest)
      {
        Some(_), True -> vm_spec.Registered
        _, _ -> vm_spec.Unregistered
      }
    Error(_) -> vm_spec.Unregistered
  }
}

/// Whether the guest's console holds the line that says its executor serves.
fn console_ready(guest: Instance) -> Bool {
  string.contains(
    result.unwrap(simplifile.read(guest.log), ""),
    vm_spec.ready_marker,
  )
}

/// Whether the daemon of the default state directory runs.
fn daemon_fact() -> vm_spec.DaemonFact {
  // The same observation `join` makes before it enrols a guest.
  case running_fence() {
    Some(_) -> vm_spec.DaemonRunning
    None -> vm_spec.DaemonStopped
  }
}

/// Whether bringing this guest up would join an existing ledger deployment.
/// That is the case for a guest with no executor bundle, in the default
/// configuration, when it holds a ledger deployment: `join` needs the daemon.
/// A configuration that cannot be read counts as no join, because `up` reports
/// its own reason for it.
fn enrolment_need(
  guest: Instance,
  names: vm_spec.Names,
  options: UpOptions,
) -> vm_spec.EnrolmentNeed {
  let bundled = bootstrap.path_exists(bundle_file(guest, names.name))

  // A guest with bundles resumes, and a guest without them joins only a ledger
  // deployment in the default file, whose daemon `up` can find.
  case bundled, holds_ledger_deployment(options) {
    False, True -> vm_spec.JoinsLedger
    _, _ -> vm_spec.NeedsNoDaemon
  }
}

/// Whether the default configuration holds a ledger deployment. Any other file,
/// a file that is absent and one that cannot be read or parsed say no: `up`
/// reports its own reason for the last.
fn holds_ledger_deployment(options: UpOptions) -> Bool {
  let state = {
    use #(config, file) <- result.try(config_of(options))
    let text = result.unwrap(simplifile.read(config), "")
    use state <- result.map(
      vm_spec.deployment_state(text) |> result.replace_error("not parsed"),
    )
    #(file, state)
  }

  // Only the default file is the daemon's, so only it can need the daemon.
  case state {
    Ok(#(DefaultConfigFile, vm_spec.LedgerDeployment(..))) -> True
    _ -> False
  }
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

/// The GitHub access this `up` launches the guest with: the flag, or the one an
/// earlier `up` recorded, or the default for `--fresh`. It is read before
/// anything is written, so a damaged record refuses `up` and changes nothing.
fn github_access(
  guest: Instance,
  options: UpOptions,
) -> Result(vm_spec.GitHubAccess, String) {
  // The record is read only when it decides the answer, so a damaged one is
  // replaced by `--github` and ignored by `--fresh`.
  use recorded <- result.try(case options.github, options.freshness {
    None, vm_spec.Resume -> recorded_github(guest)
    _, _ -> Ok(None)
  })

  Ok(vm_spec.effective_github(options.github, recorded, options.freshness))
}

/// The access the guest's github file records, or `None` when it has no file.
fn recorded_github(
  guest: Instance,
) -> Result(option.Option(vm_spec.GitHubAccess), String) {
  case simplifile.read(guest.github_file) {
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(
        guest.github_file
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
    Ok(text) ->
      vm_spec.decode_github(text)
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        guest.github_file
        <> ", "
        <> reason
        <> ". Fix or remove the file, or give --github to replace it."
      })
  }
}

/// Records the access the guest launches with, so `down` and `up` keep it.
fn record_github(
  guest: Instance,
  access: vm_spec.GitHubAccess,
) -> Result(Nil, String) {
  write_private(guest.github_file, vm_spec.encode_github(access))
}

/// What `--provision` and the guest root's history decide. The script must be
/// a file the developer named, and only this flag can name one: the workspace
/// is untrusted input and is never searched for a script.
fn provisioning(
  guest: Instance,
  options: UpOptions,
  step: vm_spec.RootStep,
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

  // The host's own copy of an earlier script. `--fresh` clears it, so it is
  // not offered to a root that `--fresh` replaces.
  let kept = case
    options.freshness,
    bootstrap.path_exists(guest.provision_file)
  {
    vm_spec.Resume, True -> Some(guest.provision_file)
    _, _ -> None
  }

  // A kept root has history to consult. A new root has no marker, whatever
  // the old one had, so it is provisioned again from the host's copy.
  case step {
    vm_spec.KeepRoot ->
      vm_spec.provision_plan(requested, root_provisioning(guest.root), kept)
    vm_spec.CloneRoot ->
      vm_spec.new_root_provision(requested, kept, vm_spec.NeverProvisioned)
    vm_spec.UpgradeRoot(..) ->
      vm_spec.new_root_provision(requested, kept, root_provisioning(guest.root))

    // The old root may be partly deleted by the swap that stopped, so what
    // decides is the host's copy and the new root, which has no marker.
    vm_spec.FinishUpgrade ->
      vm_spec.new_root_provision(
        requested,
        kept,
        root_provisioning(guest.next_root),
      )
  }
}

/// What the guest's existing root says about an earlier provisioning.
fn root_provisioning(root: String) -> vm_spec.RootProvisioning {
  case
    bootstrap.path_exists(root <> vm_spec.provision_marker),
    bootstrap.path_exists(root <> vm_spec.provision_script)
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

/// How `deployment` came by a guest's bundles.
type Deployed {
  /// A deployment this `up` minted, with the orchestrator's bundle to install.
  Minted(orchestrator: Bundle, executor: Bundle)

  /// The bundles an earlier `up` wrote, read again. Reading them again is what
  /// keeps the orchestrator's installed pins matching the executor's
  /// certificate. A guest that joined its daemon's deployment has no
  /// orchestrator bundle, because the daemon is already a member.
  Reused(orchestrator: option.Option(Bundle), executor: Bundle)
}

/// The executor bundle of any of the three.
fn executor_of(deployed: Deployed) -> Bundle {
  case deployed {
    Minted(executor:, ..) | Reused(executor:, ..) -> executor
  }
}

/// The bundles of a guest: read from `deploy/` when an earlier `up` made them,
/// and otherwise decided by which deployment `config` already belongs to
/// (`vm_spec.deployment_state`), before anything is minted or written, so a
/// refused `up` leaves nothing behind. A configuration with no deployment gets
/// one minted for it; one with a ledger deployment gets the guest enrolled in
/// it (`join`); a static one is refused, since no key remains to enrol with.
fn deployment(
  vm_home: String,
  guest: Instance,
  names: vm_spec.Names,
  config: String,
  file: ConfigFile,
) -> Result(Deployed, String) {
  let orchestrator_file = bundle_file(guest, names.orchestrator)
  let executor_file = bundle_file(guest, names.name)

  // A directory with an orchestrator bundle alone was interrupted, and one
  // bundle alone pins nothing, so only a complete pair is reused. An executor
  // bundle alone with a ledger in it is a guest that joined.
  case
    bootstrap.path_exists(orchestrator_file),
    bootstrap.path_exists(executor_file)
  {
    True, True -> {
      use orchestrator <- result.try(read_bundle(
        orchestrator_file,
        names.orchestrator_node,
      ))
      use executor <- result.try(read_bundle(executor_file, names.executor_node))
      Ok(Reused(Some(orchestrator), executor))
    }
    False, True -> {
      use executor <- result.try(read_bundle(executor_file, names.executor_node))

      // A static executor bundle without its orchestrator is a leftover.
      case executor.trust {
        distribution_bundle.SignedLedger(_) -> {
          use Nil <- result.try(refuse_revoked(config, executor))
          Ok(Reused(None, executor))
        }
        distribution_bundle.StaticPeers(_) ->
          begin(vm_home, guest, names, config, file)
      }
    }
    _, _ -> begin(vm_home, guest, names, config, file)
  }
}

/// Refuses to resume a joined guest that the daemon's installed ledger records
/// as revoked, or does not hold at all (`vm_spec.resume_refusal`): it would
/// boot and serve nothing. A configuration with no readable ledger, or one that
/// does not replay against the guest's certificate authority, says nothing and
/// the resume goes on.
fn refuse_revoked(config: String, executor: Bundle) -> Result(Nil, String) {
  // With no installed ledger there is nothing to read the standing from.
  let standing = case installed_ledger(config) {
    Some(text) -> vm_spec.standing(executor.ca, text, executor.name)
    None -> Error(Nil)
  }

  vm_spec.resume_refusal(executor.name, config, standing)
}

/// Decides, for a guest with no bundles, between minting, joining and refusing.
fn begin(
  vm_home: String,
  guest: Instance,
  names: vm_spec.Names,
  config: String,
  file: ConfigFile,
) -> Result(Deployed, String) {
  // A configuration that does not exist yet holds no deployment.
  use text <- result.try(case simplifile.read(config) {
    Ok(text) -> Ok(text)
    Error(simplifile.Enoent) -> Ok("")
    Error(error) ->
      Error(config <> " is unreadable: " <> simplifile.describe_error(error))
  })

  use state <- result.try(
    vm_spec.deployment_state(text)
    |> result.map_error(fn(reason) { config <> ": " <> reason }),
  )

  // The state of the file is the decision: no deployment to belong to, a
  // ledger to be enrolled in, or peers that nothing can be added to.
  case state {
    vm_spec.NoDeployment -> {
      // The cookie conflict is decided before anything is written: a minted
      // cookie never equals a file that exists, and the install refuses to
      // replace it, which would leave bundles and a sealed key behind.
      use home <- result.try(home())
      use Nil <- result.try(vm_spec.mint_check(
        cookie_file(home),
        home <> "/.erlang.cookie",
      ))
      provision(vm_home, guest, names)
      |> result.map(fn(pair) { Minted(pair.0, pair.1) })
    }
    vm_spec.LedgerDeployment(ledger:) ->
      join(vm_home, guest, names, Joining(config:, file:, text:, ledger:))
    vm_spec.StaticDeployment ->
      Error(
        config
        <> " holds a static deployment ([[distribution.peers]]), which kept no "
        <> "authority key, so no guest can be added to it. Re-provision it in "
        <> "ledger mode, or `loom vm rm` the guest that minted it and run "
        <> "`loom vm up` again.",
      )
  }
}

/// Whether the home already has the cookie every Erlang node of the user reads.
fn cookie_file(home: String) -> vm_spec.HomeCookie {
  case bootstrap.path_exists(home <> "/.erlang.cookie") {
    True -> vm_spec.HomeCookieThere
    False -> vm_spec.NoHomeCookie
  }
}

// The configuration a guest joins, as `begin` read it.
type Joining {
  Joining(config: String, file: ConfigFile, text: String, ledger: String)
}

/// Enrols the guest in the ledger deployment the configuration names, through
/// the daemon that runs it, and answers the executor bundle that results. The
/// authority key must be on this machine and the daemon must be running:
/// `up` starts no daemon, and a node adopts ledger entries only from a
/// signature and a chain (protocol-change/086), so there is no other way in.
/// The configuration, the cookie and the daemon are not touched. The entry
/// reaches the daemon over `ledger.append` and the daemon derives the
/// `[executors.<name>]` row from the ledger without a restart.
fn join(
  vm_home: String,
  guest: Instance,
  names: vm_spec.Names,
  joining: Joining,
) -> Result(Deployed, String) {
  // The default file is the one whose daemon `up` can find.
  use Nil <- result.try(case joining.file {
    DefaultConfigFile -> Ok(Nil)
    OtherConfigFile ->
      Error(
        joining.config
        <> " holds a ledger deployment, and only the daemon of the default "
        <> "configuration can be reached to enrol a guest in it. Run "
        <> "`loom vm up` without --config.",
      )
  })

  use daemon <- result.try(
    distribution.parse(joining.text)
    |> result.map_error(fn(reason) { joining.config <> ": " <> reason })
    |> result.try(fn(found) {
      option.to_result(found, joining.config <> " has no [distribution] table")
    }),
  )
  let files = distribution.credential_files(daemon)
  use ca <- result.try(read_text(files.ca))
  use ledger_text <- result.try(read_text(joining.ledger))
  use membership <- result.try(
    vm_spec.orchestrator_membership(
      ca,
      ledger_text,
      distribution.local_node(daemon),
    )
    |> result.map_error(fn(reason) { joining.config <> ": " <> reason }),
  )
  let request = vm_spec.guest_enrollment(names, membership.member)
  use Nil <- result.try(ledger_operator.check_enrollment(request))

  // The key first: its absence is permanent on this machine, and a daemon
  // that is down is not.
  use kept <- result.try(
    sealed_authority(vm_home, membership.deployment, Some(joining.ledger))
    |> result.map_error(fn(_) {
      key_elsewhere(guest, names, membership, request)
    }),
  )

  // A node adopts ledger entries only from a signature and a chain, so the
  // running daemon is the way in; `up` never starts one.
  use Nil <- result.try(case running_fence() {
    Some(_) -> Ok(Nil)
    None ->
      Error(
        "the daemon of "
        <> joining.config
        <> " is not running, and the guest is enrolled through it. Start it "
        <> "with `loom deployment status` (any `loom` command starts it), "
        <> "then run `loom vm up` again. `up` never starts a daemon.",
      )
  })

  use authority <- result.try(
    ledger_cli.unlock_at(kept.0, kept.1)
    |> result.map_error(fn(reason) {
      reason <> ". " <> key_elsewhere(guest, names, membership, request)
    }),
  )

  // Only a guest directory this call made is removed when the enrolment
  // fails, so a refusal leaves nothing behind.
  let existed = is_plain_directory(guest.directory)
  let path = bundle_file(guest, names.name)
  use Nil <- result.try(bootstrap.ensure_private_directory(guest.directory))
  let signed =
    ledger_cli.enroll_member(
      authority,
      request,
      admin.ThisHost(""),
      ledger_cli.socket_connect(),
      path,
    )

  // A failure before anything was signed leaves nothing, and the directory is
  // removed only when this call made it. Once the entry is signed the bundle
  // holds the only copy of the node's key, so it stays whatever the daemon
  // did, as `loom distribution enroll` leaves it.
  case signed, existed {
    Ok(signed), _ -> {
      // A daemon that did not take the entry fails the join, and the bundle
      // stays: it holds the only copy of the node's key.
      use Nil <- result.try(vm_spec.undelivered_refusal(
        ledger_cli.delivered(signed),
        path,
        names.name,
      ))

      read_bundle(path, names.executor_node)
      |> result.map(fn(executor) { Reused(None, executor) })
    }
    Error(reason), True -> Error(reason)
    Error(reason), False ->
      case remove_tree_if_present(guest.directory) {
        Ok(Nil) -> Error(reason)
        Error(more) -> Error(reason <> "; " <> more)
      }
  }
}

/// Where the sealed key of a deployment is on this machine and the passphrase
/// file to open it with, when there is one. The key `up` sealed for a
/// deployment it minted has its passphrase beside it. A key the operator kept
/// with `loom distribution provision` is under the home's `.loom/authority`, or
/// in the home recorded beside the installed ledger (`authority_home`), and its
/// passphrase is asked for on the terminal.
fn sealed_authority(
  vm_home: String,
  deployment: String,
  ledger: option.Option(String),
) -> Result(#(String, option.Option(String)), String) {
  let ours = vm_spec.authority_directory(vm_home, deployment)
  let passphrase = ours <> "/" <> vm_spec.passphrase_file

  // Without a ledger path there is no home recorded beside it to consult.
  let hinted =
    option.to_result(ledger, Nil)
    |> result.try(fn(path) {
      authority_home.hinted_home(filepath.directory_name(path))
    })
    |> result.map(authority_key.default_directory(_, deployment))
  let homed =
    home()
    |> result.map(authority_key.default_directory(_, deployment))

  // The key sealed under the vm home is the first choice, then the others.
  case authority_key.is_kept(ours), homed, hinted {
    True, _, _ -> Ok(#(ours, Some(passphrase)))
    _, Ok(directory), _ ->
      case authority_key.is_kept(directory) {
        True -> Ok(#(directory, None))
        False -> hinted_key(hinted)
      }
    _, _, _ -> hinted_key(hinted)
  }
}

/// The ledger file a configuration names, when it holds a ledger deployment and
/// can be read. Anything else is `None`: the caller falls back to what it has.
fn config_ledger(config: String) -> option.Option(String) {
  simplifile.read(config)
  |> result.replace_error(Nil)
  |> result.try(fn(text) {
    vm_spec.deployment_state(text) |> result.replace_error(Nil)
  })
  |> result.try(fn(state) {
    case state {
      vm_spec.LedgerDeployment(ledger:) -> Ok(ledger)
      vm_spec.NoDeployment | vm_spec.StaticDeployment -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The text of the ledger the daemon of `config` has installed, when there is
/// one and it can be read.
fn installed_ledger(config: String) -> option.Option(String) {
  config_ledger(config)
  |> option.then(fn(path) { simplifile.read(path) |> option.from_result })
}

/// The key in the home recorded beside the ledger, if it is really there. The
/// recorded home is only a hint, so the key must be in the directory it names.
fn hinted_key(
  hinted: Result(String, Nil),
) -> Result(#(String, option.Option(String)), String) {
  case hinted {
    Ok(directory) ->
      case authority_key.is_kept(directory) {
        True -> Ok(#(directory, None))
        False -> Error("no authority key is kept in " <> directory)
      }
    Error(Nil) -> Error("no authority key is kept")
  }
}

/// The refusal for a deployment whose key is not on this machine: the
/// deployment, and the command for the operator who holds the key.
fn key_elsewhere(
  guest: Instance,
  names: vm_spec.Names,
  membership: vm_spec.Membership,
  request: ledger_operator.Enrollment,
) -> String {
  "the authority key of deployment "
  <> membership.deployment
  <> " cannot be opened on this machine, so `loom vm up` cannot enrol "
  <> names.name
  <> " in it. The operator who holds the key runs:\n  loom distribution "
  <> "enroll "
  <> names.name
  <> " --role executor --node "
  <> request.node
  <> " --host 127.0.0.1 --port "
  <> int.to_string(vm_spec.guest_port)
  <> " --links "
  <> membership.member
  <> " --out DIR\nand the bundle DIR/"
  <> names.name
  <> distribution_provision.bundle_extension
  <> " is copied to "
  <> guest.deploy
  <> "/, after which `loom vm up --name "
  <> names.name
  <> "` resumes the guest from it."
}

/// Reads a file of the daemon's credentials, naming it when it cannot be read.
fn read_text(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(error) {
    path <> " is unreadable: " <> simplifile.describe_error(error)
  })
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

/// Mints the authority, the certificates, the cookie and a signed membership
/// ledger in this process (protocol-change/086), seals the authority key under
/// the vm home, and writes the bundles into `deploy/`. The ledger mode is what
/// lets a later node be enrolled without minting the deployment again. The
/// guest's executor bundle holds its own node key and the deployment's cookie,
/// and never the authority's key, which `provision_ledger` hands back
/// separately and which only `seal_authority` writes.
fn provision(
  vm_home: String,
  guest: Instance,
  names: vm_spec.Names,
) -> Result(#(Bundle, Bundle), String) {
  use plan <- result.try(vm_spec.deployment_plan(
    names,
    guest.orchestrator_credentials,
  ))
  use made <- result.try(distribution_provision.provision_ledger(
    plan,
    timestamp.system_time(),
  ))
  let authority =
    vm_spec.authority_directory(vm_home, made.authority.deployment)

  // The key is sealed before any bundle is written: bundles whose ledger can
  // never be extended are worse than a sealed key with no bundles. A failure
  // after that takes the directory with it, since its id exists nowhere else.
  use Nil <- result.try(
    seal_authority(authority, made)
    |> or_unseal(authority),
  )
  use bundles <- result.try(
    write_bundles(guest, made.deployment, names)
    |> or_unseal(authority),
  )
  Ok(bundles)
}

/// Seals the authority key of a ledger deployment under a passphrase `up`
/// generates, and keeps the certificate, the operator's copy of the ledger and
/// the cookie beside it, as `loom distribution provision` does. The passphrase
/// is 32 bytes from the production entropy source, written to a file of its own
/// (mode 0600, created atomically) in the same directory, because a standing
/// guest has no terminal to ask on and the later `enroll` and `revoke` of the
/// join read it with `--passphrase-file`. The directory is under the vm home,
/// which the daemon's jails mask (`workspace_policy`), and never under a guest
/// root.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.seal_authority("/h/vm/authority/3f9c", made)
/// ```
@internal
pub fn seal_authority(
  directory: String,
  made: distribution_provision.Provisioned,
) -> Result(Nil, String) {
  let text = bit_array.base64_url_encode(token.production_entropy()(32), False)
  use passphrase <- result.try(
    authority_key.passphrase(text)
    |> result.map_error(authority_key.describe),
  )
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  use Nil <- result.try(write_private(
    directory <> "/" <> vm_spec.passphrase_file,
    text <> "\n",
  ))
  let authority = made.authority
  authority_key.keep(
    directory,
    authority_key.Kept(
      deployment: authority.deployment,
      key: authority.key,
      certificate: authority.certificate,
      ledger: made.ledger,
      cookie: authority.cookie,
    ),
    passphrase,
  )
  |> result.replace(Nil)
  |> result.map_error(authority_key.describe)
}

/// Passes a success through, and removes the authority directory a failed
/// provisioning created so that no sealed key outlives the bundles it was for.
fn or_unseal(
  outcome: Result(a, String),
  authority: String,
) -> Result(a, String) {
  case outcome {
    Ok(_) -> outcome
    Error(reason) ->
      case remove_tree_if_present(authority) {
        Ok(Nil) -> Error(reason)
        Error(more) -> Error(reason <> "; " <> more)
      }
  }
}

/// Writes the bundles and the public ledger into `deploy/` and returns the
/// orchestrator's and the executor's.
fn write_bundles(
  guest: Instance,
  minted: distribution_provision.Deployment,
  names: vm_spec.Names,
) -> Result(#(Bundle, Bundle), String) {
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

// What `up` did to the user's configuration, and so what the report says.
type Enrolled {
  Enrolled(config: String, file: ConfigFile, row: Row)
}

// Whether the guest's `[executors.<name>]` row is in the file or derived.
type Row {
  // The orchestrator's bundle wrote it, and a daemon reads it at start.
  Written

  // An earlier `up` wrote it and this one found it still there. A daemon that
  // started since has read it; `ensure` therefore never asks such a daemon to
  // restart, though `up` still reports on it as it always did.
  Resumed

  // The ledger gives the daemon the row when the guest is a member, and the
  // file was not touched.
  Derived
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

/// The configuration `up` enrols in, as an absolute path, and whose it is.
fn config_of(options: UpOptions) -> Result(#(String, ConfigFile), String) {
  use home <- result.try(home())
  let config =
    option.lazy_unwrap(options.config, fn() {
      distribution_install.default_config(home)
    })
  use config <- result.try(bootstrap.absolute_path(config))
  use default <- result.try(
    bootstrap.absolute_path(distribution_install.default_config(home)),
  )
  Ok(#(config, config_file(config, default)))
}

/// Installs a newly minted orchestrator bundle into the user's `loom.toml` the
/// way `loom distribution install` does, and refuses what it would replace.
/// A guest that joined, or resumes from a bundle with no orchestrator, changes
/// nothing: the ledger is what gives the daemon its row.
fn enroll(
  deployed: Deployed,
  config: String,
  file: ConfigFile,
) -> Result(Enrolled, String) {
  use home <- result.try(home())

  // A resumed guest's deployment is already installed. Installing it again
  // compares the whole [distribution] table, so a key the user added since,
  // such as `listen_address`, would refuse the resume; the executor row is
  // what has to still be there.
  case deployed {
    Reused(orchestrator: Some(orchestrator), ..) ->
      kept_enrolment(orchestrator, config, home, file)
    Minted(orchestrator:, ..) -> install(orchestrator, config, home, file)
    Reused(orchestrator: None, ..) -> Ok(Enrolled(config:, file:, row: Derived))
  }
}

/// What a guest with orchestrator bundles owes the configuration. When the
/// file holds a deployment, an earlier `up` installed it and only the row is
/// checked. When it holds none, an earlier `up` minted the bundles and its
/// install was refused, so they are installed now (`vm_spec.kept_step`).
fn kept_enrolment(
  orchestrator: Bundle,
  config: String,
  home: String,
  file: ConfigFile,
) -> Result(Enrolled, String) {
  // A configuration that does not exist yet holds no deployment.
  let text = result.unwrap(simplifile.read(config), "")

  // The install is `RefuseExisting`, so a table or cookie that conflicts is
  // refused here exactly as it was the first time.
  case vm_spec.kept_step(vm_spec.deployment_state(text)) {
    vm_spec.InstallKept -> install(orchestrator, config, home, file)
    vm_spec.CheckKeptRow -> still_enrolled(orchestrator, config, file)
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
    True -> Ok(Enrolled(config:, file:, row: Resumed))
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
      <> "] table or a cookie that differs from the deployment's. If a guest "
      <> "made the conflicting one, `loom vm rm --name NAME` removes it. "
      <> "Otherwise remove the table from "
      <> config
      <> " or give `--config` another file. The cookie, "
      <> home
      <> "/.erlang.cookie, is read by every Erlang node of yours: move it "
      <> "aside only if none relies on it."
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
  Ok(Enrolled(config:, file:, row: Written))
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

// --- the untrusted link ------------------------------------------------------

// What `bring_up_linked` takes from `bring_up`: the checks `bring_up` made and
// the plans it computed, which a guest of either link shares.
type LinkedUp {
  LinkedUp(
    manifest: Manifest,
    vm_home: String,
    guest: Instance,
    names: vm_spec.Names,
    workspace: Workspace,
    options: UpOptions,
    github: vm_spec.GitHubAccess,
    plan: vm_spec.ProvisionPlan,
    step: vm_spec.RootStep,
  )
}

/// The link this command gives the guest: the one its `link` record says, one
/// that bundles imply, or the one `--link` asks for when the guest is new
/// (`vm_link.settle`). A guest never changes its link, so a mismatch refuses
/// before anything is written.
fn link_of(
  guest: Instance,
  options: UpOptions,
) -> Result(vm_spec.LinkKind, String) {
  use record <- result.try(read_record(guest.kind_file))
  vm_link.settle(options.name, record, traces_of(guest), options.link)
}

/// What a first `up` left in the guest's directory before it recorded a link:
/// the leaf an untrusted `up` mints, or the bundles a distribution `up` writes.
fn traces_of(guest: Instance) -> vm_link.Traces {
  let leaf = is_plain_directory(guest.link_credentials)
  let bundles = is_plain_directory(guest.deploy)

  // The leaf is looked for first: it is minted before anything else of an
  // untrusted guest exists, so it names the link of a run that stopped early.
  case leaf, bundles {
    True, _ -> vm_link.LeafTrace
    False, True -> vm_link.DeployTrace
    False, False -> vm_link.NoTraces
  }
}

/// The link a guest was made with, for the commands that only read it. A guest
/// with no record and no trace of a first run is a distribution guest.
fn recorded_kind(guest: Instance) -> Result(vm_spec.LinkKind, String) {
  use record <- result.try(read_record(guest.kind_file))
  vm_link.settle("", record, traces_of(guest), None)
}

/// The text of a record file the host wrote, or none when it is absent.
fn read_record(path: String) -> Result(option.Option(String), String) {
  case simplifile.read(path) {
    Ok(text) -> Ok(Some(text))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
  }
}

/// Runs the untrusted guest's `up`, or the distribution guest's, which is the
/// rest of `bring_up`.
fn on_link(
  kind: vm_spec.LinkKind,
  untrusted: fn() -> Result(Upped, String),
  distribution: fn() -> Result(Upped, String),
) -> Result(Upped, String) {
  case kind {
    vm_spec.Untrusted -> untrusted()
    vm_spec.Distribution -> distribution()
  }
}

/// `up` for a guest reached over the untrusted link: it mints the link's
/// credentials, settles the guest's port, enrols the guest in the host's
/// `loom.toml`, stages a root with a listener and no cookie, and boots it with
/// the port forwarded and no epmd registration. It needs no deployment, ledger,
/// authority key or running daemon.
fn bring_up_linked(linked: LinkedUp) -> Result(Upped, String) {
  let LinkedUp(
    manifest:,
    vm_home:,
    guest:,
    names:,
    workspace:,
    options:,
    github:,
    plan:,
    step:,
  ) = linked
  use #(config, file) <- result.try(config_of(options))

  // The credentials are shared by every guest of the vm home and the file is
  // read, merged and written back, so the whole of it is done by one `up` at a
  // time: two first runs would otherwise share one `link.minting` directory,
  // and two enrolments could each write the file without the other's row.
  use #(home, leaf, chosen, enrolled) <- result.try(
    with_link_lock(vm_home, fn() {
      enroll_linked(vm_home, guest, options, #(config, file))
    }),
  )
  let port = port_number(chosen)

  // The root, the allowlist, the copy and the boot are the distribution
  // guest's, with the node written differently and the port forwarded.
  use Nil <- result.try(stage_with(
    manifest,
    guest,
    stage_linked_node(guest, home, leaf, _, github, options.allow),
    workspace,
    options,
    github,
    plan,
    step,
  ))
  use Nil <- result.try(
    launch_guest(
      manifest,
      guest,
      names,
      options,
      github,
      plan,
      port,
      vm_spec.Forward,
    )
    |> result.map_error(fn(reason) {
      reason
      <> "\nIf another program holds port "
      <> int.to_string(port)
      <> " (the check for that needs `nc`), delete "
      <> guest.port_file
      <> " so the next `loom vm up` reserves another."
    }),
  )
  Ok(Upped(options:, workspace:, port:, enrolled:, link: vm_spec.Untrusted))
}

/// The part of `up` for an untrusted guest that touches what other guests
/// share, run under `with_link_lock`: the credentials, the guest's port and the
/// user's `loom.toml`. It answers what the staging and the boot need.
fn enroll_linked(
  vm_home: String,
  guest: Instance,
  options: UpOptions,
  target: #(String, ConfigFile),
) -> Result(#(vm_link_pki.Home, vm_link_pki.Leaf, Chosen, Enrolled), String) {
  let #(config, file) = target

  // The credential directories appear whole or not at all, so nothing below
  // reads half of them, and a leaf made under an authority that was since
  // replaced is refused.
  use home <- result.try(vm_link_pki.ensure_home(vm_home))
  use leaf <- result.try(vm_link_pki.ensure_leaf(home, guest.directory))

  // The port is chosen and the merge is worked out before anything about the
  // guest is recorded, so an `up` that the user's file refuses leaves no guest
  // behind, only credentials nothing trusts yet.
  use chosen <- result.try(chosen_port(guest))
  let port = port_number(chosen)
  use merged <- result.try(plan_link(home, leaf, options.name, port, config))

  // The link is recorded before the row is written, so an interrupted `up`
  // leaves a guest that `rm` can remove and that a retry resumes as untrusted.
  use Nil <- result.try(record_link(guest))
  use Nil <- result.try(record_port(guest, chosen))
  use enrolled <- result.try(enroll_link(merged, config, file))
  Ok(#(home, leaf, chosen, enrolled))
}

/// Runs `work` with the vm home's link lock held. The lock is a kernel lock on
/// `<vm home>/link.lock` that dies with the process, taken after any guest's
/// own lock and never the other way, so two callers cannot wait on each other.
/// A caller that finds it busy waits for the holder.
fn with_link_lock(
  vm_home: String,
  work: fn() -> Result(a, String),
) -> Result(a, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(vm_home)
    |> result.map_error(fn(error) {
      vm_home <> " is unwritable: " <> simplifile.describe_error(error)
    }),
  )
  let path = vm_home <> "/link.lock"

  // The first try is made before saying anything, so an uncontended call is
  // silent.
  use lock <- result.try(case bootstrap.try_launch_lock(path) {
    Ok(lock) -> Ok(lock)
    Error("busy") -> {
      io.println_error(
        "loom vm: another loom is changing the link credentials or loom.toml; "
        <> "waiting for it.",
      )
      wait_for(path) |> result.map_error(fn(failure) { ensure_reason(failure) })
    }
    Error(reason) -> Error(path <> ": " <> reason)
  })

  let outcome = work()
  bootstrap.release_launch_lock(lock)
  outcome
}

/// The words of an `ensure` failure, for a caller that reports a plain string.
fn ensure_reason(failure: EnsureFailure) -> String {
  case failure {
    Refused(reason) | DaemonRequired(reason) -> reason
  }
}

/// Records that the guest is reached over the untrusted link.
fn record_link(guest: Instance) -> Result(Nil, String) {
  write_private(guest.kind_file, vm_link.encode_kind(vm_spec.Untrusted))
}

// The port the guest's row names, and whether it is the one already recorded.
type Chosen {
  // The recorded port, which nothing else listens on.
  KeptPort(Int)

  // A newly reserved port, which `record_port` writes down.
  NewPort(Int)
}

/// The number of the chosen port.
fn port_number(chosen: Chosen) -> Int {
  case chosen {
    KeptPort(port) | NewPort(port) -> port
  }
}

/// Writes down a newly chosen port, and nothing for the recorded one.
fn record_port(guest: Instance, chosen: Chosen) -> Result(Nil, String) {
  case chosen {
    KeptPort(_) -> Ok(Nil)
    NewPort(port) -> write_private(guest.port_file, vm_link.encode_port(port))
  }
}

/// The port the guest's `link-port` record holds. A record that is missing or
/// cannot be read is the same as none, and the port is then replaced.
fn recorded_port(guest: Instance) -> option.Option(Int) {
  case read_record(guest.port_file) {
    Ok(Some(text)) -> option.from_result(vm_link.decode_port(text))
    Ok(None) | Error(_) -> None
  }
}

/// The host loopback port the guest's row names: the one recorded for the
/// guest while nothing else listens on it, and otherwise a newly reserved one.
/// Every boot of a guest then names the same address, so a daemon that read the
/// row at its start still reaches the guest. Nothing is written here, because
/// the port belongs to the guest only once the user's file has taken its row.
fn chosen_port(guest: Instance) -> Result(Chosen, String) {
  let recorded = recorded_port(guest)

  // Only a recorded port is probed, since a new one is free by construction.
  let seen = case recorded {
    Some(port) -> vm_link.Recorded(port, availability_of(port))
    None -> vm_link.NotRecorded
  }

  // The decision keeps a free recorded port and replaces any other.
  case vm_link.port_step(seen) {
    vm_link.Keep(port) -> Ok(KeptPort(port))
    vm_link.Reserve -> bootstrap.reserve_loopback_port() |> result.map(NewPort)
  }
}

/// Whether something listens on a host loopback port: `nc -z` exits zero only
/// when it connects. A host with no `nc` reads as free, and then the launcher's
/// own failure to bind the forward is the account of a taken port.
fn availability_of(port: Int) -> vm_link.Availability {
  let probe =
    tool(
      "nc",
      ["-z", "-w", "1", "127.0.0.1", int.to_string(port)],
      within: quick_ms,
    )

  // A connection means a listener; a refusal, a timeout or a missing `nc`
  // means none was found.
  case probe {
    Ok(_) -> vm_link.InUse
    Error(_) -> vm_link.Free
  }
}

/// The text of a configuration file. A file that does not exist is an empty
/// one; any other failure to read it is the user's to see.
fn read_or_empty(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(text) -> Ok(text)
    Error(simplifile.Enoent) -> Ok("")
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
  }
}

/// Works out what `[executor_link]` and the guest's row add to the user's
/// `loom.toml` beside whatever it holds, and refuses a table of the same name
/// that differs (`vm_link.install`). Nothing is written, so a refusal leaves
/// the file and the guest as they were.
fn plan_link(
  home: vm_link_pki.Home,
  leaf: vm_link_pki.Leaf,
  name: String,
  port: Int,
  config: String,
) -> Result(vm_link.Merged, String) {
  use text <- result.try(read_or_empty(config))
  vm_link.install(
    text,
    home.files,
    vm_link.Row(name:, port:, pin: leaf.pin),
    config,
  )
}

/// Writes the merged text to the user's `loom.toml`. A file that already is as
/// wanted is not written, so a resume leaves it alone, and the row is
/// `Resumed`, which asks no daemon to restart.
fn enroll_link(
  merged: vm_link.Merged,
  config: String,
  file: ConfigFile,
) -> Result(Enrolled, String) {
  // Only a change is written, and the write is the file's one rename.
  case merged.change {
    vm_link.Unchanged -> Ok(Enrolled(config:, file:, row: Resumed))
    vm_link.Added | vm_link.Moved -> {
      use Nil <- result.try(
        simplifile.create_directory_all(filepath.directory_name(config))
        |> result.map_error(fn(error) {
          config <> " cannot be made: " <> simplifile.describe_error(error)
        }),
      )
      use Nil <- result.try(write_private(config, merged.text))
      Ok(Enrolled(config:, file:, row: Written))
    }
  }
}

/// Writes the executor's node into the guest root: the authority's
/// certificate, the guest's leaf and key, and a configuration with a listener.
/// The node's home directory is empty, and there is no cookie anywhere, so the
/// key is the one secret the guest holds
/// (`vm_link.staging`).
fn stage_linked_node(
  guest: Instance,
  home: vm_link_pki.Home,
  leaf: vm_link_pki.Leaf,
  workspaces: List(String),
  github: vm_spec.GitHubAccess,
  allow: List(String),
) -> Result(Nil, String) {
  use ca <- result.try(read_text(home.files.ca))
  let config =
    vm_link.guest_config(
      vm_spec.guest_files(),
      home.pin,
      workspaces,
      github,
      allow,
    )
  let staged =
    vm_link.staging(
      vm_spec.guest_files(),
      ca,
      leaf.certificate,
      leaf.key,
      config,
    )
  use Nil <- result.try(
    list.try_each(["/home", "/creds", "/state"], fn(directory) {
      make_inside(guest.root, vm_spec.node_dir <> directory)
    }),
  )
  list.try_each(staged, fn(file) {
    write_private(guest.root <> file.path, file.contents)
  })
}

/// What `up` tells the user about a guest on the untrusted link. The daemon
/// has no reload command yet, so a row that changed reaches it at its next
/// start.
fn linked_report(upped: Upped, restart: Restart) -> String {
  let Upped(options:, workspace:, port:, enrolled:, ..) = upped
  let name = options.name
  string.join(
    list.flatten([
      [
        "The guest "
          <> name
          <> " serves its executor over the untrusted link at "
          <> vm_link.address(port)
          <> ".",
        linked_line(name, enrolled),
        "",
        "Use it with:",
        "  loom --executor " <> name <> " --workspace " <> workspace.name,
        "",
      ],
      linked_daemon_lines(name, restart),
      ["Stop it with: loom vm down --name " <> name],
    ]),
    "\n",
  )
}

/// The line that says what `up` did to the user's configuration.
fn linked_line(name: String, enrolled: Enrolled) -> String {
  case enrolled.row {
    Written | Derived ->
      "Wrote [executor_link] and [executors."
      <> name
      <> "] in "
      <> enrolled.config
      <> ", beside what it held."
    Resumed ->
      "[executors."
      <> name
      <> "] in "
      <> enrolled.config
      <> " is already as this guest needs it."
  }
}

/// The lines about the daemon, after `up` did what it does about one that
/// started before the row existed.
fn linked_daemon_lines(name: String, restart: Restart) -> List(String) {
  case restart {
    NoRestart -> []
    Daemon(outcome) -> vm_link.daemon_lines(name, outcome)
    OtherDaemon -> [
      "A daemon already running with that file must restart to reach the guest.",
      "",
    ]
  }
}

/// What `up` does about the user's daemon after a guest: nothing for an
/// untrusted guest whose row was already there, and otherwise what a newly
/// installed deployment asks, which is the one decision to stop an idle daemon
/// and leave a busy one running.
fn restart_of(upped: Upped) -> Restart {
  // The default daemon is asked about an untrusted guest's standing row; a
  // configuration other than the default has a daemon `up` cannot ask.
  case upped.link, upped.enrolled.file, upped.enrolled.row {
    vm_spec.Untrusted, DefaultConfigFile, _ ->
      case untrusted_need(upped) {
        vm_link.MustRestart -> Daemon(daemon_outcome())
        vm_link.NeedsNothing -> NoRestart
      }
    vm_spec.Untrusted, OtherConfigFile, Resumed -> NoRestart
    _, _, _ -> restart_after(upped.enrolled)
  }
}

/// The report for a distribution guest is `report`'s own; an untrusted guest's
/// is `linked_report`.
fn on_untrusted_report(
  upped: Upped,
  restart: Restart,
  distribution: fn() -> String,
) -> String {
  case upped.link {
    vm_spec.Untrusted -> linked_report(upped, restart)
    vm_spec.Distribution -> distribution()
  }
}

/// The `status` lines about how the guest is reached: the node and the host's
/// epmd entry for a distribution guest, and the link, its address and the
/// guest's pin for an untrusted one.
fn link_lines(
  guest: Instance,
  names: vm_spec.Names,
  kind: vm_spec.LinkKind,
) -> List(String) {
  // The two links leave different evidence: a node in the host's epmd, or a
  // port and a pin recorded beside the guest.
  case kind {
    vm_spec.Distribution -> [
      "node:       " <> names.executor_node,
      "epmd:       " <> epmd_line(names),
    ]
    vm_spec.Untrusted -> {
      let port = recorded_port(guest)
      let pin =
        read_text(guest.link_credentials <> "/executor.pem")
        |> result.try(vm_link.pin_of)
        |> option.from_result
      vm_link.status_lines(port, pin)
    }
  }
}

// --- the guest root ----------------------------------------------------------

/// Gives the guest its own root, its executor node and its copy of the
/// workspace.
fn stage(
  manifest: Manifest,
  guest: Instance,
  executor: Bundle,
  installed: option.Option(String),
  workspace: Workspace,
  options: UpOptions,
  github: vm_spec.GitHubAccess,
  plan: vm_spec.ProvisionPlan,
  step: vm_spec.RootStep,
) -> Result(Nil, String) {
  stage_with(
    manifest,
    guest,
    fn(registered) {
      stage_node(
        guest.root,
        executor,
        installed,
        registered,
        github,
        options.allow,
      )
    },
    workspace,
    options,
    github,
    plan,
    step,
  )
}

/// Everything `stage` does, with the writing of the executor's node left to
/// `write_node`, which is given the workspaces the configuration registers. A
/// distribution guest writes its bundle, cookie and ledger; an untrusted one
/// writes its listener and a key, and neither differs in how the root, the
/// allowlist, the script or the workspace copy are made.
fn stage_with(
  manifest: Manifest,
  guest: Instance,
  write_node: fn(List(String)) -> Result(Nil, String),
  workspace: Workspace,
  options: UpOptions,
  github: vm_spec.GitHubAccess,
  plan: vm_spec.ProvisionPlan,
  step: vm_spec.RootStep,
) -> Result(Nil, String) {
  use uname <- result.try(tool("uname", ["-s"], within: quick_ms))
  use platform <- result.try(vm_spec.platform_of(uname))
  use Nil <- result.try(record_provision_copy(guest, options))
  use Nil <- result.try(prepare_root(manifest, guest, platform, options, step))
  use Nil <- result.try(record_allow(guest, options.allow))
  use Nil <- result.try(record_github(guest, github))
  use Nil <- result.try(write_node(registered_workspaces(guest, workspace)))
  use Nil <- result.try(stage_script(guest.root, plan))

  // The revision is recorded last among the root's contents. A record says the
  // root is complete, and a stop before it makes the next `up` build or
  // provision again, which repeats harmlessly, where a record written first
  // would make the next `up` keep a root that never got its script.
  use Nil <- result.try(case step {
    vm_spec.KeepRoot -> Ok(Nil)
    vm_spec.CloneRoot | vm_spec.UpgradeRoot(..) | vm_spec.FinishUpgrade ->
      record_root_revision(guest, manifest)
  })

  use copy <- result.try(copy_workspace(guest.root, workspace, platform))
  record_checkout(guest, workspace, copy)
}

/// The workspaces the guest's configuration registers: this `up`'s, and every
/// one the host's own `checkouts` record names whose copy is in the root, so an
/// earlier `up`'s copy still resolves. The names come from the record, which the
/// host wrote, and never from a listing of the root, which the guest wrote. A
/// guest with no usable record registers the current copy alone.
fn registered_workspaces(
  guest: Instance,
  workspace: Workspace,
) -> List(String) {
  let recorded =
    result.unwrap(read_checkouts(guest), [])
    |> list.map(fn(entry) { entry.0 })
    |> list.filter(fn(name) {
      bootstrap.path_exists(guest.root <> vm_spec.workspaces_dir <> "/" <> name)
    })

  vm_spec.registered_workspaces(recorded, workspace.name)
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
/// one, clones the export and leaves `loom-vm` to create a new disk. A kept
/// root cloned from other artifacts than the manifest names is upgraded in
/// place and keeps the disk.
fn prepare_root(
  manifest: Manifest,
  guest: Instance,
  platform: vm_spec.Platform,
  options: UpOptions,
  step: vm_spec.RootStep,
) -> Result(Nil, String) {
  case step {
    vm_spec.KeepRoot -> Ok(Nil)

    // `--fresh` discards the state disk as well as the root, since the disk
    // holds the guest's writes against that root. A root that is missing, or
    // a link an older `up` left pointing at the shared export, is replaced
    // too; the disk of a guest that never ran does not exist.
    vm_spec.CloneRoot -> {
      // Only `--fresh` discards the disk; a resume's missing root has none
      // to discard, or keeps the one it has.
      use Nil <- result.try(case options.freshness {
        vm_spec.Fresh -> remove_state_disk(guest)
        vm_spec.Resume -> Ok(Nil)
      })

      replace_root(manifest, guest, platform)
    }

    vm_spec.UpgradeRoot(recorded) -> {
      // The line comes after every refusal of `up` and before the first
      // change; `build_next_root`'s own refusal of an unsafe root follows it.
      io.println_error(vm_spec.upgrade_line(
        options.name,
        recorded,
        manifest.revision,
      ))
      use Nil <- result.try(build_next_root(manifest, guest, platform))
      swap_roots(guest)
    }

    vm_spec.FinishUpgrade -> swap_roots(guest)
  }
}

/// What the guest's directory holds, and so what `up` does about the root.
fn root_step_of(
  guest: Instance,
  manifest: Manifest,
  options: UpOptions,
) -> Result(vm_spec.RootStep, String) {
  use recorded <- result.try(recorded_root_revision(guest))

  // A root that is a link counts as absent: an older `up` left it pointing at
  // the shared export, which a boot would write into, so it is replaced.
  let root = case
    bootstrap.path_exists(guest.root),
    simplifile.is_symlink(guest.root)
  {
    True, Ok(False) -> vm_spec.Present
    _, _ -> vm_spec.Absent
  }

  let layout =
    vm_spec.RootLayout(
      root:,
      moved: presence_of(guest.next_root <> vm_spec.workspaces_dir),
    )
  Ok(vm_spec.root_step(options.freshness, layout, recorded, manifest.revision))
}

/// Whether anything is at `path`, a link counting whatever it points at.
fn presence_of(path: String) -> vm_spec.Presence {
  case simplifile.link_info(path) {
    Ok(_) -> vm_spec.Present
    Error(_) -> vm_spec.Absent
  }
}

/// The revision the host recorded for the guest's root, or `None` for a root
/// from before the record.
fn recorded_root_revision(
  guest: Instance,
) -> Result(option.Option(String), String) {
  case simplifile.read(guest.root_revision_file) {
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(
        guest.root_revision_file
        <> " is unreadable: "
        <> simplifile.describe_error(error),
      )
    Ok(text) -> Ok(vm_spec.decode_root_revision(text))
  }
}

/// Records which manifest revision the root now in place was cloned from.
fn record_root_revision(
  guest: Instance,
  manifest: Manifest,
) -> Result(Nil, String) {
  write_private(
    guest.root_revision_file,
    vm_spec.encode_root_revision(manifest.revision),
  )
}

/// Keeps the host's own copy of the `--provision` script, so a root cloned
/// again is provisioned from it and the script is never read back out of the
/// untrusted root. `--fresh` with no script clears it.
fn record_provision_copy(
  guest: Instance,
  options: UpOptions,
) -> Result(Nil, String) {
  // A given script is copied, `--fresh` without one drops the copy, and a
  // resume without one keeps what is there.
  case options.provision, options.freshness {
    Some(path), _ -> {
      use bytes <- result.try(
        simplifile.read_bits(path)
        |> result.map_error(fn(error) {
          path <> " is unreadable: " <> simplifile.describe_error(error)
        }),
      )

      // A temporary file in the same directory, renamed over the copy, so a
      // failure partway leaves the earlier copy whole.
      let temporary = guest.provision_file <> ".tmp"
      let _ = simplifile.delete(temporary)
      {
        use Nil <- result.try(simplifile.write_bits(temporary, bytes))
        use Nil <- result.try(simplifile.set_permissions_octal(temporary, 0o600))
        simplifile.rename(temporary, guest.provision_file)
      }
      |> result.map_error(fn(error) {
        guest.provision_file
        <> " is unwritable: "
        <> simplifile.describe_error(error)
      })
    }
    None, vm_spec.Fresh ->
      case simplifile.delete(guest.provision_file) {
        Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) ->
          Error(
            guest.provision_file
            <> " cannot be removed: "
            <> simplifile.describe_error(error),
          )
      }
    None, vm_spec.Resume -> Ok(Nil)
  }
}

/// Builds the upgraded root beside the old one, moving the workspaces last.
///
/// The order is what lets an interrupted `up` finish. Every step before the
/// rename leaves the old root whole, so `up` runs the whole upgrade again from
/// a clean `root.next`. The new root is cloned as `root.building` and named
/// `root.next` before the workspaces move into it (`upgrade_steps`), so a
/// `root.next` with `srv/workspaces` in it exists only once the workspaces have
/// moved, and what remains is `swap_roots`, which `up` finds by that `root.next`
/// beside a root with no workspaces (`vm_spec.root_step`, `FinishUpgrade`). The
/// directory moves as one `rename`, so a link inside it stays a link and nothing
/// is followed.
fn build_next_root(
  manifest: Manifest,
  guest: Instance,
  platform: vm_spec.Platform,
) -> Result(Nil, String) {
  // The directory and every parent of it must be real directories, or the
  // rename would carry a link the guest left into the new root.
  use workspaces <- result.try(
    plain_chain(guest.root, ["srv", "workspaces"])
    |> result.map_error(vm_spec.upgrade_refusal),
  )
  use export <- result.try(
    bootstrap.canonical_directory(manifest.guest_root)
    |> result.map_error(fn(reason) {
      manifest.guest_root <> " is not a directory: " <> reason
    }),
  )

  // A `root.next` here is the leftover of an attempt that stopped before it
  // moved the workspaces, and a `root.building` is one that stopped earlier.
  use Nil <- result.try(remove_tree_if_present(guest.next_root))
  use Nil <- result.try(remove_tree_if_present(guest.building_root))
  use _ <- result.try(tool(
    "cp",
    vm_spec.copy_arguments(platform, export, guest.building_root),
    within: copy_budget_ms,
  ))
  move_into_place(workspaces, guest.building_root, guest.next_root)
}

/// The steps that put an upgrade's new root in place, in order. The clone of
/// the export may ship `srv/workspaces`, and `up` takes `root.next/srv/workspaces`
/// to mean that the real workspaces have moved and the old root may go
/// (`vm_spec.root_step`). So the clone is `building` until its slot is cleared,
/// and it is given the name `root.next` before the workspaces are renamed into
/// it. After every step the workspaces are in exactly one place, and the layout
/// says they have moved only once they are in `root.next`: a stop before the
/// last rename leaves a `root.next` without them, which `up` deletes and
/// redoes from the old root, and a stop after it is a finished move.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.upgrade_steps("/vm/dev/root/srv/workspaces", "/vm/dev/root.building", "/vm/dev/root.next")
/// ```
@internal
pub fn upgrade_steps(
  workspaces: String,
  building: String,
  next_root: String,
) -> List(fn() -> Result(Nil, String)) {
  [
    fn() { make_inside(building, "/srv") },
    fn() { clear_workspaces_slot(building) },
    fn() {
      simplifile.rename(building, next_root)
      |> result.map_error(fn(error) {
        vm_spec.upgrade_refusal(
          "the new root cannot be put in place: "
          <> simplifile.describe_error(error),
        )
      })
    },
    fn() {
      simplifile.rename(workspaces, next_root <> vm_spec.workspaces_dir)
      |> result.map_error(fn(error) {
        vm_spec.upgrade_refusal(
          "the workspaces cannot be moved into the new root: "
          <> simplifile.describe_error(error),
        )
      })
    },
  ]
}

/// Runs `upgrade_steps` in order.
fn move_into_place(
  workspaces: String,
  building: String,
  next_root: String,
) -> Result(Nil, String) {
  list.try_each(upgrade_steps(workspaces, building, next_root), fn(step) {
    step()
  })
}

/// Removes any `srv/workspaces` the clone of the export brought into the new
/// root. `up` decides that an upgrade's rename completed from this directory's
/// existence (`vm_spec.RootLayout.moved`), so it must not exist before the
/// rename, whatever the exported guest root ships. A link is removed itself
/// and never entered.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.clear_workspaces_slot("/vm/dev/root.next")
/// ```
@internal
pub fn clear_workspaces_slot(next_root: String) -> Result(Nil, String) {
  remove_tree_if_present(next_root <> vm_spec.workspaces_dir)
}

/// Replaces the root with the new one that holds the workspaces. It is safe to
/// run again after any failure: the old root holds nothing of value once the
/// workspaces have left it.
fn swap_roots(guest: Instance) -> Result(Nil, String) {
  use Nil <- result.try(remove_tree_if_present(guest.root))
  simplifile.rename(guest.next_root, guest.root)
  |> result.map_error(fn(error) {
    guest.root <> " cannot be replaced: " <> simplifile.describe_error(error)
  })
}

/// The runners of this guest that survive its launcher, and how sure the
/// match is. `loom-vm` runs the virtual machine monitor as a separate process,
/// which outlives a launcher killed by SIGKILL, so the pid file can say the
/// guest is stopped while its runner holds the root and the state disk. A
/// host whose `ps` cannot be run is treated as having none.
fn stranded_in(
  guest: Instance,
  runner: option.Option(String),
) -> #(List(Int), vm_spec.Certainty) {
  let listing =
    tool("ps", ["-axww", "-o", "pid=,ppid=,command="], within: quick_ms)
    |> result.unwrap("")

  // A runner counts when it is the current manifest's or lives in the vm
  // home's cache. Setup moves the manifest to `cache/<new tag>` while guests of
  // the old release keep running, and the runner of such a guest, once its
  // launcher is killed, would no longer match the manifest alone.
  let cache = filepath.directory_name(guest.directory) <> "/cache/"
  let prefixes = option.map(runner, fn(path) { [path <> " ", cache] })
  let pids =
    vm_spec.stranded_runners_under(
      listing,
      guest.root,
      guest.state_disk,
      prefixes,
    )
  #(pids, vm_spec.certainty_of(runner))
}

/// The runner binary the manifest names, or `None` when it cannot be read, as
/// `down`, `status` and `rm` may have to work without a manifest.
fn manifest_runner(vm_home: String) -> option.Option(String) {
  case read_manifest_if_present(vm_home) {
    Ok(Some(manifest)) -> Some(manifest.runner)
    _ -> None
  }
}

/// Refuses a command that would use the guest's root and state disk when a
/// runner of the guest survives. A second guest on the same ext4 disk would
/// corrupt it, and removing the files under a running VM would leave it
/// writing to deleted ones. Nothing is stopped here: the refusal names the
/// pids and the way to stop them.
fn refuse_stranded(
  guest: Instance,
  name: String,
  runner: option.Option(String),
  blocked: vm_spec.Blocked,
) -> Result(Nil, String) {
  // Any runner found is a refusal; none means the guest is really stopped.
  case stranded_in(guest, runner) {
    #([], _) -> Ok(Nil)
    #(pids, certainty) ->
      Error(vm_spec.stranded_refusal(name, pids, certainty, blocked))
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
  use Nil <- result.try(remove_tree_if_present(guest.next_root))
  use Nil <- result.try(remove_tree_if_present(guest.building_root))

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
  installed: option.Option(String),
  workspaces: List(String),
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
  use Nil <- result.try(stage_ledger(root, executor, installed))
  write_private(
    node <> "/loom.toml",
    vm_spec.guest_config(executor, workspaces, github, allow),
  )
}

/// Puts the membership ledger beside the executor's credentials, where the
/// `ledger` key of its configuration names it
/// (`distribution_bundle.ledger_path`). A static bundle has none. The lines are
/// the daemon's installed ledger when `vm_spec.ledger_to_stage` accepts it, and
/// the bundle's otherwise: a bundle's ledger is as of the enrolment, and a
/// certificate renewed since would make its pin table refuse the handshake on a
/// new root. The file is written only when the root has none: the executor
/// appends the entries it syncs to it, and writing over a later `up` would roll
/// the ledger back. A new root has no file, so `--fresh` and an upgrade stage
/// one.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.stage_ledger("/vm/dev/root", executor_bundle, None)
/// ```
@internal
pub fn stage_ledger(
  root: String,
  executor: Bundle,
  installed: option.Option(String),
) -> Result(Nil, String) {
  let path = root <> distribution_bundle.ledger_path(vm_spec.guest_files())

  // Only a ledger bundle has lines to stage.
  case vm_spec.ledger_to_stage(executor, installed) {
    [] -> Ok(Nil)
    lines ->
      // A link counts as present: the file is only ever read in the guest.
      case simplifile.link_info(path) {
        Ok(_) -> Ok(Nil)
        Error(_) -> write_private(path, membership_provision.file_text(lines))
      }
  }
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

/// Removes a tree when something is there, a link counting as something.
fn remove_tree_if_present(path: String) -> Result(Nil, String) {
  case presence_of(path) {
    vm_spec.Absent -> Ok(Nil)
    vm_spec.Present -> remove_tree(path)
  }
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
  github: vm_spec.GitHubAccess,
  plan: vm_spec.ProvisionPlan,
) -> Result(Int, String) {
  use port <- result.try(bootstrap.reserve_loopback_port())
  use Nil <- result.try(launch_guest(
    manifest,
    guest,
    names,
    options,
    github,
    plan,
    port,
    vm_spec.Publish,
  ))
  Ok(port)
}

/// Starts `loom-vm run` with the guest's port forwarded from the host's
/// `port` and waits until the console says its executor serves. `reach` says
/// whether the executor's node is also registered in the host's epmd.
fn launch_guest(
  manifest: Manifest,
  guest: Instance,
  names: vm_spec.Names,
  options: UpOptions,
  github: vm_spec.GitHubAccess,
  plan: vm_spec.ProvisionPlan,
  port: Int,
  reach: vm_spec.Reach,
) -> Result(Nil, String) {
  let launch =
    Launch(
      manifest:,
      names:,
      root: guest.root,
      memory_mib: options.memory_mib,
      cpus: options.cpus,
      host_port: port,
      state_disk: guest.state_disk,
      github:,
      allow: options.allow,
      reach:,
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
  await_ready(guest, record, vm_spec.boot_budget_ms(plan))
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

// What `up` leaves the user's daemon needing, after doing what it can about it.
type Restart {
  // The daemon derives the guest from a ledger it already holds.
  NoRestart

  // The guest is in a configuration other than the default, whose daemon `up`
  // cannot find.
  OtherDaemon

  // The default daemon read its configuration before `[distribution]` existed,
  // and this is what `up` did about it.
  Daemon(vm_spec.DaemonOutcome)
}

/// Does what `up` does about the daemon, which can stop an idle one, and
/// answers the outcome. It runs after the guest booted, since a failed `up`
/// must not have stopped a daemon.
fn restart_after(enrolled: Enrolled) -> Restart {
  case enrolled.row, enrolled.file {
    Derived, _ -> NoRestart
    Written, OtherConfigFile | Resumed, OtherConfigFile -> OtherDaemon
    Written, DefaultConfigFile | Resumed, DefaultConfigFile ->
      Daemon(daemon_outcome())
  }
}

/// What `up` tells the user: how to use the guest, and what to do about the
/// daemon.
fn report(upped: Upped, restart: Restart) -> String {
  use <- on_untrusted_report(upped, restart)
  let Upped(options:, workspace:, port:, enrolled:, ..) = upped
  let names = vm_spec.names(options.name)
  string.join(
    list.flatten([
      [
        "The guest "
          <> options.name
          <> " serves "
          <> names.executor_node
          <> " on host port "
          <> int.to_string(port)
          <> ".",
        enrolled_line(options, enrolled),
        "",
        "Use it with:",
        "  loom --executor "
          <> options.name
          <> " --workspace "
          <> workspace.name,
        "",
      ],
      daemon_lines(restart),
      ["Stop it with: loom vm down --name " <> options.name],
    ]),
    "\n",
  )
}

/// The line that says how the daemon comes to know the guest.
fn enrolled_line(options: UpOptions, enrolled: Enrolled) -> String {
  case enrolled.row {
    Written | Resumed ->
      "Enrolled it as [executors."
      <> options.name
      <> "] in "
      <> enrolled.config
      <> "."
    Derived ->
      "It is a member of the ledger deployment "
      <> enrolled.config
      <> " belongs to, so the daemon derives [executors."
      <> options.name
      <> "] from the ledger, with no change to the file and no restart."
  }
}

/// The lines about daemons, after doing what this `up` calls for.
fn daemon_lines(restart: Restart) -> List(String) {
  // Only the default daemon is ever observed or stopped.
  case restart {
    NoRestart -> []
    Daemon(outcome) -> vm_spec.daemon_note(outcome)
    OtherDaemon -> [
      "A daemon already running with that file must restart to use the guest.",
      "",
    ]
  }
}

/// What `up` does about the user's daemon.
///
/// A running daemon read its configuration before the `[distribution]` table
/// existed, so only a restart reaches the guest. A daemon that holds no session
/// is stopped here, and the next `loom` command starts it again with the table
/// in effect: the `loom` client renders the TLS options file whenever it starts
/// a daemon whose configuration has `[distribution]` (protocol-change/106). A
/// daemon that holds any session is never stopped; the note names the command.
fn daemon_outcome() -> vm_spec.DaemonOutcome {
  // No daemon needs no action. A running one is decided on what it said about
  // its sessions, in `vm_spec.daemon_step`, which is the only place that
  // chooses to stop it.
  case observe_daemon() {
    None -> vm_spec.NoDaemon
    Some(#(fence, sessions)) ->
      case vm_spec.daemon_step(fence.pid, sessions) {
        vm_spec.StopIt -> stop_daemon(fence)
        vm_spec.LeaveAlone(outcome) -> outcome
      }
  }
}

/// The daemon the default state directory's endpoint record names, if its
/// process is still there, with how many sessions it says it holds. Anything
/// that cannot be read counts as no daemon, because the note it chooses is
/// advice and not a decision; a daemon that answers no status is `Uncounted`.
fn observe_daemon() -> option.Option(#(endpoint.Fence, vm_spec.Sessions)) {
  // A record with no live process is no daemon; a live one is asked how many
  // sessions it holds, and an answer that cannot be read is not a count of zero.
  case running_fence() {
    None -> None
    Some(fence) ->
      case ask_daemon("status") |> result.try(vm_spec.occupied_sessions) {
        Ok(count) -> Some(#(fence, vm_spec.Counted(count)))
        Error(_) -> Some(#(fence, vm_spec.Uncounted))
      }
  }
}

/// The fence of the default state directory's daemon, when its record names a
/// process that is still there. Anything unreadable counts as no daemon.
fn running_fence() -> option.Option(endpoint.Fence) {
  let found = {
    use home <- result.try(home())
    use paths <- result.try(endpoint.paths(home <> "/.loom"))
    use found <- result.try(endpoint.load(paths))
    present_in(found)
  }
  result.unwrap(found, None)
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

      // A launcher killed without stopping its runner leaves the guest
      // running with nothing to signal, which `down` must not call stopped.
      case stranded_in(guest, manifest_runner(vm_home)) {
        #([], _) -> Ok("The guest " <> name <> " is not running.")
        #(pids, certainty) ->
          Error(
            "The guest "
            <> name
            <> " has no launcher, but "
            <> vm_spec.stranded_note(pids, certainty),
          )
      }
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
  use kind <- result.try(recorded_kind(guest))
  Ok(string.join(
    list.flatten([
      [
        "guest:      " <> name,
        "process:    " <> process_line(state),
      ],
      link_lines(guest, names, kind),
      [
        "revision:   " <> revision_line(vm_home),
        "root:       " <> root_line(guest),
        "root from:  " <> root_origin_line(guest),
        "workspaces: " <> workspace_line(guest),
        "allowed:    " <> allow_line(guest),
        "github:     " <> github_line(guest),
        "provision:  " <> provision_line(guest),
      ],
      stranded_line(guest, state, vm_home),
    ]),
    "\n",
  ))
}

/// A line naming a runner that holds the guest's files when the pid file names
/// no process, so `not running` is never the whole account of such a guest.
fn stranded_line(
  guest: Instance,
  state: ProcessState,
  vm_home: String,
) -> List(String) {
  // A running launcher owns its runner; only a missing one strands it.
  case state {
    Alive(_) -> []
    NotRunning ->
      case stranded_in(guest, manifest_runner(vm_home)) {
        #([], _) -> []
        #(pids, certainty) -> [
          "runner:     " <> vm_spec.stranded_note(pids, certainty),
        ]
      }
  }
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

/// The manifest revision the guest's root was cloned from, as `up` recorded
/// it. A root from before the record, or a development one, says so.
fn root_origin_line(guest: Instance) -> String {
  case recorded_root_revision(guest) {
    Ok(Some(revision)) -> vm_spec.printable(revision)
    Ok(None) -> "unknown (no record)"
    Error(reason) -> "unknown (" <> reason <> ")"
  }
}

/// The workspace copies the guest's root holds, which `loom --executor` names
/// with `--workspace` when the host's `checkouts` record knows them.
fn workspace_line(guest: Instance) -> String {
  // A directory that cannot be read safely is not an empty one: `none` would
  // tell the user the guest holds nothing.
  case workspace_names(guest) {
    Ok([]) -> "none"
    Error(_) -> "unreadable"
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

/// The GitHub access the guest's record names, or the default when it has none.
fn github_line(guest: Instance) -> String {
  case recorded_github(guest) {
    Ok(Some(access)) -> string.trim(vm_spec.encode_github(access))
    Ok(None) -> "not recorded (the default, gh, applies)"
    Error(reason) -> "unknown (" <> reason <> ")"
  }
}

/// Whether the guest's provisioning script ran, is waiting to run, or was never
/// given.
fn provision_line(guest: Instance) -> String {
  case root_provisioning(guest.root) {
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
    ["-c", vm_spec.log_tail_script(), "sh", int.to_string(lines), guest.log],
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
  // the deployment `up` provisions first, or the `link` record an untrusted
  // guest has instead. The manifest and the artifact cache that share the home
  // are neither.
  let names =
    entries
    |> list.filter(fn(entry) {
      result.is_ok(vm_spec.valid_existing_name(entry))
      && is_plain_directory(vm_home <> "/" <> entry)
      && {
        is_plain_directory(vm_home <> "/" <> entry <> "/deploy")
        || bootstrap.path_exists(instance(vm_home, entry).kind_file)
      }
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
    // The sealed authority key's directory, when this guest minted one and no
    // other guest's deployment uses it.
    authority: option.Option(String),
    // What happens to the guest's membership of a ledger it joined.
    revocation: Revocation,
    // The vm home's link credentials, when this is the last untrusted guest
    // and nothing needs them any more.
    link_home: option.Option(String),
  )
}

// A guest that joined its daemon's deployment is a member of the ledger, and
// removing the guest leaves that entry unless it is revoked.
type Revocation {
  // The guest minted its deployment, or is static: there is no member to
  // revoke, because the whole deployment goes with it.
  NoRevocation

  // The key is on this machine, so `rm` signs the revoke.
  RevokeWith(directory: String, passphrase: option.Option(String))

  // The key is elsewhere, and the operator who holds it runs the revoke.
  RevokeByOperator(deployment: String)
}

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

  // A runner that outlived its launcher still has the files open.
  use Nil <- result.try(refuse_stranded(
    guest,
    name,
    manifest_runner(vm_home),
    vm_spec.BlocksRemoval,
  ))

  use home <- result.try(home())
  use config <- result.try(
    bootstrap.absolute_path(
      option.lazy_unwrap(config, fn() {
        distribution_install.default_config(home)
      }),
    ),
  )

  // The file is read, planned and written back under the link lock, so a first
  // `up` for another guest cannot write a row between the read and the write.
  with_link_lock(vm_home, fn() {
    use plan <- result.try(planned_removal(vm_home, guest, name, config, home))

    // Nothing is changed until the user has said yes, and the refusal names
    // the copies the answer would lose.
    case consent {
      vm_spec.Unconfirmed ->
        Error(
          vm_spec.removal_refusal(name, held_workspaces(guest))
          <> "\n"
          <> removal_preview(plan, name, home),
        )
      vm_spec.Confirmed -> apply_removal(guest, name, home, plan)
    }
  })
}

/// Reads the configuration and the cookie and decides what undoing the guest's
/// enrolment removes. A configuration that cannot be parsed, or whose tables
/// cannot be removed line by line, refuses here with one line.
fn removal_plan(
  vm_home: String,
  guest: Instance,
  name: String,
  config: String,
  home: String,
) -> Result(RemovalPlan, String) {
  let names = vm_spec.names(name)
  let id = deployment_of(vm_home, name)
  let minter = bootstrap.path_exists(bundle_file(guest, names.orchestrator))

  // A guest that minted a deployment other guests joined holds the `[executors]`
  // row, the `[distribution]` table, the cookie and the key they need, so it
  // goes last.
  use Nil <- result.try(case id, minter {
    Ok(deployment), True ->
      case sharing_guests(vm_home, name, deployment) {
        [] -> Ok(Nil)
        joined ->
          Error(
            "the guests "
            <> string.join(joined, ", ")
            <> " joined the deployment "
            <> name
            <> " minted, and the deployment's tables, cookie and key are "
            <> "theirs too. Remove them first with `loom vm rm --name NAME`, "
            <> "then this one."
            <> " Nothing was removed.",
          )
      }
    _, _ -> Ok(Nil)
  })

  // A guest that joined has no row, table or cookie of its own to undo.
  let joiner = result.is_ok(id) && !minter

  // A joined guest touches no file; any other undoes its tables.
  use #(teardown, rewritten) <- result.try(case joiner {
    True -> Ok(#(vm_spec.joined_teardown(), None))
    False -> configured_teardown(guest, names, config, home)
  })

  // Only a guest that joined has a ledger entry of its own to revoke, and
  // whether it can be revoked here depends on the key being on this machine.
  let revocation = case id, joiner {
    Ok(deployment), True ->
      // The vm home is searched, then the operator's homes.
      case sealed_authority(vm_home, deployment, config_ledger(config)) {
        Ok(#(directory, passphrase)) -> RevokeWith(directory, passphrase)
        Error(_) -> RevokeByOperator(deployment)
      }
    _, _ -> NoRevocation
  }

  Ok(RemovalPlan(
    config:,
    teardown:,
    rewritten:,
    authority: removable_authority(vm_home, name),
    revocation:,
    link_home: None,
  ))
}

/// What `rm` undoes for a guest on the untrusted link: its row, and
/// `[executor_link]` with the vm home's link credentials when it is the last
/// untrusted guest. There is no cookie to compare, no sealed key and no ledger
/// entry to revoke, because the guest was never a member of anything.
fn linked_removal_plan(
  vm_home: String,
  guest: Instance,
  name: String,
  config: String,
) -> Result(RemovalPlan, String) {
  use text <- result.try(read_or_empty(config))
  use others <- result.try(other_kinds(vm_home, name))
  let remaining = vm_link.remaining(others)

  // The guest's row is told from another untrusted row of its name by the pin
  // of its leaf. A leaf that cannot be read matches nothing, so the row stays.
  let pin =
    read_text(guest.link_credentials <> "/executor.pem")
    |> result.try(vm_link.pin_of)
    |> result.unwrap("")
  use removal <- result.try(
    vm_link.uninstall(
      text,
      vm_link.Row(name:, port: 1, pin:),
      remaining,
      vm_link_pki.files_of(vm_home),
      config,
    )
    |> result.map_error(fn(reason) { reason <> ". Nothing was removed." }),
  )

  // Text that is unchanged needs no write, so a guest whose row is gone leaves
  // the user's file untouched.
  let rewritten = case removal.text == text {
    True -> None
    False -> Some(removal.text)
  }

  // The vm home's credentials go with the last untrusted guest, and only when
  // no table names them any more: an operator's own untrusted row keeps
  // `[executor_link]`, and the files it names.
  let link_home = case remaining, removal.table {
    vm_link.LastLinked, vm_link.LinkTableGone ->
      Some(vm_home <> "/" <> vm_spec.link_dir)
    _, _ -> None
  }

  Ok(RemovalPlan(
    config:,
    teardown: vm_spec.Teardown(
      tables: removal.removed,
      cookie: vm_spec.KeepCookie,
      left: removal.left,
    ),
    rewritten:,
    authority: None,
    revocation: NoRevocation,
    link_home:,
  ))
}

/// The links of the guests other than `name`, from their `link` records. A
/// directory with no record is a distribution guest, and a record that cannot
/// be read counts as untrusted, so the shared credentials are kept rather than
/// removed under a guest that may still need them.
fn other_kinds(
  vm_home: String,
  name: String,
) -> Result(List(vm_spec.LinkKind), String) {
  use entries <- result.try(
    simplifile.read_directory(vm_home)
    |> result.map_error(fn(error) {
      vm_home <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  Ok(
    entries
    |> list.filter(fn(entry) {
      entry != name && result.is_ok(vm_spec.valid_existing_name(entry))
    })
    |> list.map(fn(entry) {
      recorded_kind(instance(vm_home, entry))
      |> result.unwrap(vm_spec.Untrusted)
    }),
  )
}

/// The plan for the guest's own link: `removal_plan` for a distribution guest.
fn planned_removal(
  vm_home: String,
  guest: Instance,
  name: String,
  config: String,
  home: String,
) -> Result(RemovalPlan, String) {
  use kind <- result.try(recorded_kind(guest))

  // The guest's own link says what undoing it means.
  case kind {
    vm_spec.Untrusted -> linked_removal_plan(vm_home, guest, name, config)
    vm_spec.Distribution -> removal_plan(vm_home, guest, name, config, home)
  }
}

/// What undoing the guest's enrolment takes out of `config` and the cookie.
fn configured_teardown(
  guest: Instance,
  names: vm_spec.Names,
  config: String,
  home: String,
) -> Result(#(vm_spec.Teardown, option.Option(String)), String) {
  // A configuration that does not exist has no enrolment to undo.
  use text <- result.try(case simplifile.read(config) {
    Ok(text) -> Ok(text)
    Error(simplifile.Enoent) -> Ok("")
    Error(error) ->
      Error(config <> " is unreadable: " <> simplifile.describe_error(error))
  })

  use found <- result.try(
    vm_spec.read_enrolment(text, names.name)
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

  Ok(#(teardown, rewritten))
}

/// The authority directory `up` sealed for the guest called `name`, when it
/// is still there and no other guest's executor bundle names the same
/// deployment. The id is read from the guest's own executor bundle, which `up`
/// wrote, never from the guest root. A static guest, a bundle that is gone and
/// a deployment whose key was sealed somewhere else (a guest that joined an
/// operator's deployment) each have nothing here to remove.
///
/// ## Examples
///
/// ```gleam
/// // vm_cli.removable_authority("/h/vm", "dev") -> Some("/h/vm/authority/3f9c")
/// ```
@internal
pub fn removable_authority(
  vm_home: String,
  name: String,
) -> option.Option(String) {
  // A guest whose bundle names no deployment, or no bundle at all, sealed
  // nothing.
  case deployment_of(vm_home, name) {
    Error(Nil) -> None
    Ok(id) -> {
      let directory = vm_spec.authority_directory(vm_home, id)
      let shared = sharing_guests(vm_home, name, id) != []

      // The key is deleted only when it is still there and no other guest's
      // deployment depends on it.
      case is_plain_directory(directory), shared {
        True, False -> Some(directory)
        _, _ -> None
      }
    }
  }
}

/// The deployment id in the executor bundle of the guest called `name`.
fn deployment_of(vm_home: String, name: String) -> Result(String, Nil) {
  let names = vm_spec.names(name)
  use bundle <- result.try(
    read_bundle(
      bundle_file(instance(vm_home, name), names.name),
      names.executor_node,
    )
    |> result.replace_error(Nil),
  )
  vm_spec.bundle_deployment(bundle)
}

/// The guests other than `name` whose executor bundle names the deployment
/// `id`, sorted: the members that joined it, or the one that minted it.
fn sharing_guests(vm_home: String, name: String, id: String) -> List(String) {
  simplifile.read_directory(vm_home)
  |> result.unwrap([])
  |> list.filter(fn(entry) {
    entry != name
    && result.is_ok(vm_spec.valid_existing_name(entry))
    && deployment_of(vm_home, entry) == Ok(id)
  })
  |> list.sort(string.compare)
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
fn removal_preview(plan: RemovalPlan, name: String, home: String) -> String {
  string.join(
    list.flatten([
      [preview_header(plan)],
      list.map(removed_things(plan, home), fn(thing) { "  removes " <> thing }),
      list.map(revocation_line(plan, name), fn(line) {
        case plan.revocation {
          RevokeWith(..) -> "  revokes " <> line
          _ -> "  leaves " <> line
        }
      }),
      list.map(plan.teardown.left, fn(line) { "  leaves " <> line }),
    ]),
    "\n",
  )
}

/// The first line of the preview: a guest that joined has no entry in the
/// configuration to undo, and its revoke goes through the daemon of the default
/// configuration.
fn preview_header(plan: RemovalPlan) -> String {
  case plan.revocation {
    NoRevocation ->
      "`--yes` also undoes the enrolment in " <> plan.config <> ":"
    RevokeWith(..) ->
      "`--yes` also revokes the guest through the default daemon and leaves "
      <> plan.config
      <> " as it is:"
    RevokeByOperator(..) ->
      "`--yes` removes the guest and leaves " <> plan.config <> " as it is:"
  }
}

/// The sentence about the ledger entry of a guest that joined, for the preview
/// and the report. The guest's own name is `name`.
fn revocation_line(plan: RemovalPlan, name: String) -> List(String) {
  case plan.revocation {
    NoRevocation -> []
    RevokeWith(directory:, ..) -> [
      "the membership of "
      <> name
      <> " in the ledger, revoked with the key in "
      <> directory,
    ]
    RevokeByOperator(deployment:) -> [
      "the membership of "
      <> name
      <> " in the ledger: the key of deployment "
      <> deployment
      <> " is not on this machine, so run `loom distribution revoke "
      <> name
      <> "` where it is kept",
    ]
  }
}

/// Signs the revoke of a guest that joined, with the key on this machine, and
/// answers the lines that say what happened. The checks of `loom distribution
/// revoke` apply, so a guest that still owns or holds sessions is refused here
/// and nothing is removed.
fn revoke_membership(
  plan: RemovalPlan,
  name: String,
) -> Result(List(String), String) {
  // Only a key on this machine can sign; the operator's case is reported.
  case plan.revocation {
    NoRevocation -> Ok([])
    RevokeByOperator(..) -> Ok([])
    RevokeWith(directory:, passphrase:) -> {
      use authority <- result.try(ledger_cli.unlock_at(directory, passphrase))

      // A guest the operator's copy already records as revoked is done: the
      // fold would refuse the entry, and the removal must not be stuck on it.
      case revoked_already(plan.config, directory, authority, name) {
        True ->
          Ok([name <> " is already revoked in the ledger; nothing signed."])
        False -> signed_revoke(authority, name)
      }
    }
  }
}

/// Whether `name` is already revoked, in the operator's copy of the ledger or
/// in the installed ledger of the daemon, which may hold a revoke the copy has
/// not yet caught up with.
fn revoked_already(
  config: String,
  directory: String,
  authority: ledger_cli.Authority,
  name: String,
) -> Bool {
  // The daemon's ledger is read against the authority's own certificate.
  let in_daemon = case
    installed_ledger(config),
    read_text(directory <> "/ca.pem")
  {
    Some(text), Ok(ca) ->
      vm_spec.standing(ca, text, name) == Ok(membership_ledger.Revoked)
    _, _ -> False
  }

  in_daemon || ledger_cli.is_revoked(authority, name)
}

/// Signs the revoke of `name` and words what happened.
fn signed_revoke(
  authority: ledger_cli.Authority,
  name: String,
) -> Result(List(String), String) {
  use #(signed, checked) <- result.map(
    ledger_cli.revoke_member(
      authority,
      name,
      "removed with loom vm rm",
      ledger_cli.Checked,
      admin.ThisHost(""),
      ledger_cli.socket_connect(),
    )
    |> result.map_error(vm_spec.rm_revoke_refusal),
  )

  // An entry no daemon took is in the operator's copy, which is reported.
  let took = case ledger_cli.delivered(signed) {
    Ok(where_) -> "Handed to " <> where_ <> "."
    Error(reason) -> "Not handed to a daemon: " <> reason
  }

  [
    "Revoked "
      <> name
      <> " as entry "
      <> int.to_string(ledger_cli.entry_seq(signed))
      <> ". "
      <> checked,
    took,
  ]
}

/// The tables and the cookie the plan removes, each as the name a person
/// would use for it.
fn removed_things(plan: RemovalPlan, home: String) -> List(String) {
  let tables =
    list.map(plan.teardown.tables, fn(path) {
      "[" <> string.join(path, ".") <> "]"
    })

  // The cookie is listed only when the plan removes it.
  let with_cookie = case plan.teardown.cookie {
    vm_spec.RemoveCookie -> list.append(tables, [home <> "/.erlang.cookie"])
    vm_spec.KeepCookie -> tables
  }

  // The sealed key is listed after them, since it goes after them.
  let with_key = case plan.authority {
    Some(directory) ->
      list.append(with_cookie, ["the sealed authority key in " <> directory])
    None -> with_cookie
  }

  // The link credentials are the last thing listed, since they go last.
  case plan.link_home {
    Some(directory) ->
      list.append(with_key, ["the link credentials in " <> directory])
    None -> with_key
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
  // The ledger entry of a guest that joined is revoked first, because the
  // revoke can be refused (the guest still holds sessions) and then nothing
  // has been removed.
  use revoked <- result.try(revoke_membership(plan, name))

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

  // The key goes after the guest it was minted for, so a failure part way
  // leaves a guest that still names its key and can be removed again.
  use Nil <- result.try(case plan.authority {
    Some(directory) -> remove_tree(directory)
    None -> Ok(Nil)
  })

  // The link credentials go after the guest and its row, so a failure part way
  // leaves a guest that can be removed again, never a row naming files that
  // are gone.
  use Nil <- result.try(case plan.link_home {
    Some(directory) -> remove_tree(directory)
    None -> Ok(Nil)
  })

  Ok(string.join(
    list.flatten([
      ["Removed the guest " <> name <> ": deleted " <> guest.directory <> "."],
      list.map(removed_things(plan, home), fn(thing) {
        "Removed " <> thing <> "."
      }),
      revoked,
      case plan.revocation {
        RevokeByOperator(..) ->
          list.map(revocation_line(plan, name), fn(line) {
            "Left in place: " <> line
          })
        _ -> []
      },
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

/// The workspace copies a guest holds, for the refusal, or why they cannot be
/// listed.
fn held_workspaces(guest: Instance) -> Result(List(String), String) {
  workspace_names(guest)
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
  // The `-c` settings do not reach upload-pack, so the fetch relies on its own
  // rules, which an old Git lacks.
  use version <- result.try(run_git(["version"]))
  use Nil <- result.try(vm_spec.check_git_version(version))
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
  use env <- result.try(
    ffi_os.find_executable("env")
    |> result.map_error(fn(_) { "env is not on PATH" }),
  )

  // `env` sets `GIT_NO_LAZY_FETCH` because neither runner takes an
  // environment; it tells every Git process of the fetch, `git-upload-pack`
  // included, not to run a promisor remote's fetch on a copy's behalf.
  let wrapped = ["GIT_NO_LAZY_FETCH=1", git, ..arguments]

  // Only status zero is success, and the refusal shows Git's own words.
  case bootstrap.run_captured(env, wrapped, copy_budget_ms) {
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
