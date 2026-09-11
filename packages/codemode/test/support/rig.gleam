//// The feature-detected rig for the code-mode end-to-end suite: it finds
//// the toolchain, builds the real Go `loom-exec` helper, checks the build
//// seed is present and pinned, and stands up a real broker over a real
//// helper pool on an isolated on-disk root.
////
//// Skipping is the caller's decision. `prerequisites` returns the reason
//// when something is missing, so `make check` stays hermetic and fast on a
//// machine with no Go toolchain and no prepared seed, and `make
//// e2e-codemode` — which builds both first — runs the real thing.

import broker/broker.{type Broker}
import broker/exec.{type Pool}
import broker/policy.{type SandboxPolicy}
import broker/token
import codemode/compile
import codemode/enforcement.{type Report}
import codemode/launch
import codemode/seed
import core/clock.{type Clock}
import filepath
import gleam/list
import gleam/option
import gleam/string
import simplifile
import support/internal/ffi_peer
import support/scratch

/// The external things an end-to-end run needs, each located once.
pub type Prerequisites {
  Prerequisites(
    helper_path: String,
    gleam_path: String,
    erl_path: String,
    seed_root: String,
  )
}

/// One live rig: the broker and pool, plus the paths a code-mode
/// execution needs.
pub type Rig {
  Rig(
    broker: Broker,
    pool: Pool,
    root: String,
    workspace: String,
    build_root: String,
    cap_socket_path: String,
    token_dir: String,
    base_policy: SandboxPolicy,
  )
}

/// Locates the toolchain, builds the helper, and checks the seed — or
/// reports the reason to skip. The first reason no toolchain can fix is
/// a platform Loom has no jail for: the helper refuses to serve there,
/// and running it unenforced would report success for a sandbox that
/// does not exist.
pub fn prerequisites() -> Result(Prerequisites, String) {
  use Nil <- try(jailed_platform())
  use gleam_path <- try(executable("gleam"))
  use erl_path <- try(executable("erl"))
  use _go <- try(executable("go"))
  use helper_path <- try(build_helper())
  let seed_root = seed_root()
  case seed.verify(seed_root, compile.default_dependencies()) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      Ok(Prerequisites(helper_path:, gleam_path:, erl_path:, seed_root:))
  }
}

/// The prepared seed's location, relative to the `codemode` package
/// directory the test runner starts in.
pub fn seed_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
  here <> "/" <> seed.default_root
}

/// A real wall clock. Code-mode deadlines are absolute Unix milliseconds
/// and a jailed node really does die at one, so a fixture clock would be
/// measuring a different universe from the kernel.
pub fn wall_clock() -> Clock {
  clock.from_function(ffi_peer.now_ms)
}

/// Stands up a rig under the configured short scratch root, then HOME, then
/// `build/e2e-codemode`: any previous state is removed before a helper pool
/// and broker are started. The shallow preferred roots keep AF_UNIX socket
/// paths within Darwin's byte limit without hiding them under `/tmp`, which
/// the jail deliberately replaces.
///
/// Panics on failure — a rig that cannot start is a test failure, not a
/// skip, because `prerequisites` already proved the pieces are there.
pub fn start(
  name name: String,
  prerequisites prerequisites: Prerequisites,
  pool_size pool_size: Int,
) -> Rig {
  let root = scratch.fresh("e2e-" <> name)
  let workspace = root <> "/work"
  let build_root = root <> "/build-root"
  let helper_tmp = root <> "/tmp"
  let cap_dir = root <> "/cap"
  let token_dir = root <> "/token"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(build_root)
  let assert Ok(Nil) = simplifile.create_directory_all(helper_tmp)
  let base_policy = base_policy(root, prerequisites)
  let assert Ok(pool) =
    exec.start_pool(size: pool_size, spawn: fn() {
      exec.spawn_helper(exec.SpawnConfig(
        helper_path: prerequisites.helper_path,
        shell_path: "/bin/sh",
        base_policy:,
        helper_args: [],
        tmp_dir: helper_tmp,
        handshake_timeout_ms: 5000,
        cancel_grace_ms: 3000,
        heartbeat_interval_ms: 0,
      ))
    })
    as "the helper pool must start"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall_clock(),
        checkout: fn() { exec.checkout(pool, waiting: 20_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the broker must start"
  Rig(
    broker: broker_actor,
    pool:,
    root:,
    workspace:,
    build_root:,
    cap_socket_path: cap_dir <> "/cap.sock",
    token_dir:,
    base_policy:,
  )
}

/// The session base a code-mode execution runs under: its own root
/// writable and readable, the toolchain named as explicit mounts, the
/// network off, and the two cap-channel handles on the environment
/// allowlist — without which the helper would construct a child
/// environment the boot runtime cannot find its socket in.
///
/// This fixture deliberately uses the restricted profile so a missing or
/// duplicated toolchain mount still fails. The default developer session can
/// read the host, but code-mode compilation must also work with explicit
/// workspace reads. The discovered compiler, ERTS, and seed are the complete
/// dependency set for these programs; no language-manager path list is needed.
pub fn base_policy(
  root: String,
  prerequisites: Prerequisites,
) -> SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: [root],
    readable_roots: [root],
    protected: [],
    network: policy.NetworkOff,
    limits: policy.Limits(
      cpu_s: 120,
      wall_s: 180,
      mem_bytes: 2_147_483_648,
      pids: 512,
      fsize_bytes: 1_073_741_824,
      output_bytes: 4_194_304,
    ),
    env_allow: ["PATH", launch.sock_env, launch.token_env],
    scratch: policy.ScratchTmpfs,
    mounts: toolchain_mounts(prerequisites),
  )
}

/// The toolchain regions a jailed build and a jailed node have to reach:
/// the ERTS install prefix, the directory holding `gleam`, and the build
/// seed, each read-only and `MountRequired`.
///
/// This is the rig's own copy of what `client/codemode.toolchain_mounts`
/// derives for a session, and it exists because `codemode` does not depend
/// on `client`. The derivations it mirrors are the two that matter for a
/// mount plan. The `erl` prefix climbs out of `bin` and out of an
/// `erts-<version>` directory, because the emulator reads `lib` and
/// `releases` from the root beside it and a mount of `erts-<version>`
/// alone yields an `erl` that cannot boot. The `gleam` region is the
/// binary's own directory rather than the prefix above it, so a `gleam`
/// installed under `~/.local/bin` does not bring the rest of that
/// directory's contents into the jail.
///
/// A region nested inside another of the same list is dropped. On a
/// release the seed sits under the install root and on a Homebrew host
/// both binaries share one prefix, and two nested binds would be one
/// region named twice, which `broker/policy.validate` refuses.
pub fn toolchain_mounts(prerequisites: Prerequisites) -> List(policy.Mount) {
  let wanted =
    [
      erl_prefix(prerequisites.erl_path),
      filepath.directory_name(expand(prerequisites.gleam_path)),
      expand(prerequisites.seed_root),
    ]
    |> list.unique
  wanted
  |> list.filter(fn(path) {
    !list.any(wanted, fn(other) {
      other != path && policy.covers(root: other, path:)
    })
  })
  |> list.map(fn(path) {
    policy.Mount(
      path:,
      access: policy.MountReadOnly,
      requirement: policy.MountRequired,
    )
  })
}

// The install prefix `erl` boots from, which is the directory above its
// `bin` and, for an OTP install root, the directory above the
// `erts-<version>` under that.
fn erl_prefix(erl_path: String) -> String {
  let directory = filepath.directory_name(expand(erl_path))
  case filepath.base_name(directory) {
    "bin" -> {
      let prefix = filepath.directory_name(directory)
      case string.starts_with(filepath.base_name(prefix), "erts-") {
        True -> filepath.directory_name(prefix)
        False -> prefix
      }
    }
    _other -> directory
  }
}

// A mount path is taken as written on both sides of the wire, and
// `validate` refuses a `..` segment rather than pick between two names
// for one region, so the resolution happens here. `filepath.expand` is
// textual and resolves no symlink, which is what the prefix derivation
// wants.
fn expand(path: String) -> String {
  case filepath.expand(path) {
    Ok(expanded) -> expanded
    Error(Nil) -> path
  }
}

/// Stops the broker and the pool.
pub fn stop(rig: Rig) -> Nil {
  broker.stop(rig.broker)
  exec.stop_pool(rig.pool)
}

// The platform gate, shared with the other three real-helper suites
// through `broker/exec` so all four skip with the same declared reason
// (see .github/declared-skips).
fn jailed_platform() -> Result(Nil, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    option.Some(reason) -> Error(reason)
    option.None -> Ok(Nil)
  }
}

fn executable(name: String) -> Result(String, String) {
  ffi_peer.find_executable(name)
  |> replace_error(name <> " is not on PATH")
}

// Parallel prerequisites may rebuild this shared helper at the same time.
// Go copies cached executables through an unlinked or truncated destination,
// so another builder can mistake that interval for a non-object output.
// Each invocation builds into its own file beside the helper, then publishes
// the complete executable with an atomic rename. Go still checks freshness.
fn build_helper() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
  let directory = here <> "/build/e2e-codemode"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let helper_path = directory <> "/loom-exec"
  let output =
    ffi_peer.os_cmd(
      "cd ../sandbox && helper_tmp=$(mktemp '"
      <> helper_path
      <> ".XXXXXX') && trap 'rm -f \"$helper_tmp\"' EXIT && "
      <> "go build -o \"$helper_tmp\" ./cmd/loom-exec && "
      <> "mv -f \"$helper_tmp\" '"
      <> helper_path
      <> "' && echo LOOM_BUILD_OK",
    )
  case string.contains(output, "LOOM_BUILD_OK") {
    True -> Ok(helper_path)
    False -> Error("go build failed: " <> output)
  }
}

fn try(
  outcome: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case outcome {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

fn replace_error(outcome: Result(a, Nil), reason: String) -> Result(a, String) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(reason)
  }
}

/// A `PATH` for jailed toolchain invocations, built from where the tools
/// were actually found rather than guessed. `gleam build` shells out to
/// `erl`, so both directories have to be on it.
pub fn toolchain_path(prerequisites: Prerequisites) -> String {
  string.join(
    [
      filepath.directory_name(prerequisites.gleam_path),
      filepath.directory_name(prerequisites.erl_path),
      "/usr/bin",
      "/bin",
    ],
    ":",
  )
}

/// Whether anything exists at `path`, of any file type.
///
/// Not `simplifile.is_file`: that reports `Ok(False)` for a socket (Erlang
/// types it `other`), so an assertion built on it would pass whether or not
/// the cap socket was ever cleaned up — a test that captured nothing.
pub fn exists(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(_info) -> True
    Error(_error) -> False
  }
}

/// One stage's enforcement report as a line to print: the layers the
/// kernel really applied, the ones it skipped named as skipped, and — for
/// a stage that reported nothing — the reason instead.
///
/// Printed rather than asserted on, because what a given kernel provides
/// varies. What *is* asserted is that a line exists for both stages.
pub fn enforcement_line(what: String, report: Report) -> String {
  case report {
    enforcement.Unreported(reason:) ->
      what <> " made NO enforcement report: " <> reason
    enforcement.Reported(entries: _, degraded:) -> {
      let #(applied, skipped) = enforcement.layers(report)
      what
      <> " enforced ["
      <> string.join(applied, ", ")
      <> "]"
      <> case skipped {
        [] -> ""
        missing -> ", SKIPPED [" <> string.join(missing, ", ") <> "]"
      }
      <> case degraded {
        True -> " (DEGRADED)"
        False -> ""
      }
    }
  }
}
