//// The orchestrator's link against a hostile executor (protocol-change/109).
////
//// Each test runs the real link over a real TLS connection and plays the
//// executor by hand, so the executor can do what an honest gateway never
//// would: forge a binding, replay a callback id, ask about a call that is not
//// in flight or describe one with other arguments, call back for another
//// session, answer a request it was never sent or with the wrong kind, and
//// send bytes that are not a frame. The owner port records everything that
//// reaches it, so "refused" means the owner never saw it.
////
//// The background-execution tests (slice 2) do the same for a program the
//// orchestrator started with `start_execution`: a program's capability reaches
//// the owner only while its start is outstanding, a launch and an interaction
//// only from the `code_mode` call that makes them, and a start's answer
//// reaches its worker once across a dropped connection, while a cancel after
//// the re-send goes out on the new one.

import broker/framing
import client/escalate
import client/internal/ffi_tls_stream.{type Listener, type Stream}
import client/owner_services
import client/remote/address
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_codec
import client/remote/untrusted_link
import client/remote/untrusted_wire
import codemode/satellite
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import telemetry/log
import tools/agent
import tools/codemode as codemode_tool
import tools/tool

type Rig {
  Rig(
    listener: Listener,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    link: process.Pid,
  )
}

/// What a hand-driven executor learned from one attach.
type Attached {
  Attached(stream: Stream, binding: BitArray)
}

// A link to a hand-driven executor listening on this machine.
fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let #(listener, port) = rig.listen(pair.executor, [pair.orchestrator_pin])
  let name = process.new_name("untrusted_link_test")
  let assert Ok(link) =
    untrusted_link.start(untrusted_link.Config(
      executor: "pod",
      name:,
      host: "127.0.0.1",
      port:,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
  process.unlink(link)
  Rig(listener:, address: untrusted_link.address(name), link:)
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.link)
  ffi_tls_stream.close_listener(rig.listener)
}

// An owner port that records every message it receives and answers the ones
// the tests ask about.
fn recording_port() -> #(Subject(protocol.OwnerMessage), Subject(String)) {
  let seen = process.new_subject()
  let handed = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(handed, inbox)
    record(inbox, seen)
  })
  let assert Ok(inbox) = process.receive(handed, 1000) as "the port starts"
  #(inbox, seen)
}

fn record(inbox: Subject(protocol.OwnerMessage), seen: Subject(String)) -> Nil {
  case process.receive_forever(inbox) {
    protocol.Escalate(reply:, ..) -> {
      process.send(seen, "escalate")
      process.send(reply, escalate.Resume(grants: []))
    }
    protocol.FactGet(reply:, ..) -> {
      process.send(seen, "fact_get")
      process.send(reply, Ok(None))
    }
    protocol.Capability(reply:, ..) -> {
      process.send(seen, "capability")
      process.send(
        reply,
        Error(satellite.CapDenial(code: "recorded", message: "recorded")),
      )
    }
    protocol.Tail(..) -> process.send(seen, "tail")
    protocol.Holds(reply:, ..) -> {
      process.send(seen, "holds")
      process.send(reply, Ok(Nil))
    }
    protocol.LaunchExecution(reply:, ..) -> {
      process.send(seen, "launch")
      process.send(reply, Ok(json.String("exec-1")))
    }
    protocol.InteractExecution(reply:, ..) -> {
      process.send(seen, "interact")
      process.send(reply, Ok(json.String("running")))
    }
    _other -> process.send(seen, "other")
  }
  record(inbox, seen)
}

// Whether the owner port saw nothing within a short wait.
fn unseen(seen: Subject(String)) -> Bool {
  process.receive(seen, 300) == Error(Nil)
}

// Sends an attach for `session` from this process and, as the executor, reads
// it off the wire. A first attach greets a new connection; a later one reads
// from the stream already open.
fn attach(
  rig: Rig,
  session: String,
  port: Subject(protocol.OwnerMessage),
  stream: option.Option(Stream),
) -> Attached {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session:,
      workspace: "/work",
      incarnation: 0,
      token: <<"token":utf8>>,
      owner_port: port,
      reply:,
    ),
  )
  let stream = case stream {
    option.Some(stream) -> stream
    None -> rig.greeted(rig.listener)
  }
  let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) = rig.next(stream)
    as "the attach arrives"
  let assert Ok(untrusted_wire.AttachRequest(binding:, session: named, ..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as an attach"
  assert named == session
  Attached(stream:, binding:)
}

// Sends a run for `session` from a process of its own, and reads it off the
// wire. The process waits for the answer and reports it.
fn run_in_flight(
  rig: Rig,
  stream: Stream,
  session: String,
  run: ToolRun,
) -> #(Int, process.Pid, Subject(protocol.RunAnswer)) {
  let answers = process.new_subject()
  let address = rig.address
  let asker =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      address.deliver(
        address,
        protocol.Run(
          key: protocol.key_of(session, run),
          incarnation: 0,
          token: <<"token":utf8>>,
          run:,
          authority: fixtures.authority(),
          reply:,
        ),
      )
      process.send(answers, process.receive_forever(reply))
    })
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "the run arrives"
  let assert Ok(untrusted_wire.RunRequest(key:, ..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as a run"
  assert key == protocol.key_of(session, run)
  #(id, asker, answers)
}

// Sends a callback and reads the answer to it.
fn called(
  stream: Stream,
  binding: BitArray,
  id: Int,
  callback: untrusted_wire.Callback,
) -> untrusted_wire.Answer {
  rig.send(stream, untrusted_wire.Callback(binding:, id:, callback:))
  let assert Ok(untrusted_codec.AnswerEnvelope(binding: answered, id: of, body:)) =
    rig.next(stream)
    as "the callback is answered"
  assert answered == binding
  assert of == id
  let assert option.Some(kind) = untrusted_wire.answer_kind(callback)
    as "the callback has an answer"
  let assert Ok(answer) = untrusted_codec.decode_answer(kind, body)
    as "the answer decodes"
  answer
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

pub fn a_run_goes_out_and_its_response_reaches_the_asker_test() {
  let rig = start("run")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)
  let #(id, _asker, answers) = run_in_flight(rig, stream, "s1", run)

  let outcome = fixtures.expected_outcome(run)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.RunAnswered(protocol.RunFinished(outcome)),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.RunFinished(outcome))
  stop(rig)
}

pub fn a_callback_on_a_binding_the_link_never_minted_is_refused_test() {
  let rig = start("forged-binding")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let forged = <<7:size(128)>>
  assert forged != binding

  let answer = called(stream, forged, 1, untrusted_wire.FactGetCall("job/one"))
  let assert untrusted_wire.FactCellAnswered(Error(owner_services.Failed(_))) =
    answer
  assert unseen(seen)
  stop(rig)
}

pub fn a_replayed_callback_id_is_refused_test() {
  let rig = start("replay")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let ask = untrusted_wire.FactGetCall("client/working_directory/main")

  assert called(stream, binding, 1, ask)
    == untrusted_wire.FactCellAnswered(Ok(None))
  assert process.receive(seen, 2000) == Ok("fact_get")

  // The same id again, and an older one after a newer, are both replays.
  let assert untrusted_wire.FactCellAnswered(Error(owner_services.Failed(_))) =
    called(stream, binding, 1, ask)
  assert called(stream, binding, 5, ask)
    == untrusted_wire.FactCellAnswered(Ok(None))
  assert process.receive(seen, 2000) == Ok("fact_get")
  let assert untrusted_wire.FactCellAnswered(Error(owner_services.Failed(_))) =
    called(stream, binding, 3, ask)
  assert unseen(seen)
  stop(rig)
}

pub fn an_escalation_reaches_the_owner_only_for_the_call_in_flight_test() {
  let rig = start("escalate")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)

  // No call is in flight yet, so the operator is not asked.
  assert called(
      stream,
      binding,
      1,
      untrusted_wire.EscalateCall(refused_for(run), 1000),
    )
    == untrusted_wire.Decided(escalate.Settle)
  assert unseen(seen)

  // The call is in flight, but the executor describes it with other
  // arguments: still not asked.
  let #(_id, _asker, _answers) = run_in_flight(rig, stream, "s1", run)
  let rewritten =
    escalate.Refused(
      ..refused_for(run),
      arguments: json.Object([#("command", json.String("rm -rf /"))]),
    )
  assert called(
      stream,
      binding,
      2,
      untrusted_wire.EscalateCall(rewritten, 1000),
    )
    == untrusted_wire.Decided(escalate.Settle)
  assert unseen(seen)

  // The call exactly as the orchestrator sent it reaches the owner.
  assert called(
      stream,
      binding,
      3,
      untrusted_wire.EscalateCall(refused_for(run), 1000),
    )
    == untrusted_wire.Decided(escalate.Resume(grants: []))
  assert process.receive(seen, 2000) == Ok("escalate")
  stop(rig)
}

pub fn a_callback_for_another_sessions_call_is_refused_test() {
  let rig = start("other-session")
  let #(first_port, first_seen) = recording_port()
  let #(second_port, second_seen) = recording_port()
  let Attached(stream:, binding: _first) = attach(rig, "s1", first_port, None)
  let Attached(binding: second, ..) =
    attach(rig, "s2", second_port, option.Some(stream))
  let run = fixtures.tool_run("call_1", 0)
  let #(_id, _asker, _answers) = run_in_flight(rig, stream, "s1", run)

  // s2's binding naming s1's call reaches neither owner.
  assert called(
      stream,
      second,
      1,
      untrusted_wire.EscalateCall(refused_for(run), 1000),
    )
    == untrusted_wire.Decided(escalate.Settle)
  let assert untrusted_wire.CapabilityAnswered(Error(_denied)) =
    called(
      stream,
      second,
      2,
      untrusted_wire.CapabilityCall(fixtures.capability_call()),
    )
  assert unseen(first_seen)
  assert unseen(second_seen)
  stop(rig)
}

pub fn a_retired_binding_is_refused_after_the_session_attaches_again_test() {
  let rig = start("retired")
  let #(first_port, first_seen) = recording_port()
  let #(second_port, _second_seen) = recording_port()
  let Attached(stream:, binding: old) = attach(rig, "s1", first_port, None)

  // A new open of the session has a new owner port and a new binding.
  let Attached(binding: new, ..) =
    attach(rig, "s1", second_port, option.Some(stream))
  assert new != old
  let assert untrusted_wire.FactCellAnswered(Error(owner_services.Failed(_))) =
    called(stream, old, 1, untrusted_wire.FactGetCall("job/one"))
  assert unseen(first_seen)
  stop(rig)
}

pub fn a_resent_attach_keeps_its_binding_test() {
  let rig = start("resent-attach")
  let #(port, _seen) = recording_port()
  let Attached(stream:, binding: first) = attach(rig, "s1", port, None)
  let Attached(binding: again, ..) =
    attach(rig, "s1", port, option.Some(stream))
  assert again == first
  stop(rig)
}

pub fn a_response_to_a_request_never_sent_closes_and_the_run_is_sent_again_test() {
  let rig = start("unsent")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)
  let #(_id, _asker, answers) = run_in_flight(rig, stream, "s1", run)

  rig.send(
    stream,
    untrusted_wire.Response(
      id: 999,
      response: untrusted_wire.RunAnswered(protocol.RunLost),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)

  // The link dials again and sends both outstanding requests, in order.
  let again = rig.greeted(rig.listener)
  let assert Ok(untrusted_codec.RequestEnvelope(body: first, ..)) =
    rig.next(again)
    as "the attach is sent again"
  let assert Ok(untrusted_wire.AttachRequest(..)) =
    untrusted_codec.decode_request(first)
    as "it is the attach"
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body: second)) =
    rig.next(again)
    as "the run is sent again"
  let assert Ok(untrusted_wire.RunRequest(key:, ..)) =
    untrusted_codec.decode_request(second)
    as "it is the run"
  assert key == protocol.key_of("s1", run)

  // And its answer on the new connection reaches the asker.
  rig.send(
    again,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.RunAnswered(protocol.RunLost),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.RunLost)
  stop(rig)
}

pub fn a_response_of_the_wrong_kind_closes_the_connection_test() {
  let rig = start("wrong-kind")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))

  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.LookupAnswered(Ok(protocol.Missing)),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  assert process.receive(answers, 300) == Error(Nil)
  stop(rig)
}

pub fn a_malformed_frame_closes_the_connection_test() {
  let rig = start("malformed")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send_raw(stream, <<"{\"frame\": \"response\", \"id\": ":utf8>>)
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  stop(rig)
}

pub fn a_frame_only_an_orchestrator_sends_closes_the_connection_test() {
  let rig = start("backwards")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send(
    stream,
    untrusted_wire.Request(
      id: 1,
      request: untrusted_wire.QueryRequest(protocol.Key("s1", "op", "step", 0)),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  stop(rig)
}

pub fn an_oversized_frame_closes_the_connection_test() {
  let rig = start("oversized")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send_raw(stream, bit_array_of(untrusted_wire.max_frame_bytes + 1))
  assert rig.closed(stream, 10_000)
  assert process.is_alive(rig.link)
  stop(rig)
}

fn bit_array_of(size: Int) -> BitArray {
  <<0:size({ size * 8 })>>
}

pub fn the_death_of_an_asker_cancels_its_request_at_the_executor_test() {
  let rig = start("cancel")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))

  process.kill(asker)
  assert rig.next(stream) == Ok(untrusted_codec.CancelEnvelope(id:))
  stop(rig)
}

pub fn a_tail_for_a_call_not_in_flight_never_reaches_the_owner_test() {
  let rig = start("tail")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)
  let tail = tool_tail()

  rig.send(
    stream,
    untrusted_wire.Callback(
      binding:,
      id: 1,
      callback: untrusted_wire.TailCast(run:, tail:),
    ),
  )

  // A refused callback's answer orders the tail ahead of the check: frames
  // are read one at a time, so the tail was judged before this was answered.
  let assert untrusted_wire.FactCellAnswered(Error(_refused)) =
    called(stream, <<9:size(128)>>, 1, untrusted_wire.FactGetCall("job/one"))
  assert unseen(seen)

  // In flight, the same tail is delivered.
  let #(_id, _asker, _answers) = run_in_flight(rig, stream, "s1", run)
  rig.send(
    stream,
    untrusted_wire.Callback(
      binding:,
      id: 3,
      callback: untrusted_wire.TailCast(run:, tail:),
    ),
  )
  assert process.receive(seen, 2000) == Ok("tail")
  stop(rig)
}

fn tool_tail() -> tool.OutputTail {
  tool.OutputTail(stream: framing.Stdout, tail: "hello", total_bytes: 5)
}

pub fn an_executor_with_a_certificate_from_another_authority_is_refused_test() {
  let pair = rig.pair("stranger")
  let #(stranger, _stranger_pin) = rig.stranger("stranger")
  let #(listener, port) = rig.listen(stranger, [pair.orchestrator_pin])
  let name = process.new_name("untrusted_link_test")
  let assert Ok(link) =
    untrusted_link.start(untrusted_link.Config(
      executor: "pod",
      name:,
      host: "127.0.0.1",
      port:,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
  process.unlink(link)
  let #(owner, _seen) = recording_port()
  let reply = process.new_subject()
  address.deliver(
    untrusted_link.address(name),
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: <<"token":utf8>>,
      owner_port: owner,
      reply:,
    ),
  )

  // The link dials, and the handshake fails on the pin.
  let assert Ok(raw) = ffi_tls_stream.accept(listener, 10_000)
    as "the link dials"
  let assert Error(_refused) = ffi_tls_stream.handshake(raw, 10_000)
  // No attach can succeed over a connection the pin refused.
  let attached = case process.receive(reply, 300) {
    Ok(Ok(_attached)) -> True
    Ok(Error(_refused)) | Error(Nil) -> False
  }
  assert !attached
  process.kill(link)
  ffi_tls_stream.close_listener(listener)
}

pub fn an_executor_with_another_pin_under_the_same_authority_is_refused_test() {
  let pair = rig.pair("same-authority")
  let #(listener, port) = rig.listen(pair.stray, [pair.orchestrator_pin])
  let #(link, address) = link_to(port, pair)
  let #(owner, _seen) = recording_port()
  let reply = attach_unread(address, owner)

  // The leaf chains to the authority both sides trust and still fails the
  // link's pin, so the link never says hello.
  let assert Ok(raw) = ffi_tls_stream.accept(listener, 10_000)
    as "the link dials"
  let greeted = case ffi_tls_stream.handshake(raw, 10_000) {
    Error(_failure) -> False
    Ok(stream) ->
      case rig.next(stream) {
        Ok(untrusted_codec.HelloEnvelope(..)) -> True
        Ok(_other) | Error(_closed) -> False
      }
  }
  assert !greeted
  // No attach can succeed over a connection the pin refused.
  let attached = case process.receive(reply, 300) {
    Ok(Ok(_attached)) -> True
    Ok(Error(_refused)) | Error(Nil) -> False
  }
  assert !attached
  process.kill(link)
  ffi_tls_stream.close_listener(listener)
}

pub fn an_attach_to_an_executor_nobody_answers_for_is_refused_test() {
  let pair = rig.pair("down")
  let #(listener, port) = rig.listen(pair.executor, [pair.orchestrator_pin])

  // Nothing listens there any more, so every dial fails.
  ffi_tls_stream.close_listener(listener)
  let #(link, address) = link_to(port, pair)
  let #(owner, _seen) = recording_port()
  let reply = attach_unread(address, owner)

  let assert Ok(Error(protocol.Unreachable(_))) = process.receive(reply, 15_000)
    as "the attach is refused as unreachable"
  assert process.is_alive(link)
  process.kill(link)
}

// A link to `port` that expects the pair's executor leaf.
fn link_to(
  port: Int,
  pair: rig.Pair,
) -> #(process.Pid, address.Address(protocol.HostMessage(RemoteCensus))) {
  let name = process.new_name("untrusted_link_test")
  let assert Ok(link) =
    untrusted_link.start(untrusted_link.Config(
      executor: "pod",
      name:,
      host: "127.0.0.1",
      port:,
      pin: pair.executor_pin,
      credentials: pair.orchestrator,
      mint: untrusted_link.strong_binding,
      logger: log.discard(),
    ))
    as "the link starts"
  process.unlink(link)
  #(link, untrusted_link.address(name))
}

// Sends an attach and returns where its answer will go, reading nothing.
fn attach_unread(
  address: address.Address(protocol.HostMessage(RemoteCensus)),
  owner: Subject(protocol.OwnerMessage),
) -> Subject(Result(protocol.Attached(RemoteCensus), protocol.Refusal)) {
  let reply = process.new_subject()
  address.deliver(
    address,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: <<"token":utf8>>,
      owner_port: owner,
      reply:,
    ),
  )
  reply
}

// --- background executions (slice 2) ---------------------------------------------

// Sends a start for execution `id` of `session` from a worker process of its
// own, as a record's worker does, and reads it off the wire. The worker
// forwards every answer it hears, so a duplicate would be seen.
fn start_in_flight(
  rig: Rig,
  stream: Stream,
  session: String,
  id: String,
) -> #(Int, process.Pid, Subject(protocol.ExecutionAnswer)) {
  let answers = process.new_subject()
  let address = rig.address
  let key = fixtures.execution_key(session, id)
  let worker =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      address.deliver(
        address,
        protocol.StartExecution(
          key:,
          incarnation: 0,
          token: <<"token":utf8>>,
          terms: fixtures.execution_terms(),
          remaining_ms: 60_000,
          reply:,
        ),
      )
      forward_answers(reply, answers)
    })
  let request = read_start(stream)
  assert request.1 == key
  #(request.0, worker, answers)
}

fn forward_answers(
  reply: Subject(protocol.ExecutionAnswer),
  answers: Subject(protocol.ExecutionAnswer),
) -> Nil {
  process.send(answers, process.receive_forever(reply))
  forward_answers(reply, answers)
}

// Reads the next frame as a start, answering its id and key.
fn read_start(stream: Stream) -> #(Int, protocol.Key) {
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "the start arrives"
  let assert Ok(untrusted_wire.StartExecutionRequest(key:, terms:, ..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as a start"
  assert terms == fixtures.execution_terms()
  #(id, key)
}

// Reads the next frame as an attach.
fn read_attach(stream: Stream) -> Nil {
  let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) = rig.next(stream)
    as "the attach is sent again"
  let assert Ok(untrusted_wire.AttachRequest(..)) =
    untrusted_codec.decode_request(body)
    as "it is the attach"
  Nil
}

// A capability call as the program of execution `id` makes one: the
// launching call's operation, strand and position under the execution's step.
fn program_call(id: String) -> untrusted_wire.Callback {
  let terms = fixtures.execution_terms()
  untrusted_wire.CapabilityCall(
    owner_services.OwnerCapCall(
      ..fixtures.capability_call(),
      strand: terms.strand,
      op_id: terms.op_id,
      step_id: fixtures.execution_key("s1", id).step,
      source_index: terms.source_index,
    ),
  )
}

// A `code_mode` call at `source_index`, under the operation and step the
// execution terms name.
fn code_mode_run(call_id: String, source_index: Int) -> ToolRun {
  let run = fixtures.tool_run(call_id, source_index)
  effects.ToolRun(
    ..run,
    call: message.ToolCall(..run.call, name: codemode_tool.tool_name),
  )
}

fn denied(answer: untrusted_wire.Answer) -> Bool {
  case answer {
    untrusted_wire.CapabilityAnswered(Error(satellite.CapDenial(
      code: "owner_refused",
      ..,
    ))) -> True
    _other -> False
  }
}

pub fn a_start_goes_out_and_its_answer_reaches_the_worker_test() {
  let rig = start("start")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _worker, answers) = start_in_flight(rig, stream, "s1", "e1")

  let value = json.Object([#("status", json.String("ok"))])
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ExecutionAnswered(protocol.ExecutionFinished(
        value,
      )),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.ExecutionFinished(value))

  // A stop has no reply and goes out as a request of its own.
  let key = fixtures.execution_key("s1", "e1")
  address.deliver(rig.address, protocol.StopExecution(key:, incarnation: 0))
  let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) = rig.next(stream)
    as "the stop arrives"
  assert untrusted_codec.decode_request(body)
    == Ok(untrusted_wire.StopExecutionRequest(key:, incarnation: 0))
  stop(rig)
}

pub fn a_program_reaches_the_owner_only_while_its_execution_is_live_test() {
  let rig = start("program-live")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)

  // Before the orchestrator starts the execution, its program does not exist.
  assert denied(called(stream, binding, 1, program_call("e1")))
  assert unseen(seen)

  // While the start is outstanding the program reaches the owner, and so does
  // its tool-list check.
  let #(id, worker, _answers) = start_in_flight(rig, stream, "s1", "e1")
  let assert untrusted_wire.CapabilityAnswered(Error(satellite.CapDenial(
    code: "recorded",
    ..,
  ))) = called(stream, binding, 2, program_call("e1"))
  assert process.receive(seen, 2000) == Ok("capability")
  let terms = fixtures.execution_terms()
  let caller =
    agent.Caller(
      strand: terms.strand,
      operation: terms.op_id,
      step_id: fixtures.execution_key("s1", "e1").step,
      source_index: terms.source_index,
      minter: agent.Program(ordinal: 0),
    )
  assert called(stream, binding, 3, untrusted_wire.HoldsCall(caller, "bash"))
    == untrusted_wire.HoldsAnswered(Ok(Nil))
  assert process.receive(seen, 2000) == Ok("holds")

  // Another execution's step, and the live one's under another strand, are
  // not the live program.
  assert denied(called(stream, binding, 4, program_call("e2")))
  let assert untrusted_wire.CapabilityCall(asked) = program_call("e1")
  assert denied(called(
    stream,
    binding,
    5,
    untrusted_wire.CapabilityCall(
      owner_services.OwnerCapCall(..asked, strand: "other"),
    ),
  ))
  assert unseen(seen)

  // The record closes and kills its worker: the start is cancelled at the
  // executor, and the program it named reaches nobody any more.
  process.kill(worker)
  assert rig.next(stream) == Ok(untrusted_codec.CancelEnvelope(id:))
  assert denied(called(stream, binding, 6, program_call("e1")))
  assert unseen(seen)
  stop(rig)
}

pub fn a_program_callback_on_a_forged_replayed_or_retired_binding_is_refused_test() {
  let rig = start("program-binding")
  let #(first_port, first_seen) = recording_port()
  let #(second_port, second_seen) = recording_port()
  let Attached(stream:, binding: old) = attach(rig, "s1", first_port, None)
  let #(_id, _worker, _answers) = start_in_flight(rig, stream, "s1", "e1")

  // A binding the link never minted.
  assert denied(called(stream, <<7:size(128)>>, 1, program_call("e1")))
  assert unseen(first_seen)

  // The binding's first use reaches the owner; the same id again does not.
  let assert untrusted_wire.CapabilityAnswered(Error(satellite.CapDenial(
    code: "recorded",
    ..,
  ))) = called(stream, old, 1, program_call("e1"))
  assert process.receive(first_seen, 2000) == Ok("capability")
  assert denied(called(stream, old, 1, program_call("e1")))
  assert unseen(first_seen)

  // The session opens again with a new owner port: the old binding is
  // retired, and the program, still running, reaches the new port through
  // the new binding.
  let Attached(binding: new, ..) =
    attach(rig, "s1", second_port, option.Some(stream))
  assert new != old
  assert denied(called(stream, old, 2, program_call("e1")))
  assert unseen(first_seen)
  let assert untrusted_wire.CapabilityAnswered(Error(satellite.CapDenial(
    code: "recorded",
    ..,
  ))) = called(stream, new, 1, program_call("e1"))
  assert process.receive(second_seen, 2000) == Ok("capability")
  stop(rig)
}

pub fn a_launch_or_interaction_reaches_the_owner_only_from_its_code_mode_call_test() {
  let rig = start("launch")
  let #(port, seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let terms = fixtures.execution_terms()
  let launch = fn(source_index) {
    untrusted_wire.LaunchExecutionCall(
      owner_services.ExecutionTerms(..terms, source_index:),
    )
  }
  let interact = fn(strand) {
    untrusted_wire.InteractExecutionCall(
      strand:,
      handle: "exec-1",
      interaction: codemode_tool.Check,
      within_ms: 0,
    )
  }

  // Nothing in flight: no record is claimed and no handle is touched.
  let assert untrusted_wire.LaunchAnswered(Error(_refused)) =
    called(stream, binding, 1, launch(0))
  let assert untrusted_wire.InteractAnswered(Error(_refused)) =
    called(stream, binding, 2, interact("main"))
  assert unseen(seen)

  // A `bash` call at the launch's coordinates is not a `code_mode` call.
  let #(_bash, _asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let assert untrusted_wire.LaunchAnswered(Error(_refused)) =
    called(stream, binding, 3, launch(0))
  let assert untrusted_wire.InteractAnswered(Error(_refused)) =
    called(stream, binding, 4, interact("main"))
  assert unseen(seen)

  // A `code_mode` call in flight claims only at its own coordinates, and
  // interacts only as its own strand.
  let #(_code_mode, _asker, _answers) =
    run_in_flight(rig, stream, "s1", code_mode_run("call_2", 1))
  let assert untrusted_wire.LaunchAnswered(Error(_refused)) =
    called(stream, binding, 5, launch(0))
  let assert untrusted_wire.InteractAnswered(Error(_refused)) =
    called(stream, binding, 6, interact("other"))
  assert unseen(seen)
  assert called(stream, binding, 7, launch(1))
    == untrusted_wire.LaunchAnswered(Ok(json.String("exec-1")))
  assert process.receive(seen, 2000) == Ok("launch")
  assert called(stream, binding, 8, interact("main"))
    == untrusted_wire.InteractAnswered(Ok(json.String("running")))
  assert process.receive(seen, 2000) == Ok("interact")
  stop(rig)
}

pub fn a_run_answer_to_a_start_closes_and_the_start_is_sent_again_test() {
  let rig = start("start-wrong-kind")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _worker, answers) = start_in_flight(rig, stream, "s1", "e1")

  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.RunAnswered(protocol.RunLost),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  assert process.receive(answers, 300) == Error(Nil)

  // The start is still the worker's, so the next connection carries it.
  let again = rig.greeted(rig.listener)
  read_attach(again)
  assert read_start(again) == #(id, fixtures.execution_key("s1", "e1"))
  stop(rig)
}

pub fn a_start_answered_after_a_reconnect_reaches_its_worker_once_test() {
  let rig = start("start-reconnect")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _worker, answers) = start_in_flight(rig, stream, "s1", "e1")

  // The connection drops while the program runs: a partition, not a cancel.
  ffi_tls_stream.close(stream)
  let again = rig.greeted(rig.listener)
  read_attach(again)
  assert read_start(again) == #(id, fixtures.execution_key("s1", "e1"))
  assert process.receive(answers, 300) == Error(Nil)

  // The re-sent start is answered from the executor's ledger, and a second
  // answer for the same id is dropped: the worker hears the value once.
  let value = json.Object([#("status", json.String("ok"))])
  let response =
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ExecutionAnswered(protocol.ExecutionFinished(
        value,
      )),
    )
  rig.send(again, response)
  assert process.receive(answers, 5000) == Ok(protocol.ExecutionFinished(value))
  rig.send(again, response)
  assert process.receive(answers, 300) == Error(Nil)

  // The late duplicate did not close the connection: the next frame the link
  // writes still arrives on it. Reading a frame, rather than waiting for a
  // silence, leaves the socket unarmed, so its close when the link stops is
  // not a message the next test in this process would read.
  let key = fixtures.execution_key("s1", "e1")
  address.deliver(rig.address, protocol.StopExecution(key:, incarnation: 0))
  let assert Ok(untrusted_codec.RequestEnvelope(..)) = rig.next(again)
    as "the connection still carries frames"
  stop(rig)
}

pub fn a_start_resent_after_a_drop_is_cancelled_on_the_new_connection_test() {
  let rig = start("start-cancel")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, worker, _answers) = start_in_flight(rig, stream, "s1", "e1")

  ffi_tls_stream.close(stream)
  let again = rig.greeted(rig.listener)
  read_attach(again)
  assert read_start(again) == #(id, fixtures.execution_key("s1", "e1"))

  // The record closes after the reconnect: the cancel names the start's id on
  // the connection that carries it now.
  process.kill(worker)
  assert rig.next(again) == Ok(untrusted_codec.CancelEnvelope(id:))
  stop(rig)
}
