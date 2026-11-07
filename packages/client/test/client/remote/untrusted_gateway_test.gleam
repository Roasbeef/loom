//// The executor's gateway against an orchestrator driven by hand
//// (protocol-change/109).
////
//// The gateway feeds a real host. These tests check the two things the host
//// reads from the gateway's waiters: a dropped connection is a partition that
//// never cancels a call, and a cancel sent after the orchestrator re-sent the
//// call on a new connection is still an abort. They also check that the
//// gateway admits only the orchestrator pins it lists.
////
//// The same two hold for a background program (slice 2): a drop leaves it
//// running, and the start the orchestrator re-sends reads the value it stored
//// while nobody was connected, or is stopped by a cancel. The executor's proxy
//// carries a launch to the orchestrator and refuses an answer of another kind
//// as it would a lost one.

import client/internal/ffi_tls_stream.{type Stream}
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_codec
import client/remote/untrusted_gateway
import client/remote/untrusted_wire
import core/json
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/string
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import support/remote_orchestrator
import support/untrusted_rig as rig
import telemetry/log

const token = <<"token":utf8>>

type Rig {
  Rig(
    pair: rig.Pair,
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    workers: Subject(process.Pid),
  )
}

fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let workers = process.new_subject()
  let executor =
    remote_orchestrator.start(holding(
      workers,
      remote_orchestrator.census(remote_orchestrator.standard_tools()),
    ))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Rig(pair:, executor:, gateway:, workers:)
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.gateway.acceptor)
  process.kill(rig.gateway.acceptor)
  remote_orchestrator.stop(rig.executor)
}

// A plane for the background tests: every call asks the owner to launch the fixtures' execution and reports what it was told; a
// program reports its worker and a subject that releases it, and ends with the
// value it was released with.
fn programs(
  launches: Subject(Result(json.JsonValue, String)),
  started: Subject(#(process.Pid, Subject(json.JsonValue))),
  census: RemoteCensus,
) -> host.PlaneFactory(RemoteCensus) {
  fn(spec: host.AttachSpec) {
    let owner = spec.owner
    Ok(host.Plane(
      run: fn(run, _authority) {
        process.send(
          launches,
          owner.launch_execution(fixtures.execution_terms()),
        )
        fixtures.expected_outcome(run)
      },
      census:,
      children: fn(builder) { builder },
      close: fn(retire_children) {
        let _retired = retire_children()
        protocol.AllRetired
      },
      execute: fn(_start) {
        let release = process.new_subject()
        process.send(started, #(process.self(), release))
        process.receive_forever(release)
      },
      abort_step: fn(_op, _step) { Nil },
      evolution: None,
      state: None,
    ))
  }
}

// A plane whose every call reports its worker and then waits to be killed.
fn holding(
  workers: Subject(process.Pid),
  census: RemoteCensus,
) -> host.PlaneFactory(RemoteCensus) {
  fn(_spec: host.AttachSpec) {
    Ok(host.Plane(
      run: fn(run, _authority) {
        process.send(workers, process.self())
        process.sleep_forever()
        fixtures.expected_outcome(run)
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

// Reads frames until the response to `id`, answering the two questions a
// plane's build asks its owner on the way.
fn response_to(stream: Stream, id: Int) -> Nil {
  case rig.next(stream) {
    Ok(untrusted_codec.ResponseEnvelope(id: answered, ..)) if answered == id ->
      Nil
    Ok(untrusted_codec.CallbackEnvelope(binding:, id: asked, body:)) -> {
      let answer = case untrusted_codec.decode_callback(body) {
        Ok(untrusted_wire.McpPlanCall) ->
          untrusted_wire.McpPlanAnswered(protocol.McpPlan([], []))
        _other -> untrusted_wire.GitIdentityAnswered(None)
      }
      rig.send(stream, untrusted_wire.Answer(binding:, id: asked, answer:))
      response_to(stream, id)
    }
    Ok(_other) -> response_to(stream, id)
    Error(reason) -> panic as reason
  }
}

fn attach(stream: Stream) -> Nil {
  rig.send(
    stream,
    untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.AttachRequest(
        version: protocol.version,
        session: "s1",
        workspace: "/work",
        incarnation: 0,
        token:,
        binding: <<1:size(128)>>,
      ),
    ),
  )
  response_to(stream, 1)
}

fn run_request(id: Int, run: ToolRun) -> untrusted_wire.Frame {
  untrusted_wire.Request(
    id:,
    request: untrusted_wire.RunRequest(
      key: protocol.key_of("s1", run),
      incarnation: 0,
      token:,
      run:,
      authority: fixtures.authority(),
    ),
  )
}

pub fn a_cancel_after_a_reconnect_still_aborts_the_call_test() {
  let rig = start("reconnect-cancel")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  let run = fixtures.tool_run("hold", 0)
  rig.send(first, run_request(2, run))
  let assert Ok(worker) = process.receive(rig.workers, 5000)
    as "the call starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  // The connection drops: a partition, which must not cancel the call.
  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The orchestrator re-sends the call on a new connection, then the asker
  // dies and it cancels. Only the new waiter is left, so the host aborts.
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, run_request(2, run))
  process.sleep(200)
  rig.send(second, untrusted_wire.Cancel(2))
  assert process.selector_receive(down, 10_000) == Ok(Nil)
  stop(rig)
}

pub fn an_orchestrator_the_gateway_does_not_list_is_refused_test() {
  let rig = start("unlisted")

  // The stray leaf chains to the same authority, and is still not admitted,
  // because its pin is not one the gateway lists.
  let refused = case
    rig.dial(rig.gateway.port, rig.pair.stray, rig.pair.executor_pin)
  {
    Error(_failure) -> True
    Ok(stream) -> rig.closed(stream, 5000)
  }
  assert refused
  stop(rig)
}

// --- background executions (slice 2) ---------------------------------------------

type Programs {
  Programs(
    pair: rig.Pair,
    executor: remote_orchestrator.Executor,
    gateway: untrusted_gateway.Gateway,
    launches: Subject(Result(json.JsonValue, String)),
    started: Subject(#(process.Pid, Subject(json.JsonValue))),
  )
}

fn start_programs(label: String) -> Programs {
  let pair = rig.pair(label)
  let launches = process.new_subject()
  let started = process.new_subject()
  let executor =
    remote_orchestrator.start(programs(
      launches,
      started,
      remote_orchestrator.census(remote_orchestrator.standard_tools()),
    ))
  let assert Ok(gateway) =
    untrusted_gateway.start(untrusted_gateway.Config(
      address: "127.0.0.1",
      port: 0,
      credentials: pair.executor,
      orchestrators: [pair.orchestrator_pin],
      host: executor.address,
      blobs: None,
      logger: log.discard(),
    ))
    as "the gateway starts"
  Programs(pair:, executor:, gateway:, launches:, started:)
}

fn stop_programs(rig: Programs) -> Nil {
  process.unlink(rig.gateway.acceptor)
  process.kill(rig.gateway.acceptor)
  remote_orchestrator.stop(rig.executor)
}

fn start_request(id: Int) -> untrusted_wire.Frame {
  untrusted_wire.Request(
    id:,
    request: untrusted_wire.StartExecutionRequest(
      key: fixtures.execution_key("s1", "e1"),
      incarnation: 0,
      token:,
      terms: fixtures.execution_terms(),
      remaining_ms: 60_000,
    ),
  )
}

// Reads frames until the response to `id` and decodes it as an execution's.
fn execution_answer(stream: Stream, id: Int) -> protocol.ExecutionAnswer {
  let assert Ok(untrusted_codec.ResponseEnvelope(id: answered, body:)) =
    rig.next(stream)
    as "the start is answered"
  assert answered == id
  let assert Ok(untrusted_wire.ExecutionAnswered(answer)) =
    untrusted_codec.decode_response(untrusted_wire.ExecutionKind, body)
    as "the answer is an execution's"
  answer
}

pub fn a_dropped_connection_leaves_a_program_running_and_the_resent_start_reads_its_value_test() {
  let rig = start_programs("program-partition")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  rig.send(first, start_request(2))
  let assert Ok(#(worker, release)) = process.receive(rig.started, 5000)
    as "the program starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  // The connection drops: a partition, which must not stop the program.
  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The program ends while nobody is connected, and its value waits in the
  // ledger for the orchestrator's re-send.
  let value = json.Object([#("status", json.String("ok"))])
  process.send(release, value)
  assert process.selector_receive(down, 5000) == Ok(Nil)
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, start_request(2))
  assert execution_answer(second, 2) == protocol.ExecutionFinished(value)
  assert process.receive(rig.started, 300) == Error(Nil)
  stop_programs(rig)
}

pub fn a_cancel_after_a_reconnect_still_stops_the_program_test() {
  let rig = start_programs("program-cancel")
  let first = rig.hello(rig.gateway.port, rig.pair)
  attach(first)
  rig.send(first, start_request(2))
  let assert Ok(#(worker, _release)) = process.receive(rig.started, 5000)
    as "the program starts"
  let watch = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_down) { Nil })

  ffi_tls_stream.close(first)
  assert process.selector_receive(down, 500) == Error(Nil)

  // The re-sent start joins the program that is running instead of starting
  // a second one, and the cancel after it stops that program.
  let second = rig.hello(rig.gateway.port, rig.pair)
  rig.send(second, start_request(2))
  assert process.receive(rig.started, 200) == Error(Nil)
  rig.send(second, untrusted_wire.Cancel(2))
  assert process.selector_receive(down, 10_000) == Ok(Nil)
  stop_programs(rig)
}

// Sends a `launch` call, answers the launch callback the plane makes with
// `answer`, and reports what the plane was told.
fn launched_with(
  label: String,
  answer: fn(BitArray, Int) -> untrusted_wire.Answer,
) -> Result(json.JsonValue, String) {
  let rig = start_programs(label)
  let stream = rig.hello(rig.gateway.port, rig.pair)
  attach(stream)
  rig.send(stream, run_request(2, fixtures.tool_run("launch", 0)))
  let assert Ok(untrusted_codec.CallbackEnvelope(binding:, id:, body:)) =
    rig.next(stream)
    as "the plane's launch is called back"
  assert untrusted_codec.decode_callback(body)
    == Ok(untrusted_wire.LaunchExecutionCall(fixtures.execution_terms()))
  rig.send(
    stream,
    untrusted_wire.Answer(binding:, id:, answer: answer(binding, id)),
  )
  let assert Ok(told) = process.receive(rig.launches, 5000)
    as "the plane hears the launch's answer"
  stop_programs(rig)
  told
}

pub fn a_launch_is_called_back_and_answered_with_the_owners_handle_test() {
  let told =
    launched_with("launch-answered", fn(_binding, _id) {
      untrusted_wire.LaunchAnswered(Ok(json.String("exec-1")))
    })
  assert told == Ok(json.String("exec-1"))
}

pub fn a_launch_answered_with_the_wrong_kind_is_refused_as_unanswered_test() {
  let told =
    launched_with("launch-wrong-kind", fn(_binding, _id) {
      untrusted_wire.InteractAnswered(Ok(json.String("exec-1")))
    })
  let assert Error(reason) = told
    as "an interaction's answer never answers a launch"
  assert string.contains(reason, "did not answer the launch")
  assert string.contains(reason, fixtures.handle_of(fixtures.execution_terms()))
}
