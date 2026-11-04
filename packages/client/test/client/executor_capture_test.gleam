//// An executor captures its scope's workspace on request, through the real host
//// and the production plane (protocol-change/107, slice 3).
////
//// Slice 2 gave the host a `StateCapture` and left every plane answering
//// `NoStates`. This is the plane that does not: a worktree workspace served by
//// the production factory over a real repository, with a store behind it. The
//// session's tree gets an edit and a new file, the orchestrator's capture
//// request reaches the plane under the scope's token, and the state that comes
//// back is in the executor's store, whole, with the tree untouched.

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
import client/state_capture
import client/state_object.{Dirty, Full}
import client/state_service
import client/state_store
import client/worktree_git
import core/clock
import gleam/erlang/process
import gleam/option.{None, Some}
import provider/secret
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/worktree_rig.{type Rig, session, write}
import telemetry/log

const token = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

type Plane {
  Plane(
    rig: Rig,
    host_pid: process.Pid,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
    store: state_store.Store,
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

// The executor, with or without the means to capture.
type Capture {
  Able
  Unable
}

fn serve(name: String, capture: Capture) -> Plane {
  let rig = worktree_rig.rig(name)
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
  let capturer = case capture {
    Able -> Some(state_capture.new(git, rig.state, [], endpoint, store))
    Unable -> None
  }
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("executor_capture_host"),
      ledger_path: rig.ledger_path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      execution_result_bytes: host.default_execution_result_bytes,
      states: endpoint,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory_capturing(
        machine(rig),
        [rig.workspace],
        rig.trees,
        capturer,
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
      mcp: protocol.McpPlan(served: [], expected: []),
      git_identity: Some(git_identity.Identity(
        Some("Owner"),
        Some("owner@example.invalid"),
      )),
    ))
    as "the owner port starts"
  Plane(rig:, host_pid: started.pid, address: started.data, port:, store:)
}

fn stop(plane: Plane) -> Nil {
  process.unlink(plane.host_pid)
  process.kill(plane.host_pid)
}

fn attached(plane: Plane) -> surface.Attachment(RemoteCensus) {
  let assert Ok(attachment) =
    surface.attach(
      surface.Config(
        address: plane.address,
        session: session(1),
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
  attachment
}

fn tree_of(plane: Plane) -> String {
  plane.rig.state <> "/worktrees/repo/" <> session(1)
}

fn capture_request(plane: Plane) {
  let reply = process.new_subject()
  address.deliver(
    plane.address,
    protocol.StateCapture(
      session: session(1),
      incarnation: 0,
      token:,
      basis: Full,
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 200_000)
    as "the host answers a capture"
  answer
}

pub fn an_executor_captures_its_scopes_tree_into_its_store_test() {
  let plane = serve("capture-able", Able)
  let _attachment = attached(plane)
  let tree = tree_of(plane)
  write(tree <> "/README", "edited on the executor\n")
  write(tree <> "/new.txt", "made on the executor\n")
  let assert Ok(readme) = simplifile.read(tree <> "/README")

  let assert Ok(state) = capture_request(plane)

  // The state is in the executor's store, whole, and the tree is as it was.
  assert state.dirty == Dirty
  let assert Ok(Some(held)) = state_store.get(plane.store, state.hash)
  assert held.state == state
  assert simplifile.read(tree <> "/README") == Ok(readme)
  stop(plane)
}

pub fn an_executor_with_no_capturer_answers_that_it_cannot_test() {
  let plane = serve("capture-unable", Unable)
  let _attachment = attached(plane)
  let assert Error(protocol.NoStates(_)) = capture_request(plane)
  stop(plane)
}
