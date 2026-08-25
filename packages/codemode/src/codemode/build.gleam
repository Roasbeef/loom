//// The production `compile.Builder` — `gleam build`, run hermetically
//// inside a network-off jail against a pre-seeded package cache.
////
//// The compile service prepares a build root (the program under its pinned
//// module name, the generated satellite entry, and a `gleam.toml` that
//// pins exactly the prelude and one standard-library version) and then
//// hands that root to a `Builder`. This is the one that runs for real.
////
//// # What makes the build hermetic
////
//// Three things, in order of how much they matter:
////
//// 1. **The network is off, by policy, in the kernel.** The build is an
////    ordinary `broker.clear_call` whose requirements set `NetworkOff`,
////    dispatched with `RefuseNarrowed`, so a session base that cannot
////    deliver a network-off jail refuses the build instead of running it
////    open. The Go helper enforces that at socket creation (seccomp) and
////    with an interface-less network namespace (bwrap) — two layers,
////    either sufficient.
//// 2. **The packages are already there.** Gleam re-resolves — and reaches
////    Hex — whenever a project root has no `build/packages`, so the build
////    root is prepared as a copy of a seed that was resolved once, online
////    (`codemode/seed`). The builder refuses to run against a seed whose
////    dependency table is not byte-identical to the one the compile
////    service generated.
//// 3. **Nothing outside the build root is needed.** The prelude is
////    vendored *inside* it, so the composed policy grants exactly one
////    writable root — the build root — plus read access to the toolchain.
////
//// A build that nonetheless tries to resolve is diagnosed as such rather
//// than reported as a broken program: the seed is what failed, not the
//// model's source.
////
//// # `--warnings-as-errors`, and what it buys
////
//// The build runs with warnings as errors. That is a security choice, not
//// a tidiness one: Gleam warns (and does not yet error) when a module from
//// a *transitive* dependency is imported, and `gleam/erlang/process`,
//// `gleam/otp/*`, and `core/*` are exactly that in a generated program.
//// With warnings as errors, importing one is a compile error — so the
//// build graph is closed to them by the compiler and not only by the
//// vetting allowlist (M4 triage CH-F1).
////
//// The price is that ordinary warnings — an unused variable, an unused
//// import — also fail the build. That is acceptable, and arguably right:
//// the failure is a structured `BuildRejected` carrying the compiler's own
//// diagnostics, which is precisely what the model reads and fixes, and the
//// type checker is already doing double duty as the tool-argument
//// validator here.
////
//// # `PATH` is required
////
//// `gleam build` shells out to `erl` to compile the generated Erlang, so
//// the jailed build needs `PATH` in its environment and in the composed
//// policy's `env_allow`. Without it the compiler dies with an escript
//// error that looks nothing like a missing environment variable, so the
//// requirement is stated here and checked by the composition.

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/policy.{type SandboxPolicy}
import codemode/compile.{type BuildProducts, type CompileError, type Dependency}
import codemode/seed
import core/ids.{type OpId}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tools/blob
import tools/tool.{type Collected}

/// The directory, inside a build root, the flattened `.beam` set is
/// gathered into. One directory means one `-pa` on the satellite's argv.
pub const beam_directory = "ebin"

// How long the synchronous clearance for the build may take.
const clear_timeout_ms = 5000

// Slack over the build timeout before the collector gives up on a helper
// that never settles.
const settle_margin_ms = 10_000

// How much compiler output to carry back as diagnostics.
const diagnostics_limit = 8000

/// Everything the production builder needs beyond the build root.
pub type BuildConfig {
  BuildConfig(
    /// The running broker the build is dispatched through.
    broker: Broker,
    /// The operation the build belongs to.
    op_id: OpId,
    /// The step within the operation.
    step_id: String,
    /// The prepared seed (`codemode/seed`) the build root is cloned from.
    seed_root: String,
    /// Absolute path to the `gleam` executable.
    gleam_path: String,
    /// The session base policy.
    base_policy: SandboxPolicy,
    /// Roots the build may read: the Gleam and Erlang toolchains. Usually
    /// `["/"]`, which the session base must then also cover.
    toolchain_roots: List(String),
    /// The pooled budget for the build.
    budget: Budget,
    /// Enforcement strictness demanded of the jailed build.
    demand: EnforcementDemand,
    /// The child environment. Must carry `PATH` — see the module doc.
    env: List(#(String, String)),
    /// The dependency table the compile service pins, checked against the
    /// seed's.
    dependencies: List(Dependency),
    /// How long the build itself may take.
    timeout_ms: Int,
    /// Receives the build's enforcement report (`entries`, `degraded`), so
    /// a caller can say out loud which layers the kernel provided.
    enforcement: fn(List(String), Bool) -> Nil,
  )
}

/// Builds the production `compile.Builder`.
pub fn builder(config: BuildConfig) -> compile.Builder {
  fn(build_root) { build(config, build_root) }
}

fn build(
  config: BuildConfig,
  root: String,
) -> Result(BuildProducts, CompileError) {
  use _ <- result.try(
    seed.verify(config.seed_root, config.dependencies)
    |> result.map_error(compile.BuildUnavailable),
  )
  use _ <- result.try(clone_seed(config.seed_root, root))
  use _ <- result.try(run_build(config, root))
  products(root)
}

// --- preparing the root ---------------------------------------------------

// Clones the seed's vendored prelude, resolved manifest, and package cache
// into the build root the compile service already wrote sources into. The
// seed's own compiled program is dropped: an artifact from the placeholder
// has no business being in the set this build produces.
//
// Anything a previous build left in the root goes first. The build root is
// meant to be fresh, but "meant to be" is not a guarantee, and a stale
// `ebin` would silently join the artifact — and its content address.
fn clone_seed(seed_root: String, root: String) -> Result(Nil, CompileError) {
  let _cleared =
    simplifile.delete_all([
      root <> "/vendor",
      root <> "/build",
      root <> "/manifest.toml",
      root <> "/" <> beam_directory,
    ])
  use _ <- result.try(copy_tree(seed_root <> "/vendor", root <> "/vendor"))
  use _ <- result.try(copy_file(
    seed_root <> "/manifest.toml",
    root <> "/manifest.toml",
  ))
  use _ <- result.try(copy_tree(seed_root <> "/build", root <> "/build"))
  let _dropped =
    simplifile.delete(root <> "/build/dev/erlang/" <> compile.package_name)
  Ok(Nil)
}

// --- running the build ----------------------------------------------------

fn run_build(config: BuildConfig, root: String) -> Result(Nil, CompileError) {
  let events = process.new_subject()
  case
    broker.clear_call(
      config.broker,
      build_call(config, root),
      events:,
      waiting: clear_timeout_ms,
    )
  {
    Error(refusal) ->
      Error(compile.BuildUnavailable(
        "the hermetic build was refused: " <> refusal_text(refusal),
      ))
    Ok(_handle) ->
      case
        tool.collect_events(
          events,
          waiting: config.timeout_ms + settle_margin_ms,
        )
      {
        Error(Nil) ->
          Error(compile.BuildUnavailable(
            "the hermetic build produced no settlement",
          ))
        Ok(collected) -> settle(config, collected)
      }
  }
}

fn settle(
  config: BuildConfig,
  collected: Collected,
) -> Result(Nil, CompileError) {
  case collected.outcome {
    broker.CallFailed(failure:) ->
      Error(compile.BuildUnavailable(
        "the hermetic build could not run: " <> tool.exec_failure_text(failure),
      ))
    broker.CallExited(result:) -> {
      config.enforcement(result.enforcement, result.degraded)
      let diagnostics = diagnostics(collected)
      case result.timed_out, result.code {
        True, _ ->
          Error(compile.BuildUnavailable(
            "the hermetic build hit its wall limit and was killed",
          ))
        False, 0 -> Ok(Nil)
        // A build that reached for Hex is a broken *seed*, not a broken
        // program, and saying so is the difference between "fix your
        // code" and "rebuild the package cache".
        False, _ ->
          case reached_for_hex(diagnostics) {
            True ->
              Error(compile.BuildUnavailable(
                "the hermetic build tried to resolve dependencies, which "
                <> "means its package cache was not usable; the network was "
                <> "off, so it failed rather than fetching: "
                <> diagnostics,
              ))
            False -> Error(compile.BuildRejected(diagnostics:))
          }
      }
    }
  }
}

// Gleam announces resolution before it happens and names the Hex repo when
// it fails, so either marker identifies a build that left the seed behind.
fn reached_for_hex(diagnostics: String) -> Bool {
  string.contains(diagnostics, "Resolving versions")
  || string.contains(diagnostics, "hex.pm")
}

/// The clearance that runs the build: network off, exactly one writable
/// root (the build root), and the toolchain readable.
pub fn build_call(config: BuildConfig, root: String) -> CallSpec {
  broker.CallSpec(
    op_id: config.op_id,
    step_id: config.step_id,
    base_policy: config.base_policy,
    requirements: build_requirements(config, root),
    grants: [],
    // Nothing about a hermetic build is best-effort: a session base that
    // cannot deliver these requirements must refuse, not run a build with
    // the network on or the workspace writable.
    response: broker.RefuseNarrowed,
    demand: config.demand,
    argv: [config.gleam_path, "build", "--warnings-as-errors"],
    env: config.env,
    cwd: root,
    budget: config.budget,
  )
}

/// What the build requires of the session base. Narrower than the base in
/// every dimension it touches: one writable root, the toolchain readable,
/// the network off, and only the environment names actually passed.
pub fn build_requirements(config: BuildConfig, root: String) -> SandboxPolicy {
  policy.SandboxPolicy(
    ..config.base_policy,
    writable_roots: [root],
    readable_roots: list.unique([root, ..config.toolchain_roots]),
    network: policy.NetworkOff,
    env_allow: list.map(config.env, fn(pair) { pair.0 }),
  )
}

// --- the products ---------------------------------------------------------

// Flattens every package's compiled modules into one directory and hashes
// the result. Flattening is safe because Gleam prefixes a module's beam
// name with its package (`gleam@list`, `cap@fs`), so no two packages can
// collide; and one directory is one `-pa` for the satellite's argv.
fn products(root: String) -> Result(BuildProducts, CompileError) {
  let beam_dir = root <> "/" <> beam_directory
  let erlang_root = root <> "/build/dev/erlang"
  use _ <- result.try(
    simplifile.create_directory_all(beam_dir)
    |> file_error("create " <> beam_dir),
  )
  use packages <- result.try(
    simplifile.read_directory(erlang_root)
    |> file_error("read " <> erlang_root),
  )
  use gathered <- result.try(
    list.try_fold(list.sort(packages, string.compare), [], fn(acc, package) {
      gather(erlang_root <> "/" <> package <> "/ebin", beam_dir, acc)
    }),
  )
  let entry = compile.entry_module <> ".beam"
  case list.contains(gathered, entry) {
    False ->
      Error(compile.ArtifactIncomplete(
        "the build produced no " <> entry <> " in " <> beam_dir,
      ))
    True -> {
      use manifest_hash <- result.try(fingerprint(beam_dir, gathered))
      Ok(compile.BuildProducts(beam_dir:, manifest_hash:))
    }
  }
}

// Copies one package's `ebin` into the flattened directory, returning the
// names taken so far. A package directory without an `ebin` (Gleam keeps
// bookkeeping directories alongside the real ones) contributes nothing.
fn gather(
  ebin: String,
  destination: String,
  taken: List(String),
) -> Result(List(String), CompileError) {
  case simplifile.read_directory(ebin) {
    Error(_) -> Ok(taken)
    Ok(entries) ->
      list.try_fold(entries, taken, fn(acc, name) {
        case string.ends_with(name, ".beam") || string.ends_with(name, ".app") {
          False -> Ok(acc)
          True -> {
            use _ <- result.try(
              simplifile.copy_file(
                at: ebin <> "/" <> name,
                to: destination <> "/" <> name,
              )
              |> file_error("copy " <> name),
            )
            Ok([name, ..acc])
          }
        }
      })
  }
}

// A content address over the whole compiled set: every file's name and the
// hash of its bytes, sorted, hashed again. Two builds of the same source
// against the same seed produce the same value; one changed byte anywhere
// in the artifact changes it.
fn fingerprint(
  beam_dir: String,
  names: List(String),
) -> Result(String, CompileError) {
  use lines <- result.try(
    list.try_map(list.sort(names, string.compare), fn(name) {
      use bytes <- result.try(
        simplifile.read_bits(from: beam_dir <> "/" <> name)
        |> file_error("read " <> name),
      )
      Ok(name <> " " <> blob.ref_for(bytes))
    }),
  )
  Ok(blob.ref_for(bit_array.from_string(string.join(lines, "\n"))))
}

// --- helpers --------------------------------------------------------------

fn copy_tree(source: String, destination: String) -> Result(Nil, CompileError) {
  simplifile.copy_directory(at: source, to: destination)
  |> file_error("copy " <> source)
  |> result.replace(Nil)
}

fn copy_file(source: String, destination: String) -> Result(Nil, CompileError) {
  simplifile.copy_file(at: source, to: destination)
  |> file_error("copy " <> source)
  |> result.replace(Nil)
}

fn file_error(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, CompileError) {
  result.map_error(outcome, fn(error) {
    compile.WorkspaceSetupFailed(
      "could not " <> what <> ": " <> simplifile.describe_error(error),
    )
  })
}

fn diagnostics(collected: Collected) -> String {
  let text =
    string.trim(text_of(collected.stdout) <> "\n" <> text_of(collected.stderr))
  string.slice(text, at_index: 0, length: diagnostics_limit)
}

fn text_of(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

fn refusal_text(refusal: broker.Refusal) -> String {
  case refusal {
    broker.PolicyRefused(denial:) -> "policy refused: " <> denial.reason
    broker.InvalidPolicy(error: _) -> "the composed policy is invalid"
    broker.BudgetRefused(refusal: _) -> "the pooled budget refused it"
    broker.MintRefused(error: _) -> "the broker could not mint a token"
    broker.NoHelper(error: _) -> "no sandbox helper was available"
    broker.BrokerUnavailable -> "the tool broker is unavailable"
  }
}
