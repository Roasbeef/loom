//// Fixtures for a registered session on an in-process executor.
////
//// The executor is the real host over a real ledger, with a fake plane whose
//// census is built by hand: a few described tools, a prompt fact, a broker
//// subject, and an executor clock that can be set apart from this machine's.
//// The fake plane's run records each call in a `Probe` and completes with the
//// text `ran:<tool name>`, so a test can count what reached the executor.

import broker/broker
import broker/exec
import broker/token
import client/remote/address
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus, RemoteCensus}
import client/remote/workspace
import client/system_prompt
import client/workspace_plane
import client/workspace_policy
import core/clock
import core/json
import gleam/erlang/process
import gleam/option.{Some}
import runtime/effects
import storage/exec_ledger
import support/remote_fixtures as fixtures
import tools/tool

/// The workspace root the fake executor reports. It is a path on the
/// executor's machine and is never created.
pub const executor_root = "/executor/checkout"

/// A tool description with the given name and replay safety.
pub fn described(name: String, replay: tool.ReplaySafety) -> tool.Described {
  tool.Described(
    name:,
    description: "The fake " <> name <> " tool.",
    prompt_snippet: Some("Use " <> name <> " for the fixture."),
    schema: json.Object([#("type", json.String("object"))]),
    replay:,
    execution_mode: tool.Exclusive,
  )
}

/// The census the fake executor reports when its clock reads `now_ms`, with a
/// broker subject nothing answers. A caller that never reaches the broker needs
/// no more.
pub fn census(now_ms: Int, tools: List(tool.Described)) -> RemoteCensus {
  census_over(now_ms, tools, process.new_subject())
}

/// The same census over an executor broker that is really running.
pub fn census_over(
  now_ms: Int,
  tools: List(tool.Described),
  executor_broker: process.Subject(broker.Msg),
) -> RemoteCensus {
  RemoteCensus(
    census: workspace_plane.Census(
      workspace: executor_root,
      toolchain: Error("the fake executor has no toolchain"),
      lsp_servers: [],
      extensions: [],
      platform: #("linux", "x86_64"),
      shell: "/bin/sh",
      base_policy: workspace_policy.base_policy(executor_root),
      env: [],
      unset_env: [],
      git: "git",
      hook_files: [],
      warnings: [],
    ),
    tools:,
    prompt: workspace_plane.PromptFacts(
      guidance: [
        system_prompt.GuidanceFile(
          path: executor_root <> "/AGENTS.md",
          origin: system_prompt.WorkspaceFile,
          text: "EXECUTOR-GUIDANCE-MARKER",
        ),
      ],
      guidance_notes: [],
      helper: workspace_plane.Healthy,
    ),
    broker: executor_broker,
    executor_now_ms: now_ms,
  )
}

/// A running broker standing for the executor's. It refuses every clearance, as
/// a pool with no helpers would, and records each attempt in `attempts`, so a
/// test can see that a call reached it and nothing needs a sandbox helper.
pub fn refusing_broker(attempts: fixtures.Marks) -> broker.Broker {
  let assert Ok(running) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() {
          fixtures.mark(
            attempts,
            protocol.Key(session: "", op: "", step: "", source_index: 0),
          )
          Error(exec.PoolUnavailable)
        },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the refusing broker starts"
  running
}

/// A plane factory over `census`, whose plane runs the fake tool.
pub fn factory(
  probe: fixtures.Probe,
  census: RemoteCensus,
  close_outcome: protocol.CloseOutcome,
) -> host.PlaneFactory(RemoteCensus) {
  fn(spec: host.AttachSpec) {
    process.send(probe.subject, fixtures.Built(owner: spec.owner))
    Ok(
      host.Plane(
        run: fn(run, _authority) {
          process.send(
            probe.subject,
            fixtures.Ran(pid: process.self(), call: run.call.id),
          )
          effects.ToolCompleted(
            result: fixtures.text_result(run, "ran:" <> run.call.name),
            terminate: False,
          )
        },
        census:,
        children: fn(builder) { builder },
        close: fn(retire_children) {
          let _ = retire_children()
          process.send(probe.subject, fixtures.Closed)
          close_outcome
        },
      ),
    )
  }
}

/// A running executor: the host's pid and its address.
pub type Executor {
  Executor(pid: process.Pid, address: address.Address(RemoteCensus))
}

/// Starts a host over a fresh ledger in a private directory.
pub fn start(factory: host.PlaneFactory(RemoteCensus)) -> Executor {
  let path = fixtures.scratch("orchestrator") <> "/ledger.db"
  start_at(path, factory)
}

/// Starts a host over the ledger at `path`.
pub fn start_at(
  path: String,
  factory: host.PlaneFactory(RemoteCensus),
) -> Executor {
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("orchestrator_test_host"),
      ledger_path: path,
      limits: exec_ledger.default_limits(),
      max_result_bytes: 65_536,
      clock: clock.fixed(at: 1000),
      factory:,
    ))
    as "the host starts"
  Executor(pid: started.pid, address: started.data)
}

/// Stops the host.
pub fn stop(executor: Executor) -> Nil {
  process.unlink(executor.pid)
  process.kill(executor.pid)
}

/// How an orchestrator reaches the executor.
pub fn reach(executor: Executor) -> workspace.Reach {
  workspace.Reach(
    address: executor.address,
    connect: fn() { Ok(Nil) },
    attach_within_ms: 2000,
  )
}

/// The census every test of this family uses: a `bash` that must not be
/// replayed and an `fs_read` that may be.
pub fn standard_tools() -> List(tool.Described) {
  [described("bash", tool.Never), described("fs_read", tool.Safe)]
}

/// No owner callbacks served, for a test of the attach alone.
pub fn quiet() {
  fixtures.quiet_services()
}

/// A registered-session configuration over `executor` for the given store.
pub fn registered(
  executor: Executor,
  opened,
  local: clock.Clock,
) -> workspace.Registered {
  workspace.Registered(
    reach: reach(executor),
    session: "registered-session",
    workspace: "registered-name",
    opened:,
    owner: quiet(),
    clock: local,
    reconcile_every_ms: 60_000,
  )
}
