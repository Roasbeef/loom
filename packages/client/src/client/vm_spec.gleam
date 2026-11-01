//// The decisions behind `loom vm up | down | status`, with no effect in them.
////
//// `client/vm_cli` does the work: it provisions, copies, spawns and signals.
//// Everything it needs to decide first lives here as a function of plain
//// data, so a test can hold each decision still without a guest, a process or
//// a file. The decisions are:
////
//// - which command and options an argument list asks for (`parse`);
//// - what the artifact manifest says, and whether those artifacts match the
////   running build (`decode_manifest`, `check_revision`);
//// - the two-node deployment plan and the executor's own `loom.toml`
////   (`deployment_plan`, `guest_config`);
//// - the `loom-vm run` command line (`launch_arguments`) and the shell
////   command that clones a tree (`copy_arguments`);
//// - what a workspace copy may keep of its Git configuration
////   (`scrub_git_config`);
//// - how to read the two small records the command leaves behind and consults
////   later: its pid file (`encode_pid`, `decode_pid`) and the host epmd's
////   listing (`registered_port`).
////
//// ## Flow
////
//// - `parse` turns `loom vm`'s words into a `Command`.
//// - `decode_manifest` reads the artifact manifest and `check_revision`
////   compares it with the running build.
//// - `names` derives the node names, `deployment_plan` the two-node plan, and
////   `guest_config` the executor's configuration file, with the tools table that
////   GitHub access needs.
//// - `launch_arguments` builds the `loom-vm run` command line.
////
//// ## The deployment
////
//// One standing guest is two daemons that trust each other. The orchestrator
//// is the user's own daemon, enrolled by installing its bundle into their
//// `loom.toml`. The executor runs in the guest. Both have `127.0.0.1` as
//// their host: the guest has no route to the host's network, so the
//// orchestrator reaches the executor through the port `loom-vm run --publish`
//// forwards, under the executor's own node name (ADR-022, "The link").
//// Nothing here reads the clock, the environment or a file.

import client/distribution.{type CredentialFiles, CredentialFiles}
import client/distribution_bundle.{type Bundle}
import client/distribution_plan.{type Plan, Executor, Node, Orchestrator, Plan}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue

/// The name a standing guest has unless `--name` says another.
pub const default_name = "vm"

/// The manifest format this build reads.
pub const manifest_version = 1

/// The executor's distribution port inside the guest, which the plan fixes and
/// `--publish` forwards.
pub const guest_port = 4370

/// Where the executor node's directory sits inside the guest.
pub const node_dir = "/srv/loom-node"

/// Where the guest keeps its workspaces.
pub const workspaces_dir = "/srv/workspaces"

/// The guest's entry point: it stages nothing, it starts the executor daemon
/// on the node directory and prints the console markers `up` waits for.
pub const guest_entry = "/usr/local/sbin/loom-guest-executor"

/// The guest device the state disk appears as: the first virtio-blk device.
pub const state_device = "/dev/vda"

/// The GitHub hosts a guest with GitHub access may reach, through the
/// launcher's credential proxy. git pushes to `github.com`; `gh` speaks to
/// `api.github.com` and uploads release assets to `uploads.github.com`.
pub const github_hosts = ["github.com", "api.github.com", "uploads.github.com"]

/// The environment names a jailed tool call needs to use the credential
/// proxy: the proxy itself, the hosts that bypass it, and the placeholder
/// token `gh` and git present. The real token never enters the guest.
pub const github_env = ["HTTPS_PROXY", "NO_PROXY", "GH_TOKEN", "GITHUB_TOKEN"]

/// The console line that says the executor serves.
pub const ready_marker = "LOOM-EXECUTOR-READY"

/// The console line that says the executor died, followed by its log.
pub const failed_marker = "LOOM-EXECUTOR-FAILED"

/// The longest `--name`. The orchestrator's plan name adds `-host`, and a plan
/// name is at most 32 bytes.
pub const name_limit = 27

/// The manifest's workspace-name rule beyond the daemon's: the name becomes a
/// directory in the guest, so it is one safe path segment.
const segment_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

// --- the command line --------------------------------------------------------

/// What `loom vm up` was asked.
pub type UpOptions {
  UpOptions(
    /// The standing guest's name, which is also its `[executors.<name>]`.
    name: String,
    /// The directory to copy into the guest, or `None` for the current one.
    workspace: Option(String),
    /// The guest's memory in MiB.
    memory_mib: Int,
    /// The guest's virtual CPUs.
    cpus: Int,
    /// The `loom.toml` the orchestrator is installed into, or `None` for
    /// `$HOME/.loom/loom.toml`.
    config: Option(String),
    /// Where the guest's GitHub token comes from, or that it has none.
    github: GitHubAccess,
    /// Whether `up` keeps the guest's root and state disk or starts both
    /// again.
    freshness: Freshness,
  )
}

/// How a standing guest reaches GitHub. The token is read on the host by
/// `loom-vm` and injected by its credential proxy in flight; the guest only
/// ever holds a placeholder (ADR-022, the dev-experience addendum).
pub type GitHubAccess {
  /// The token `gh auth token` prints on the host.
  GitHubFromGh

  /// The token in the host's `LOOM_VM_GITHUB_TOKEN`.
  GitHubFromEnv

  /// No GitHub access: the guest's egress allowlist is empty and its jailed
  /// tools have no network.
  GitHubOff
}

/// Whether `up` resumes a guest's earlier root and state or starts again.
pub type Freshness {
  /// Keep the guest's root, its workspace copies and its state disk when
  /// they exist, so edits and sessions survive `down` and `up`.
  Resume

  /// Replace the root from the export and the state disk with a new one.
  Fresh
}

/// One of the three commands.
pub type Command {
  /// Provision, stage and boot the guest.
  Up(UpOptions)

  /// Stop the guest named.
  Down(name: String)

  /// Report the guest named.
  Status(name: String)
}

/// Reads the words after `loom vm`.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.parse(["status", "--name", "dev"]) == Ok(vm_spec.Status("dev"))
/// ```
pub fn parse(arguments: List(String)) -> Result(Command, String) {
  // The first word picks the command; only `up` has options beyond a name, and
  // each command checks the name it was given before anything runs.
  case arguments {
    ["up", ..flags] -> {
      use options <- result.try(up_flags(flags, default_up()))
      use Nil <- result.try(valid_name(options.name))
      Ok(Up(options))
    }
    ["down", ..flags] -> name_flag(flags) |> result.map(Down)
    ["status", ..flags] -> name_flag(flags) |> result.map(Status)
    [] -> Error("loom vm needs a command: up, down or status")
    [word, ..] -> Error("unknown loom vm command " <> word)
  }
}

/// The options `up` has when no flag says otherwise.
fn default_up() -> UpOptions {
  UpOptions(
    name: default_name,
    workspace: None,
    memory_mib: 2048,
    cpus: 4,
    config: None,
    github: GitHubFromGh,
    freshness: Resume,
  )
}

/// Reads `up`'s flags. Every flag takes one value, and the word after a flag is
/// its value even when it starts with a dash, as it does in every other
/// `loomd` command.
fn up_flags(
  arguments: List(String),
  options: UpOptions,
) -> Result(UpOptions, String) {
  // Each arm takes one flag and its value and recurses on the rest, so the
  // flags may come in any order and a repeated one is the last one given.
  case arguments {
    [] -> Ok(options)
    ["--name", value, ..rest] ->
      up_flags(rest, UpOptions(..options, name: value))
    ["--workspace", value, ..rest] ->
      up_flags(rest, UpOptions(..options, workspace: Some(value)))
    ["--config", value, ..rest] ->
      up_flags(rest, UpOptions(..options, config: Some(value)))
    ["--github", value, ..rest] -> {
      use github <- result.try(github_access(value))
      up_flags(rest, UpOptions(..options, github:))
    }

    // The one flag with no value: starting again is a choice, not a setting.
    ["--fresh", ..rest] ->
      up_flags(rest, UpOptions(..options, freshness: Fresh))
    ["--mem", value, ..rest] -> {
      use memory <- result.try(bounded("--mem", value, 256, 1_048_576))
      up_flags(rest, UpOptions(..options, memory_mib: memory))
    }
    ["--cpus", value, ..rest] -> {
      use cpus <- result.try(bounded("--cpus", value, 1, 128))
      up_flags(rest, UpOptions(..options, cpus:))
    }
    [flag] ->
      case string.starts_with(flag, "--") {
        True -> Error(flag <> " needs a value")
        False -> Error("unexpected argument " <> flag)
      }
    [word, ..] ->
      case string.starts_with(word, "--") {
        True -> Error("unknown option " <> word)
        False -> Error("unexpected argument " <> word)
      }
  }
}

/// Reads `--github`'s value.
fn github_access(value: String) -> Result(GitHubAccess, String) {
  // The three sources are spelled as `loom-vm run --github-token-from` spells
  // the two it takes, plus `off`.
  case value {
    "gh" -> Ok(GitHubFromGh)
    "env" -> Ok(GitHubFromEnv)
    "off" -> Ok(GitHubOff)
    _ -> Error("--github must be gh, env or off, got " <> value)
  }
}

/// A whole number flag value from `low` to `high`, or the refusal that names
/// the flag and the range.
fn bounded(
  flag: String,
  value: String,
  low: Int,
  high: Int,
) -> Result(Int, String) {
  case int.parse(value) {
    Ok(number) if number >= low && number <= high -> Ok(number)
    _ ->
      Error(
        flag
        <> " must be a whole number from "
        <> int.to_string(low)
        <> " to "
        <> int.to_string(high)
        <> ", got "
        <> value,
      )
  }
}

/// `down` and `status` take the guest's name and nothing else.
fn name_flag(arguments: List(String)) -> Result(String, String) {
  // Anything but the one flag is refused, so `down --mem 512` does not look
  // like it did something.
  case arguments {
    [] -> Ok(default_name)
    ["--name", value] -> valid_name(value) |> result.replace(value)
    ["--name"] -> Error("--name needs a value")
    [word, ..] -> Error("unexpected argument " <> word)
  }
}

/// Whether text can name a standing guest: an executor-grammar name short
/// enough that the orchestrator's `<name>-host` is one too.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.valid_name("dev") == Ok(Nil)
/// assert result.is_error(vm_spec.valid_name("Dev Box"))
/// ```
pub fn valid_name(name: String) -> Result(Nil, String) {
  case
    catalogue.is_executor_name(name) && string.byte_size(name) <= name_limit
  {
    True -> Ok(Nil)
    False ->
      Error(
        "--name must be lowercase letters, numbers, _ and -, starting with a "
        <> "letter, at most "
        <> int.to_string(name_limit)
        <> " characters, got "
        <> name,
      )
  }
}

/// Whether a directory's last segment can name its copy in the guest and its
/// `[workspaces.<name>]` row: one segment of letters, digits, `.`, `_` and
/// `-`, and neither `.` nor `..`.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.valid_workspace_name("proj-2") == Ok(Nil)
/// assert result.is_error(vm_spec.valid_workspace_name(".."))
/// ```
pub fn valid_workspace_name(name: String) -> Result(Nil, String) {
  let safe =
    name != ""
    && name != "."
    && name != ".."
    && string.byte_size(name) <= 128
    && list.all(string.to_graphemes(name), string.contains(
      segment_characters,
      _,
    ))

  // The refusal says what to change, because the name comes from a directory
  // the user did not choose a name for.
  case safe {
    True -> Ok(Nil)
    False ->
      Error(
        "the workspace directory's name \""
        <> name
        <> "\" must be letters, digits, . _ and - only, because it names the "
        <> "copy inside the guest; rename the directory or copy it elsewhere",
      )
  }
}

/// The reason `distribution install` refused, without its advice to pass
/// `--force`, which `loom vm up` has no such flag for.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.without_force_hint("a.toml has [x]; pass --force to replace it")
///   == "a.toml has [x]"
/// ```
pub fn without_force_hint(reason: String) -> String {
  case string.split_once(reason, "; pass --force") {
    Ok(#(before, _)) -> before
    Error(Nil) ->
      case string.split_once(reason, ". Pass --force") {
        Ok(#(before, _)) -> before <> "."
        Error(Nil) -> reason
      }
  }
}

// --- the artifact manifest ---------------------------------------------------

/// What `<vm home>/manifest.json` names: the built pieces of the tier.
pub type Manifest {
  Manifest(
    /// The commit the artifacts were built from, or `dev` for a tree build.
    revision: String,
    /// The `loom-vm` launcher.
    loom_vm: String,
    /// The `go-microvm-runner` binary it spawns.
    runner: String,
    /// The directory holding libkrun.
    lib_dir: String,
    /// The directory holding a custom libkrunfw, or `None` for the stock one.
    firmware_dir: Option(String),
    /// The exported guest root `up` clones for each guest.
    guest_root: String,
  )
}

/// Reads the manifest text. Every refusal names the field, and none holds file
/// content beyond the field's name.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(manifest) = vm_spec.decode_manifest(text)
/// assert manifest.revision == "dev"
/// ```
pub fn decode_manifest(text: String) -> Result(Manifest, String) {
  use found <- result.try(
    json.parse(text, manifest_decoder())
    |> result.map_error(describe_json),
  )
  let #(version, manifest) = found

  // A version this build does not know may mean other fields; reading it as
  // version 1 would trust a path that now means something else.
  use Nil <- result.try(case version == manifest_version {
    True -> Ok(Nil)
    False ->
      Error(
        "version "
        <> int.to_string(version)
        <> " is not one this build reads ("
        <> int.to_string(manifest_version)
        <> ")",
      )
  })

  use Nil <- result.try(absolute("loom_vm", manifest.loom_vm))
  use Nil <- result.try(absolute("runner", manifest.runner))
  use Nil <- result.try(absolute("lib_dir", manifest.lib_dir))
  use Nil <- result.try(absolute("guest_root", manifest.guest_root))

  // The stock kernel needs no directory, so an absent firmware directory has
  // no path to check.
  use Nil <- result.try(case manifest.firmware_dir {
    Some(directory) -> absolute("firmware_dir", directory)
    None -> Ok(Nil)
  })

  Ok(manifest)
}

/// The manifest's fields with its version, which the caller checks.
fn manifest_decoder() -> decode.Decoder(#(Int, Manifest)) {
  use version <- decode.field("version", decode.int)
  use revision <- decode.field("revision", decode.string)
  use loom_vm <- decode.field("loom_vm", decode.string)
  use runner <- decode.field("runner", decode.string)
  use lib_dir <- decode.field("lib_dir", decode.string)
  use firmware <- decode.field("firmware_dir", decode.string)
  use guest_root <- decode.field("guest_root", decode.string)

  // An empty string is how the manifest says the stock kernel is enough.
  let firmware_dir = case firmware {
    "" -> None
    directory -> Some(directory)
  }

  decode.success(#(
    version,
    Manifest(revision:, loom_vm:, runner:, lib_dir:, firmware_dir:, guest_root:),
  ))
}

fn absolute(field: String, path: String) -> Result(Nil, String) {
  case distribution_plan.is_absolute_path(path) {
    True -> Ok(Nil)
    False -> Error(field <> " must be an absolute path")
  }
}

/// Words for a manifest that did not parse or did not have the expected shape,
/// naming the first field that was wrong and never quoting the file.
fn describe_json(error: json.DecodeError) -> String {
  // The decoder's first error is the field to fix; the rest follow from it.
  case error {
    json.UnexpectedEndOfInput -> "the manifest is not complete JSON"
    json.UnexpectedByte(_) | json.UnexpectedSequence(_) ->
      "the manifest is not valid JSON"
    json.UnableToDecode([decode.DecodeError(expected:, found:, path:), ..]) ->
      "field "
      <> case path {
        [] -> "(top level)"
        _ -> string.join(path, ".")
      }
      <> " is wrong: expected "
      <> expected
      <> ", found "
      <> found
    json.UnableToDecode([]) -> "the manifest does not match its format"
  }
}

/// Refuses artifacts built from another release than the running one.
///
/// A guest daemon from another release crashes the host on its first message
/// the two do not both understand, so the check is a refusal and not a
/// warning. `dev` is the revision of a tree build, which has no commit to
/// match. Either commit may be abbreviated, down to seven characters.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.check_revision(manifest_at("dev"), "unknown") == Ok(Nil)
/// assert result.is_error(vm_spec.check_revision(manifest_at("abc1234"), "def5678"))
/// ```
pub fn check_revision(
  manifest: Manifest,
  running: String,
) -> Result(Nil, String) {
  case manifest.revision == "dev" || same_commit(manifest.revision, running) {
    True -> Ok(Nil)
    False ->
      Error(
        "the microVM artifacts were built from revision "
        <> manifest.revision
        <> " and this loom is "
        <> running
        <> ". A guest daemon from another release crashes the host on its "
        <> "first unmatched message, so `loom vm up` will not start one. "
        <> "Fetch the artifacts for this release with `loom-vm setup --release TAG`, or "
        <> "`make vmm vmm-runner vmm-firmware vmm-guest-root` in a checkout "
        <> "of it.",
      )
  }
}

fn same_commit(left: String, right: String) -> Bool {
  let long = string.byte_size(left) >= 7 && string.byte_size(right) >= 7
  long && { string.starts_with(left, right) || string.starts_with(right, left) }
}

// --- the deployment ----------------------------------------------------------

/// The names one standing guest's two daemons go by.
pub type Names {
  Names(
    /// The guest's name.
    name: String,
    /// The orchestrator's plan name, and so its bundle's file name.
    orchestrator: String,
    /// The orchestrator's Erlang node name.
    orchestrator_node: String,
    /// The executor's node name's part before the `@`, which `--publish`
    /// registers in the host epmd.
    executor_short: String,
    /// The executor's Erlang node name.
    executor_node: String,
  )
}

/// The node names for a guest called `name`.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.names("vm").executor_node == "loom_vm_vm_exec@127.0.0.1"
/// ```
pub fn names(name: String) -> Names {
  let short = "loom_vm_" <> name <> "_exec"
  Names(
    name:,
    orchestrator: name <> "-host",
    orchestrator_node: "loom_vm_" <> name <> "_orch@127.0.0.1",
    executor_short: short,
    executor_node: short <> "@127.0.0.1",
  )
}

/// The plan for one orchestrator, whose credentials go in `orchestrator_dir`,
/// and one executor that orchestrator uses. The executor serves no workspace
/// in the plan: `up` registers the one it copies in the guest's own
/// configuration, so the deployment does not depend on which directory was
/// copied last.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(plan) = vm_spec.deployment_plan(vm_spec.names("vm"), "/home/me/.loom/vm/vm/orch")
/// assert list.length(plan.nodes) == 2
/// ```
pub fn deployment_plan(
  names: Names,
  orchestrator_dir: String,
) -> Result(Plan, String) {
  distribution_plan.validate(
    Plan(
      nodes: [
        Node(
          name: names.orchestrator,
          role: Orchestrator,
          erlang_node: names.orchestrator_node,
          host: "127.0.0.1",
          listen_port: None,
          bundle_dir: Some(orchestrator_dir),
          executors: [names.name],
          workspaces: [],
        ),
        Node(
          name: names.name,
          role: Executor,
          erlang_node: names.executor_node,
          host: "127.0.0.1",
          listen_port: Some(guest_port),
          bundle_dir: None,
          executors: [],
          workspaces: [],
        ),
      ],
      directory: [],
    ),
  )
}

/// Where the executor's credentials sit inside the guest.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.guest_files().cookie == "/srv/loom-node/home/.erlang.cookie"
/// ```
pub fn guest_files() -> CredentialFiles {
  CredentialFiles(
    ca: node_dir <> "/creds/ca.pem",
    certificate: node_dir <> "/creds/cert.pem",
    key: node_dir <> "/creds/key.pem",
    cookie: node_dir <> "/home/.erlang.cookie",
  )
}

/// The executor's `loom.toml`, written with guest paths only.
///
/// The model table is one every daemon's configuration carries and an
/// executor never uses: it opens no session. `workspace` is the name the copy
/// is registered under; its root is `workspaces_dir/<workspace>`.
///
/// ## Examples
///
/// ```gleam
/// let text = vm_spec.guest_config(executor_bundle, "proj", vm_spec.GitHubOff)
/// assert string.contains(text, "[workspaces.proj]")
/// ```
pub fn guest_config(
  bundle: Bundle,
  workspace: String,
  github: GitHubAccess,
) -> String {
  let tables =
    distribution_bundle.config_tables(bundle, guest_files())
    |> list.map(fn(table) { table.text })

  // The executor's own tables come from the bundle, so its node name, its
  // listen port and its trust in the orchestrator are what the plan said. The
  // workspace row is the one thing the plan leaves to `up`.
  string.join(
    list.flatten([
      [unused_model],
      tables,
      [
        "[workspaces."
        <> distribution_bundle.toml_key(workspace)
        <> "]\nroot = "
        <> distribution_bundle.toml_string(workspaces_dir <> "/" <> workspace)
        <> "\n",
      ],
      tools_table(github),
    ]),
    "\n",
  )
}

/// The executor's `[tools]` table. With GitHub access the jail's network is
/// on, because the guest's egress allowlist, enforced by the launcher's host
/// side stack, is now the boundary, and the proxy's names pass the
/// environment allowlist. Without it the table is absent and the jail keeps
/// the network off.
fn tools_table(github: GitHubAccess) -> List(String) {
  // Only the off case changes nothing; both token sources need the same
  // guest-side configuration.
  case github {
    GitHubOff -> []
    GitHubFromGh | GitHubFromEnv -> [
      "[tools]\nnetwork = \"full\"\nenv = ["
      <> string.join(
        list.map(github_env, distribution_bundle.toml_string),
        ", ",
      )
      <> "]\n",
    ]
  }
}

const unused_model =
  "[models.unused]
dialect = \"anthropic\"
api_key_env = \"LOOM_VM_UNUSED_KEY\"
base_url = \"http://127.0.0.1:9\"
model_id = \"unused\"
context_window = 100000
max_output_tokens = 4096

[roles]
main = [\"unused\"]
"

// --- launching ---------------------------------------------------------------

/// What `loom-vm run` is given for one guest.
pub type Launch {
  Launch(
    manifest: Manifest,
    names: Names,
    /// The guest's private root, a clone it boots from and writes into.
    root: String,
    memory_mib: Int,
    cpus: Int,
    /// The host loopback port forwarded to the guest's distribution port.
    host_port: Int,
    /// The raw image `loom-vm` attaches as the guest's state device.
    state_disk: String,
    /// Where the guest's GitHub token comes from, or that it has none.
    github: GitHubAccess,
  )
}

/// `text`, a `loom.toml` just enrolled for a standing guest, with its
/// distribution listener bound to loopback (protocol-change/106). A table that
/// already names a listen address is left as the user wrote it.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.with_loopback_listener("[distribution]\nnode = \"a@127.0.0.1\"\n")
///   == "[distribution]\nlisten_address = \"127.0.0.1\"\nnode = \"a@127.0.0.1\"\n"
/// ```
pub fn with_loopback_listener(text: String) -> String {
  // The install writes the table header on a line of its own; anything else
  // is a file this function does not recognise and leaves alone.
  let header = "[distribution]\n"
  case
    string.contains(text, "listen_address"),
    string.split_once(text, header)
  {
    False, Ok(#(before, after)) ->
      before <> header <> "listen_address = \"127.0.0.1\"\n" <> after
    _, _ -> text
  }
}

/// The `loom-vm` arguments that boot the guest and run its executor.
///
/// The timeout is zero, which `loom-vm run` reads as "until stopped": its
/// default of ten minutes would end a standing guest in the middle of a
/// session. The state disk becomes the guest's first block device, which the
/// guest script mounts as the executor's state root.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(vm_spec.launch_arguments(launch), "--publish")
/// ```
pub fn launch_arguments(launch: Launch) -> List(String) {
  // The stock libkrunfw needs no flag; a custom one, such as the Landlock
  // kernel the tier's broker demands, is named.
  let firmware = case launch.manifest.firmware_dir {
    Some(directory) -> ["--firmware-dir", directory]
    None -> []
  }

  // With GitHub access the proxy's hosts form the egress allowlist and
  // `loom-vm` starts the credential proxy; without it the allowlist is empty.
  let github = case launch.github {
    GitHubOff -> []
    GitHubFromGh -> ["--github-token-from", "gh", ..github_allow()]
    GitHubFromEnv -> ["--github-token-from", "env", ..github_allow()]
  }

  list.flatten([
    [
      "run",
      "--name",
      launch.names.name,
      "--root-dir",
      launch.root,
      "--runner",
      launch.manifest.runner,
      "--lib-dir",
      launch.manifest.lib_dir,
    ],
    firmware,
    [
      "--cpus",
      int.to_string(launch.cpus),
      "--mem",
      int.to_string(launch.memory_mib),
      "--timeout",
      "0",
      "--state-disk",
      launch.state_disk,
      "--publish",
      launch.names.executor_short
        <> ":"
        <> int.to_string(launch.host_port)
        <> ":"
        <> int.to_string(guest_port),
    ],
    github,
    ["--", guest_entry, node_dir, "--state-device", state_device],
  ])
}

/// `--allow` for each GitHub host.
fn github_allow() -> List(String) {
  list.flat_map(github_hosts, fn(host) { ["--allow", host] })
}

/// The host systems `cp` clones on.
pub type Platform {
  Macos
  Linux
}

/// Reads `uname -s`.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.platform_of("Darwin\n") == Ok(vm_spec.Macos)
/// ```
pub fn platform_of(uname: String) -> Result(Platform, String) {
  case string.trim(uname) {
    "Darwin" -> Ok(Macos)
    "Linux" -> Ok(Linux)
    other -> Error("the microVM tier runs on macOS and Linux, not " <> other)
  }
}

/// The `cp` arguments that clone the tree `from` to the new path `to`,
/// copy-on-write where the file system allows, keeping modes and links.
///
/// `-p` matters on macOS: without it `cp` applies the umask to directory modes
/// and the guest's `/tmp` loses its world-write bit.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.copy_arguments(vm_spec.Macos, "/a", "/b") == ["-cRp", "/a", "/b"]
/// ```
pub fn copy_arguments(
  platform: Platform,
  from: String,
  to: String,
) -> List(String) {
  case platform {
    Macos -> ["-cRp", from, to]
    Linux -> ["-a", "--reflink=auto", from, to]
  }
}

// --- the workspace's Git configuration ---------------------------------------

/// A copy of a repository's `.git/config` without what could authenticate as
/// the user or redirect where the guest fetches from.
///
/// The guest's default read scope reads the file, and model code runs there,
/// so the copy keeps no `[credential]` section, no `insteadOf` or
/// `pushInsteadOf` key of a `[url]` section (those can carry a token in a
/// rewritten URL), and no `extraheader` key (which is how a CI token is
/// usually passed). Everything else is kept as written, including its
/// comments. A remote URL that itself holds a password is not rewritten.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.scrub_git_config("[credential]\n\thelper = store\n") == ""
/// ```
pub fn scrub_git_config(text: String) -> String {
  let #(kept, _) =
    list.fold(string.split(text, "\n"), #([], Keeping), scrub_line)
  kept |> list.reverse |> string.join("\n")
}

// Where the scrub is: before any section, inside one it keeps, or inside a
// `[credential]` section it is dropping whole.
type Position {
  Keeping
  Section(name: String)
  Dropping
}

// What follows a header's closing bracket on its own line.
type Remainder {
  Nothing
  Inline(setting: String)
}

/// Takes one line of the configuration: the lines kept so far, newest first,
/// and where the scrub is. A header moves the scrub to its section, and any
/// other line is kept or dropped by the section it is in.
fn scrub_line(
  state: #(List(String), Position),
  line: String,
) -> #(List(String), Position) {
  let #(lines, position) = state

  // A header decides the section; every other line belongs to the section the
  // scrub is in.
  case section_header(line) {
    Some(#(name, rest)) -> scrub_header(lines, line, name, rest)
    None -> scrub_setting(lines, line, position)
  }
}

/// A section header: `[credential]` sections are dropped whole, and a `[url]`
/// header with its setting on the same line keeps the header and loses the
/// setting when the setting is one the scrub removes.
fn scrub_header(
  lines: List(String),
  line: String,
  name: String,
  rest: Remainder,
) -> #(List(String), Position) {
  let section = Section(name)

  // Only a credential section and an inline `insteadOf` change anything; every
  // other header is kept as written.
  case name, rest {
    "credential", _ -> #(lines, Dropping)
    "url", Inline(setting) ->
      case drops_key(section, setting) {
        True -> #([header_only(line), ..lines], section)
        False -> #([line, ..lines], section)
      }
    _, _ -> #([line, ..lines], section)
  }
}

/// A line that is not a header: dropped inside a `[credential]` section, and
/// elsewhere dropped only when it sets a key the scrub removes.
fn scrub_setting(
  lines: List(String),
  line: String,
  position: Position,
) -> #(List(String), Position) {
  // Comments and blank lines inside a kept section stay, because they are not
  // keys, and so do all lines before the first section.
  case position {
    Dropping -> #(lines, Dropping)
    Section(_) ->
      case drops_key(position, line) {
        True -> #(lines, position)
        False -> #([without_userinfo(line), ..lines], position)
      }
    Keeping -> #([line, ..lines], Keeping)
  }
}

/// A `url = ...` line with any `user:password@` removed from the URL's
/// authority. A remote written as `https://x:ghp_...@github.com/o/r` carries
/// a token, and under the guest's default read scope model code could read
/// it; the guest reaches GitHub through the credential proxy instead. Every
/// other line is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.without_userinfo("\turl = https://x:t@github.com/o/r")
///   == "\turl = https://github.com/o/r"
/// ```
pub fn without_userinfo(line: String) -> String {
  // Only a `url` key whose value has a scheme and an `@` before the path is
  // rewritten; anything else, scp-style `git@host:path` included, is not a
  // URL with userinfo and stays.
  let rewritten = {
    use #(key, value) <- result.try(string.split_once(line, "="))
    use Nil <- result.try(case string.lowercase(string.trim(key)) {
      "url" -> Ok(Nil)
      _ -> Error(Nil)
    })
    use #(scheme, rest) <- result.try(string.split_once(
      string.trim(value),
      "://",
    ))
    let #(authority, path) = case string.split_once(rest, "/") {
      Ok(#(authority, path)) -> #(authority, "/" <> path)
      Error(Nil) -> #(rest, "")
    }
    use host <- result.try(string.split(authority, "@") |> list.last)
    case string.contains(authority, "@") {
      True -> Ok(key <> "= " <> scheme <> "://" <> host <> path)
      False -> Error(Nil)
    }
  }
  result.unwrap(rewritten, line)
}

/// A section header's lowercased name, up to the first space or quote, and what
/// follows its last `]`. The last bracket closes it: a quoted subsection holds
/// a URL, and a URL does not hold a `]` that matters here.
fn section_header(line: String) -> Option(#(String, Remainder)) {
  let trimmed = string.trim(line)

  // Only a line that starts with a bracket is a header.
  case string.starts_with(trimmed, "[") {
    False -> None
    True -> {
      let inner = string.drop_start(trimmed, 1)
      Some(#(header_name(inner), remainder(inner)))
    }
  }
}

/// The section name at the start of a header's inside: the text before the
/// first space, quote or closing bracket, lowercased, as Git compares them.
fn header_name(inner: String) -> String {
  [" ", "\"", "]"]
  |> list.fold(inner, fn(name, separator) {
    string.split(name, separator) |> list.first |> result.unwrap("")
  })
  |> string.lowercase
}

/// What follows a header's last `]`, unless it is nothing or a comment.
fn remainder(inner: String) -> Remainder {
  // Splitting on `]` and reversing puts the text after the last bracket first,
  // and a header with no bracket has nothing after it.
  case list.reverse(string.split(inner, "]")) {
    [after, _, ..] -> trailing(string.trim(after))
    _ -> Nothing
  }
}

/// Whether the text after a header is a setting.
fn trailing(text: String) -> Remainder {
  let comment = string.starts_with(text, "#") || string.starts_with(text, ";")

  // A comment after a header is not a setting, so the line is a plain header.
  case text == "" || comment {
    True -> Nothing
    False -> Inline(text)
  }
}

/// A header line without what follows its last `]`.
fn header_only(line: String) -> String {
  case list.reverse(string.split(line, "]")) {
    [_, ..before] -> string.join(list.reverse(before), "]") <> "]"
    [] -> line
  }
}

/// Whether a line sets a key the scrub removes, given the section it is in.
fn drops_key(section: Position, line: String) -> Bool {
  let key =
    line
    |> string.split("=")
    |> list.first
    |> result.unwrap("")
    |> string.trim
    |> string.lowercase

  // `extraheader` carries a CI token in any section; the rewrite keys matter
  // only under `[url]`, where Git reads them.
  case section, key {
    _, "extraheader" -> True
    Section("url"), "insteadof" | Section("url"), "pushinsteadof" -> True
    _, _ -> False
  }
}

// --- the pid file and the epmd listing ---------------------------------------

/// The process `up` started: its pid and the platform's birth marker for it,
/// so a later signal reaches that process and never a recycled pid.
pub type PidRecord {
  PidRecord(pid: Int, birth: String)
}

/// The pid file's text.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.encode_pid(vm_spec.PidRecord(42, "birth")) == "42\nbirth\n"
/// ```
pub fn encode_pid(record: PidRecord) -> String {
  int.to_string(record.pid) <> "\n" <> record.birth <> "\n"
}

/// Reads the pid file's text.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.decode_pid("42\nbirth\n") == Ok(vm_spec.PidRecord(42, "birth"))
/// ```
pub fn decode_pid(text: String) -> Result(PidRecord, String) {
  case string.split(string.trim_end(text), "\n") {
    [pid, birth] if birth != "" ->
      case int.parse(pid) {
        Ok(number) if number > 1 -> Ok(PidRecord(pid: number, birth:))
        _ -> Error("the pid file does not hold a process id")
      }
    _ -> Error("the pid file is not a process id and a birth marker")
  }
}

/// The host port a node name is registered at in `epmd -names` output, or
/// `None` when it is not listed.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.registered_port("name a at port 4370\n", "a") == Some(4370)
/// ```
pub fn registered_port(listing: String, short: String) -> Option(Int) {
  let prefix = "name " <> short <> " at port "
  string.split(listing, "\n")
  |> list.find_map(fn(line) {
    case string.starts_with(line, prefix) {
      True ->
        int.parse(string.trim(string.drop_start(line, string.length(prefix))))
      False -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The tail of a log, at most `limit` characters, for an error that shows why a
/// guest did not start.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.tail("abcdef", 3) == "...def"
/// ```
pub fn tail(text: String, limit: Int) -> String {
  let trimmed = string.trim(text)
  let excess = string.length(trimmed) - limit

  // The ellipsis says the text was cut at the front.
  case excess > 0 {
    True -> "..." <> string.drop_start(trimmed, excess)
    False -> trimmed
  }
}
