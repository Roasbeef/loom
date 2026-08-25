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
import codemode/launch
import codemode/seed
import core/clock.{type Clock}
import filepath
import gleam/option
import gleam/string
import simplifile
import support/internal/ffi_peer

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

/// Stands up a rig under `build/e2e-codemode/<name>`: a fresh root (any
/// previous run's state removed), a helper pool of `pool_size`, and a
/// broker whose checkout borrows from it.
///
/// Panics on failure — a rig that cannot start is a test failure, not a
/// skip, because `prerequisites` already proved the pieces are there.
pub fn start(
  name name: String,
  prerequisites prerequisites: Prerequisites,
  pool_size pool_size: Int,
) -> Rig {
  let assert Ok(here) = simplifile.current_directory()
  let root = here <> "/build/e2e-codemode/" <> name
  let _cleared = simplifile.delete(root)
  let workspace = root <> "/work"
  let build_root = root <> "/build-root"
  let helper_tmp = root <> "/tmp"
  let cap_dir = root <> "/cap"
  let token_dir = root <> "/token"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(build_root)
  let assert Ok(Nil) = simplifile.create_directory_all(helper_tmp)
  let base_policy = base_policy(root)
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
/// writable, the filesystem readable (the toolchain and the BEAM live
/// outside it), the network off, and the two cap-channel handles on the
/// environment allowlist — without which the helper would construct a
/// child environment the boot runtime cannot find its socket in.
pub fn base_policy(root: String) -> SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: [root],
    readable_roots: ["/"],
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
  )
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

// Built with the Go toolchain, which caches, so this is cheap per run.
fn build_helper() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
  let directory = here <> "/build/e2e-codemode"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let helper_path = directory <> "/loom-exec"
  let output =
    ffi_peer.os_cmd(
      "cd ../sandbox && go build -o '"
      <> helper_path
      <> "' ./cmd/loom-exec && echo LOOM_BUILD_OK",
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
