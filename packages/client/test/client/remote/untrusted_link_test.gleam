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
import client/remote/blob_transfer
import client/remote/outcome_fetch
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_bridge
import client/remote/untrusted_codec
import client/remote/untrusted_link
import client/remote/untrusted_wire
import codemode/satellite
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import runtime/effects.{type ToolRun}
import simplifile
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import telemetry/log
import tools/tool

type Rig {
  Rig(
    listener: Listener,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    link: process.Pid,
    blobs: Subject(untrusted_bridge.BlobAsk),
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
  let assert Ok(started) =
    untrusted_link.start_placing(untrusted_link.Config(
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
  process.unlink(started.pid)
  Rig(
    listener:,
    address: untrusted_link.address(name),
    link: started.pid,
    blobs: started.blobs,
  )
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.link)
  ffi_tls_stream.close_listener(rig.listener)
  rig.flush()
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

// --- outcomes fetched in pieces (protocol-change/110) ----------------------------

/// An outcome whose encoding is larger than one piece.
fn large_outcome() -> effects.ToolOutcome {
  effects.ToolFailed(reason: string.repeat("x", 20_000_000))
}

/// What the executor declares for an outcome, and the bytes it cuts pieces
/// from.
fn encoding_of(outcome: effects.ToolOutcome) -> #(BitArray, Int, String) {
  let bytes = untrusted_codec.encode_outcome_bytes(outcome)
  #(bytes, bit_array.byte_size(bytes), blob_transfer.digest_of(bytes))
}

/// Reads the next frame as an outcome piece request, answering its id and
/// offset.
fn piece_request(stream: Stream) -> #(Int, Int) {
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "a piece is asked for"
  let assert Ok(untrusted_wire.OutcomePieceRequest(offset:, ..)) =
    untrusted_codec.decode_request(body)
    as "it is an outcome piece request"
  #(id, offset)
}

/// Serves the piece at `offset` of `bytes`, as an honest executor would.
fn serve_piece(
  stream: Stream,
  id: Int,
  bytes: BitArray,
  size: Int,
  digest: String,
  offset: Int,
) -> Nil {
  let length = int.min(untrusted_wire.max_piece_bytes, size - offset)
  let assert Ok(cut) = bit_array.slice(bytes, offset, length)
    as "the piece is inside the outcome"
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.OutcomePieceAnswered(
        untrusted_wire.OutcomeServed(size:, digest:, offset:, bytes: cut),
      ),
    ),
  )
}

pub fn an_oversized_outcome_is_fetched_in_pieces_and_delivered_test() {
  let rig = start("fetch")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let outcome = large_outcome()
  let #(bytes, size, digest) = encoding_of(outcome)

  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  let #(first, at) = piece_request(stream)
  assert at == 0
  serve_piece(stream, first, bytes, size, digest, 0)
  let #(second, at) = piece_request(stream)
  assert at == untrusted_wire.max_piece_bytes
  serve_piece(stream, second, bytes, size, digest, at)

  assert process.receive(answers, 10_000) == Ok(protocol.RunFinished(outcome))
  stop(rig)
}

pub fn an_outcome_whose_bytes_never_match_its_digest_is_lost_test() {
  let rig = start("wrong-digest")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(bytes, size, _digest) = encoding_of(effects.ToolFailed(reason: "no"))
  let lie = blob_transfer.digest_of(<<"something else">>)

  // Every fetch gets the whole outcome under a digest it does not have. The
  // link starts over a bounded number of times and then answers the asker
  // with the lost form, never with the bytes.
  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest: lie))
  list.each(list.repeat(Nil, outcome_fetch.max_restarts + 1), fn(_attempt) {
    let #(piece, at) = piece_request(stream)
    assert at == 0
    serve_piece(stream, piece, bytes, size, lie, 0)
  })

  assert process.receive(answers, 5000) == Ok(protocol.RunLost)
  assert process.is_alive(rig.link)
  stop(rig)
}

pub fn an_outcome_piece_that_runs_past_its_size_is_lost_test() {
  let rig = start("past-size")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(bytes, size, digest) = encoding_of(effects.ToolFailed(reason: "no"))

  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  let #(piece, _at) = piece_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: piece,
      response: untrusted_wire.OutcomePieceAnswered(
        untrusted_wire.OutcomeServed(
          size:,
          digest:,
          offset: 0,
          bytes: bit_array.append(bytes, <<"more">>),
        ),
      ),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.RunLost)
  stop(rig)
}

pub fn an_outcome_over_the_links_bound_is_lost_without_a_fetch_test() {
  let rig = start("too-large")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))

  rig.send(
    stream,
    untrusted_wire.Oversized(
      id:,
      size: untrusted_wire.max_outcome_bytes + 1,
      digest: blob_transfer.digest_of(<<"x">>),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.RunLost)
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

pub fn an_oversized_reply_to_no_request_closes_the_connection_test() {
  let rig = start("unrequested-oversized")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send(
    stream,
    untrusted_wire.Oversized(
      id: 999,
      size: 64,
      digest: blob_transfer.digest_of(<<"x">>),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  stop(rig)
}

pub fn an_outcome_piece_nobody_asked_for_closes_the_connection_test() {
  let rig = start("unrequested-piece")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(bytes, size, digest) = encoding_of(effects.ToolFailed(reason: "no"))

  // A piece for the run's own id, which is not a piece request, does not
  // decode as the run's reply; one for an id never minted is a violation.
  serve_piece(stream, 999, bytes, size, digest, 0)
  assert rig.closed(stream, 5000)
  assert process.receive(answers, 300) == Error(Nil)

  // The run is still outstanding and is sent again on the next connection.
  let again = rig.greeted(rig.listener)
  let assert Ok(untrusted_codec.RequestEnvelope(..)) = rig.next(again)
    as "the attach is sent again"
  let assert Ok(untrusted_codec.RequestEnvelope(id: resent, ..)) =
    rig.next(again)
    as "the run is sent again"
  assert resent == id
  stop(rig)
}

pub fn a_replayed_oversized_does_not_ask_twice_test() {
  let rig = start("replayed-oversized")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let outcome = effects.ToolFailed(reason: "no")
  let #(bytes, size, digest) = encoding_of(outcome)

  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  let #(piece, _at) = piece_request(stream)
  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  assert rig.next_raw(stream, 300) == Error("silent")

  serve_piece(stream, piece, bytes, size, digest, 0)
  assert process.receive(answers, 5000) == Ok(protocol.RunFinished(outcome))
  stop(rig)
}

pub fn a_fetch_resumes_after_a_reconnect_and_a_cancel_reaches_both_ids_test() {
  let rig = start("fetch-reconnect")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(bytes, size, digest) = encoding_of(large_outcome())

  // The first piece arrives, the second is asked for, and the connection
  // drops before it is served.
  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  let #(first, _at) = piece_request(stream)
  serve_piece(stream, first, bytes, size, digest, 0)
  let #(_second, at) = piece_request(stream)
  assert at == untrusted_wire.max_piece_bytes
  ffi_tls_stream.close(stream)

  // The run is sent again, the executor says oversized again, and the fetch
  // asks for the piece it was missing rather than starting over.
  let again = rig.greeted(rig.listener)
  let assert Ok(untrusted_codec.RequestEnvelope(..)) = rig.next(again)
    as "the attach is sent again"
  let assert Ok(untrusted_codec.RequestEnvelope(id: resent, ..)) =
    rig.next(again)
    as "the run is sent again"
  assert resent == id
  rig.send(again, untrusted_wire.Oversized(id:, size:, digest:))
  let #(third, at) = piece_request(again)
  assert at == untrusted_wire.max_piece_bytes

  // The asker dies: the run and the piece in flight are both cancelled.
  process.kill(asker)
  let assert Ok(untrusted_codec.CancelEnvelope(id: cancelled)) = rig.next(again)
    as "the run is cancelled"
  assert cancelled == id
  let assert Ok(untrusted_codec.CancelEnvelope(id: cancelled)) = rig.next(again)
    as "the piece is cancelled"
  assert cancelled == third
  stop(rig)
}

// --- placed blobs (protocol-change/110) ----------------------------------------

/// A file of `size` bytes in a scratch directory, and its description.
fn blob_file(label: String, size: Int) -> #(String, blob_transfer.Blob) {
  let path = fixtures.scratch("untrusted-blob-" <> label) <> "/blob.bin"
  let assert Ok(Nil) = simplifile.write_bits(path, bit_array_of(size))
    as "the blob is written"
  let assert Ok(blob) = blob_transfer.describe(path) as "the blob is described"
  #(path, blob)
}

/// Places a blob from a process of its own and reports how the placement
/// ended.
fn placing(
  rig: Rig,
  session: String,
  path: String,
  blob: blob_transfer.Blob,
) -> Subject(Result(blob_transfer.Placed, blob_transfer.Failure)) {
  let ended = process.new_subject()
  let link = untrusted_link.blob_link(rig.blobs, session, 5000)
  process.spawn_unlinked(fn() {
    process.send(ended, blob_transfer.place(path, blob, link))
  })
  ended
}

/// Reads the next frame as a blob request.
fn blob_request(stream: Stream) -> #(Int, untrusted_wire.Request) {
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "a blob request arrives"
  let assert Ok(request) = untrusted_codec.decode_request(body) as "it decodes"
  #(id, request)
}

pub fn a_blob_is_placed_in_pieces_under_the_sessions_binding_test() {
  let rig = start("blob")
  let #(port, _seen) = recording_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let #(path, blob) = blob_file("placed", blob_transfer.piece_bytes + 10)
  let ended = placing(rig, "s1", path, blob)

  let #(status, request) = blob_request(stream)
  assert request
    == untrusted_wire.BlobStatusRequest(binding:, digest: blob.digest)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: status,
      response: untrusted_wire.BlobStatusAnswered(Ok(blob_transfer.Absent)),
    ),
  )
  let #(first, request) = blob_request(stream)
  let assert untrusted_wire.BlobPutRequest(binding: named, piece:) = request
  assert named == binding
  assert piece.offset == 0
  assert bit_array.byte_size(piece.bytes) == blob_transfer.piece_bytes
  rig.send(
    stream,
    untrusted_wire.Response(
      id: first,
      response: untrusted_wire.BlobPutAnswered(blob_transfer.Accepted(
        held: blob_transfer.piece_bytes,
      )),
    ),
  )
  let #(second, request) = blob_request(stream)
  let assert untrusted_wire.BlobPutRequest(piece:, ..) = request
  assert piece.offset == blob_transfer.piece_bytes
  assert bit_array.byte_size(piece.bytes) == 10
  rig.send(
    stream,
    untrusted_wire.Response(
      id: second,
      response: untrusted_wire.BlobPutAnswered(blob_transfer.Stored),
    ),
  )

  assert process.receive(ended, 5000)
    == Ok(Ok(blob_transfer.Placed(blob:, sent: 2)))
  stop(rig)
}

pub fn a_blob_the_executor_holds_is_placed_with_no_bytes_test() {
  let rig = start("blob-held")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(path, blob) = blob_file("held", 64)
  let ended = placing(rig, "s1", path, blob)

  let #(status, _request) = blob_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: status,
      response: untrusted_wire.BlobStatusAnswered(Ok(blob_transfer.Complete)),
    ),
  )
  assert process.receive(ended, 5000)
    == Ok(Ok(blob_transfer.Placed(blob:, sent: 0)))
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

pub fn an_executor_that_keeps_correcting_the_offset_stalls_the_placement_test() {
  let rig = start("blob-backwards")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(path, blob) = blob_file("backwards", 64)
  let ended = placing(rig, "s1", path, blob)

  let #(status, _request) = blob_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: status,
      response: untrusted_wire.BlobStatusAnswered(Ok(blob_transfer.Absent)),
    ),
  )

  // The executor answers every piece by sending the sender backwards. The
  // placement follows a bounded number of corrections and stops.
  let stalled = bounce(stream, ended, 0)
  assert stalled == Error(blob_transfer.Stalled)
  assert process.is_alive(rig.link)
  stop(rig)
}

/// Answers each piece with an out-of-order verdict until the placement ends.
fn bounce(
  stream: Stream,
  ended: Subject(Result(blob_transfer.Placed, blob_transfer.Failure)),
  answered: Int,
) -> Result(blob_transfer.Placed, blob_transfer.Failure) {
  assert answered <= blob_transfer.max_resyncs + 2
  case process.receive(ended, 0) {
    Ok(result) -> result
    Error(Nil) ->
      case rig.next(stream) {
        Ok(untrusted_codec.RequestEnvelope(id:, ..)) -> {
          rig.send(
            stream,
            untrusted_wire.Response(
              id:,
              response: untrusted_wire.BlobPutAnswered(blob_transfer.OutOfOrder(
                expected: 0,
              )),
            ),
          )
          bounce(stream, ended, answered + 1)
        }
        _other -> {
          let assert Ok(result) = process.receive(ended, 5000)
            as "the placement ends"
          result
        }
      }
  }
}

pub fn an_offset_outside_the_blob_ends_the_placement_test() {
  let rig = start("blob-outside")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(path, blob) = blob_file("outside", 64)
  let ended = placing(rig, "s1", path, blob)

  let #(status, _request) = blob_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: status,
      response: untrusted_wire.BlobStatusAnswered(Ok(blob_transfer.Absent)),
    ),
  )
  let #(put, _request) = blob_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id: put,
      response: untrusted_wire.BlobPutAnswered(blob_transfer.OutOfOrder(
        expected: 1_000_000,
      )),
    ),
  )
  let assert Ok(Error(blob_transfer.Faulted(_reason))) =
    process.receive(ended, 5000)
    as "the placement refuses to read outside the blob"
  stop(rig)
}

pub fn a_blob_for_a_session_with_no_binding_is_refused_at_once_test() {
  let rig = start("blob-unbound")
  let #(path, blob) = blob_file("unbound", 64)
  let ended = placing(rig, "nobody", path, blob)
  let assert Ok(Error(blob_transfer.Declined(_reason))) =
    process.receive(ended, 5000)
    as "a session the link never attached has nowhere to place a blob"
  stop(rig)
}
