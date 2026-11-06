//// The orchestrator's link against a hostile executor (protocol-change/109).
////
//// Each test runs the real link over a real TLS connection and plays the
//// executor by hand, so the executor can do what an honest gateway never
//// would: forge a binding, replay a callback id, ask about a call that is not
//// in flight or describe one with other arguments, call back for another
//// session, answer a request it was never sent or with the wrong kind, and
//// send bytes that are not a frame. The owner port records everything that
//// reaches it, so "refused" means the owner never saw it.

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
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import telemetry/log
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
      let assert Ok(answer) = process.receive(reply, 10_000)
        as "the run is answered"
      process.send(answers, answer)
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
  assert process.receive(answers, 300) == Error(Nil)
  stop(rig)
}

pub fn a_malformed_frame_closes_the_connection_test() {
  let rig = start("malformed")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send_raw(stream, <<"{\"frame\": \"response\", \"id\": ":utf8>>)
  assert rig.closed(stream, 5000)
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
  stop(rig)
}

pub fn an_oversized_frame_closes_the_connection_test() {
  let rig = start("oversized")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send_raw(stream, bit_array_of(untrusted_wire.max_frame_bytes + 1))
  assert rig.closed(stream, 10_000)
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
  assert unseen(seen)

  // In flight, the same tail is delivered.
  let #(_id, _asker, _answers) = run_in_flight(rig, stream, "s1", run)
  rig.send(
    stream,
    untrusted_wire.Callback(
      binding:,
      id: 2,
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
  assert process.receive(reply, 300) == Error(Nil)
  process.kill(link)
  ffi_tls_stream.close_listener(listener)
}
