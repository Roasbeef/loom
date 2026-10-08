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
import client/executors
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
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/result
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

/// The census the fake executor reports, with a broker subject nothing
/// answers. A caller that never reaches the broker needs no more.
pub fn census(tools: List(tool.Described)) -> RemoteCensus {
  census_over(tools, process.new_subject())
}

/// The same census over an executor broker that is really running.
pub fn census_over(
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
  Executor(
    pid: process.Pid,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
  )
}

/// Starts a host over a fresh ledger in a private directory.
pub fn start(factory: host.PlaneFactory(RemoteCensus)) -> Executor {
  let path = fixtures.scratch("orchestrator") <> "/ledger.db"
  start_at(path, factory)
}

/// Starts a host whose clock is `executor_clock`, over a fresh ledger. The
/// clock is the executor's reading in every attach reply, so a test sets the
/// executor's time apart from this machine's through it.
pub fn start_on(
  factory: host.PlaneFactory(RemoteCensus),
  executor_clock executor_clock: clock.Clock,
) -> Executor {
  let path = fixtures.scratch("orchestrator") <> "/ledger.db"
  start_with(path, factory, exec_ledger.default_limits(), executor_clock)
}

/// A clock that reads `from` until `set` gives it another value, for a test
/// that moves an executor's time between two attaches. The value lives in a
/// process of its own, so the clock can be read from the host's process.
pub fn settable_clock(from from: Int) -> #(clock.Clock, fn(Int) -> Nil) {
  // A subject is received only by the process that made it, so the holder
  // makes its own and hands it back.
  let made = process.new_subject()
  let _holder =
    process.spawn_unlinked(fn() {
      let cell = process.new_subject()
      process.send(made, cell)
      hold_time(cell, from)
    })
  let assert Ok(cell) = process.receive(made, 5000) as "the clock cell starts"
  let read = fn() {
    let reply = process.new_subject()
    process.send(cell, ReadTime(reply))
    let assert Ok(now) = process.receive(reply, 5000)
      as "the clock cell answers"
    now
  }
  #(clock.from_function(read), fn(now) { process.send(cell, SetTime(now)) })
}

type TimeMessage {
  ReadTime(reply: Subject(Int))
  SetTime(now: Int)
}

fn hold_time(cell: Subject(TimeMessage), now: Int) -> Nil {
  case process.receive_forever(cell) {
    ReadTime(reply:) -> {
      process.send(reply, now)
      hold_time(cell, now)
    }
    SetTime(now: next) -> hold_time(cell, next)
  }
}

/// Starts a host that admits at most `scopes` scopes that are not cleanly
/// closed, over a fresh ledger.
pub fn start_limited(
  factory: host.PlaneFactory(RemoteCensus),
  scopes scopes: Int,
) -> Executor {
  let path = fixtures.scratch("orchestrator") <> "/ledger.db"
  start_with(
    path,
    factory,
    exec_ledger.Limits(
      ..exec_ledger.default_limits(),
      max_unclean_scopes: scopes,
    ),
    clock.fixed(at: 1000),
  )
}

/// Starts a host over the ledger at `path`.
pub fn start_at(
  path: String,
  factory: host.PlaneFactory(RemoteCensus),
) -> Executor {
  start_with(path, factory, exec_ledger.default_limits(), clock.fixed(at: 1000))
}

fn start_with(
  path: String,
  factory: host.PlaneFactory(RemoteCensus),
  limits: exec_ledger.Limits,
  executor_clock: clock.Clock,
) -> Executor {
  let assert Ok(started) =
    host.start(host.Config(
      name: process.new_name("orchestrator_test_host"),
      ledger_path: path,
      limits:,
      max_result_bytes: 65_536,
      clock: executor_clock,
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

/// The executor name a single-executor placement of this family uses.
pub const executor_name = "box"

/// A candidate named `name` that declares nothing and is reached over `reach`.
pub fn candidate_over(
  name: String,
  reach: workspace.Reach,
) -> workspace.Candidate {
  workspace.Candidate(
    executor: executors.plain(name, name <> "@127.0.0.1"),
    reach:,
  )
}

/// A candidate named `name` for a running executor, declaring nothing.
pub fn candidate(name: String, executor: Executor) -> workspace.Candidate {
  candidate_over(name, reach(executor))
}

/// The same candidate with a declaration of the executor's machine.
pub fn declaring(
  found: workspace.Candidate,
  declaration: fn(executors.Executor) -> executors.Executor,
) -> workspace.Candidate {
  workspace.Candidate(..found, executor: declaration(found.executor))
}

/// A placement over `candidates`: the first open tries them in order, a record
/// naming one finds it by name, and `chosen` is told the name an attach chose.
pub fn placement_of(
  candidates: List(workspace.Candidate),
  chosen: fn(String) -> Nil,
) -> workspace.Placement {
  workspace.Placement(
    first: fn() { Ok(candidates) },
    named: fn(name) {
      list.find(candidates, fn(each) { each.executor.name == name })
      |> result.replace_error(
        "executor_unavailable: no executor named " <> name,
      )
    },
    chosen:,
  )
}

/// A placement whose one candidate is `executor`, named `executor_name`.
pub fn placement(executor: Executor) -> workspace.Placement {
  placement_of([candidate(executor_name, executor)], fn(_name) { Nil })
}

/// A registered-session configuration over `executor` for the given store.
pub fn registered(
  executor: Executor,
  opened,
  local: clock.Clock,
) -> workspace.Registered {
  registered_in(placement(executor), opened, local)
}

/// A registered-session configuration over any placement.
pub fn registered_in(
  placement: workspace.Placement,
  opened,
  local: clock.Clock,
) -> workspace.Registered {
  workspace.Registered(
    placement:,
    session: "registered-session",
    workspace: "registered-name",
    opened:,
    owner: quiet(),
    clock: local,
    reconcile_every_ms: 60_000,
  )
}

/// A host-shaped proxy in front of `real` that stands for a link breaking right
/// after an attach was delivered. It forwards the first attach to the real
/// host with a reply address nobody reads and then exits, so the real host
/// creates the scope and answers into the void, while the orchestrator sees its
/// executor go away without a word. Anything that arrives before the attach
/// passes through unchanged.
///
/// The returned `Executor` is the proxy's: build a candidate over it. Pair it
/// with `one_connection`, so the orchestrator cannot repair the link.
pub fn lossy_link(real: Executor) -> Executor {
  let name = process.new_name("orchestrator_test_lossy")
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) = process.register(process.self(), name)
        as "the proxy registers its name"
      process.send(ready, Nil)
      lose_first_attach(real, process.named_subject(name))
    })
  let assert Ok(Nil) = process.receive(ready, 5000) as "the proxy starts"
  Executor(pid:, address: address.Address(node: real.address.node, name:))
}

fn lose_first_attach(
  real: Executor,
  inbox: Subject(protocol.HostMessage(RemoteCensus)),
) -> Nil {
  case process.receive_forever(inbox) {
    protocol.Attach(
      version:,
      session:,
      workspace:,
      incarnation:,
      token:,
      owner_port:,
      reply: _,
    ) ->
      address.deliver(
        real.address,
        protocol.Attach(
          version:,
          session:,
          workspace:,
          incarnation:,
          token:,
          owner_port:,
          reply: process.new_subject(),
        ),
      )
    message -> {
      address.deliver(real.address, message)
      lose_first_attach(real, inbox)
    }
  }
}

/// A `connect` that succeeds once and fails after that, for an orchestrator
/// whose first connection works and whose repairs do not.
pub fn one_connection() -> fn() -> Result(Nil, String) {
  let connections = process.new_subject()
  process.send(connections, Nil)
  fn() {
    case process.receive(connections, 0) {
      Ok(Nil) -> Ok(Nil)
      Error(Nil) -> Error("the link is down")
    }
  }
}
