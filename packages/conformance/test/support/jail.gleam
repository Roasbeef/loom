//// The feature-detected sandbox rig for the e2e suite: locates the real
//// Go `loom-exec` helper `make sandbox` built, prepares an isolated
//// on-disk root (workspace, helper tmp, blob store, session file), and
//// stands up a real broker over a real helper pool. Skipping is the
//// caller's decision — when `prebuilt_helper` fails, tests print the
//// reason and return.

import broker/broker.{type Broker}
import broker/exec.{type Pool}
import broker/policy.{type SandboxPolicy}
import broker/token
import core/clock.{type Clock}
import gleam/option.{None, Some}
import simplifile

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

/// Locates the `loom-exec` helper `make sandbox` built, or reports the
/// reason to skip — including the one reason no build can fix, a
/// platform Loom has no jail for.
///
/// The suite never compiles the helper itself. It used to run a `go
/// build` per test, and under a parallel run those builds were in flight
/// at once with the other packages' real-helper suites; on the
/// containerised signoff some of them read a Go build-cache object that
/// was zero from some offset on and failed to link. `make e2e` and `make
/// check` build the helper first. A run without it skips with the remedy
/// named, and the skip census counts that skip as a failure.
///
/// ## Examples
///
/// ```gleam
/// case jail.prebuilt_helper() {
///   Error(reason) -> io.println_error("SKIP e2e: " <> reason)
///   Ok(helper_path) -> run(helper_path)
/// }
/// ```
pub fn prebuilt_helper() -> Result(String, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> prebuilt_helper_here()
  }
}

fn prebuilt_helper_here() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
  let helper_path = here <> "/../sandbox/loom-exec"
  case simplifile.is_file(helper_path) {
    Ok(True) -> Ok(helper_path)
    _absent_or_unreadable ->
      Error("no loom-exec at " <> helper_path <> "; run `make sandbox`")
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
      helper_args: [],
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

/// The e2e session base policy: the workspace writable and readable,
/// network off — enough to cover the bash tool's requirements so the
/// happy path composes without narrowing.
///
/// It used to grant `readable_roots: ["/"]`, which restated the helper's
/// old base view rather than any need of this session's. Under
/// `protocol-change/020` the regions outside the workspace an ordinary
/// command needs are the helper's per-OS system roots and the mounts a
/// real boot derives, neither of which a fixture supplies or should.
pub fn base_policy(workspace: String) -> SandboxPolicy {
  policy.workspace_default(workspace)
}

/// Stops the broker and the pool. A helper still lent to an in-flight
/// execution (the crash rider's hanging bash) is reaped when its port
/// closes at VM exit.
pub fn stop(jail: Jail) -> Nil {
  broker.stop(jail.broker)
  exec.stop_pool(jail.pool)
}
