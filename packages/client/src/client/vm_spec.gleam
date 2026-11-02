//// The decisions behind `loom vm setup | up | down | status | logs | list | rm |
//// sync`, with no effect in them.
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
//// - the extra egress hosts a guest may reach and the file that records them
////   (`valid_host`, `encode_allow`, `decode_allow`, `effective_allow`);
//// - whether a provisioning script is staged, retried or refused
////   (`provision_plan`) and how long the guest may take to report
////   (`boot_budget_ms`);
//// - which release `setup` installs and with what arguments (`release_candidates`,
////   `setup_attempts`, `setup_failure`);
//// - how a linked worktree's copy gets a repository of its own (`head_target`,
////   `clone_arguments`, `head_arguments`, `origin_arguments`);
//// - what a workspace copy may keep of its Git configuration
////   (`scrub_git_config`);
//// - what to tell the user about a daemon that read its configuration before
////   `up` changed it (`occupied_sessions`, `daemon_note`);
//// - how to read the two small records the command leaves behind and consults
////   later: its pid file (`encode_pid`, `decode_pid`) and the host epmd's
////   listing (`registered_port`);
//// - the daily verbs: what may be printed of text a guest wrote (`printable`),
////   the record of each workspace's developer checkout (`encode_checkouts`,
////   `decode_checkouts`), the Git command lines of `sync` (`fetch_arguments`,
////   `bundle_arguments`), the Git version `sync` requires (`git_version`,
////   `check_git_version`) and what `rm` undoes in the user's `loom.toml`
////   (`read_enrolment`, `plan_teardown`).
////
//// ## Flow
////
//// - `parse` turns `loom vm`'s words into a `Command`.
//// - `release_candidates` and `setup_attempts` say what `loom-vm setup` is asked,
////   and `setup_failure` what to say when none of it worked.
//// - `decode_manifest` reads the artifact manifest and `check_revision`
////   compares it with the running build.
//// - `names` derives the node names, `deployment_plan` the two-node plan, and
////   `guest_config` the executor's configuration file, with the tools table that
////   GitHub access needs.
//// - `launch_arguments` builds the `loom-vm run` command line.
//// - `valid_host`, `encode_allow`, `decode_allow` and `effective_allow` keep
////   the `--allow` list, and `provision_plan` and `boot_budget_ms` decide what
////   `--provision` does.
//// - `printable`, `decode_checkouts`, `only_workspace`, `fetch_arguments`,
////   `bundle_arguments` and `check_git_version` serve the commands that read a
////   guest's root and sync it; `read_enrolment` and `plan_teardown` decide what
////   removing a guest takes out of the user's configuration.
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
import core/json as core_json
import gleam/bool
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

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

/// Where `up` copies the provisioning script inside the guest root. The guest
/// init runs it as root, once, before the executor starts.
pub const provision_script = "/etc/loom-vm/provision"

/// The file the guest init creates when the provisioning script exits zero.
/// While it exists, a resumed guest does not run the script again.
pub const provision_marker = "/etc/loom-vm/provisioned"

/// The name of the file in a guest's directory that records its `--allow`
/// hosts, one per line.
pub const allow_file = "allow"

/// How long `up` waits for a guest that runs no provisioning script.
pub const ready_budget_ms = 120_000

/// How long `up` waits for a guest that runs a provisioning script, which may
/// install a toolchain over the network.
pub const provision_budget_ms = 1_800_000

/// The console line that says the executor serves.
pub const ready_marker = "LOOM-EXECUTOR-READY"

/// The console line that says the executor died, followed by its log.
pub const failed_marker = "LOOM-EXECUTOR-FAILED"

/// The console line that says the provisioning script failed, followed by its
/// exit status. The script's own output precedes it on the console.
pub const provision_failed_marker = "LOOM-PROVISION-FAILED"

/// How many lines `loom vm logs` prints when `--lines` is not given.
pub const default_log_lines = 100

/// The most lines `loom vm logs` will print.
pub const log_lines_limit = 100_000

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
    /// Hosts the guest may reach besides GitHub's, in the order given. Empty
    /// means `--allow` was not given, which is not the same as an empty
    /// recorded list on a resume (`effective_allow`).
    allow: List(String),
    /// The host path of the script `--provision` names.
    provision: Option(String),
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

/// Where `setup` gets the microVM artifacts from.
pub type SetupSource {
  /// The release of the running build: its tag follows from its version, and a
  /// development build has none.
  OwnRelease

  /// A named release tag, as `loom-vm setup --release` takes it.
  ReleaseTag(tag: String)

  /// A build tree, as `loom-vm setup --from-build` takes it.
  BuildTree(directory: String)
}

/// One of the commands.
pub type Command {
  /// Install the artifacts the guest boots from and write their manifest.
  Setup(SetupSource)

  /// Provision, stage and boot the guest.
  Up(UpOptions)

  /// Stop the guest named.
  Down(name: String)

  /// Report the guest named.
  Status(name: String)

  /// Print the end of the guest's console log.
  Logs(name: String, lines: Int)

  /// List the guests under the vm home, one line each.
  Guests

  /// Delete a stopped guest and undo its enrolment.
  Remove(name: String, config: Option(String), consent: Consent)

  /// Move committed work between the developer's checkout and a guest's copy.
  Sync(SyncOptions)
}

/// Whether the user said `--yes` to a deletion that cannot be undone.
pub type Consent {
  /// `--yes` was given.
  Confirmed

  /// The flag was not given, so the command lists what it would lose and
  /// stops.
  Unconfirmed
}

/// Which way `vm sync` moves commits.
pub type Direction {
  /// The guest's committed work arrives in the developer's checkout.
  FromGuest

  /// The developer's commits are bundled for the guest to fetch.
  ToGuest
}

/// What `loom vm sync` was asked.
pub type SyncOptions {
  SyncOptions(
    /// The guest's name.
    name: String,
    /// The workspace copy to sync, or `None` for the guest's only one.
    workspace: Option(String),
    /// The developer's checkout, overriding the one `up` recorded.
    checkout: Option(String),
    /// Which way the commits go.
    direction: Direction,
  )
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
    ["setup", ..flags] -> setup_flags(flags, OwnRelease) |> result.map(Setup)
    ["up", ..flags] -> {
      use options <- result.try(up_flags(flags, default_up()))
      use Nil <- result.try(valid_name(options.name))
      Ok(Up(options))
    }
    ["down", ..flags] -> name_flag(flags) |> result.map(Down)
    ["status", ..flags] -> name_flag(flags) |> result.map(Status)
    ["logs", ..flags] -> logs_flags(flags, default_name, default_log_lines)
    ["list"] -> Ok(Guests)
    ["list", word, ..] -> Error("unexpected argument " <> word)
    ["rm", ..flags] ->
      remove_flags(flags, Remove(default_name, None, Unconfirmed))
    ["sync", ..flags] ->
      sync_flags(flags, SyncOptions(default_name, None, None, FromGuest))
      |> result.map(Sync)
    [] ->
      Error(
        "loom vm needs a command: setup, up, down, status, logs, list, rm or sync",
      )
    [word, ..] -> Error("unknown loom vm command " <> word)
  }
}

/// Reads `setup`'s flags: at most one of `--release TAG` and `--from-build DIR`,
/// and neither means the running build's own release.
fn setup_flags(
  arguments: List(String),
  source: SetupSource,
) -> Result(SetupSource, String) {
  // The two sources exclude each other, so a second one is refused whichever
  // order they come in; the same flag twice is refused as well.
  case arguments, source {
    [], _ -> Ok(source)
    ["--release", tag, ..rest], OwnRelease -> setup_flags(rest, ReleaseTag(tag))
    ["--from-build", directory, ..rest], OwnRelease ->
      setup_flags(rest, BuildTree(directory))
    ["--release", _, ..], _ | ["--from-build", _, ..], _ ->
      Error("setup takes one of --release TAG and --from-build DIR")
    [flag], _ ->
      case string.starts_with(flag, "--") {
        True -> Error(flag <> " needs a value")
        False -> Error("unexpected argument " <> flag)
      }
    [word, ..], _ ->
      case string.starts_with(word, "--") {
        True -> Error("unknown option " <> word)
        False -> Error("unexpected argument " <> word)
      }
  }
}

/// The release tags that can hold the artifacts for a build, in the order to
/// try them, or the refusal a development build gets because it has no release
/// to install from.
///
/// A nightly build reports its release's version and its own commit, and is
/// published as the prerelease `commit-<full commit>`; the tagged release of
/// the same version is a different commit. So a commit of 40 hexadecimal
/// digits gives `commit-<commit>` first, and `v<version>` follows for a tagged
/// release, whose commit the tag does not repeat. A short or `unknown` commit
/// names no nightly.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.release_candidates("0.3.2", "unknown") == Ok(["v0.3.2"])
/// assert result.is_error(vm_spec.release_candidates("dev", "unknown"))
/// ```
pub fn release_candidates(
  version: String,
  commit: String,
) -> Result(List(String), String) {
  // The development version is the launcher's word for "no release metadata",
  // and an empty one is the same absence.
  use <- bool.guard(
    version == "dev" || version == "",
    Error(development_refusal),
  )

  // Only a commit that names a whole commit can name a nightly's tag.
  let nightly = case full_commit(commit) {
    True -> ["commit-" <> commit]
    False -> []
  }

  Ok(list.append(nightly, ["v" <> version]))
}

/// Whether text is a full SHA-1 commit name in lowercase hexadecimal.
fn full_commit(text: String) -> Bool {
  string.byte_size(text) == 40
  && list.all(string.to_graphemes(text), string.contains("0123456789abcdef", _))
}

const development_refusal =
  "this is a development build, which has no release to install the microVM artifacts from. Build them in a checkout of this tree and run `make vmm-install-dev`"

/// One `loom-vm setup` run `setup` may make.
pub type Attempt {
  Attempt(
    /// What the attempt installs, for the error that lists what was tried.
    name: String,
    /// The `loom-vm` arguments.
    arguments: List(String),
  )
}

/// The `loom-vm setup` runs for a source, in the order to try them, with the
/// guest home each writes to. A source naming a release or a tree is one
/// attempt; the running build's own release is one for each candidate tag,
/// each with `--revision` set to the running commit when it is known.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok([attempt]) =
///   vm_spec.setup_attempts(vm_spec.ReleaseTag("v1"), "0.3.2", "unknown", "/h")
/// assert attempt.arguments == ["setup", "--home", "/h", "--release", "v1"]
/// ```
pub fn setup_attempts(
  source: SetupSource,
  version: String,
  commit: String,
  home: String,
) -> Result(List(Attempt), String) {
  let base = ["setup", "--home", home]

  // Only the running build's own release needs its identity; the other two
  // sources name what to install. A tag guessed from the build must hold the
  // build's commit, so `loom-vm` is told the commit and refuses an image of
  // another one before it downloads or writes anything.
  case source {
    OwnRelease ->
      release_candidates(version, commit)
      |> result.map(
        list.map(_, fn(tag) {
          Attempt(
            tag,
            list.flatten([
              base,
              ["--release", tag],
              revision_flag(commit),
            ]),
          )
        }),
      )
    ReleaseTag(tag) -> Ok([Attempt(tag, list.append(base, ["--release", tag]))])
    BuildTree(directory) ->
      Ok([Attempt(directory, list.append(base, ["--from-build", directory]))])
  }
}

/// `--revision COMMIT` for a commit that names one, at least seven lowercase
/// hexadecimal digits, and nothing for `unknown` or an empty commit.
fn revision_flag(commit: String) -> List(String) {
  let hexadecimal =
    list.all(string.to_graphemes(commit), string.contains("0123456789abcdef", _))

  // Anything shorter is no commit name, and `loom-vm` would refuse it.
  case hexadecimal && string.byte_size(commit) >= 7 {
    True -> ["--revision", commit]
    False -> []
  }
}

/// The one-line error for a `setup` in which every attempt failed, naming each
/// with its reason. For the running build's own release it says the artifacts
/// may not be published yet and how to pick another release.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   vm_spec.setup_failure(vm_spec.OwnRelease, [#("v1", "status 1")]),
///   "v1: status 1",
/// )
/// ```
pub fn setup_failure(
  source: SetupSource,
  failures: List(#(String, String)),
) -> String {
  let tried =
    failures
    |> list.map(fn(failure) { failure.0 <> ": " <> one_line(failure.1) })
    |> string.join("; ")

  // Only a source chosen from the running build can be a wrong guess, so only
  // it gets the advice about another release.
  let hint = case source {
    OwnRelease ->
      ". The artifacts may not be published for this build yet; "
      <> "`loom vm setup --release TAG` picks another release of the same "
      <> "commit"
    ReleaseTag(_) | BuildTree(_) -> ""
  }

  "could not install the microVM artifacts (tried " <> tried <> ")" <> hint
}

fn one_line(text: String) -> String {
  text |> string.replace("\n", " ") |> string.trim
}

/// Why `up` or `status` found no manifest, with the way to make one. A
/// development build cannot install a release, so its words name the make
/// target instead of `loom vm setup`.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(vm_spec.missing_manifest("/h/manifest.json", "0.3.2"), "loom vm setup")
/// ```
pub fn missing_manifest(path: String, version: String) -> String {
  let installed =
    path <> " does not exist, so the microVM artifacts are not installed. "

  // A build with a release is told to install it; a development build is told
  // where its artifacts come from instead.
  case release_candidates(version, "unknown") {
    Ok(_) -> installed <> "Run `loom vm setup`."
    Error(reason) -> installed <> string.capitalise(reason) <> "."
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
    allow: [],
    provision: None,
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
    ["--allow", value, ..rest] -> {
      use Nil <- result.try(
        valid_host(value)
        |> result.map_error(fn(reason) { "--allow " <> reason }),
      )

      // A host named twice is one host, so the recorded file and the
      // launcher's argument list never repeat it.
      let allow = case list.contains(options.allow, value) {
        True -> options.allow
        False -> list.append(options.allow, [value])
      }

      up_flags(rest, UpOptions(..options, allow:))
    }
    ["--provision", value, ..rest] ->
      case value {
        "" -> Error("--provision needs the path of a script")
        _ -> up_flags(rest, UpOptions(..options, provision: Some(value)))
      }
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

// --- the egress allowlist ----------------------------------------------------

/// Whether text can be a host the guest's egress allowlist names: a bare
/// hostname, or a leading `*.` over a name of at least two labels. This is the
/// rule `machine.Spec.Validate` applies to the same entries, so `up` refuses
/// here what `loom-vm` would refuse after the root was cloned. Whitespace of
/// any kind is refused as well, because the recorded file holds one host per
/// line. The refusal is a clause that starts with the offending text, so a
/// caller can put a flag name before it.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.valid_host("deb.debian.org") == Ok(Nil)
/// assert vm_spec.valid_host("*.golang.org") == Ok(Nil)
/// assert result.is_error(vm_spec.valid_host("*.com"))
/// ```
pub fn valid_host(host: String) -> Result(Nil, String) {
  // The wildcard prefix is not part of the name the other checks judge.
  let name = case string.starts_with(host, "*.") {
    True -> string.drop_start(host, 2)
    False -> host
  }

  let wildcard = name != host
  let spaced =
    string.contains(name, " ")
    || string.contains(name, "\t")
    || string.contains(name, "\n")
    || string.contains(name, "\r")

  // The same three questions `checkHost` asks, in its order.
  case name == "", spaced || contains_any(name, ["*", "/", ":", "@"]) {
    True, _ -> Error("\"" <> host <> "\" is not a hostname")
    _, True -> Error("\"" <> host <> "\" is not a bare hostname")
    _, _ ->
      case wildcard && !string.contains(name, ".") {
        True ->
          Error(
            "\""
            <> host
            <> "\" covers a whole top-level domain; name at least two labels "
            <> "after \"*.\"",
          )
        False -> Ok(Nil)
      }
  }
}

/// Whether `text` holds any of the fragments.
fn contains_any(text: String, fragments: List(String)) -> Bool {
  list.any(fragments, string.contains(text, _))
}

/// The text of a guest's allow file: one host per line.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.encode_allow(["a.example.com", "b.example.com"])
///   == "a.example.com\nb.example.com\n"
/// ```
pub fn encode_allow(hosts: List(String)) -> String {
  list.map(hosts, fn(host) { host <> "\n" }) |> string.concat
}

/// Reads an allow file. Blank lines are skipped, and every other line must be
/// a host `valid_host` accepts; the first that is not is the error, with its
/// line number, so a hand-edited file is refused and never half-read.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.decode_allow("a.example.com\n\n") == Ok(["a.example.com"])
/// assert result.is_error(vm_spec.decode_allow("*.com\n"))
/// ```
pub fn decode_allow(text: String) -> Result(List(String), String) {
  let lines =
    string.split(text, "\n")
    |> list.index_map(fn(line, n) { #(n + 1, string.trim(line)) })

  // Each line is judged alone, and the hosts keep their order.
  list.try_fold(lines, [], fn(hosts, numbered) {
    let #(number, line) = numbered

    // A blank line and a repeated host add nothing; any other line is judged.
    case line, list.contains(hosts, line) {
      "", _ -> Ok(hosts)
      _, True -> Ok(hosts)
      _, False ->
        case valid_host(line) {
          Ok(Nil) -> Ok(list.append(hosts, [line]))
          Error(reason) ->
            Error("line " <> int.to_string(number) <> ": " <> reason)
        }
    }
  })
}

/// The hosts a guest is launched with beyond GitHub's. Hosts given on the
/// command line replace the recorded ones. With none given, a resume keeps the
/// recorded list and `--fresh` starts from none, as it does for the root.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.effective_allow([], ["a.example.com"], vm_spec.Resume)
///   == ["a.example.com"]
/// assert vm_spec.effective_allow([], ["a.example.com"], vm_spec.Fresh) == []
/// ```
pub fn effective_allow(
  given: List(String),
  recorded: List(String),
  freshness: Freshness,
) -> List(String) {
  case given, freshness {
    [_, ..], _ -> given
    [], Resume -> recorded
    [], Fresh -> []
  }
}

// --- the provisioning script -------------------------------------------------

/// What `up` finds in a guest root about an earlier provisioning, read from
/// the root before it is replaced or resumed.
pub type RootProvisioning {
  /// The marker is there: a script ran and exited zero.
  AlreadyProvisioned

  /// A script is staged and the marker is not: an earlier run failed or was
  /// interrupted, so the guest init runs it again.
  FailedBefore

  /// No script was ever staged in this root.
  NeverProvisioned
}

/// What `up` does about the provisioning script.
pub type ProvisionPlan {
  /// Nothing runs: no script, or one the marker says already succeeded.
  NoScript

  /// Copy the script at this host path into the root; the init runs it.
  StageScript(host_path: String)

  /// The root holds a script an earlier `up` staged and did not finish.
  RetryStaged
}

/// Decides what `--provision` and the root's history mean together. A script
/// given for a guest that already succeeded is refused, because a resume must
/// not run it again; `--fresh` is the way to run a new one, and it replaces the
/// root, so the caller passes `NeverProvisioned` for it.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.provision_plan(None, vm_spec.AlreadyProvisioned)
///   == Ok(vm_spec.NoScript)
/// assert result.is_error(
///   vm_spec.provision_plan(Some("/s.sh"), vm_spec.AlreadyProvisioned),
/// )
/// ```
pub fn provision_plan(
  requested: Option(String),
  seen: RootProvisioning,
) -> Result(ProvisionPlan, String) {
  case requested, seen {
    Some(_), AlreadyProvisioned ->
      Error(
        "--provision: this guest was provisioned already and a resume does "
        <> "not run a script again. Add --fresh to replace the guest and run "
        <> "the script on the new one.",
      )
    Some(path), _ -> Ok(StageScript(path))
    None, FailedBefore -> Ok(RetryStaged)
    None, AlreadyProvisioned | None, NeverProvisioned -> Ok(NoScript)
  }
}

/// How long `up` waits for the guest's console to report. A script that runs
/// delays the executor's start by as long as it takes.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.boot_budget_ms(vm_spec.NoScript) == vm_spec.ready_budget_ms
/// ```
pub fn boot_budget_ms(plan: ProvisionPlan) -> Int {
  case plan {
    NoScript -> ready_budget_ms
    StageScript(_) | RetryStaged -> provision_budget_ms
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

/// Reads `logs`'s flags: a name and a line count.
fn logs_flags(
  arguments: List(String),
  name: String,
  lines: Int,
) -> Result(Command, String) {
  // Each arm takes one flag and its value, so the flags come in any order.
  case arguments {
    [] -> Ok(Logs(name, lines))
    ["--name", value, ..rest] -> {
      use Nil <- result.try(valid_name(value))
      logs_flags(rest, value, lines)
    }
    ["--lines", value, ..rest] -> {
      use lines <- result.try(bounded("--lines", value, 1, log_lines_limit))
      logs_flags(rest, name, lines)
    }
    _ -> unknown_flag(arguments)
  }
}

/// Reads `rm`'s flags: a name, a configuration file and `--yes`.
fn remove_flags(
  arguments: List(String),
  command: Command,
) -> Result(Command, String) {
  // The command always holds a `Remove`; the arms below rebuild it.
  case arguments, command {
    [], _ -> Ok(command)
    ["--name", value, ..rest], Remove(_, config, consent) -> {
      use Nil <- result.try(valid_name(value))
      remove_flags(rest, Remove(value, config, consent))
    }
    ["--config", value, ..rest], Remove(name, _, consent) ->
      remove_flags(rest, Remove(name, Some(value), consent))
    ["--yes", ..rest], Remove(name, config, _) ->
      remove_flags(rest, Remove(name, config, Confirmed))
    _, _ -> unknown_flag(arguments)
  }
}

/// Reads `sync`'s flags.
fn sync_flags(
  arguments: List(String),
  options: SyncOptions,
) -> Result(SyncOptions, String) {
  // Each arm takes one flag and recurses on the rest, as `up_flags` does.
  case arguments {
    [] -> Ok(options)
    ["--name", value, ..rest] -> {
      use Nil <- result.try(valid_name(value))
      sync_flags(rest, SyncOptions(..options, name: value))
    }
    ["--workspace", value, ..rest] -> {
      use Nil <- result.try(valid_workspace_name(value))
      sync_flags(rest, SyncOptions(..options, workspace: Some(value)))
    }
    ["--checkout", value, ..rest] ->
      sync_flags(rest, SyncOptions(..options, checkout: Some(value)))

    // The one flag with no value: the direction is a choice, not a setting.
    ["--to-guest", ..rest] ->
      sync_flags(rest, SyncOptions(..options, direction: ToGuest))
    _ -> unknown_flag(arguments)
  }
}

/// The refusal for the first word of `arguments` that no flag arm took.
fn unknown_flag(arguments: List(String)) -> Result(a, String) {
  case arguments {
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
    [] -> Error("unexpected end of the command line")
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
        <> "Install the artifacts for this release with `loom vm setup`, or "
        <> "with `make vmm-install-dev` in a checkout of it.",
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

/// The workspaces the guest's configuration registers: the ones the host's own
/// `checkouts` record names whose copies are in the root (`recorded`), and the
/// one this `up` copies, each once, sorted. The guest's root is never listed
/// for this, because it is untrusted.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.registered_workspaces(["b", "a"], "c") == ["a", "b", "c"]
/// assert vm_spec.registered_workspaces(["a"], "a") == ["a"]
/// ```
pub fn registered_workspaces(
  recorded: List(String),
  current: String,
) -> List(String) {
  list.sort(list.unique([current, ..recorded]), string.compare)
}

/// The executor's `loom.toml`, written with guest paths only.
///
/// The model table is one every daemon's configuration carries and an
/// executor never uses: it opens no session. Each of `workspaces` is a name a
/// copy is registered under; its root is `workspaces_dir/<name>`.
///
/// ## Examples
///
/// ```gleam
/// let text = vm_spec.guest_config(executor_bundle, ["proj"], vm_spec.GitHubOff, [])
/// assert string.contains(text, "[workspaces.proj]")
/// ```
pub fn guest_config(
  bundle: Bundle,
  workspaces: List(String),
  github: GitHubAccess,
  allow: List(String),
) -> String {
  let tables =
    distribution_bundle.config_tables(bundle, guest_files())
    |> list.map(fn(table) { table.text })

  // The executor's own tables come from the bundle, so its node name, its
  // listen port and its trust in the orchestrator are what the plan said. The
  // workspace rows are the one thing the plan leaves to `up`.
  string.join(
    list.flatten([
      [unused_model],
      tables,
      list.map(workspaces, fn(workspace) {
        "[workspaces."
        <> distribution_bundle.toml_key(workspace)
        <> "]\nroot = "
        <> distribution_bundle.toml_string(workspaces_dir <> "/" <> workspace)
        <> "\n"
      }),
      tools_table(github, allow),
    ]),
    "\n",
  )
}

/// The executor's `[tools]` table. With GitHub access or an allowed host the
/// jail's network is on, because the guest's egress allowlist, enforced by the
/// launcher's host side stack, is now the boundary. With GitHub access the
/// proxy's names also pass the environment allowlist; allowed hosts alone have
/// no proxy and need none. With neither the table is absent and the jail keeps
/// the network off.
fn tools_table(github: GitHubAccess, allow: List(String)) -> List(String) {
  // Both token sources need the same guest-side configuration.
  case github, allow {
    GitHubOff, [] -> []
    GitHubOff, [_, ..] -> ["[tools]\nnetwork = \"full\"\n"]
    GitHubFromGh, _ | GitHubFromEnv, _ -> [
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
    /// The hosts the guest may reach besides GitHub's. They are allowed and
    /// never injection hosts: nothing here reaches `--inject-host`.
    allow: List(String),
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
  // The header must start a line, so a commented `#[distribution]` does not
  // take the key.
  let header = "[distribution]\n"

  // The header either opens the file or follows a newline.
  let anchored = case string.starts_with(text, header) {
    True -> Ok(#("", string.drop_start(text, string.length(header))))
    False ->
      string.split_once(text, "\n" <> header)
      |> result.map(fn(parts) { #(parts.0 <> "\n", parts.1) })
  }

  // A file that already names a listener keeps the operator's choice.
  case string.contains(text, "listen_address"), anchored {
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
  // `loom-vm` starts the credential proxy; without it the allowlist holds only
  // what `--allow` named. The proxy admits exactly the allowlist, so an allowed
  // host is tunnelled for a client that honours `HTTPS_PROXY` and is reachable
  // directly for one that does not.
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
    list.flat_map(launch.allow, fn(host) { ["--allow", host] }),
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

    // A `[url "https://user:token@host/"]` header holds the credential in
    // its subsection name; its keys are the rewrite keys the scrub drops
    // anyway, so the whole section goes.
    "url", _ ->
      case has_userinfo(line) {
        True -> #(lines, Dropping)
        False -> scrub_url_header(lines, line, section, rest)
      }
    _, _ -> #([line, ..lines], section)
  }
}

/// A `[url]` header without userinfo: kept, losing an inline setting the
/// scrub removes.
fn scrub_url_header(
  lines: List(String),
  line: String,
  section: Position,
  rest: Remainder,
) -> #(List(String), Position) {
  // Only an inline `insteadOf` changes the line; a bare header is kept.
  case rest {
    Inline(setting) ->
      case drops_key(section, setting) {
        True -> #([header_only(line), ..lines], section)
        False -> #([line, ..lines], section)
      }
    Nothing -> #([line, ..lines], section)
  }
}

/// Whether a line holds a URL with userinfo: an `@` after `://` and before
/// the next `/`.
fn has_userinfo(line: String) -> Bool {
  // Without a scheme there is no URL authority to hold userinfo.
  string.split_once(line, "://")
  |> result.map(fn(parts) { string.contains(split_authority(parts.1).0, "@") })
  |> result.unwrap(False)
}

/// Splits what follows a URL's `://` into its authority and its path, the
/// path keeping its leading `/` and empty when there is none.
fn split_authority(rest: String) -> #(String, String) {
  // An authority with no path runs to the end of the text.
  case string.split_once(rest, "/") {
    Ok(#(authority, path)) -> #(authority, "/" <> path)
    Error(Nil) -> #(rest, "")
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
    let name = string.lowercase(string.trim(key))
    use <- bool.guard(name != "url" && name != "pushurl", Error(Nil))
    use #(scheme, rest) <- result.try(string.split_once(
      string.trim(value),
      "://",
    ))
    let #(authority, path) = split_authority(rest)
    use <- bool.guard(!string.contains(authority, "@"), Error(Nil))
    use host <- result.try(string.split(authority, "@") |> list.last)
    Ok(key <> "= " <> scheme <> "://" <> host <> path)
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

// --- a linked worktree's repository ------------------------------------------

/// Where a linked worktree's `HEAD` points, which its standalone copy must
/// keep pointing at.
pub type HeadTarget {
  /// A branch: the full ref name and the commit it holds.
  OnBranch(ref: String, commit: String)

  /// A commit with no branch.
  Detached(commit: String)
}

/// What `git rev-parse --symbolic-full-name HEAD` and `git rev-parse --verify
/// HEAD` said about a worktree, as the `HEAD` to give its copy.
///
/// The first answers `refs/heads/<branch>` on a branch and `HEAD` when
/// detached. A ref outside `refs/heads/`, an object name that is not a full
/// hexadecimal one, or a ref holding whitespace is refused rather than passed
/// to Git as an argument.
///
/// ## Examples
///
/// ```gleam
/// let commit = string.repeat("a", 40)
/// assert vm_spec.head_target("refs/heads/main\n", commit <> "\n")
///   == Ok(vm_spec.OnBranch("refs/heads/main", commit))
/// assert vm_spec.head_target("HEAD\n", commit) == Ok(vm_spec.Detached(commit))
/// ```
pub fn head_target(
  symbolic: String,
  commit: String,
) -> Result(HeadTarget, String) {
  let ref = string.trim(symbolic)
  let commit = string.trim(commit)
  let hexadecimal =
    list.all(string.to_graphemes(commit), string.contains("0123456789abcdef", _))
  let length = string.byte_size(commit)

  // A SHA-1 or SHA-256 object name is the only commit text Git is handed.
  use Nil <- result.try(case hexadecimal && { length == 40 || length == 64 } {
    True -> Ok(Nil)
    False -> Error("the worktree's HEAD is not a commit name")
  })

  // `HEAD` is Git's answer for a detached head; any other answer must be a
  // branch ref of the plain kind.
  case ref {
    "HEAD" -> Ok(Detached(commit))
    _ ->
      case
        string.starts_with(ref, "refs/heads/")
        && !string.contains(ref, " ")
        && !string.contains(ref, "\t")
      {
        True -> Ok(OnBranch(ref, commit))
        False -> Error("the worktree's HEAD is not a branch or a commit")
      }
  }
}

/// The `git` arguments that make a standalone repository from a worktree
/// without checking anything out. `--no-local` makes Git copy the objects over
/// its own transport instead of linking or copying the source's object
/// directory, which also leaves out an `objects/info/alternates` file naming
/// host paths that a source made with `git clone --shared` carries.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.clone_arguments("/w", "/s")
///   == ["clone", "--quiet", "--no-checkout", "--no-local", "/w", "/s"]
/// ```
pub fn clone_arguments(source: String, into: String) -> List(String) {
  ["clone", "--quiet", "--no-checkout", "--no-local", source, into]
}

/// The `git` commands, each run in the copy, that point its `HEAD` where the
/// worktree's pointed. The clone's `HEAD` is the source's own when the source
/// has a branch, but a detached commit no branch holds is not fetched, so the
/// copy is told rather than trusted.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.head_arguments(vm_spec.Detached(commit))
///   == [["update-ref", "--no-deref", "HEAD", commit]]
/// ```
pub fn head_arguments(target: HeadTarget) -> List(List(String)) {
  case target {
    Detached(commit) -> [["update-ref", "--no-deref", "HEAD", commit]]
    OnBranch(ref, commit) -> [
      ["update-ref", ref, commit],
      ["symbolic-ref", "HEAD", ref],
    ]
  }
}

/// The `git` arguments that give the copy the worktree's own `origin`, or none.
/// The clone made one that names the host path of the worktree, which the guest
/// must not keep. The URL is the repository's configuration as written, and
/// `scrub_git_config` removes any userinfo from it afterwards.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.origin_arguments("https://github.com/o/r\n")
///   == ["remote", "set-url", "origin", "https://github.com/o/r"]
/// assert vm_spec.origin_arguments("\n") == ["remote", "remove", "origin"]
/// ```
pub fn origin_arguments(url: String) -> List(String) {
  case string.trim(url) {
    "" -> ["remote", "remove", "origin"]
    found -> ["remote", "set-url", "origin", found]
  }
}

/// The refusal for a Git step that failed while a worktree's copy was being
/// given a repository of its own: one line, with what was being done.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(vm_spec.git_refusal("/w", "git exited with status 128"), "/w")
/// ```
pub fn git_refusal(worktree: String, reason: String) -> String {
  worktree
  <> " is a Git worktree and its copy could not be given a repository of its "
  <> "own: "
  <> reason
  <> ". Nothing was copied into the guest."
}

// --- the daemon that was running before `up` -----------------------------------

/// What a running daemon said about the sessions it holds.
pub type Sessions {
  /// The daemon's `status` reply gave a count.
  Counted(count: Int)

  /// The daemon did not answer, or answered something with no count.
  Uncounted
}

/// What `up` does about a running daemon, decided from what it said.
pub type DaemonStep {
  /// Ask the daemon to drain and wait for its process to go.
  StopIt

  /// Leave the daemon running, with the outcome to report.
  LeaveAlone(outcome: DaemonOutcome)
}

/// How `up` left the user's daemon, for its closing note.
pub type DaemonOutcome {
  /// No daemon was running, so the next `loom` command starts one.
  NoDaemon

  /// A daemon held no session and was stopped.
  Stopped

  /// A daemon held no session and was not stopped, for the reason given.
  NotStopped(pid: Int, why: String)

  /// A daemon holds `sessions` resident, opening, stopping or blocked ones.
  Holding(pid: Int, sessions: Int)

  /// A daemon runs and did not say how many sessions it holds.
  Unasked(pid: Int)
}

/// Whether to stop the daemon with `pid`, given what it said. Only a daemon
/// that reports no session is stopped; one that holds any, or that said
/// nothing, is left running, so a daemon's work is never ended on a guess.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.daemon_step(7, vm_spec.Counted(0)) == vm_spec.StopIt
/// assert vm_spec.daemon_step(7, vm_spec.Counted(2))
///   == vm_spec.LeaveAlone(vm_spec.Holding(7, 2))
/// ```
pub fn daemon_step(pid: Int, sessions: Sessions) -> DaemonStep {
  case sessions {
    Counted(0) -> StopIt
    Counted(count) -> LeaveAlone(Holding(pid, count))
    Uncounted -> LeaveAlone(Unasked(pid))
  }
}

/// The number of sessions a daemon's `status` reply says it holds: the ones
/// resident, opening, stopping or blocked, which is its `occupied` count.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.occupied_sessions(json.Object([#("occupied", json.Int(2))])) == Ok(2)
/// ```
pub fn occupied_sessions(body: core_json.JsonValue) -> Result(Int, String) {
  case body {
    core_json.Object(fields) ->
      case list.key_find(fields, "occupied") {
        Ok(core_json.Int(count)) if count >= 0 -> Ok(count)
        _ -> Error("the daemon's status has no session count")
      }
    _ -> Error("the daemon's status is not an object")
  }
}

/// The `kill` command that asks the daemon with `pid` to stop gracefully.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.stop_command(4242) == "kill -TERM 4242"
/// ```
pub fn stop_command(pid: Int) -> String {
  "kill -TERM " <> int.to_string(pid)
}

/// The lines `up` ends with about the daemon.
///
/// A daemon that holds any session is never stopped for the user: the note
/// names the exact command instead. A stopped daemon is started again by the
/// next `loom` command, which renders the TLS options file the new
/// `[distribution]` table needs (protocol-change/106).
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.daemon_note(vm_spec.NoDaemon) != []
/// ```
pub fn daemon_note(outcome: DaemonOutcome) -> List(String) {
  let reason =
    "It read its configuration before the [distribution] table was installed, "
    <> "so it must restart to use the guest."

  // Each outcome is one thing said, and only a daemon that is still running
  // gets the command that stops it.
  case outcome {
    NoDaemon -> [
      "The next `loom` command starts the daemon with the table in effect.",
      "",
    ]
    Stopped -> [
      "Your daemon held no sessions, so it was stopped. The next `loom` "
        <> "command starts it with the table in effect.",
      "",
    ]
    NotStopped(pid, why) -> [
      "Your daemon holds no sessions but did not stop ("
        <> why
        <> "). "
        <> reason,
      "Stop it with: " <> stop_command(pid),
      "",
    ]
    Holding(pid, sessions) -> [
      "Your daemon holds "
        <> int.to_string(sessions)
        <> " session"
        <> plural(sessions)
        <> ", so it was left running. "
        <> reason,
      "When they are finished, stop it with: " <> stop_command(pid),
      "",
    ]
    Unasked(pid) -> [
      "Your daemon is running and did not say whether it holds sessions, so "
        <> "it was left running. "
        <> reason,
      "When it holds none, stop it with: " <> stop_command(pid),
      "",
    ]
  }
}

fn plural(count: Int) -> String {
  case count {
    1 -> ""
    _ -> "s"
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

// --- text a guest wrote ------------------------------------------------------

/// `text` with every character that could steer a terminal removed. A guest's
/// root is written by model-influenced code, so a log line, a ref name or a
/// directory name read from it is untrusted input to the host, and an escape
/// sequence in it could rewrite the screen or the title. Newlines stay, a tab
/// becomes a space, and the other C0 and C1 controls, DEL and the bidirectional
/// overrides are dropped.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.printable("ok\u{1b}[31m\r\nnext\ttab") == "ok[31m\nnext tab"
/// ```
pub fn printable(text: String) -> String {
  string.replace(text, "\t", " ")
  |> string.to_utf_codepoints
  |> list.filter(fn(point) {
    printable_code(string.utf_codepoint_to_int(point))
  })
  |> string.from_utf_codepoints
}

/// Whether a code point may reach a terminal.
fn printable_code(code: Int) -> Bool {
  let control = code < 0x20 || code == 0x7F || { code >= 0x80 && code <= 0x9F }
  let bidirectional =
    { code >= 0x202A && code <= 0x202E } || { code >= 0x2066 && code <= 0x2069 }

  // A newline is the one control character a multi-line report needs.
  code == 0x0A || { !control && !bidirectional }
}

// --- where a workspace came from ---------------------------------------------

/// The name of the file in a guest's directory that records the developer's
/// checkout of each workspace copy, one `NAME<TAB>PATH` line each. It lives
/// beside the root and never inside it, because the guest can write the root.
pub const checkouts_file = "checkouts"

/// Whether a path can be recorded: absolute, and free of control characters,
/// because the record holds one path per line after a tab.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.valid_checkout_path("/src/proj") == Ok(Nil)
/// assert result.is_error(vm_spec.valid_checkout_path("proj"))
/// ```
pub fn valid_checkout_path(path: String) -> Result(Nil, String) {
  let clean =
    string.to_utf_codepoints(path)
    |> list.all(fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code >= 0x20 && code != 0x7F
    })

  // The refusal names what to change, because the path comes from the
  // directory the user chose.
  case string.starts_with(path, "/") && clean {
    True -> Ok(Nil)
    False ->
      Error(
        "the checkout path \""
        <> printable(path)
        <> "\" must be absolute and hold no control characters",
      )
  }
}

/// The text of a checkouts record: a `NAME<TAB>PATH` line per workspace.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.encode_checkouts([#("proj", "/src/proj")])
///   == "proj\t/src/proj\n"
/// ```
pub fn encode_checkouts(entries: List(#(String, String))) -> String {
  list.map(entries, fn(entry) { entry.0 <> "\t" <> entry.1 <> "\n" })
  |> string.concat
}

/// Reads a checkouts record. Blank lines are skipped, every other line must be
/// a valid workspace name, a tab and a valid path, and the first that is not
/// is the error with its number, so a damaged record is refused and never
/// half-read. A name that appears twice keeps its last path.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.decode_checkouts("proj\t/src/proj\n") == Ok([#("proj", "/src/proj")])
/// assert result.is_error(vm_spec.decode_checkouts("proj /src/proj\n"))
/// ```
pub fn decode_checkouts(
  text: String,
) -> Result(List(#(String, String)), String) {
  let lines =
    string.split(text, "\n")
    |> list.index_map(fn(line, n) { #(n + 1, line) })

  // Each line is judged alone, in order, so a later line replaces an earlier
  // one of the same workspace.
  list.try_fold(lines, [], fn(entries, numbered) {
    let #(number, line) = numbered
    let at = "line " <> int.to_string(number) <> ": "

    // A blank line adds nothing; any other must be a name, a tab, a path.
    case string.trim(line) {
      "" -> Ok(entries)
      _ ->
        case string.split_once(line, "\t") {
          Error(Nil) -> Error(at <> "expected NAME, a tab and PATH")
          Ok(#(name, path)) -> {
            use Nil <- result.try(
              valid_workspace_name(name)
              |> result.map_error(fn(reason) { at <> reason }),
            )
            use Nil <- result.try(
              valid_checkout_path(path)
              |> result.map_error(fn(reason) { at <> reason }),
            )
            Ok(record_checkout(entries, name, path))
          }
        }
    }
  })
}

/// `entries` with `workspace` recorded at `path`, replacing an earlier path
/// for the same workspace.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.record_checkout([#("a", "/x")], "a", "/y") == [#("a", "/y")]
/// ```
pub fn record_checkout(
  entries: List(#(String, String)),
  workspace: String,
  path: String,
) -> List(#(String, String)) {
  list.append(list.filter(entries, fn(entry) { entry.0 != workspace }), [
    #(workspace, path),
  ])
}

/// The checkout recorded for `workspace`, if there is one.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.checkout_of([#("a", "/x")], "a") == Some("/x")
/// ```
pub fn checkout_of(
  entries: List(#(String, String)),
  workspace: String,
) -> Option(String) {
  list.key_find(entries, workspace) |> option.from_result
}

// --- sync --------------------------------------------------------------------

/// Where, inside the guest, `sync --to-guest` puts the bundle of the host's
/// commits.
pub const host_refs_dir = "/srv/host-refs"

/// The guest path of the bundle `sync --to-guest` writes for a workspace.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.bundle_guest_path("proj") == "/srv/host-refs/proj.bundle"
/// ```
pub fn bundle_guest_path(workspace: String) -> String {
  host_refs_dir <> "/" <> workspace <> ".bundle"
}

/// The command to run in the guest to take the host's branches from the bundle
/// as `refs/remotes/host/*`.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.guest_fetch_command("proj")
///   == "git fetch /srv/host-refs/proj.bundle '+refs/heads/*:refs/remotes/host/*'"
/// ```
pub fn guest_fetch_command(workspace: String) -> String {
  "git fetch "
  <> bundle_guest_path(workspace)
  <> " '+refs/heads/*:refs/remotes/host/*'"
}

/// The `git` arguments that fetch a guest copy's branches into the developer's
/// checkout as `refs/remotes/vm/*`.
///
/// The repository is the developer's checkout and the guest's copy is only the
/// remote. A guest's root is written by model-influenced code, so nothing here
/// runs Git with its working directory inside it: a planted `.git/config` could
/// run commands through `core.fsmonitor`, `core.sshCommand`, `core.hooksPath`
/// and others. Git's local transport does start `git-upload-pack` on the copy,
/// which reads the copy's configuration; `uploadpack.packObjectsHook` is
/// honoured only from protected configuration, and `docs/architecture/microvm.md`
/// records the hostile configuration this was tried against. Objects are
/// checked as they arrive (both `fetch.fsckObjects` and `transfer.fsckObjects`,
/// because the first overrides the second), tags and submodules are not
/// followed, the developer's own hooks do not run, and no background
/// maintenance is left running after the command.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(
///   vm_spec.fetch_arguments("/src/proj", "/vm/root/srv/workspaces/proj"),
///   "--no-tags",
/// )
/// ```
pub fn fetch_arguments(checkout: String, copy: String) -> List(String) {
  [
    "-C", checkout, "-c", "transfer.fsckObjects=true", "-c",
    "fetch.fsckObjects=true", "-c", "core.hooksPath=/dev/null", "-c",
    "maintenance.auto=false", "fetch", "--no-tags", "--no-recurse-submodules",
    copy, "+refs/heads/*:refs/remotes/vm/*",
  ]
}

/// The `git` arguments that bundle the local branches of the developer's
/// checkout into `file`. `--branches` and not `--all`, so the stash,
/// remote-tracking refs, notes and tags stay on the host.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.bundle_arguments("/src/proj", "/vm/x.bundle")
///   == ["-C", "/src/proj", "bundle", "create", "--quiet", "/vm/x.bundle", "--branches"]
/// ```
pub fn bundle_arguments(checkout: String, file: String) -> List(String) {
  ["-C", checkout, "bundle", "create", "--quiet", file, "--branches"]
}

/// The Git releases `sync` fetches with, as words for a refusal. The fetch's
/// `-c` settings do not reach `git-upload-pack`, because the local transport
/// unsets `GIT_CONFIG_PARAMETERS` for it, so what stops a copy's planted
/// `extensions.partialclone`, promisor remote and `core.sshCommand` from running
/// a command on the host is upload-pack's own refusal to lazy fetch. That is
/// Git commit 7b70e9efb18c, which reached each maintained series at the patch
/// `refuses_lazy_fetch` names.
const git_required =
  "2.45.1 or newer, or 2.39.4, 2.40.2, 2.41.1, 2.42.2, 2.43.4 or 2.44.1 in those series"

/// The version in the output of `git version`, such as `git version 2.54.0
/// (Apple Git-155)` or `git version 2.46.0.windows.1`: the first three numbers
/// of the first word after `git version`, a missing patch being zero and a
/// suffix such as `-rc1` ignored.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.git_version("git version 2.54.0 (Apple Git-155)\n") == Ok(#(2, 54, 0))
/// ```
pub fn git_version(output: String) -> Result(#(Int, Int, Int), Nil) {
  use rest <- result.try(
    string.split_once(string.trim(output), "git version ")
    |> result.map(fn(parts) { parts.1 }),
  )

  // The version is the word after `git version`; a build suffix follows it.
  let word = case string.split_once(rest, " ") {
    Ok(#(first, _)) -> first
    Error(Nil) -> rest
  }

  // Each dotted part contributes its leading digits.
  case list.map(string.split(word, "."), leading_int) {
    [Ok(major), Ok(minor), Ok(patch), ..] -> Ok(#(major, minor, patch))
    [Ok(major), Ok(minor)] -> Ok(#(major, minor, 0))
    _ -> Error(Nil)
  }
}

/// Whether a Git release holds upload-pack's refusal to lazy fetch.
fn refuses_lazy_fetch(version: #(Int, Int, Int)) -> Bool {
  let #(major, minor, patch) = version

  // The fix landed in 2.45.1 and was backported, so each older series has its
  // own first release that holds it, and a series before 2.39 has none.
  case major, minor {
    2, 39 -> patch >= 4
    2, 40 -> patch >= 2
    2, 41 -> patch >= 1
    2, 42 -> patch >= 2
    2, 43 -> patch >= 4
    2, 44 -> patch >= 1
    2, 45 -> patch >= 1
    2, _ -> minor > 45
    _, _ -> major > 2
  }
}

/// The leading decimal digits of `text` as a number.
fn leading_int(text: String) -> Result(Int, Nil) {
  string.to_graphemes(text)
  |> list.take_while(string.contains("0123456789", _))
  |> string.concat
  |> int.parse
}

/// Whether the output of `git version` names a Git that `sync` may fetch with:
/// one line naming the version found and the one required otherwise.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.check_git_version("git version 2.45.1\n") == Ok(Nil)
/// assert result.is_error(vm_spec.check_git_version("git version 2.45.0\n"))
/// ```
pub fn check_git_version(output: String) -> Result(Nil, String) {
  let required = git_required
  let found = printable(string.trim(output))

  // A version that cannot be read is refused as if it were old.
  case git_version(output) {
    Ok(#(major, minor, patch)) ->
      case refuses_lazy_fetch(#(major, minor, patch)) {
        True -> Ok(Nil)
        False ->
          Error(
            "git "
            <> int.to_string(major)
            <> "."
            <> int.to_string(minor)
            <> "."
            <> int.to_string(patch)
            <> " is too old for `loom vm sync`, which needs git "
            <> required
            <> " to fetch from an untrusted repository safely",
          )
      }
    Error(Nil) ->
      Error(
        "cannot read a version from \""
        <> found
        <> "\"; `loom vm sync` needs git "
        <> required
        <> " or newer",
      )
  }
}

/// The most bytes of the console log `logs` prints, taken from the end.
pub const log_bytes_limit = 4_194_304

/// The shell script `logs` runs with the line count as `$1` and the log as
/// `$2`: the last lines, at most `log_bytes_limit` bytes of them, with what is
/// not UTF-8 dropped. A guest writes the console, so one line may be any size,
/// and the byte cap is applied before the text reaches the BEAM.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(vm_spec.log_tail_script(), "tail -c 4194304")
/// ```
pub fn log_tail_script() -> String {
  "tail -n \"$1\" \"$2\" | tail -c "
  <> int.to_string(log_bytes_limit)
  <> " | iconv -c -f UTF-8 -t UTF-8 || true"
}

/// The workspace `sync` acts on: the one asked for when the guest holds it,
/// or the guest's only one. `held` is the names of the guest's copies.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.only_workspace(["proj"], None) == Ok("proj")
/// assert result.is_error(vm_spec.only_workspace(["a", "b"], None))
/// ```
pub fn only_workspace(
  held: List(String),
  asked: Option(String),
) -> Result(String, String) {
  case asked, held {
    Some(name), _ ->
      case list.contains(held, name) {
        True -> Ok(name)
        False ->
          Error(
            "the guest holds no workspace "
            <> name
            <> " ("
            <> held_names(held)
            <> ")",
          )
      }
    None, [only] -> Ok(only)
    None, [] -> Error("the guest holds no workspace copy yet")
    None, _ ->
      Error(
        "the guest holds several workspaces ("
        <> held_names(held)
        <> "); name one with --workspace",
      )
  }
}

/// The names a guest holds, for a message.
fn held_names(held: List(String)) -> String {
  case held {
    [] -> "none"
    _ -> "it holds " <> string.join(held, ", ")
  }
}

/// What `rm` says when it was not given `--yes`: the workspace copies that
/// would be lost, and the way to go on. A listing that failed is said as such.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(vm_spec.removal_refusal("vm", Ok(["proj"])), "--yes")
/// ```
pub fn removal_refusal(
  name: String,
  copies: Result(List(String), String),
) -> String {
  // A guest with no copy, or whose copies cannot be listed, says so.
  let held = case copies {
    Ok([]) -> ["  no workspace copy"]
    Ok(names) -> list.map(names, fn(workspace) { "  " <> printable(workspace) })
    Error(reason) -> ["  unreadable (" <> printable(reason) <> ")"]
  }

  string.join(
    list.flatten([
      [
        "Deleting the guest "
        <> name
        <> " is permanent: its root, its state disk and every copy of a "
        <> "workspace in it are lost, and work that is not pushed is gone. "
        <> "It holds:",
      ],
      held,
      [
        "Fetch committed work first with `loom vm sync`; uncommitted edits "
        <> "cannot be fetched. Run again with --yes to delete it.",
      ],
    ]),
    "\n",
  )
}

// --- undoing an enrolment ----------------------------------------------------

/// What a `loom.toml` says about one guest's enrolment.
pub type Enrolment {
  Enrolment(
    /// The `node` of the `[executors.<name>]` table, when there is one.
    executor_node: Option(String),
    /// The `node` of the `[distribution]` table, when there is one.
    distribution_node: Option(String),
    /// The names of the other `[executors.*]` tables.
    other_executors: List(String),
  )
}

/// Reads the enrolment of the guest called `name` out of a `loom.toml`. Empty
/// text is a file with nothing in it. Text that is not valid TOML is the error,
/// and `rm` then touches nothing.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) = vm_spec.read_enrolment("[executors.vm]\nnode = \"a@b\"\n", "vm")
/// assert found.executor_node == Some("a@b")
/// ```
pub fn read_enrolment(text: String, name: String) -> Result(Enrolment, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "is not valid TOML: " <> string.inspect(error)
    }),
  )
  let others =
    tom.get_table(document, ["executors"])
    |> result.map(dict.keys)
    |> result.unwrap([])
    |> list.filter(fn(other) { other != name })
    |> list.sort(string.compare)

  Ok(Enrolment(
    executor_node: tom.get_string(document, ["executors", name, "node"])
      |> option.from_result,
    distribution_node: tom.get_string(document, ["distribution", "node"])
      |> option.from_result,
    other_executors: others,
  ))
}

/// What the home's `.erlang.cookie` is, compared with the cookie in the
/// guest's `deploy/` bundle.
pub type CookieState {
  /// There is no cookie file.
  CookieAbsent

  /// The file holds this guest's deployment's cookie.
  CookieOurs

  /// The file holds another cookie, or the guest's bundle is not there to
  /// compare with.
  CookieOther
}

/// Compares the cookie file's contents with the deployment's.
///
/// ## Examples
///
/// ```gleam
/// assert vm_spec.cookie_state(Some("c"), Some("c")) == vm_spec.CookieOurs
/// assert vm_spec.cookie_state(Some("c"), None) == vm_spec.CookieOther
/// ```
pub fn cookie_state(
  found: Option(String),
  deployed: Option(String),
) -> CookieState {
  case found, deployed {
    None, _ -> CookieAbsent
    Some(have), Some(want) if have == want -> CookieOurs
    Some(_), _ -> CookieOther
  }
}

/// What `rm` does with the cookie file.
pub type CookieAction {
  RemoveCookie
  KeepCookie
}

/// What `rm` takes out of the user's configuration, and what it leaves with
/// the reason.
pub type Teardown {
  Teardown(
    /// The table paths to remove, such as `["executors", "vm"]`.
    tables: List(List(String)),
    /// Whether the home's cookie file goes.
    cookie: CookieAction,
    /// One line for each thing left in place, with its reason.
    left: List(String),
  )
}

/// Decides what undoing a guest's enrolment may remove.
///
/// The `[executors.<name>]` table goes when it names this guest's executor
/// node. The `[distribution]` table and the home's cookie are shared by every
/// executor of the daemon, so they go only when they are this guest's
/// deployment's (the table names the guest's orchestrator node, the cookie
/// equals the one in `deploy/`) and no other `[executors.*]` table remains.
/// Anything else is left and named.
///
/// ## Examples
///
/// ```gleam
/// let found = vm_spec.Enrolment(Some("loom_vm_vm_exec@127.0.0.1"), Some("loom_vm_vm_orch@127.0.0.1"), [])
/// let plan = vm_spec.plan_teardown(vm_spec.names("vm"), found, vm_spec.CookieOurs)
/// assert plan.tables == [["executors", "vm"], ["distribution"]]
/// ```
pub fn plan_teardown(
  names: Names,
  found: Enrolment,
  cookie: CookieState,
) -> Teardown {
  let row = "[executors." <> names.name <> "]"

  // The row goes only when it names this guest's executor; another node under
  // the same key is the user's own and keeps the deployment in use.
  let #(rows, row_left, own) = case found.executor_node {
    Some(node) if node == names.executor_node -> #(
      [["executors", names.name]],
      [],
      [],
    )
    Some(node) -> #(
      [],
      [row <> " names the node " <> node <> ", not this guest's, so it stays"],
      [names.name],
    )
    None -> #([], [], [])
  }

  let remaining = list.append(found.other_executors, own)
  let shared_present = found.distribution_node != None || cookie != CookieAbsent

  // An executor that remains is a reason to leave the shared tables, and the
  // line says which one.
  let still_used = case remaining {
    [] -> []
    _ -> [
      "[distribution] and the cookie stay because "
      <> string.join(
        list.map(remaining, fn(other) { "[executors." <> other <> "]" }),
        ", ",
      )
      <> " still need them",
    ]
  }

  // The shared tables are judged together: another deployment's table, or an
  // executor that still needs it, keeps both the table and the cookie.
  case found.distribution_node, still_used {
    Some(node), _ if node != names.orchestrator_node ->
      Teardown(rows, KeepCookie, [
        "[distribution] names the node "
          <> node
          <> ", which is another deployment's, so it and the cookie stay",
        ..row_left
      ])
    _, [line] if shared_present -> Teardown(rows, KeepCookie, [line, ..row_left])
    _, _ -> own_shared(found, rows, row_left, cookie)
  }
}

/// What goes of the shared tables when no executor needs them and they are not
/// another deployment's: the `[distribution]` table when there is one, and the
/// cookie when it is this guest's deployment's.
fn own_shared(
  found: Enrolment,
  rows: List(List(String)),
  row_left: List(String),
  cookie: CookieState,
) -> Teardown {
  // A missing `[distribution]` table leaves only the executor row to go.
  let tables = case found.distribution_node {
    Some(_) -> list.append(rows, [["distribution"]])
    None -> rows
  }

  // A cookie that is not the deployment's belongs to someone else and stays.
  case cookie {
    CookieOurs -> Teardown(tables, RemoveCookie, row_left)
    CookieOther ->
      Teardown(tables, KeepCookie, [
        "the home's .erlang.cookie is not this guest's deployment's, so it "
          <> "stays",
        ..row_left
      ])
    CookieAbsent -> Teardown(tables, KeepCookie, row_left)
  }
}
