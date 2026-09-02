//// `loom ext` — the operator's whole surface for extensions.
////
//// Four verbs, no daemon, no hot install: `install`, `list`, `remove`,
//// `verify`. The session server reads the records at boot and nothing
//// re-reads them while it runs, which is the same restart-to-change
//// posture `client/catalog` takes toward `loom.toml` — with the one
//// difference the ruling names, that here the approval is *recorded*
//// rather than implied by an edit.
////
//// This is the first subcommand surface in the tree. `loomd` has never
//// had a verb layer, so the shape is set here: the verb is the first
//// argument, the rest is parsed by the same flat recursion
//// `client/serve` uses for its flags, and an unknown verb or flag is a
//// usage error on stderr with exit 1.
////
//// # Why the failure text names a layer
////
//// Every install failure is printed as `install refused: <layer>: <why>`.
//// An extension is somebody else's repository, and the person reading the
//// refusal is usually not the person who can fix it — so the message has
//// to be forwardable. "vetting: src/w/nif.gleam: an @external is not
//// permitted" is a bug report; "install failed" is not.
////
//// # Exit codes
////
//// 0 when the verb did what it says, 1 otherwise, and nothing else. A
//// `verify` that finds a refused extension exits 1, because the verb's
//// question is "is this loadable" and the answer was no.

import broker/budget
import broker/exec.{type EnforcementDemand}
import client/extension/archive
import client/extension/install
import client/extension/installed
import client/extension/record
import client/extension/source
import client/internal/ffi_os
import client/serve
import codemode/build
import codemode/compile
import codemode/identity
import core/clock.{type Clock}
import core/ids
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/secret
import simplifile

/// The usage text every flag error carries.
pub const usage = "usage: loom ext <command>
  install <source> [--rev <r>] [--home <dir>] [--helper <path>]
                   [--codemode-seed <dir>] [--best-effort]
  list
  remove <name>
  verify <name>

A source is a local path, an https:// .tar.gz, or an
https://github.com/<owner>/<repo> URL. Extensions install under
<home>/.loom/extensions."

/// How long the jailed build of an extension may take. The same bound
/// code mode gives a program's build, because it is the same build.
pub const build_timeout_ms = 180_000

/// The step id an install's clearances are accounted under. An install is
/// not part of any run, so it mints its own operation and names its one
/// step for what it is.
pub const install_step = "ext-install"

/// Runs `loom ext`.
///
/// ## Examples
///
/// ```gleam
/// // cli.main(["list"])
/// ```
///
pub fn main(arguments: List(String)) -> Nil {
  case dispatch(arguments) {
    Ok(lines) -> list.each(lines, io.println)
    Error(reason) -> {
      io.println_error("loom ext: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// The verbs, as a function of the arguments and the filesystem, so a
/// test can assert on the lines rather than on what reached a terminal.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(lines) = cli.dispatch(["list", "--home", home])
/// ```
///
pub fn dispatch(arguments: List(String)) -> Result(List(String), String) {
  case arguments {
    ["install", ..rest] -> install_command(rest)
    ["list", ..rest] -> list_command(rest)
    ["remove", ..rest] -> remove_command(rest)
    ["verify", ..rest] -> verify_command(rest)
    [] -> Error("a command is required\n" <> usage)
    [unknown, ..] -> Error("unknown command `" <> unknown <> "`\n" <> usage)
  }
}

// --- flags -----------------------------------------------------------------

// The raw flag values, before defaults, for the reason `serve`'s own
// `Flags` is shaped this way: absence is data, so one place owns every
// default.
type Flags {
  Flags(
    positional: Option(String),
    rev: Option(String),
    home: Option(String),
    helper: Option(String),
    seed: Option(String),
    effort: Effort,
  )
}

// Whether the operator accepted a degraded sandbox. A named type rather
// than a `Bool` because what reads it is choosing between two enforcement
// demands, and `True` names neither of them.
type Effort {
  DemandPlatform
  AcceptDegraded
}

fn no_flags() -> Flags {
  Flags(
    positional: None,
    rev: None,
    home: None,
    helper: None,
    seed: None,
    effort: DemandPlatform,
  )
}

fn parse(arguments: List(String), flags: Flags) -> Result(Flags, String) {
  case arguments {
    [] -> Ok(flags)
    ["--rev", value, ..rest] -> parse(rest, Flags(..flags, rev: Some(value)))
    ["--home", value, ..rest] -> parse(rest, Flags(..flags, home: Some(value)))
    ["--helper", value, ..rest] ->
      parse(rest, Flags(..flags, helper: Some(value)))
    ["--codemode-seed", value, ..rest] ->
      parse(rest, Flags(..flags, seed: Some(value)))
    ["--best-effort", ..rest] ->
      parse(rest, Flags(..flags, effort: AcceptDegraded))
    [word, ..rest] -> word_or_flag(word, rest, flags)
  }
}

// Anything left is either a stray flag — refused, because a mistyped
// `--rev` silently read as a source is the worst kind of quiet — or the
// one positional argument the verb takes.
fn word_or_flag(
  word: String,
  rest: List(String),
  flags: Flags,
) -> Result(Flags, String) {
  case string.starts_with(word, "--"), flags.positional, word {
    True, _, _ -> Error("unknown flag `" <> word <> "`\n" <> usage)
    False, _, "" -> Error("an empty argument names nothing\n" <> usage)
    False, None, _ -> parse(rest, Flags(..flags, positional: Some(word)))
    False, Some(first), _ ->
      Error(
        "`" <> first <> "` and `" <> word <> "` are both positional\n" <> usage,
      )
  }
}

fn required(flags: Flags, what: String) -> Result(String, String) {
  case flags.positional {
    Some(value) -> Ok(value)
    None -> Error(what <> " is required\n" <> usage)
  }
}

// The root every verb works against. `--home` names the directory that
// *holds* `.loom`, exactly as `HOME` does, so `--home /tmp/x` installs to
// `/tmp/x/.loom/extensions` and a test needs no environment at all.
fn root_of(flags: Flags) -> Result(record.Root, String) {
  case flags.home {
    Some(home) -> Ok(record.root_for(home))
    None ->
      secret.lookup(secret.env(), "HOME")
      |> result.map(record.root_for)
      |> result.replace_error(
        "HOME is unset, so there is no ~/.loom to install into; pass --home",
      )
  }
}

// --- install ---------------------------------------------------------------

fn install_command(arguments: List(String)) -> Result(List(String), String) {
  use flags <- result.try(parse(arguments, no_flags()))
  use text <- result.try(required(flags, "a source"))
  use from <- result.try(source.parse(text))
  use root <- result.try(root_of(flags))
  use workspace <- result.try(working_directory())
  use Nil <- result.try(staging_root(root))

  // The build plane is the boot's own, started here and torn down on
  // every path out: an install that failed must not leave a pool of
  // jails running under an operator's shell.
  use plane <- result.try(serve.start_build_plane(
    helper: flags.helper,
    seed: flags.seed,
    workspace:,
    writable: record.path(root),
    tmp_dir: staging_path(root),
    clock: wall_clock(),
  ))
  let outcome = install.run(config(plane, flags, root), from, rev: flags.rev)
  serve.stop_build_plane(plane)
  reported(outcome)
}

fn reported(
  outcome: Result(install.Installed, install.Failure),
) -> Result(List(String), String) {
  case outcome {
    Error(failure) -> Error("install refused: " <> install.describe(failure))
    Ok(done) ->
      Ok([
        "installed "
          <> done.record.name
          <> " "
          <> done.record.version
          <> " at "
          <> done.record.revision,
        "  tools:  " <> string.join(done.record.tools, ", "),
        "  digest: " <> done.record.tree_digest,
        "  where:  " <> done.directory,
      ])
  }
}

fn config(
  plane: serve.BuildPlane,
  flags: Flags,
  root: record.Root,
) -> install.Config {
  install.Config(
    root:,
    caps: archive.default_caps(),
    fetch: unwired_fetch,
    build: jailed_build(plane, flags),
    clock: wall_clock(),
    entropy: ffi_os.unique_positive_integer,
    approved_by: result.unwrap(secret.lookup(secret.env(), "USER"), "unknown"),
  )
}

// The fetch is not wired in this build. `broker/egress` is the module
// that will make it, under the one-host policy the ruling describes, and
// the orchestrator wires `broker/egress` here. Until then a URL source is
// refused saying so rather than silently falling back to something less
// policed.
fn unwired_fetch(url: String, _max_bytes: Int) -> Result(BitArray, String) {
  Error(
    "network fetch not wired: "
    <> url
    <> " cannot be fetched by this build; install from a local path",
  )
}

// The extension build is the code-mode build with one call's worth of
// coordinates minted for it. Everything about the jail — the network off,
// one writable root, the toolchain readable — comes from `codemode/build`,
// so there is no second answer to "may this build run".
fn jailed_build(plane: serve.BuildPlane, flags: Flags) -> install.Build {
  build_for(plane, demand(flags))
}

/// The install build seam over a started plane, at a chosen enforcement
/// demand.
///
/// Public because the extension suite's real-jail test builds through
/// exactly this: a second assembly of the same `BuildConfig` in a test
/// would be a second answer to "under what policy is an extension
/// compiled", and the whole point of the factoring is that there is one.
///
/// ## Examples
///
/// ```gleam
/// // cli.build_for(plane, exec.PlatformEnforcement)
/// ```
///
pub fn build_for(
  plane: serve.BuildPlane,
  demand: EnforcementDemand,
) -> install.Build {
  let builder =
    build.builder(build.BuildConfig(
      broker: plane.broker,
      seed_root: plane.toolchain.seed_root,
      gleam_path: plane.toolchain.gleam_path,
      base_policy: plane.base_policy,
      toolchain_roots: ["/"],
      demand:,
      env: [#("PATH", serve.toolchain_path_of(plane))],
      dependencies: compile.default_dependencies(),
      timeout_ms: build_timeout_ms,
    ))
  let phase = identity.build_phase(install_identity())
  fn(root) { builder(phase, root, []) }
}

// An install belongs to no run, so it mints an operation of its own. The
// budget is the build's: one effect at a time, and a deadline the build
// timeout cannot outlive.
fn install_identity() -> identity.ExecIdentity {
  let now = ffi_os.system_time_ms()
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(
      clock.fixed(at: now),
      seed: ffi_os.unique_positive_integer(),
    ))
  identity.for_execution(
    op_id:,
    step_id: install_step,
    budget: budget.Budget(
      max_outstanding: 1,
      deadline_ms: now + build_timeout_ms + build_timeout_ms,
    ),
  )
}

fn demand(flags: Flags) -> EnforcementDemand {
  case flags.effort {
    AcceptDegraded -> exec.BestEffort
    DemandPlatform -> exec.PlatformEnforcement
  }
}

// --- list, remove, verify --------------------------------------------------

fn list_command(arguments: List(String)) -> Result(List(String), String) {
  use flags <- result.try(parse(arguments, no_flags()))
  use root <- result.try(root_of(flags))
  case installed.discover(root) {
    [] -> Ok(["no extensions installed under " <> record.path(root)])
    entries -> Ok(list.map(entries, installed.summarise))
  }
}

fn remove_command(arguments: List(String)) -> Result(List(String), String) {
  use flags <- result.try(parse(arguments, no_flags()))
  use name <- result.try(required(flags, "an extension name"))
  use root <- result.try(root_of(flags))
  use Nil <- result.try(installed.remove(root, name))
  Ok(["removed " <> name])
}

fn verify_command(arguments: List(String)) -> Result(List(String), String) {
  use flags <- result.try(parse(arguments, no_flags()))
  use name <- result.try(required(flags, "an extension name"))
  use root <- result.try(root_of(flags))
  case installed.one(root, name) {
    installed.Ready(record: written, manifest: decoded, artifact:) ->
      Ok([
        installed.summarise(installed.Ready(
          record: written,
          manifest: decoded,
          artifact:,
        )),
        "ok",
      ])

    // A refused extension is an exit-1 answer, because the verb's whole
    // question is whether this one would load and the answer was no.
    installed.Refused(name:, reason:) -> Error(name <> ": " <> reason)
  }
}

// --- the host --------------------------------------------------------------

// The staging root has to exist before the build plane is started,
// because it is also the jail's scratch directory: a helper spawned
// against a directory that is not there refuses before an install can
// say anything more useful.
fn staging_root(root: record.Root) -> Result(Nil, String) {
  simplifile.create_directory_all(staging_path(root))
  |> result.map_error(fn(error) {
    "could not create "
    <> staging_path(root)
    <> ": "
    <> simplifile.describe_error(error)
  })
}

fn staging_path(root: record.Root) -> String {
  record.path(root) <> "/" <> record.staging_directory
}

fn working_directory() -> Result(String, String) {
  simplifile.current_directory()
  |> result.replace_error("the working directory is unreadable")
}

fn wall_clock() -> Clock {
  clock.from_function(ffi_os.system_time_ms)
}
