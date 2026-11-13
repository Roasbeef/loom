//// An executor in this VM, for the tests of states on an executor
//// (protocol-change/107, slice 4b).
////
//// The host is the real one and the plane is the production factory over a real
//// repository, with a store and a sandboxed Git behind it, exactly as
//// `executor_capture_test` builds them. A session attaches through the real
//// surface, and the record of what that session can do with states comes from the
//// production `workspace.states_over`, so a test drives the same functions the
//// orchestrator's session assembly does.

import broker/exec
import client/catalog
import client/executor_plane
import client/git_identity
import client/internal/ffi_os
import client/jobs
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/remote/workspace as remote_workspace
import client/session_states.{type SessionStates}
import client/state_capture
import client/state_service
import client/state_store
import client/workspaces
import client/worktree_git
import core/clock
import gleam/erlang/process
import gleam/option.{None, Some}
import provider/secret
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/worktree_rig.{type Rig, session}
import telemetry/log

/// The attach token every session of the rig uses.
pub const token = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

/// An executor: its rig, its host and the store behind it.
pub type Plane {
  Plane(
    rig: Rig,
    host_pid: process.Pid,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
    store: state_store.Store,
  )
}

/// A session attached to an executor, with the record of what it can do with
/// states.
pub type Attached {
  Attached(
    attachment: surface.Attachment(RemoteCensus),
    session: String,
    states: SessionStates,
  )
}

fn machine(rig: Rig) -> executor_plane.Machine {
  executor_plane.Machine(
    state_root: rig.state,
    helper_path: helper(),
    helper_pool_size: 4,
    demand: exec.BestEffort,
    workspace: catalog.default_workspace(),
    tools: catalog.default_tools(),
    deactivated_tools: [],
    lsp_servers: [],
    jobs_policy: jobs.default_policy,
    codemode_seed: Some(rig.state <> "/no-such-seed"),
    secrets: secret.env(),
    home: None,
    logger: log.discard(),
    mcp_servers: [],
    credentials: [],
  )
}

fn helper() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/../sandbox/loom-exec"
}

/// An executor serving a workspace in worktree mode over a new repository.
///
/// ## Examples
///
/// ```gleam
/// let plane = executor_rig.serve("seed-whole")
/// ```
pub fn serve(name: String) -> Plane {
  let rig = worktree_rig.rig(name)
  serve_over(rig, [rig.workspace])
}

/// An executor serving the rig's repository as a `shared` workspace, whose
/// sessions all work in the repository itself.
///
/// ## Examples
///
/// ```gleam
/// let plane = executor_rig.serve_shared("seed-shared")
/// ```
pub fn serve_shared(name: String) -> Plane {
  let rig = worktree_rig.rig(name)
  serve_over(rig, [workspaces.shared("repo", rig.root)])
}

fn serve_over(rig: Rig, served: List(workspaces.Workspace)) -> Plane {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let endpoint = state_service.endpoint(service)
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: helper(),
      scratch: rig.state <> "/state-git",
      state_root: rig.state,
      credentials: [],
      demand: exec.BestEffort,
    ))
    as "the sandboxed Git starts"
  let capturer = state_capture.new(git, rig.state, [], endpoint, store)
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("executor_rig_host"),
      ledger_path: rig.ledger_path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      execution_result_bytes: host.default_execution_result_bytes,
      states: endpoint,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory_capturing(
        machine(rig),
        served,
        rig.trees,
        Some(capturer),
      ),
    ))
    as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.empty_mcp_plan(),
      git_identity: Some(git_identity.Identity(
        Some("Owner"),
        Some("owner@example.invalid"),
      )),
    ))
    as "the owner port starts"
  Plane(rig:, host_pid: started.pid, address: started.data, port:, store:)
}

/// Stops the executor's host.
pub fn stop(plane: Plane) -> Nil {
  process.unlink(plane.host_pid)
  process.kill(plane.host_pid)
}

/// Attaches session number `n` to the executor, as an orchestrator's session
/// open does, and builds its record of what it can do with states.
///
/// ## Examples
///
/// ```gleam
/// let attached = executor_rig.attach(plane, 1, "runner")
/// ```
pub fn attach(plane: Plane, n: Int, executor: String) -> Attached {
  let assert Ok(attachment) =
    surface.attach(
      surface.Config(
        address: plane.address,
        session: session(n),
        workspace: "repo",
        incarnation: 0,
        port: plane.port,
        read_authority: fn(_run) { Ok(fixtures.authority()) },
        reconnect: fn() { Ok(Nil) },
        remote_tools: ["fs_write", "fs_read", "bash"],
        attach_within_ms: 120_000,
        mint_token: fn() { token },
      ),
    )
    as "the attach succeeds"
  Attached(
    attachment:,
    session: session(n),
    states: remote_workspace.states_over(
      session(n),
      executor,
      plane.address,
      attachment.surface,
      attachment.attached.census,
    ),
  )
}

/// The tree of session number `n`.
pub fn tree_of(plane: Plane, n: Int) -> String {
  plane.rig.state <> "/worktrees/repo/" <> session(n)
}
