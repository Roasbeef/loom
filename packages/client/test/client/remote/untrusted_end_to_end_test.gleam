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
////
//// The broker tunnel (protocol-change/117) carries the session's non-tool
//// callers over the same link and gateway, into a plane whose broker is the production
//// broker over a real helper: a goal check, the baseline probe, the worktree
//// diff after a jailed edit and the peer observation each return what the
//// executor's repository holds, and an imported hook stays refused.

import broker/broker
import broker/budget
import broker/exec
import broker/executor
import broker/framing
import broker/policy
import client/catalog
import client/escalate
import client/goalcheck
import client/goalstate
import client/host_git
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
import client/serve
import client/workspace_plane
import client/workspace_policy
import client/worktree_diff
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import runtime/effects.{type ToolRun}
import simplifile
import support/enforcement
import support/fake_clear_call
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import support/worktree_rig
import telemetry/log
import tools/codemode as codemode_tool
import tools/tool
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
    /// The credentials and pins the link was started with, kept so a test can
    /// start another link for the same executor.
    pair: rig.Pair,
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
    /// The link's tunnel door (protocol-change/117).
    door: process.Name(untrusted_link.Tunnel),
  )
}

/// The outcome the plane's `big` call returns: larger than one frame of the
/// link, so it can only arrive in pieces (protocol-change/110).
fn big_outcome() -> effects.ToolOutcome {
  effects.ToolFailed(reason: string.repeat("proof transcript ", 2_500_000))
}

fn start(label: String) -> Rig {
  start_over(
    label,
    remote_orchestrator.census(remote_orchestrator.standard_tools()),
  )
}

/// `start` over a plane that reports `census`, whose broker a test may make
/// real.
fn start_over(label: String, census: RemoteCensus) -> Rig {
  let pair = rig.pair(label)
  let seen = process.new_subject()
  let escalations = process.new_subject()
  let executor =
    remote_orchestrator.start_holding(plane_factory(seen, census), 67_108_864)
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
      demand: exec.PlatformEnforcement,
      logger: log.discard(),
    ))
    as "the gateway starts"
  let name = process.new_name("untrusted_end_to_end")
  let door = process.new_name("untrusted_end_to_end_door")
  let #(link, blobs) = start_link(pair, gateway, name, door)
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
    pair:,
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
    door:,
  )
}

// Starts a link under `name` for the gateway, as the daemon starts one for a
// configured executor.
fn start_link(
  pair: rig.Pair,
  gateway: untrusted_gateway.Gateway,
  name: process.Name(protocol.HostMessage(RemoteCensus)),
  door: process.Name(untrusted_link.Tunnel),
) -> #(process.Pid, Subject(untrusted_bridge.BlobAsk)) {
  let assert Ok(untrusted_link.Started(pid: link, blobs:)) =
    untrusted_link.start_placing(untrusted_link.Config(
      executor: "pod",
      name:,
      door:,
      host: "127.0.0.1",
      port: gateway.port,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
  #(link, blobs)
}

// Kills the rig's link and waits until its name is free, then starts another
// link under the same name for the same gateway. The new link holds no
// binding, as one started again after a crash does. The gateway and the host
// behind it are untouched, so the executor still holds the session's plane.
fn restart_link(rig: Rig) -> Rig {
  process.unlink(rig.link)
  process.kill(rig.link)
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case untrusted_link.running(rig.name, "pod") {
        Error(_gone) -> poll.Done(Nil)
        Ok(Nil) -> poll.Retry
      }
    })
    as "the dead link's name is freed"
  let door = process.new_name("untrusted_end_to_end_door")
  let #(link, blobs) = start_link(rig.pair, rig.gateway, rig.name, door)
  Rig(..rig, link:, blobs:, door:)
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
          "slow" -> {
            process.sleep(1500)
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
    surface.attach(
      surface.Config(
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
        attached: fn(_attached) { Nil },
      ),
    )
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

pub fn a_call_after_the_link_started_again_still_reaches_its_owner_test() {
  let rig = start("relink")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let rig = restart_link(rig)
  let run = call("ask")

  // The new link holds no binding for the session, though the executor still
  // holds its plane. The link answers the run with `NoPlane`, the surface
  // attaches again under a binding of the new link, and the call's escalation
  // is admitted instead of refused for a binding the link does not hold.
  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  let assert Ok(refused) = process.receive(rig.escalations, 5000)
    as "the owner was asked through the new link"
  assert refused.call_id == "ask"
  stop(rig)
}

pub fn a_call_in_flight_when_the_link_dies_is_sent_again_and_runs_once_test() {
  let rig = start("relink-flight")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  let run = call("slow")
  let answers = process.new_subject()
  let _asker =
    process.spawn_unlinked(fn() {
      process.send(answers, surface.run(remote, run))
    })
  let assert Ok(Running(call: "slow", ..)) = process.receive(rig.seen, 5000)
    as "the plane started the call"

  // The link dies with the call in flight. The asker finds the address gone,
  // waits for a link, and sends the same key to the one started in its place.
  // That link holds no binding and refuses with `NoPlane`; the surface
  // attaches again and sends the key a third time, and the host joins the
  // call it is already running.
  let rig = restart_link(rig)
  assert process.receive(answers, 15_000) == Ok(fixtures.expected_outcome(run))
  assert process.receive(rig.seen, 300) == Error(Nil)
  stop(rig)
}

pub fn a_request_made_while_no_link_holds_the_name_completes_once_one_does_test() {
  let rig = start("relink-gap")
  let surface.Attachment(surface: remote, ..) = attached(rig)
  process.unlink(rig.link)
  process.kill(rig.link)
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case untrusted_link.running(rig.name, "pod") {
        Error(_gone) -> poll.Done(Nil)
        Ok(Nil) -> poll.Retry
      }
    })
    as "the dead link's name is freed"

  // Nothing holds the name now. The call, the ack and the stop are sent to it
  // from this process and from a second one, and none raises.
  let run = call("plain")
  let answers = process.new_subject()
  let _asker =
    process.spawn_unlinked(fn() {
      process.send(answers, surface.run(remote, run))
    })
  surface.ack(remote, run)
  surface.stop_execution(remote, fixtures.execution_key("s1", "e1"))
  assert process.receive(answers, 300) == Error(Nil)

  // A link registered under the name later is found by the asker's repair.
  let #(link, _blobs) =
    start_link(
      rig.pair,
      rig.gateway,
      rig.name,
      process.new_name("untrusted_end_to_end_door"),
    )
  assert process.receive(answers, 15_000) == Ok(fixtures.expected_outcome(run))
  stop(Rig(..rig, link:))
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

// --- the broker tunnel (protocol-change/117) -------------------------------------

/// What a real plane gives a tunnel test: the session's clearing function
/// through the link, and the wiring the repository observations use with it.
type Tunnelled {
  Tunnelled(
    clear: workspace_plane.ClearCall,
    wiring: worktree_diff.Wiring,
    workspace: String,
    base: policy.SandboxPolicy,
    path: String,
  )
}

/// Runs `run` against a host whose plane's broker is the production broker
/// and pool over a Git repository with one commit, reached through the link
/// and the gateway, when the helper enforces here.
fn with_tunnel(label: String, run: fn(Tunnelled) -> Nil) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a package working directory"
  let assert Ok(repository) = bootstrap.canonical_directory(here <> "/../..")
    as "the source repository locates the built helper"
  case enforcement.probe(repository <> "/bin/loom", "tunnel e2e " <> label) {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      // The jail replaces /tmp with scratch, so /var/tmp keeps the
      // workspace's path the same inside it.
      let directory =
        "/var/tmp/loom-tunnel-e2e-"
        <> int.to_string(bootstrap.current_process_id())
        <> "-"
        <> label
        <> "-"
        <> int.to_string(bootstrap.system_time_ms())
      let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
        as "the test owns a workspace"
      let assert Ok(workspace) = bootstrap.canonical_directory(directory)
        as "the policy uses absolute paths"
      committed(workspace)
      let #(base, path) = tunnel_base(workspace)
      let clock = clock.from_function(bootstrap.system_time_ms)
      let assert Ok(#(_pool, plane_broker, service)) =
        serve.start_effect_plane(
          helper: repository <> "/bin/loom-exec",
          base_policy: base,
          tmp_dir: workspace <> "/.helper",
          size: 1,
          clock:,
        )
        as "the production broker and pool start"
      let census =
        remote_orchestrator.census_over(
          remote_orchestrator.standard_tools(),
          broker.subject(plane_broker),
        )
      let census =
        remote_census.RemoteCensus(
          ..census,
          census: workspace_plane.Census(
            ..census.census,
            workspace:,
            base_policy: base,
          ),
        )
      let rig = start_over("tunnel-" <> label, census)
      let _attachment = attached(rig)
      let clear = untrusted_link.tunnel_through(rig.door, "s1")
      let env = [#("PATH", path), #("HOME", "/nonexistent")]
      let wiring =
        worktree_diff.Wiring(
          workspace:,
          clear_call: clear,
          base_policy: base,
          clock:,
          demand: exec.PlatformEnforcement,
          env:,
          entropy: fn() { bootstrap.system_time_ms() },
          git: host_git.program(),
        )
      run(Tunnelled(clear:, wiring:, workspace:, base:, path:))
      stop(rig)
      broker.stop(plane_broker)
      let _closed =
        executor.close(
          service,
          draining: executor.drain_ms,
          helpers: executor.helpers_ms,
        )
      Nil
    }
  }
}

/// A repository with one committed file, made on the host.
fn committed(workspace: String) -> Nil {
  let _init = worktree_rig.git(workspace, ["init", "--quiet"])
  let assert Ok(Nil) = simplifile.write(workspace <> "/tracked.txt", "before\n")
    as "the tracked file is written"
  let _add = worktree_rig.git(workspace, ["add", "--", "tracked.txt"])
  let _commit =
    worktree_rig.git(workspace, [
      "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture",
    ])
  Nil
}

/// The plane's base over the workspace and the `PATH` a jailed Git needs here.
/// Apple ships the real Git with Xcode, and `/usr/bin/git` is a launcher whose
/// discovery needs host preferences, so only the developer tree is admitted
/// beside the workspace and its binary comes first.
fn tunnel_base(workspace: String) -> #(policy.SandboxPolicy, String) {
  let base = workspace_policy.base_policy_for(workspace, catalog.WorkspaceReads)
  let developer_usr = "/Applications/Xcode.app/Contents/Developer/usr"
  case simplifile.is_directory(developer_usr) {
    Ok(True) -> #(
      policy.SandboxPolicy(..base, readable_roots: [workspace, developer_usr]),
      developer_usr <> "/bin:/usr/bin:/bin:/usr/local/bin",
    )
    Ok(False) | Error(_) -> #(base, "/usr/local/bin:/usr/bin:/bin")
  }
}

/// Runs `command` in the workspace through the tunnel as a jailed shell, and
/// answers how it settled.
fn jailed(tunnel: Tunnelled, step: String, command: String) -> tool.Collected {
  let events = process.new_subject()
  let spec =
    broker.CallSpec(
      op_id: fixtures.tool_run("edit", 0).operation,
      step_id: step,
      base_policy: tunnel.base,
      // The link holds at most a mebibyte per stream, so the call names a
      // smaller limit than the plane's base.
      requirements: policy.SandboxPolicy(
        ..tunnel.base,
        limits: policy.Limits(..tunnel.base.limits, output_bytes: 65_536),
      ),
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.PlatformEnforcement,
      argv: ["/bin/sh", "-c", command],
      env: [#("PATH", tunnel.path), #("HOME", "/nonexistent")],
      cwd: tunnel.workspace,
      budget: budget.Budget(1, bootstrap.system_time_ms() + 30_000),
    )
  let assert Ok(call) = tunnel.clear(spec, events, 15_000)
    as "the jailed command clears through the tunnel"
  call.stdin(<<>>, True)
  let assert Ok(collected) = tool.collect_events(events, waiting: 20_000)
    as "the jailed command settles"
  collected
}

// The baseline probe runs Git through the link into the real plane and finds
// the commit the repository holds.
pub fn a_baseline_probe_runs_through_the_tunnel_test() {
  use tunnel <- with_tunnel("baseline")
  let head = worktree_rig.git(tunnel.workspace, ["rev-parse", "HEAD"])
  assert worktree_diff.starting_revision(tunnel.wiring)
    == worktree_diff.Revision(head)
}

// A jailed edit through the tunnel shows in the worktree diff observed
// through the tunnel.
pub fn a_worktree_diff_after_a_jailed_edit_runs_through_the_tunnel_test() {
  use tunnel <- with_tunnel("diff")
  let edit = jailed(tunnel, "edit", "echo edited > tracked.txt")
  let assert broker.CallExited(result:) = edit.outcome as "the edit exits"
  assert result.code == 0

  let assert Ok(board) = worktree_diff.capture(tunnel.wiring)
    as "the worktree is observed through the tunnel"
  assert board.total == 1
  let assert [file] = board.entries as "the one changed file is listed"
  assert string.contains(file.patch, "+edited")
}

// The peer view's observation runs through the tunnel and names the
// repository the plane holds.
pub fn a_peer_observation_runs_through_the_tunnel_test() {
  use tunnel <- with_tunnel("peer")
  let observed = json.to_string(worktree_diff.peer_observation(tunnel.wiring))
  assert string.contains(observed, "\"repository_root\"")
  assert string.contains(observed, tunnel.workspace)
  assert !string.contains(observed, "unavailable")
}

// A goal check runs through the tunnel and returns the command's real status
// and output.
pub fn a_goal_check_runs_through_the_tunnel_test() {
  use tunnel <- with_tunnel("goal")
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  let wiring =
    goalcheck.wiring(
      goalcheck.Runner(
        clear_call: fn(spec, events) { tunnel.clear(spec, events, 15_000) },
        base_policy: tunnel.base,
        demand: exec.PlatformEnforcement,
        env: [#("PATH", tunnel.path), #("HOME", "/nonexistent")],
        workspace: tunnel.workspace,
        clock: clock.from_function(bootstrap.system_time_ms),
        op_id:,
        clearance_ms: 15_000,
      ),
      timeout_ms: 20_000,
    )
  let passed = wiring.run("echo goal-ok")
  assert passed.ending == goalstate.Exited(0)
  assert string.contains(passed.output, "goal-ok")
  let failed = wiring.run("exit 3")
  assert failed.ending == goalstate.Exited(3)
}

// A hook on an untrusted placement is refused, though
// the same plane's clearing function serves the goal check and Git.
pub fn a_hook_on_an_untrusted_placement_is_refused_test() {
  use tunnel <- with_tunnel("hook")
  let spec =
    broker.CallSpec(
      op_id: fixtures.tool_run("hook", 0).operation,
      step_id: "imported-hooks",
      base_policy: tunnel.base,
      // A real hook asks for a mebibyte per stream, which the link admits, so
      // only the refusing function stands between a hook and the executor.
      requirements: policy.SandboxPolicy(
        ..tunnel.base,
        limits: policy.Limits(..tunnel.base.limits, output_bytes: 1_048_576),
      ),
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.PlatformEnforcement,
      argv: ["/bin/sh", "-c", "echo hooked"],
      env: [#("PATH", tunnel.path)],
      cwd: tunnel.workspace,
      budget: budget.Budget(1, bootstrap.system_time_ms() + 30_000),
    )

  // Over a recording clearing function, a refused placement never calls it,
  // and a placement that runs hooks does.
  let probe = process.new_subject()
  let recording =
    fake_clear_call.answering(probe, fn(_spec) {
      [
        broker.CallSettled(
          broker.CallFailed(exec.ExecutionLost(exec.RelayDown)),
        ),
      ]
    })
  let events = process.new_subject()
  let assert Error(broker.BrokerUnavailable) =
    serve.hook_clear_call(workspace_plane.HooksRefused, recording)(
      spec,
      events,
      5000,
    )
    as "the hook's command is refused"
  assert process.receive(probe, 300) == Error(Nil)
  let assert Ok(_call) =
    serve.hook_clear_call(workspace_plane.HooksRun, recording)(
      spec,
      process.new_subject(),
      5000,
    )
    as "a placement that runs hooks clears through its function"
  let assert Ok(fake_clear_call.Cleared(..)) = process.receive(probe, 300)
    as "the clearing function was called"

  // The same spec through the tunnel itself clears and runs, so the refusal
  // above is the refusing function's and not the link's.
  let assert Ok(call) = tunnel.clear(spec, events, 15_000)
    as "the tunnel admits a hook-sized spec"
  call.stdin(<<>>, True)
  let assert Ok(collected) = tool.collect_events(events, waiting: 20_000)
    as "the call settles"
  assert collected.stdout == <<"hooked\n">>
}
