//// The feature-detected sandbox rig for the e2e suite: builds the real
//// Go `loom-exec` helper, prepares an isolated on-disk root (workspace,
//// helper tmp, blob store, session file), and stands up a real broker
//// over a real helper pool. Skipping is the caller's decision — when
//// `build_helper` fails, tests print the reason and return.

import broker/broker.{type Broker}
import broker/exec.{type Pool}
import broker/policy.{type SandboxPolicy}
import broker/token
import core/clock.{type Clock}
import gleam/string
import simplifile
import support/internal/ffi_shell

/// One live rig: the broker and pool plus the paths a wiring config
/// needs.
pub type Jail {
  Jail(
    broker: Broker,
    pool: Pool,
    root: String,
    workspace: String,
    blob_root: String,
    session_path: String,
    base_policy: SandboxPolicy,
    env: List(#(String, String)),
  )
}

/// Builds the `loom-exec` helper with the Go toolchain (cached by Go,
/// so cheap per run), or reports the reason to skip.
pub fn build_helper() -> Result(String, String) {
  case ffi_shell.find_executable("go") {
    Error(Nil) -> Error("go toolchain not on PATH")
    Ok(_go) -> {
      let assert Ok(here) = simplifile.current_directory()
      let dir = here <> "/build/e2e"
      let assert Ok(Nil) = simplifile.create_directory_all(dir)
      let helper_path = dir <> "/loom-exec"
      let output =
        ffi_shell.os_cmd(
          "cd ../sandbox && go build -o '"
          <> helper_path
          <> "' ./cmd/loom-exec && echo LOOM_BUILD_OK",
        )
      case string.contains(output, "LOOM_BUILD_OK") {
        True -> Ok(helper_path)
        False -> Error("go build failed: " <> output)
      }
    }
  }
}

/// Stands up one rig under `build/e2e/<name>`: a fresh root (any
/// previous run's state deleted, so the sqlite session always starts
/// empty), a helper pool of `pool_size`, and a broker whose checkout
/// seam borrows from it. Panics on failure — a rig that cannot start is
/// a test failure, not a skip (the helper binary already built).
pub fn start(
  name name: String,
  helper_path helper_path: String,
  pool_size pool_size: Int,
  clock clock: Clock,
) -> Jail {
  let assert Ok(here) = simplifile.current_directory()
  let root = here <> "/build/e2e/" <> name
  // Absent on first run; stale state from a previous run otherwise.
  let _cleared = simplifile.delete(root)
  let workspace = root <> "/work"
  let tmp = root <> "/tmp"
  let blob_root = workspace <> "/.blobs"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(tmp)
  let assert Ok(Nil) = simplifile.create_directory_all(blob_root)
  let base_policy = base_policy(workspace)
  let spawn_config =
    exec.SpawnConfig(
      helper_path:,
      shell_path: "/bin/sh",
      base_policy:,
      tmp_dir: tmp,
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(pool) =
    exec.start_pool(size: pool_size, spawn: fn() {
      exec.spawn_helper(spawn_config)
    })
    as "the helper pool must start"
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock:,
        checkout: fn() { exec.checkout(pool, waiting: 15_000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
    as "the broker must start"
  Jail(
    broker: broker_actor,
    pool:,
    root:,
    workspace:,
    blob_root:,
    session_path: root <> "/session.db",
    base_policy:,
    env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")],
  )
}

/// The e2e session base policy: workspace writable, the whole
/// filesystem readable (interpreters live outside the workspace),
/// network off — wide enough to cover the bash tool's requirements so
/// the happy path composes without narrowing.
pub fn base_policy(workspace: String) -> SandboxPolicy {
  policy.SandboxPolicy(..policy.workspace_default(workspace), readable_roots: [
    "/",
  ])
}

/// Stops the broker and the pool. A helper still lent to an in-flight
/// execution (the crash rider's hanging bash) is reaped when its port
/// closes at VM exit.
pub fn stop(jail: Jail) -> Nil {
  broker.stop(jail.broker)
  exec.stop_pool(jail.pool)
}
