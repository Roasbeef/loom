//// A checkout placed on an untrusted executor as Git states, through the link
//// (protocol-changes 107, 109 and 110).
////
//// The orchestrator holds a repository the executor has never seen: no commit
//// in it is in the executor's workspace repository. It captures a full bundle
//// of one commit, sends it in pieces over the untrusted link and gateway into a
//// real host and the production plane, and applies it into the session's
//// tree. A second commit then goes as a thin bundle against the first, which
//// the executor now holds, so only the delta moves. Nothing here is a
//// distribution peer: the surface addresses the link by name, and the link
//// dials the gateway over TLS.

import broker/exec
import client/catalog
import client/executor_plane
import client/git_identity
import client/internal/ffi_os
import client/jobs
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/state_link
import client/remote/surface
import client/remote/untrusted_gateway
import client/remote/untrusted_link
import client/state_capture
import client/state_object.{type State, Full, Thin}
import client/state_service
import client/state_store
import client/state_transfer
import client/worktree_git
import core/clock
import filepath
import gleam/erlang/process
import gleam/option.{None, Some}
import host/bootstrap
import provider/secret
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/state_rig
import support/untrusted_rig as tls
import support/worktree_rig.{type Rig, git, session, write}
import telemetry/log

/// The executor behind its gateway, and the orchestrator's link to it.
type Placement {
  Placement(
    rig: Rig,
    host_pid: process.Pid,
    gateway: untrusted_gateway.Gateway,
    link: process.Pid,
    name: process.Name(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
    /// The orchestrator's own store and the means to capture into it.
    store: state_store.Store,
    capturer: state_capture.Capturer,
  )
}

fn helper() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  here <> "/../sandbox/loom-exec"
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

/// A store, its service and a capturer rooted at `root`.
fn states_at(
  root: String,
) -> #(state_store.Store, state_transfer.Endpoint, state_capture.Capturer) {
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/states")
  let assert Ok(store) =
    state_store.open(state_store.directory(root), state_store.default_limits)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let endpoint = state_service.endpoint(service)
  let assert Ok(sandboxed) =
    worktree_git.start(worktree_git.Config(
      helper_path: helper(),
      scratch: root <> "/state-git",
      state_root: root,
      credentials: [],
      demand: exec.BestEffort,
    ))
    as "the sandboxed Git starts"
  #(store, endpoint, state_capture.new(sandboxed, root, [], endpoint, store))
}

fn serve(label: String) -> Placement {
  let rig = worktree_rig.rig(label)
  let #(_executor_store, endpoint, executor_capturer) = states_at(rig.state)
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("untrusted_state_host"),
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
        Some(executor_capturer),
      ),
    ))
    as "the host starts"
  let pair = tls.pair("state-" <> label)
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: started.data,
      blobs: None,
      logger: log.discard(),
    ))
    as "the gateway starts"
  let name = process.new_name("untrusted_state_link")
  let assert Ok(link) =
    untrusted_link.start(untrusted_link.Config(
      executor: "pod",
      name:,
      host: "127.0.0.1",
      port: gateway.port,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
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
  // The orchestrator's state root stands in for a daemon's, so it holds the
  // entries a daemon makes before any capture: the capture's jail masks them,
  // and on Linux a jail refuses to mask a path that does not exist.
  let orchestrator = filepath.directory_name(rig.root) <> "/orchestrator"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(orchestrator)
  let assert Ok(orchestrator) = bootstrap.canonical_directory(orchestrator)
  worktree_rig.establish(orchestrator)
  let #(store, _endpoint, capturer) = states_at(orchestrator)
  Placement(
    rig:,
    host_pid: started.pid,
    gateway:,
    link:,
    name:,
    port:,
    store:,
    capturer:,
  )
}

fn stop(placement: Placement) -> Nil {
  process.unlink(placement.link)
  process.kill(placement.link)
  process.unlink(placement.gateway.acceptor)
  process.kill(placement.gateway.acceptor)
  process.unlink(placement.host_pid)
  process.kill(placement.host_pid)
}

fn attached(placement: Placement) -> surface.Surface(RemoteCensus) {
  let assert Ok(surface.Attachment(surface: remote, ..)) =
    surface.attach(
      surface.Config(
        address: untrusted_link.address(placement.name),
        session: session(1),
        workspace: "repo",
        incarnation: 0,
        port: placement.port,
        read_authority: fn(_run) { Ok(fixtures.authority()) },
        reconnect: fn() { untrusted_link.running(placement.name, "pod") },
        remote_tools: ["fs_write", "fs_read", "bash"],
        attach_within_ms: 120_000,
        mint_token: surface.strong_token,
        attached: fn(_attached) { Nil },
      ),
    )
    as "the attach succeeds over the link"
  remote
}

/// A repository that shares no history with the executor's: its own first
/// commit, with its own files.
fn unseen_repository(placement: Placement) -> String {
  let directory = filepath.directory_name(placement.rig.root) <> "/unseen"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  git(directory, ["init", "--quiet", "--initial-branch=review"])
  write(directory <> "/go.mod", "module example.com/review\n")
  write(directory <> "/main.go", "package main\n\nfunc main() {}\n")
  git(directory, ["add", "go.mod", "main.go"])
  git(directory, ["commit", "--quiet", "-m", "the commit under review"])
  directory
}

/// Captures the repository's `HEAD` into the orchestrator's store, sends it to
/// the executor through the link, and applies it into the session's tree.
fn placed(
  placement: Placement,
  remote: surface.Surface(RemoteCensus),
  directory: String,
  basis: state_object.Basis,
) -> #(State, Result(String, protocol.Refusal)) {
  let assert Ok(state) =
    state_capture.capture(
      placement.capturer,
      directory,
      state_rig.identity(),
      basis,
    )
    as "the orchestrator captures the commit"
  let link = state_link.via_host(untrusted_link.address(placement.name), 60_000)
  assert state_transfer.send(placement.store, state.hash, link)
    == state_transfer.Delivered
  let applied =
    surface.ask(remote, fn(reply) {
      protocol.StateApply(
        session: session(1),
        incarnation: surface.incarnation(remote),
        token: surface.token(remote),
        state:,
        reply:,
      )
    })
  #(state, applied)
}

fn tree_of(placement: Placement) -> String {
  placement.rig.state <> "/worktrees/repo/" <> session(1)
}

pub fn an_unseen_repository_is_placed_whole_and_then_by_its_delta_test() {
  let placement = serve("unseen")
  let remote = attached(placement)
  let source = unseen_repository(placement)
  let first = git(source, ["rev-parse", "HEAD"])

  // The executor's repository has never held this commit.
  let #(code, _missing) =
    worktree_rig.git_status(placement.rig.root, [
      "cat-file",
      "-e",
      first <> "^{commit}",
    ])
  assert code != 0

  // A full bundle carries the whole history, and the scope's tree checks it
  // out on the session's branch.
  let #(whole, applied) = placed(placement, remote, source, Full)
  assert whole.base == None
  assert applied == Ok(first)
  let tree = tree_of(placement)
  assert git(tree, ["rev-parse", "HEAD"]) == first
  assert simplifile.read(tree <> "/go.mod") == Ok("module example.com/review\n")

  // The next commit goes as a delta against the one the executor now holds.
  write(source <> "/fix.go", "package main\n\nfunc fix() {}\n")
  git(source, ["add", "fix.go"])
  git(source, ["commit", "--quiet", "-m", "the fix"])
  let second = git(source, ["rev-parse", "HEAD"])
  let #(delta, applied) = placed(placement, remote, source, Thin(first))
  assert delta.base == Some(first)
  let assert Ok(Some(held)) = state_store.get(placement.store, delta.hash)
    as "the orchestrator holds the delta"
  let assert Ok(bytes) = simplifile.read_bits(held.path)
  let assert Ok(header) = state_object.parse_header(bytes)
  assert header.prerequisites == [first]
  assert applied == Ok(second)
  assert git(tree, ["rev-parse", "HEAD"]) == second
  assert simplifile.read(tree <> "/fix.go")
    == Ok("package main\n\nfunc fix() {}\n")
  stop(placement)
}
