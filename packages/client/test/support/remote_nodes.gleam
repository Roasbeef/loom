//// The two halves of a remote tool call across real emulators.
////
//// `client_distribution_fixture_ffi` boots one emulator per node with the
//// production TLS distribution flags, and its roles call into this module.
//// The executor role starts the real host over a fake workspace plane and
//// registers a probe so the orchestrator can count how many times the fake
//// tool ran. The orchestrator role attaches a real surface, runs a call, and
//// loses the connection while the call is in flight, because a connection that
//// is dropped on a real network is the only way to show that a re-sent `Run`
//// reaches a host that already holds the call.
////
//// The scenarios differ in how long the connection stays down. A short outage
//// is repaired while the tool is still running, so the re-sent `Run` joins the
//// live call. A long one outlasts the tool, so the outcome waits in the ledger
//// and the re-sent `Run` is answered from the stored row. Both must produce the
//// outcome exactly once and run the tool exactly once.

import broker/exec
import client/catalog
import client/distribution
import client/escalate
import client/executor_plane
import client/internal/ffi_os
import client/internal/ffi_remote
import client/jobs
import client/owner_services
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/workspaces
import core/clock
import core/json
import core/message
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/secret
import runtime/effects
import simplifile
import storage/exec_ledger
import support/remote_fixtures as fixtures
import support/worktree_rig
import telemetry/log

/// What the executor role keeps until it is asked to verify.
pub type HostHandle {
  HostHandle(probe: fixtures.Probe)
}

@external(erlang, "erlang", "disconnect_node")
fn disconnect_node(node: Node) -> Bool

fn probe_name() -> Name(fixtures.ProbeMessage) {
  ffi_remote.fixed_name("loom_remote_probe")
}

/// The executor role: a host over a ledger in `directory`, whose fake tool
/// finishes `hold_ms` milliseconds after it starts. `asks` is `"owner"` for a
/// tool that asks its owner to decide a refusal first and `"nothing"` otherwise.
pub fn host(
  directory: String,
  asks: String,
  hold_ms: Int,
) -> Result(HostHandle, String) {
  let probe = fixtures.named_probe(fixtures.Held, probe_name())
  let mode = case asks {
    "owner" -> fixtures.AsksOwner
    _ -> fixtures.AsksNothing
  }
  let config =
    host.Config(
      name: address.default(),
      ledger_path: directory <> "/ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: 65_536,
      clock: clock.fixed(at: 1000),
      factory: fixtures.factory(probe, mode, protocol.AllRetired),
      execution_result_bytes: host.default_execution_result_bytes,
    )
  use _started <- result.try(
    host.start(config) |> result.map_error(string.inspect),
  )

  // The tool is released a fixed time after it starts, by the executor itself,
  // so it finishes whether or not the orchestrator is connected.
  let _releaser =
    process.spawn_unlinked(fn() {
      let _started = fixtures.eventually(fn() { fixtures.runs(probe) != [] })
      process.sleep(hold_ms)
      fixtures.release(probe)
    })
  Ok(HostHandle(probe:))
}

/// The executor role's last word: the fake tool ran exactly once.
pub fn verify_host(handle: HostHandle) -> Result(Nil, String) {
  case list.length(fixtures.runs(handle.probe)) {
    1 -> Ok(Nil)
    other ->
      Error(
        "the executor ran the tool "
        <> string.inspect(other)
        <> " times, not once",
      )
  }
}

/// The orchestrator role. `scenario` is `"run"` for an undisturbed call that
/// round-trips an owner callback, `"short_outage"` for a connection that drops
/// and is repaired while the tool runs, and `"long_outage"` for one that stays
/// down until the tool has finished.
pub fn orchestrate(
  peer: distribution.Peer,
  scenario: String,
) -> Result(Nil, String) {
  let target = distribution.node(peer)
  let reconnect = case scenario {
    "long_outage" -> fn() {
      process.sleep(2500)
      reconnect_to(peer)
    }
    _ -> fn() { reconnect_to(peer) }
  }
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: owner_services.OwnerServices(
        ..fixtures.quiet_services(),
        escalate: fn(_refused: escalate.Refused) { escalate.Settle },
      ),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
    )),
  )
  use attachment <- result.try(
    surface.attach(surface.Config(
      address: address.Address(node: target, name: address.default()),
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      port:,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect:,
      remote_tools: ["bash"],
      attach_within_ms: 10_000,
      mint_token: surface.strong_token,
    ))
    |> result.map_error(protocol.describe),
  )
  let remote = attachment.surface
  let run = fixtures.tool_run("call_1", 0)
  let outcome = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, surface.run(remote, run))
    })
  use Nil <- result.try(case scenario {
    "run" -> Ok(Nil)
    _ -> partition(target)
  })
  use finished <- result.try(
    process.receive(outcome, 30_000)
    |> result.replace_error("the call never produced an outcome"),
  )
  let expected = case scenario {
    "run" ->
      effects.ToolCompleted(
        result: fixtures.text_result(run, "settled"),
        terminate: False,
      )
    _ -> fixtures.expected_outcome(run)
  }
  use Nil <- result.try(case finished == expected {
    True -> Ok(Nil)
    False -> Error("unexpected outcome: " <> string.inspect(finished))
  })
  exactly_once(peer, target)
}

fn reconnect_to(peer: distribution.Peer) -> Result(Nil, String) {
  distribution.connect(peer, 5000)
  |> result.map_error(distribution.describe)
}

// Waits for the executor's tool to start, then drops the connection under it.
fn partition(target: Node) -> Result(Nil, String) {
  let started =
    fixtures.eventually(fn() {
      executor_runs(target) |> result.unwrap([]) != []
    })
  case started {
    False -> Error("the tool never started on the executor")
    True -> {
      let _dropped = disconnect_node(target)
      Ok(Nil)
    }
  }
}

// Asks the executor's probe what the fake tool did, over whatever connection
// exists now.
fn executor_runs(target: Node) -> Result(List(#(process.Pid, String)), String) {
  let reply = process.new_subject()
  ffi_remote.send(to: target, name: probe_name(), message: fixtures.Runs(reply))
  process.receive(reply, 1000)
  |> result.replace_error("the executor's probe did not answer")
}

// After the outcome is in hand, the connection is repaired if it is still down,
// and the executor's probe is asked how many times the tool ran.
fn exactly_once(peer: distribution.Peer, target: Node) -> Result(Nil, String) {
  use Nil <- result.try(reconnect_to(peer))
  use runs <- result.try(executor_runs(target))
  case list.map(runs, fn(entry) { entry.1 }) {
    ["call_1"] -> Ok(Nil)
    other ->
      Error("the executor ran " <> string.inspect(other) <> ", not call_1 once")
  }
}

// --- a real workspace across two nodes -------------------------------------

/// What the executor role of a real workspace keeps until it verifies.
pub type WorkspaceHandle {
  WorkspaceHandle(checkout: String)
}

/// The executor role of a real workspace: the production factory over a
/// checkout under `directory`, served by the real host under its fixed name.
pub fn workspace_host(directory: String) -> Result(WorkspaceHandle, String) {
  let checkout = directory <> "/checkout"
  let state = directory <> "/state"
  use Nil <- result.try(
    simplifile.create_directory_all(checkout)
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(bootstrap.ensure_private_directory(state))
  use helper <- result.try(helper_path())
  let machine =
    executor_plane.Machine(
      state_root: state,
      helper_path: helper,
      helper_pool_size: 4,
      demand: exec.BestEffort,
      workspace: catalog.default_workspace(),
      tools: catalog.default_tools(),
      deactivated_tools: [],
      lsp_servers: [],
      jobs_policy: jobs.default_policy,
      codemode_seed: Some(state <> "/no-such-seed"),
      secrets: secret.env(),
      home: None,
      logger: log.discard(),
      mcp_servers: [],
    )
  let served = [workspaces.shared("proj", checkout)]
  use trees <- result.try(executor_plane.worktrees_of(machine, served))
  let config =
    host.Config(
      name: address.default(),
      ledger_path: state <> "/exec-ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory(machine, served, trees),
      execution_result_bytes: host.default_execution_result_bytes,
    )
  use _started <- result.try(
    host.start(config) |> result.map_error(string.inspect),
  )
  Ok(WorkspaceHandle(checkout:))
}

/// What the executor role of worktree workspaces keeps until it verifies.
pub type TreesHandle {
  TreesHandle(repository: String, state: String)
}

/// The executor role of a worktree workspace: a real repository under
/// `directory`, the production factory with `proj` in worktree mode, and the
/// real host under its fixed name.
pub fn worktree_host(directory: String) -> Result(TreesHandle, String) {
  let state = directory <> "/state"
  use Nil <- result.try(bootstrap.ensure_private_directory(state))
  use state <- result.try(bootstrap.canonical_directory(state))
  worktree_rig.establish(state)
  let repository = worktree_rig.repository(directory <> "/repo")
  use helper <- result.try(helper_path())
  let machine =
    executor_plane.Machine(
      state_root: state,
      helper_path: helper,
      helper_pool_size: 4,
      demand: exec.BestEffort,
      workspace: catalog.default_workspace(),
      tools: catalog.default_tools(),
      deactivated_tools: [],
      lsp_servers: [],
      jobs_policy: jobs.default_policy,
      codemode_seed: Some(state <> "/no-such-seed"),
      secrets: secret.env(),
      home: None,
      logger: log.discard(),
      mcp_servers: [],
    )
  let served = [
    workspaces.Workspace("proj", repository, workspaces.Worktree("main")),
  ]
  use trees <- result.try(executor_plane.worktrees_of(machine, served))
  let config =
    host.Config(
      name: address.default(),
      ledger_path: state <> "/exec-ledger.db",
      limits: exec_ledger.default_limits(),
      max_result_bytes: host.default_max_result_bytes,
      clock: clock.from_function(ffi_os.system_time_ms),
      factory: executor_plane.factory(machine, served, trees),
      execution_result_bytes: host.default_execution_result_bytes,
    )
  use _started <- result.try(
    host.start(config) |> result.map_error(string.inspect),
  )
  Ok(TreesHandle(repository:, state:))
}

/// The executor role's last word: the clean session's tree is gone and the one
/// with changes is still there with them, and both branches remain.
pub fn verify_worktrees(handle: TreesHandle) -> Result(Nil, String) {
  let clean = handle.state <> "/worktrees/proj/" <> clean_session
  let dirty = handle.state <> "/worktrees/proj/" <> dirty_session
  use Nil <- result.try(case worktree_rig.exists(clean) {
    True -> Error("the clean session's tree was not removed")
    False -> Ok(Nil)
  })
  use Nil <- result.try(case simplifile.read(dirty <> "/wip.txt") {
    Ok("unsaved\n") -> Ok(Nil)
    other -> Error("the changed tree holds " <> string.inspect(other))
  })
  let branches =
    worktree_rig.git(handle.repository, ["branch", "--list", "loom/*"])
  case
    string.contains(branches, "loom/" <> clean_session)
    && string.contains(branches, "loom/" <> dirty_session)
  {
    True -> Ok(Nil)
    False -> Error("a branch is missing: " <> branches)
  }
}

const clean_session = "0198c0de-0000-7000-8000-0000000000a1"

const dirty_session = "0198c0de-0000-7000-8000-0000000000a2"

/// The orchestrator role of a worktree workspace: two sessions attach to `proj`
/// over TLS distribution, each gets a tree and a branch of its own and edits
/// the same file without seeing the other, then one closes clean and the other
/// with an unsaved file.
pub fn orchestrate_worktrees(peer: distribution.Peer) -> Result(Nil, String) {
  let target = distribution.node(peer)
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
    )),
  )
  let attach = fn(session) {
    surface.attach(surface.Config(
      address: address.Address(node: target, name: address.default()),
      session:,
      workspace: "proj",
      incarnation: 0,
      port:,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect: fn() { reconnect_to(peer) },
      remote_tools: ["fs_write", "fs_read"],
      attach_within_ms: 120_000,
      mint_token: surface.strong_token,
    ))
    |> result.map_error(protocol.describe)
  }
  use first <- result.try(attach(clean_session))
  use second <- result.try(attach(dirty_session))
  let one: RemoteCensus = first.attached.census
  let two: RemoteCensus = second.attached.census
  use Nil <- result.try(
    case
      one.census.workspace != two.census.workspace
      && one.branch == Some("loom/" <> clean_session)
      && two.branch == Some("loom/" <> dirty_session)
    {
      True -> Ok(Nil)
      False -> Error("the two sessions did not get a tree and a branch each")
    },
  )

  // Both write the same relative file in their own trees.
  use Nil <- result.try(write_readme(first, one, "from one\n", 0))
  use Nil <- result.try(write_readme(second, two, "from two\n", 1))
  use Nil <- result.try(read_readme(first, one, "from one", 2))
  use Nil <- result.try(read_readme(second, two, "from two", 3))

  // The first session puts the file back as the repository has it, so its tree
  // is clean again, and the second leaves an unsaved file; then both scopes
  // close.
  use Nil <- result.try(write_readme(first, one, "one\n", 5))
  let wip = two.census.workspace <> "/wip.txt"
  use Nil <- result.try(
    completed(surface.run(
      second.surface,
      call(
        "fs_write",
        [#("path", json.String(wip)), #("content", json.String("unsaved\n"))],
        4,
      ),
    )),
  )
  use Nil <- result.try(close_scope(target, clean_session))
  close_scope(target, dirty_session)
}

fn write_readme(
  attachment: surface.Attachment(RemoteCensus),
  census: RemoteCensus,
  text: String,
  n: Int,
) -> Result(Nil, String) {
  completed(surface.run(
    attachment.surface,
    call(
      "fs_write",
      [
        #("path", json.String(census.census.workspace <> "/README")),
        #("content", json.String(text)),
      ],
      n,
    ),
  ))
}

fn read_readme(
  attachment: surface.Attachment(RemoteCensus),
  census: RemoteCensus,
  expected: String,
  n: Int,
) -> Result(Nil, String) {
  let read =
    surface.run(
      attachment.surface,
      call(
        "fs_read",
        [#("path", json.String(census.census.workspace <> "/README"))],
        n,
      ),
    )
  contains(text_of(read), expected)
}

fn close_scope(target: Node, session: String) -> Result(Nil, String) {
  let reply = process.new_subject()
  address.deliver(
    address.Address(node: target, name: address.default()),
    protocol.Close(session:, workspace: "proj", incarnation: 0, reply:),
  )
  case process.receive(reply, 120_000) {
    Ok(Ok(protocol.AllRetired)) -> Ok(Nil)
    Ok(Ok(protocol.UnknownCleanup(..))) ->
      Error("the close of " <> session <> " could not prove cleanup")
    Ok(Error(refusal)) -> Error(protocol.describe(refusal))
    Error(Nil) -> Error("the close of " <> session <> " was not answered")
  }
}

// The shipped helper beside the packages, by the path the test runner's
// working directory gives it.
fn helper_path() -> Result(String, String) {
  use here <- result.try(
    simplifile.current_directory() |> result.map_error(string.inspect),
  )
  Ok(here <> "/../sandbox/loom-exec")
}

/// The executor role's last word: the orchestrator's file is in the checkout.
pub fn verify_workspace(handle: WorkspaceHandle) -> Result(Nil, String) {
  case simplifile.read(handle.checkout <> "/from-orchestrator.txt") {
    Ok("written over tls\n") -> Ok(Nil)
    other -> Error("the executor's checkout holds " <> string.inspect(other))
  }
}

/// The orchestrator role of a real workspace: it attaches by name, learns the
/// executor's checkout from the census, writes a file there and reads it back.
pub fn orchestrate_workspace(peer: distribution.Peer) -> Result(Nil, String) {
  let target = distribution.node(peer)
  use port <- result.try(
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
    )),
  )
  use attachment <- result.try(
    surface.attach(surface.Config(
      address: address.Address(node: target, name: address.default()),
      session: "s1",
      workspace: "proj",
      incarnation: 0,
      port:,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect: fn() { reconnect_to(peer) },
      remote_tools: ["fs_write", "fs_read"],
      attach_within_ms: 60_000,
      mint_token: surface.strong_token,
    ))
    |> result.map_error(protocol.describe),
  )
  let census: RemoteCensus = attachment.attached.census
  let path = census.census.workspace <> "/from-orchestrator.txt"
  let written =
    surface.run(
      attachment.surface,
      call(
        "fs_write",
        [
          #("path", json.String(path)),
          #("content", json.String("written over tls\n")),
        ],
        0,
      ),
    )
  use Nil <- result.try(completed(written))
  let read =
    surface.run(
      attachment.surface,
      call("fs_read", [#("path", json.String(path))], 1),
    )
  use Nil <- result.try(completed(read))
  contains(text_of(read), "written over tls")
}

fn call(
  name: String,
  arguments: List(#(String, json.JsonValue)),
  n: Int,
) -> effects.ToolRun {
  let base = fixtures.tool_run("call_" <> string.inspect(n), n)
  let arguments = json.Object(arguments)
  effects.ToolRun(
    ..base,
    call: message.ToolCall(..base.call, name:, arguments:),
    arguments:,
  )
}

fn completed(outcome: effects.ToolOutcome) -> Result(Nil, String) {
  case outcome {
    effects.ToolCompleted(..) -> Ok(Nil)
    effects.ToolFailed(reason:) -> Error("the tool failed: " <> reason)
  }
}

fn text_of(outcome: effects.ToolOutcome) -> String {
  case outcome {
    effects.ToolCompleted(result: message.ToolResultMessage(content:, ..), ..) ->
      list.filter_map(content, fn(part) {
        case part {
          message.ToolResultText(text:, ..) -> Ok(text)
          message.ToolResultImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    effects.ToolCompleted(..) | effects.ToolFailed(..) -> ""
  }
}

fn contains(text: String, fragment: String) -> Result(Nil, String) {
  case string.contains(text, fragment) {
    True -> Ok(Nil)
    False -> Error("the read returned " <> string.inspect(text))
  }
}
