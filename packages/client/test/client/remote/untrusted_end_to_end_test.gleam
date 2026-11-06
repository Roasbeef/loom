//// An orchestrator's surface and owner port driving a real executor host
//// through the untrusted link and gateway (protocol-change/109).
////
//// Nothing here is a distribution peer: the surface addresses the link by a
//// name on this node, the link dials the gateway over TLS with minted
//// certificates, and the gateway feeds the same host a trusted executor runs.
//// The tests show that the vocabulary of 078 survives the trip unchanged: an
//// attach comes back with the census minus what the orchestrator decides for
//// itself, a call runs and its outcome returns, an escalation the plane raises
//// mid-call reaches the owner port and its decision reaches the plane, and the
//// death of the process that asked becomes the host's abort.

import client/escalate
import client/owner_services
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/remote/untrusted_gateway
import client/remote/untrusted_link
import client/remote/untrusted_wire
import core/clock
import core/json
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import telemetry/log

/// What the fake plane tells the test.
type Seen {
  /// The plane started running a call, in this process.
  Running(call: String, pid: process.Pid)

  /// The owner answered the plane's escalation.
  Decided(decision: escalate.Decision)
}

type Rig {
  Rig(
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    link: process.Pid,
    name: process.Name(protocol.HostMessage(RemoteCensus)),
    port: owner_port.Port,
    seen: Subject(Seen),
    escalations: Subject(escalate.Refused),
  )
}

fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let seen = process.new_subject()
  let escalations = process.new_subject()
  let executor =
    remote_orchestrator.start(plane_factory(
      seen,
      remote_orchestrator.census(remote_orchestrator.standard_tools()),
    ))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      logger: log.discard(),
    ))
    as "the gateway starts"
  let name = process.new_name("untrusted_end_to_end")
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
  let services = owner_services_resuming(fixtures.quiet_services(), escalations)
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
      git_identity: None,
    ))
    as "the port starts"
  Rig(executor:, gateway:, link:, name:, port:, seen:, escalations:)
}

// Owner services whose escalation records the refusal and resumes.
fn owner_services_resuming(
  services: owner_services.OwnerServices,
  escalations: Subject(escalate.Refused),
) -> owner_services.OwnerServices {
  owner_services.OwnerServices(..services, escalate: fn(refused) {
    process.send(escalations, refused)
    escalate.Resume(grants: [])
  })
}

// A plane whose `ask` call escalates to its owner mid-run, whose `hold` call
// waits until it is killed, and whose other calls complete at once.
fn plane_factory(
  seen: Subject(Seen),
  census: RemoteCensus,
) -> host.PlaneFactory(RemoteCensus) {
  fn(spec: host.AttachSpec) {
    Ok(host.Plane(
      run: fn(run, _authority) {
        process.send(seen, Running(call: run.call.id, pid: process.self()))
        case run.call.id {
          "ask" -> {
            let decision = spec.owner.escalate(refused_for(run))
            process.send(seen, Decided(decision))
            fixtures.expected_outcome(run)
          }
          "hold" -> {
            process.sleep_forever()
            fixtures.expected_outcome(run)
          }
          _other -> fixtures.expected_outcome(run)
        }
      },
      census:,
      children: fn(builder) { builder },
      close: fn(retire_children) {
        let _retired = retire_children()
        protocol.AllRetired
      },
      execute: fn(_start) { json.Null },
      abort_step: fn(_op, _step) { Nil },
      evolution: None,
      state: None,
    ))
  }
}

fn refused_for(run: ToolRun) -> escalate.Refused {
  escalate.Refused(
    operation: run.operation,
    strand: run.strand,
    step_id: run.step_id,
    source_index: run.source_index,
    call_id: run.call.id,
    tool: run.call.name,
    denial: fixtures.denial(),
    arguments: run.arguments,
    deadline_ms: 60_000,
  )
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.link)
  process.kill(rig.link)
  process.unlink(rig.gateway.acceptor)
  process.kill(rig.gateway.acceptor)
  remote_orchestrator.stop(rig.executor)
}

fn attached(rig: Rig) -> surface.Attachment(RemoteCensus) {
  let assert Ok(attachment) =
    surface.attach(surface.Config(
      address: untrusted_link.address(rig.name),
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      port: rig.port,
      read_authority: fn(_run) { Ok(fixtures.authority()) },
      reconnect: fn() { untrusted_link.running(rig.name, "pod") },
      remote_tools: ["bash"],
      attach_within_ms: 10_000,
      mint_token: surface.strong_token,
    ))
    as "the attach succeeds over the link"
  attachment
}

fn call(id: String) -> ToolRun {
  fixtures.tool_run(id, 0)
}

pub fn an_attach_returns_the_census_with_the_orchestrators_own_fields_test() {
  let rig = start("census")
  let surface.Attachment(attached:, ..) = attached(rig)

  let expected =
    remote_orchestrator.census(remote_orchestrator.standard_tools())
  assert attached.census.tools == expected.tools
  assert attached.census.prompt == expected.prompt
  assert attached.census.census.workspace == expected.census.workspace
  assert attached.census.evolution
    == remote_census.Uncompiled(untrusted_wire.no_evolution_reason)
  assert attached.unacked
    == protocol.Unacked(terminal: [], unknown: [], executions: [])
  stop(rig)
}

pub fn a_call_runs_on_the_executor_and_its_outcome_returns_test() {
  let rig = start("run")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = call("plain")

  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  let assert Ok(Running(call: "plain", ..)) = process.receive(rig.seen, 2000)
    as "the plane ran the call"
  stop(rig)
}

pub fn an_escalation_mid_call_reaches_the_owner_and_its_decision_the_plane_test() {
  let rig = start("escalate")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = call("ask")

  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  let assert Ok(refused) = process.receive(rig.escalations, 2000)
    as "the owner was asked"
  assert refused.call_id == "ask"
  assert refused.arguments == run.arguments
  let assert Ok(Running(call: "ask", ..)) = process.receive(rig.seen, 2000)
    as "the plane ran the call"
  assert process.receive(rig.seen, 2000)
    == Ok(Decided(escalate.Resume(grants: [])))
  stop(rig)
}

pub fn the_death_of_the_asker_aborts_the_call_on_the_executor_test() {
  let rig = start("abort")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = call("hold")
  let asker = process.spawn_unlinked(fn() { surface.run(remote, run) })
  let assert Ok(Running(call: "hold", pid: worker)) =
    process.receive(rig.seen, 5000)
    as "the plane started the call"
  let watch = process.monitor(worker)

  // The cancel crosses the link, the gateway kills the waiter, and the host
  // reads that as an abort and stops the call's worker.
  process.kill(asker)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
  assert process.selector_receive(selector, 10_000) == Ok(Nil)
  stop(rig)
}
