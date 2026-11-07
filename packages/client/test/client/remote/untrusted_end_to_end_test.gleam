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
////
//// A background program takes the whole trip of slice 2: the plane's
//// `code_mode` call asks the owner to launch it, the owner's execution service
//// starts it through the surface the session attached with, the host runs it,
//// its capability call reaches the owner while it runs, and its value comes
//// back to the record's worker. The worker's death stops it on the executor.

import broker/framing
import client/escalate
import client/owner_services
import client/remote/blob_service
import client/remote/blob_store
import client/remote/blob_transfer
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/remote/untrusted_bridge
import client/remote/untrusted_codec
import client/remote/untrusted_gateway
import client/remote/untrusted_link
import client/remote/untrusted_wire
import core/clock
import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import runtime/effects.{type ToolRun}
import simplifile
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import telemetry/log
import tools/codemode as codemode_tool
import weft/poll

/// What the fake plane tells the test.
type Seen {
  /// The plane started running a call, in this process.
  Running(call: String, pid: process.Pid)

  /// The owner answered the plane's escalation.
  Decided(decision: escalate.Decision)

  /// The owner answered the plane's launch.
  Launched(answer: Result(json.JsonValue, String))

  /// A background program started, in this process.
  Programmed(pid: process.Pid)
}

/// What the owner's execution service tells the test.
type Record {
  /// The record's worker started, in this process.
  Working(pid: process.Pid)

  /// The worker heard how its execution ended.
  Ended(answer: protocol.ExecutionAnswer)

  /// The owner served a program's capability call.
  Served(call: owner_services.OwnerCapCall)
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
    /// Where the orchestrator places blobs through the link.
    blobs: Subject(untrusted_bridge.BlobAsk),
    /// The executor's keeper of placed blobs.
    keeper: blob_service.Service,
    records: Subject(Record),
  )
}

/// The outcome the plane's `big` call returns: larger than one frame of the
/// link, so it can only arrive in pieces (protocol-change/110).
fn big_outcome() -> effects.ToolOutcome {
  effects.ToolFailed(reason: string.repeat("proof transcript ", 2_500_000))
}

fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let seen = process.new_subject()
  let escalations = process.new_subject()
  let executor =
    remote_orchestrator.start_holding(
      plane_factory(
        seen,
        remote_orchestrator.census(remote_orchestrator.standard_tools()),
      ),
      67_108_864,
    )
  let assert Ok(store) =
    blob_store.open(
      fixtures.scratch("untrusted-e2e-blobs-" <> label) <> "/placed-blobs",
      blob_store.default_limits,
    )
    as "the blob store opens"
  let assert Ok(keeper) =
    blob_service.start(store, blob_service.default_bounds, fn() { 1_000_000 })
    as "the keeper starts"
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: Some(keeper),
      logger: log.discard(),
    ))
    as "the gateway starts"
  let name = process.new_name("untrusted_end_to_end")
  let assert Ok(untrusted_link.Started(pid: link, blobs:)) =
    untrusted_link.start_placing(untrusted_link.Config(
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
  let records = process.new_subject()
  let services =
    owner_services_resuming(fixtures.quiet_services(), escalations)
    |> serving_capabilities(records)
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: recording_executions(records),
      mcp: protocol.empty_mcp_plan(),
      git_identity: None,
    ))
    as "the port starts"
  Rig(
    executor:,
    gateway:,
    link:,
    name:,
    port:,
    seen:,
    escalations:,
    blobs:,
    keeper:,
    records:,
  )
}

// Owner services whose capability records the call and answers `pong`.
fn serving_capabilities(
  services: owner_services.OwnerServices,
  records: Subject(Record),
) -> owner_services.OwnerServices {
  owner_services.OwnerServices(..services, capability: fn(call) {
    process.send(records, Served(call))
    Ok(framing.CapOk(msgpack.StringValue("pong")))
  })
}

// An execution service that claims every launch as execution `e1` and starts
// its record's worker as the real one does: a process that starts the program
// through the host link the session attached with and waits for its end.
fn recording_executions(records: Subject(Record)) -> owner_port.Executions {
  owner_port.Executions(
    launch: fn(terms, link) {
      let key = protocol.execution_key("s1", terms.op_id, "e1")
      let worker =
        process.spawn_unlinked(fn() {
          process.send(records, Ended(link.start(key, terms, 60_000)))
        })
      process.send(records, Working(worker))
      Ok(json.String("e1"))
    },
    interact: fn(_strand, _handle, _interaction, _within) {
      Error("no interaction here")
    },
    standing: fn(_key) { owner_port.RecordLive },
  )
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
// waits until it is killed, whose `launch` calls launch a background program,
// and whose other calls complete at once.
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
          "big" -> big_outcome()
          "launch" | "launch-hold" -> {
            process.send(
              seen,
              Launched(spec.owner.launch_execution(terms_of(run))),
            )
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
      execute: fn(start) {
        process.send(seen, Programmed(process.self()))
        program(spec.owner, start)
      },
      abort_step: fn(_op, _step) { Nil },
      evolution: None,
      state: None,
    ))
  }
}

// The fake program: one capability call, made as `executor_plane` makes a
// program's calls (the launching call's strand and position under the
// execution's step), whose answer is its value. A program whose source is
// `hold` waits until it is stopped.
fn program(
  owner: owner_services.OwnerServices,
  start: host.ExecutionStart,
) -> json.JsonValue {
  let terms = start.terms
  case terms.source {
    "hold" -> {
      process.sleep_forever()
      json.Null
    }
    _other ->
      case
        owner.capability(
          owner_services.OwnerCapCall(
            ..fixtures.capability_call(),
            strand: terms.strand,
            op_id: terms.op_id,
            step_id: start.step,
            source_index: terms.source_index,
          ),
        )
      {
        Ok(framing.CapOk(msgpack.StringValue(answer))) ->
          json.Object([#("capability", json.String(answer))])
        Ok(_other) | Error(_denied) ->
          json.Object([#("capability", json.String("denied"))])
      }
  }
}

// What a `code_mode` call's launch captures, as `executor_plane.terms_of`
// builds it from the call.
fn terms_of(run: ToolRun) -> owner_services.ExecutionTerms {
  owner_services.ExecutionTerms(
    ..fixtures.execution_terms(),
    strand: run.strand,
    op_id: run.operation,
    launch_step: run.step_id,
    source_index: run.source_index,
    source: case run.call.id {
      "launch-hold" -> "hold"
      _other -> "pub fn main() { Nil }"
    },
  )
}

// A `code_mode` call with id `id`.
fn code_mode_call(id: String) -> ToolRun {
  let run = fixtures.tool_run(id, 0)
  effects.ToolRun(
    ..run,
    call: message.ToolCall(..run.call, name: codemode_tool.tool_name),
  )
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
      remote_tools: ["bash", codemode_tool.tool_name],
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

pub fn an_outcome_larger_than_a_frame_returns_whole_test() {
  let rig = start("big")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = call("big")
  let outcome = big_outcome()

  // The encoded outcome is past the frame bound, so the gateway can only send
  // it as `oversized` and the link fetches it in pieces from the ledger.
  assert bit_array.byte_size(untrusted_codec.encode_outcome_bytes(outcome))
    > untrusted_wire.max_frame_bytes
  assert surface.run(remote, run) == outcome
  stop(rig)
}

pub fn a_blob_placed_through_the_link_opens_on_the_executor_and_moves_once_test() {
  let rig = start("blob")
  let _attachment = attached(rig)
  let path = fixtures.scratch("untrusted-e2e-archive") <> "/modules.tar"
  let content = <<7:size({ { 2 * blob_transfer.piece_bytes + 5 } * 8 })>>
  let assert Ok(Nil) = simplifile.write_bits(path, content)
    as "the archive is written"

  let assert Ok(blob_transfer.Placed(blob:, sent: 3)) =
    untrusted_link.place_blob(rig.blobs, "s1", path, 30_000)
    as "the archive moves in three pieces"
  assert untrusted_link.place_blob(rig.blobs, "s1", path, 30_000)
    == Ok(blob_transfer.Placed(blob:, sent: 0))

  // The session's plane is handed the checked file; another session is not.
  let assert Ok(held) = blob_service.open(rig.keeper, "s1", blob.digest)
    as "the session's plane opens the blob"
  assert simplifile.read_bits(held) == Ok(content)
  let assert Error(_other) = blob_service.open(rig.keeper, "s2", blob.digest)
  stop(rig)
}

pub fn a_closed_scope_gives_its_blob_claims_back_test() {
  let rig = start("blob-close")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let path = fixtures.scratch("untrusted-e2e-close") <> "/cache.tar"
  let assert Ok(Nil) = simplifile.write_bits(path, <<"module cache":utf8>>)
    as "the cache is written"
  let assert Ok(blob_transfer.Placed(blob:, ..)) =
    untrusted_link.place_blob(rig.blobs, "s1", path, 30_000)
    as "the cache is placed"
  let assert Ok(_path) = blob_service.open(rig.keeper, "s1", blob.digest)
    as "the session holds it while its scope is open"

  let assert Ok(_closed) =
    surface.ask(remote, fn(reply) {
      protocol.Close(
        session: "s1",
        workspace: "/work",
        incarnation: surface.incarnation(remote),
        reply:,
      )
    })
    as "the scope closes"

  // The book retires the closed open's binding, and with it the claim, so
  // the keeper no longer hands the blob to the session.
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 20, attempt: fn() {
      case blob_service.open(rig.keeper, "s1", blob.digest) {
        Error(_released) -> poll.Done(Nil)
        Ok(_still) -> poll.Retry
      }
    })
    as "the claim is given back"
  stop(rig)
}

pub fn a_background_program_launches_calls_its_owner_and_returns_its_value_test() {
  let rig = start("program")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = code_mode_call("launch")

  // The `code_mode` call launches: the owner claims the record, and its
  // worker starts the program through the link.
  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  let assert Ok(Running(call: "launch", ..)) = process.receive(rig.seen, 2000)
    as "the plane ran the call"
  let assert Ok(Working(..)) = process.receive(rig.records, 5000)
    as "the record's worker started"

  // The launching call reports its answer from its own process and the
  // program reports its start from another, so the two arrive in either
  // order: the worker can start the program before the call's report lands.
  let assert Ok(first) = process.receive(rig.seen, 5000)
    as "the plane reports the launch or the program"
  let assert Ok(second) = process.receive(rig.seen, 5000)
    as "the plane reports the other of the two"
  let launched = Launched(Ok(json.String("e1")))
  let assert True = case first, second {
    Launched(..), Programmed(..) -> first == launched
    Programmed(..), Launched(..) -> second == launched
    _, _ -> False
  }
    as "the launch was answered with the handle and the program started"

  // The program's capability call is admitted on its start, whose step is
  // the execution's own, and its answer is the value the worker hears.
  let assert Ok(Served(call)) = process.receive(rig.records, 5000)
    as "the owner served the program's capability"
  assert call.step_id == fixtures.execution_key("s1", "e1").step
  assert call.strand == run.strand
  assert process.receive(rig.records, 10_000)
    == Ok(
      Ended(
        protocol.ExecutionFinished(
          json.Object([#("capability", json.String("pong"))]),
        ),
      ),
    )
  stop(rig)
}

pub fn the_death_of_the_records_worker_stops_the_program_on_the_executor_test() {
  let rig = start("program-stop")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = code_mode_call("launch-hold")

  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  let assert Ok(Working(pid: worker)) = process.receive(rig.records, 5000)
    as "the record's worker started"
  let program = programmed(rig.seen)
  let watch = process.monitor(program)

  // The record closes and kills its worker: the cancel crosses the link, the
  // gateway kills the waiter, and the host stops the program.
  process.kill(worker)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })
  assert process.selector_receive(selector, 10_000) == Ok(Nil)
  stop(rig)
}

// Reads what the plane says until a program starts, and answers its process.
fn programmed(seen: Subject(Seen)) -> process.Pid {
  case process.receive(seen, 5000) {
    Ok(Programmed(pid:)) -> pid
    Ok(_other) -> programmed(seen)
    Error(Nil) -> panic as "the host never started the program"
  }
}
